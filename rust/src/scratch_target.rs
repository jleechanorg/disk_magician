//! Bounded apply orchestration for one digest-bound Scratch manifest.

use crate::scratch_recovery::{self, RecoveryHint};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

// Match the existing quarantine actuator's 256 MiB manifest limit.
const MAX_MANIFEST_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, Deserialize)]
struct Manifest {
    version: u8,
    root: Root,
    entries: Vec<Entry>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
struct Root {
    path: PathBuf,
    dev: u64,
    ino: u64,
}

#[derive(Clone, Debug, Deserialize)]
struct Entry {
    path: String,
    kind: String,
    dev: Option<u64>,
    ino: Option<u64>,
    size: Option<u64>,
    mtime_ns: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Receipt {
    pub path: String,
    pub result: String,
    pub used_before_bytes: u64,
    pub used_after_bytes: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ResumeState {
    version: u8,
    manifest_sha256: String,
    target_used_bytes: u64,
    root: Root,
    filesystem_id: String,
    pending_paths: VecDeque<String>,
    receipts: Vec<Receipt>,
    status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    in_flight_quarantine_id: Option<String>,
    used_before_bytes: Option<u64>,
    used_after_bytes: Option<u64>,
}

#[derive(Serialize)]
pub struct Report {
    pub status: String,
    pub complete: bool,
    pub target_reached: bool,
    pub target_used_bytes: u64,
    pub used_before_bytes: Option<u64>,
    pub used_after_bytes: Option<u64>,
    pub pending_paths: Vec<String>,
    pub receipts: Vec<Receipt>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery: Option<RecoveryHint>,
}

fn read_manifest(path: &Path, digest: &str) -> io::Result<Manifest> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::other("manifest must be a regular file"));
    }
    if metadata.len() > MAX_MANIFEST_BYTES {
        return Err(io::Error::other("manifest exceeds the actuator size limit"));
    }
    // Hash and parse the same bytes, even if the path is replaced after open.
    let mut bytes = Vec::new();
    file.take(MAX_MANIFEST_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_MANIFEST_BYTES {
        return Err(io::Error::other("manifest exceeds the actuator size limit"));
    }
    if format!("{:x}", Sha256::digest(&bytes)) != digest {
        return Err(io::Error::other("manifest digest mismatch"));
    }
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if manifest.version != 1 {
        return Err(io::Error::other("unsupported manifest version"));
    }
    Ok(manifest)
}

fn mounted_usage(root: &Root, filesystem_id: Option<&str>) -> io::Result<(String, u64)> {
    #[cfg(target_os = "linux")]
    {
        crate::volume_linux::mounted_usage(&root.path, root.dev, root.ino, filesystem_id)
    }
    #[cfg(target_os = "macos")]
    {
        crate::volume_macos::mounted_usage(&root.path, root.dev, root.ino, filesystem_id)
    }
}

fn write_state(path: &Path, state: &ResumeState) -> io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    if fs::canonicalize(parent)? != parent {
        return Err(io::Error::other("resume-state parent must be canonical"));
    }
    if fs::symlink_metadata(path).is_ok_and(|meta| !meta.is_file()) {
        return Err(io::Error::other("resume state must be a regular file"));
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let temp = parent.join(format!(
        ".scratch-target-{}-{nonce}.tmp",
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temp)?;
    serde_json::to_writer(&mut file, state).map_err(io::Error::other)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temp, path)?;
    File::open(parent)?.sync_all()
}

pub fn apply(
    manifest_path: &Path,
    digest: &str,
    resume_path: &Path,
    target_used_bytes: u64,
    selected_paths: &[String],
    all_entries: bool,
    ack_restored: Option<&str>,
) -> io::Result<Report> {
    if target_used_bytes == 0 {
        return Err(io::Error::other("target used bytes must be positive"));
    }
    let resume_parent = resume_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let resume_name = resume_path
        .file_name()
        .ok_or_else(|| io::Error::other("resume state needs a filename"))?;
    let canonical_resume = fs::canonicalize(resume_parent)?.join(resume_name);
    let resume_path = canonical_resume.as_path();
    let manifest = read_manifest(manifest_path, digest)?;
    if resume_path.starts_with(&manifest.root.path) {
        return Err(io::Error::other("resume state must be outside Scratch"));
    }
    if fs::canonicalize(manifest_path)?.as_path() == resume_path {
        return Err(io::Error::other("resume state cannot replace the manifest"));
    }
    let existing_state = if resume_path.exists() {
        let meta = fs::symlink_metadata(resume_path)?;
        if !meta.is_file() {
            return Err(io::Error::other("resume state must be a regular file"));
        }
        let state: ResumeState =
            serde_json::from_slice(&fs::read(resume_path)?).map_err(io::Error::other)?;
        if state.version != 1
            || state.manifest_sha256 != digest
            || state.target_used_bytes != target_used_bytes
            || state.root != manifest.root
        {
            return Err(io::Error::other("resume state identity mismatch"));
        }
        Some(state)
    } else {
        None
    };
    if existing_state.is_some() && (all_entries || !selected_paths.is_empty()) {
        return Err(io::Error::other(
            "resume uses the persisted exact selection",
        ));
    }
    if let Some(path) = ack_restored {
        if all_entries || !selected_paths.is_empty() {
            return Err(io::Error::other(
                "restored acknowledgment cannot select candidates",
            ));
        }
        let state = existing_state
            .ok_or_else(|| io::Error::other("restored acknowledgment needs a saved checkpoint"))?;
        if state.status.strip_prefix("applying:") != Some(path)
            || state.pending_paths.front().map(String::as_str) != Some(path)
        {
            return Err(io::Error::other(
                "restored path must match the in-flight entry",
            ));
        }
        return acknowledge_restored(state, &manifest.entries, path, resume_path);
    }
    if let Some(state) = existing_state.as_ref() {
        if state.status.starts_with("applying:") {
            return Ok(report_recovery_required(state, &manifest.entries));
        }
    }
    let initial_paths = if existing_state.is_none() {
        Some(selected_manifest_paths(
            &manifest,
            selected_paths,
            all_entries,
        )?)
    } else {
        None
    };
    let measured = mounted_usage(
        &manifest.root,
        existing_state
            .as_ref()
            .map(|state| state.filesystem_id.as_str())
            .filter(|id| !id.is_empty()),
    );
    let (filesystem_id, start_used) = match measured {
        Ok(usage) => usage,
        Err(error) => {
            if let Some(mut state) = existing_state {
                state.status = format!("deferred:{}", error);
                state.used_after_bytes = None;
                write_state(resume_path, &state)?;
                return Ok(report(state));
            }
            let state = ResumeState {
                version: 1,
                manifest_sha256: digest.to_owned(),
                target_used_bytes,
                root: manifest.root,
                filesystem_id: String::new(),
                pending_paths: initial_paths.unwrap_or_default().into(),
                receipts: Vec::new(),
                status: format!("deferred:{}", error),
                in_flight_quarantine_id: None,
                used_before_bytes: None,
                used_after_bytes: None,
            };
            write_state(resume_path, &state)?;
            return Ok(report(state));
        }
    };
    let mut state = if let Some(state) = existing_state {
        if !state.filesystem_id.is_empty() && state.filesystem_id != filesystem_id {
            return Err(io::Error::other("resume Scratch identity changed"));
        }
        let mut state = state;
        state.filesystem_id = filesystem_id;
        if state.used_before_bytes.is_none() {
            state.used_before_bytes = Some(start_used);
        }
        state
    } else {
        let paths = initial_paths.unwrap_or_default();
        ResumeState {
            version: 1,
            manifest_sha256: digest.to_owned(),
            target_used_bytes,
            root: manifest.root,
            filesystem_id,
            pending_paths: paths.into(),
            receipts: Vec::new(),
            status: "in_progress".into(),
            in_flight_quarantine_id: None,
            used_before_bytes: Some(start_used),
            used_after_bytes: Some(start_used),
        }
    };

    if state
        .receipts
        .last()
        .is_some_and(|receipt| receipt.used_after_bytes.is_none())
    {
        if let Some(receipt) = state.receipts.last_mut() {
            receipt.used_after_bytes = Some(start_used);
        }
        state.used_after_bytes = Some(start_used);
        state.status = if start_used <= target_used_bytes {
            "target_reached".into()
        } else if state.pending_paths.is_empty() {
            "queue_exhausted".into()
        } else {
            "in_progress".into()
        };
        write_state(resume_path, &state)?;
    }
    if !state.pending_paths.is_empty() {
        state.status = if start_used <= target_used_bytes {
            "target_reached"
        } else {
            "deferred:native-actuator-unavailable"
        }
        .into();
        state.used_after_bytes = Some(start_used);
        write_state(resume_path, &state)?;
    }
    Ok(report(state))
}

fn selected_manifest_paths(
    manifest: &Manifest,
    selected: &[String],
    all_entries: bool,
) -> io::Result<Vec<String>> {
    let paths: Vec<String> = if all_entries {
        if !selected.is_empty() {
            return Err(io::Error::other("--all cannot be combined with --path"));
        }
        manifest
            .entries
            .iter()
            .map(|entry| entry.path.clone())
            .collect()
    } else {
        selected.to_vec()
    };
    let mut manifest_paths = std::collections::HashMap::new();
    for entry in &manifest.entries {
        if manifest_paths
            .insert(entry.path.as_str(), entry.kind.as_str())
            .is_some()
        {
            return Err(io::Error::other("duplicate manifest entry"));
        }
    }
    if paths.is_empty()
        || paths.iter().collect::<std::collections::HashSet<_>>().len() != paths.len()
        || paths.iter().any(|path| {
            !matches!(
                manifest_paths.get(path.as_str()).copied(),
                Some("regular_file" | "managed_run")
            )
        })
    {
        return Err(io::Error::other(
            "select unique paths present in the manifest",
        ));
    }
    Ok(paths)
}

fn restored_entry_metadata(root: &Root, relative: &str) -> io::Result<fs::Metadata> {
    let components: Vec<_> = Path::new(relative).components().collect();
    if components.is_empty()
        || !components
            .iter()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
    {
        return Err(io::Error::other("invalid restored manifest path"));
    }
    let root_metadata = fs::symlink_metadata(&root.path)?;
    if !root_metadata.is_dir() || root_metadata.dev() != root.dev || root_metadata.ino() != root.ino
    {
        return Err(io::Error::other("Scratch root identity changed"));
    }
    let mut path = root.path.clone();
    let mut result = None;
    for (index, component) in components.iter().enumerate() {
        path.push(component.as_os_str());
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() || metadata.dev() != root.dev {
            return Err(io::Error::other(
                "restored path crossed a symlink or filesystem boundary",
            ));
        }
        if index + 1 < components.len() && !metadata.is_dir() {
            return Err(io::Error::other(
                "restored path has a non-directory ancestor",
            ));
        }
        result = Some(metadata);
    }
    result.ok_or_else(|| io::Error::other("restored path is empty"))
}

fn acknowledge_restored(
    mut state: ResumeState,
    entries: &[Entry],
    relative: &str,
    resume_path: &Path,
) -> io::Result<Report> {
    let relative_path = Path::new(relative);
    if relative.is_empty()
        || !relative_path
            .components()
            .all(|part| matches!(part, std::path::Component::Normal(_)))
    {
        return Err(io::Error::other("invalid restored manifest path"));
    }
    let entry = entries
        .iter()
        .find(|entry| entry.path == relative)
        .ok_or_else(|| io::Error::other("restored path is missing from the manifest"))?;
    let identity = entry
        .dev
        .zip(entry.ino)
        .filter(|(dev, _)| *dev == state.root.dev)
        .ok_or_else(|| io::Error::other("restored entry identity unavailable"))?;
    let (filesystem_id, used) = mounted_usage(&state.root, Some(state.filesystem_id.as_str()))?;
    let path = state.root.path.join(relative_path);
    if !scratch_recovery::restore_is_settled(&path, identity)? {
        return Err(io::Error::other("quarantine recovery is still unresolved"));
    }
    let metadata = restored_entry_metadata(&state.root, relative)?;
    let expected_type = match entry.kind.as_str() {
        "regular_file" => metadata.is_file(),
        "managed_run" => metadata.is_dir(),
        _ => false,
    };
    let modified = i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec());
    if !expected_type
        || (metadata.dev(), metadata.ino()) != identity
        || entry.size != Some(metadata.size())
        || entry.mtime_ns.map(i128::from) != Some(modified)
    {
        return Err(io::Error::other(
            "restored path differs from the nominated entry",
        ));
    }
    let used_before = state
        .used_after_bytes
        .or(state.used_before_bytes)
        .unwrap_or(used);
    state.filesystem_id = filesystem_id;
    state.used_after_bytes = Some(used);
    state.pending_paths.pop_front();
    state.in_flight_quarantine_id = None;
    state.receipts.push(Receipt {
        path: relative.to_owned(),
        result: "kept:restored".into(),
        used_before_bytes: used_before,
        used_after_bytes: Some(used),
    });
    state.status = if used <= state.target_used_bytes {
        "target_reached"
    } else if state.pending_paths.is_empty() {
        "queue_exhausted"
    } else {
        "in_progress"
    }
    .into();
    write_state(resume_path, &state)?;
    Ok(report(state))
}

fn report(state: ResumeState) -> Report {
    let target_reached = state.status == "target_reached";
    let complete = target_reached || state.status == "queue_exhausted";
    Report {
        status: state.status,
        complete,
        target_reached,
        target_used_bytes: state.target_used_bytes,
        used_before_bytes: state.used_before_bytes,
        used_after_bytes: state.used_after_bytes,
        pending_paths: state.pending_paths.into_iter().collect(),
        receipts: state.receipts,
        recovery: None,
    }
}

fn report_recovery_required(state: &ResumeState, entries: &[Entry]) -> Report {
    let recovery = state.pending_paths.front().map(|path| {
        let identity = entries
            .iter()
            .find(|entry| &entry.path == path)
            .and_then(|entry| entry.dev.zip(entry.ino));
        scratch_recovery::hint(
            &state.root.path,
            path,
            identity,
            state.in_flight_quarantine_id.as_deref(),
        )
    });
    Report {
        status: "recovery_required:check exact in-flight quarantine before resume".into(),
        complete: false,
        target_reached: false,
        target_used_bytes: state.target_used_bytes,
        used_before_bytes: state.used_before_bytes,
        used_after_bytes: state.used_after_bytes,
        pending_paths: state.pending_paths.iter().cloned().collect(),
        receipts: state.receipts.clone(),
        recovery,
    }
}

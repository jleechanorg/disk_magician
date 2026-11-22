//! Bounded apply orchestration for one digest-bound Scratch manifest.

use crate::scratch_file_transaction::{self, FileIdentity, Outcome};
use crate::scratch_lease::{self, BundleKind, FinishOutcome, OwnerProcessState};
use crate::scratch_recovery::{self, RecoveryHint};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

// Match the existing quarantine actuator's 256 MiB manifest limit.
const MAX_MANIFEST_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, Deserialize)]
struct Manifest {
    version: u8,
    root: Root,
    before_epoch_seconds: i64,
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
    ctime_ns: Option<i64>,
}

impl Entry {
    fn file_identity(&self) -> io::Result<FileIdentity> {
        let unavailable = || io::Error::other("manifest lacks exact file identity");
        let modified = self.mtime_ns.ok_or_else(unavailable)?;
        let changed = self.ctime_ns.ok_or_else(unavailable)?;
        Ok(FileIdentity {
            device: self.dev.ok_or_else(unavailable)?,
            inode: self.ino.ok_or_else(unavailable)?,
            size: self.size.ok_or_else(unavailable)?,
            modified_seconds: modified.div_euclid(1_000_000_000),
            modified_nanoseconds: modified.rem_euclid(1_000_000_000),
            changed_seconds: changed.div_euclid(1_000_000_000),
            changed_nanoseconds: changed.rem_euclid(1_000_000_000),
            link_count: 1,
        })
    }
}

pub enum RecoveryAction {
    Acknowledge(String),
    Restore(String),
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_stage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_stage_identity: Option<(u64, u64)>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_recovery_stage: Option<String>,
}

fn read_bounded(path: &Path) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > MAX_MANIFEST_BYTES {
        return Err(io::Error::other(
            "actuator input must be a bounded regular file",
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_MANIFEST_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_MANIFEST_BYTES {
        return Err(io::Error::other("actuator input exceeds the size limit"));
    }
    Ok(bytes)
}

fn read_manifest(path: &Path, digest: &str) -> io::Result<Manifest> {
    // Hash and parse the same bytes, even if the path is replaced after open.
    let bytes = read_bounded(path)?;
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
    if root.path == scratch_lease::temp_path()? {
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&root.path)?;
        let meta = directory.metadata()?;
        let id = format!("system-tmp:{}:{}", root.dev, root.ino);
        if (meta.dev(), meta.ino()) != (root.dev, root.ino)
            || filesystem_id.is_some_and(|value| value != id)
        {
            return Err(io::Error::other("managed temp root identity changed"));
        }
        let mut volume = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        if unsafe { libc::fstatvfs(directory.as_raw_fd(), volume.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let volume = unsafe { volume.assume_init() };
        let bytes =
            volume.f_blocks.saturating_sub(volume.f_bfree) as u128 * volume.f_frsize as u128;
        return Ok((id, u64::try_from(bytes).map_err(io::Error::other)?));
    }
    #[cfg(target_os = "linux")]
    {
        crate::volume_linux::mounted_usage(&root.path, root.dev, root.ino, filesystem_id)
    }
    #[cfg(target_os = "macos")]
    {
        crate::volume_macos::mounted_usage(&root.path, root.dev, root.ino, filesystem_id)
    }
}

pub(crate) fn measure_usage(path: &Path, device: u64) -> io::Result<u64> {
    let root = Root {
        path: path.to_path_buf(),
        dev: device,
        ino: fs::symlink_metadata(path)?.ino(),
    };
    mounted_usage(&root, None).map(|(_, used)| used)
}

pub(crate) fn recover_sweeps(state: &Path, root: &Path) -> io::Result<Vec<serde_json::Value>> {
    use serde_json::json;
    let attempts = match fs::read_dir(state.join("sweeps")) {
        Ok(attempts) => attempts,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut results = Vec::new();
    for attempt in attempts {
        let attempt = attempt?;
        if !attempt.file_type()?.is_dir() {
            continue;
        }
        let path = attempt.path();
        let resume = path.join("resume.json");
        let recover = || -> io::Result<Option<String>> {
            let Some(saved) = read_state(&resume)? else {
                return Ok(None);
            };
            let Some(relative) = saved.status.strip_prefix("applying:") else {
                return Ok(None);
            };
            if saved.root.path != root {
                return Ok(None);
            }
            let pid: libc::pid_t = saved
                .native_stage
                .as_deref()
                .and_then(|stage| stage.strip_prefix(".diskm-remove-")?.split_once('-'))
                .and_then(|(pid, _)| pid.parse().ok())
                .filter(|pid| *pid > 1)
                .ok_or_else(|| io::Error::other("native stage producer identity unavailable"))?;
            if unsafe { libc::kill(pid, 0) } != -1
                || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
            {
                return Ok(None);
            }
            apply(
                &path.join("manifest.json"),
                &saved.manifest_sha256,
                &resume,
                saved.target_used_bytes,
                &[],
                false,
                Some(&RecoveryAction::Restore(relative.into())),
            )?;
            Ok(Some(relative.into()))
        };
        match recover() {
            Ok(Some(restored)) => results.push(json!({"attempt":path,"restored":restored})),
            Ok(None) => {}
            Err(error) => results.push(json!({"attempt":path,"error":error.to_string()})),
        }
    }
    Ok(results)
}

fn read_state(path: &Path) -> io::Result<Option<ResumeState>> {
    let bytes = match read_bounded(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(io::Error::other)
}

fn write_state(path: &Path, state: &ResumeState, create: bool) -> io::Result<()> {
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
    let result = (|| {
        serde_json::to_writer(&mut file, state).map_err(io::Error::other)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        if create {
            fs::hard_link(&temp, path)?;
            fs::remove_file(&temp)?;
        } else {
            fs::rename(&temp, path)?;
        }
        File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

pub fn apply(
    manifest_path: &Path,
    digest: &str,
    resume_path: &Path,
    target_used_bytes: u64,
    selected_paths: &[String],
    all_entries: bool,
    recovery: Option<&RecoveryAction>,
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
    let existing_state = read_state(resume_path)?;
    if let Some(state) = &existing_state {
        if state.version != 1
            || state.manifest_sha256 != digest
            || state.target_used_bytes != target_used_bytes
            || state.root != manifest.root
        {
            return Err(io::Error::other("resume state identity mismatch"));
        }
    }
    let new_checkpoint = existing_state.is_none();
    if existing_state.is_some() && (all_entries || !selected_paths.is_empty()) {
        return Err(io::Error::other(
            "resume uses the persisted exact selection",
        ));
    }
    if let Some(action) = recovery {
        let path = match action {
            RecoveryAction::Acknowledge(path) | RecoveryAction::Restore(path) => path.as_str(),
        };
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
        let captured = if matches!(action, RecoveryAction::Restore(_)) {
            let stage = state
                .native_stage
                .as_deref()
                .ok_or_else(|| io::Error::other("checkpoint has no native recovery stage"))?;
            let entry = manifest
                .entries
                .iter()
                .find(|entry| entry.path == path && entry.kind == "regular_file")
                .ok_or_else(|| io::Error::other("native recovery requires an exact file entry"))?;
            mounted_usage(&state.root, Some(&state.filesystem_id))?;
            scratch_file_transaction::restore_exact(
                &state.root.path,
                state.root.dev,
                state.root.ino,
                Path::new(path),
                entry.file_identity()?,
                OsStr::new(stage),
                state.native_stage_identity,
            )?
        } else {
            None
        };
        return acknowledge_restored(state, &manifest.entries, path, resume_path, captured);
    }
    let existing_state = match existing_state {
        Some(state) if state.status.starts_with("applying:") => {
            return Ok(report_recovery_required(state, &manifest.entries));
        }
        other => other,
    };
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
    let mut state = existing_state.unwrap_or_else(|| ResumeState {
        version: 1,
        manifest_sha256: digest.to_owned(),
        target_used_bytes,
        root: manifest.root,
        filesystem_id: String::new(),
        pending_paths: initial_paths.unwrap_or_default().into(),
        receipts: Vec::new(),
        status: "in_progress".into(),
        in_flight_quarantine_id: None,
        native_stage: None,
        native_stage_identity: None,
        used_before_bytes: None,
        used_after_bytes: None,
    });
    let (filesystem_id, start_used) = match measured {
        Ok(usage) => usage,
        Err(error) => {
            state.status = format!("deferred:{error}");
            state.used_after_bytes = None;
            write_state(resume_path, &state, new_checkpoint)?;
            return Ok(report(state));
        }
    };
    if !state.filesystem_id.is_empty() && state.filesystem_id != filesystem_id {
        return Err(io::Error::other("resume Scratch identity changed"));
    }
    state.filesystem_id = filesystem_id;
    state.used_before_bytes.get_or_insert(start_used);
    if new_checkpoint {
        state.used_after_bytes = Some(start_used);
    }

    if let Some(receipt) = state
        .receipts
        .last_mut()
        .filter(|receipt| receipt.used_after_bytes.is_none())
    {
        receipt.used_after_bytes = Some(start_used);
        state.used_after_bytes = Some(start_used);
        state.status = settled_status(&state, start_used, "in_progress");
        write_state(resume_path, &state, false)?;
    }
    let mut create = new_checkpoint;
    let mut used = start_used;
    let entries: std::collections::HashMap<_, _> = manifest
        .entries
        .iter()
        .map(|entry| (entry.path.as_str(), entry))
        .collect();
    for _ in 0..state.pending_paths.len() {
        if used <= state.target_used_bytes {
            break;
        }
        let Some(path) = state.pending_paths.front().cloned() else {
            break;
        };
        let entry = entries
            .get(path.as_str())
            .ok_or_else(|| io::Error::other("checkpoint path is missing from the manifest"))?;
        let used_before = used;
        let result = match cleanup_policy(&state.root, entry, manifest.before_epoch_seconds) {
            Err(reason) => reason,
            Ok(expected) => {
                let nonce = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(io::Error::other)?
                    .as_nanos();
                let stage = format!(".diskm-remove-{}-{nonce}", std::process::id());
                state.status = format!("applying:{path}");
                state.native_stage = Some(stage.clone());
                state.native_stage_identity = None;
                state.used_after_bytes = Some(used);
                write_state(resume_path, &state, create)?;
                create = false;
                let root = state.root.clone();
                let result = scratch_file_transaction::remove_exact(
                    &root.path,
                    root.dev,
                    root.ino,
                    Path::new(&path),
                    expected,
                    OsStr::new(&stage),
                    |identity| {
                        state.native_stage_identity = Some(identity);
                        write_state(resume_path, &state, false)
                    },
                );
                match result {
                    Ok(Outcome::Removed {
                        parent_synced: true,
                        ..
                    }) => "removed",
                    Ok(Outcome::AlreadyAbsent) => "already-absent",
                    Ok(Outcome::Changed | Outcome::RestoredMismatch) => {
                        "kept:file-identity-changed"
                    }
                    Ok(Outcome::DeferredOpen { .. }) => "deferred:open-file",
                    Ok(Outcome::DeferredCheck { .. }) => "deferred:open-file-check-unavailable",
                    Ok(Outcome::Unsupported { .. }) => "kept:native-file-unsupported",
                    Ok(Outcome::Removed {
                        parent_synced: false,
                        ..
                    })
                    | Ok(Outcome::RecoveryRequired { .. })
                    | Err(_) => return Ok(report_recovery_required(state, &manifest.entries)),
                }
            }
        };
        state.native_stage = None;
        state.native_stage_identity = None;
        state.pending_paths.pop_front();
        if result.starts_with("deferred:") {
            state.pending_paths.push_back(path.clone());
        }
        state.receipts.push(Receipt {
            path,
            result: result.into(),
            used_before_bytes: used_before,
            used_after_bytes: None,
        });
        state.status = "receipt_pending_usage".into();
        write_state(resume_path, &state, create)?;
        create = false;
        if result == "removed" {
            match mounted_usage(&state.root, Some(&state.filesystem_id)) {
                Ok((_, measured)) => used = measured,
                Err(error) => {
                    state.status = format!("deferred:{error}");
                    state.used_after_bytes = None;
                    write_state(resume_path, &state, false)?;
                    return Ok(report(state));
                }
            }
        }
        if let Some(receipt) = state.receipts.last_mut() {
            receipt.used_after_bytes = Some(used);
        }
    }
    state.used_after_bytes = Some(used);
    state.status = settled_status(&state, used, "deferred:pending-paths");
    write_state(resume_path, &state, create)?;
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
                Some("regular_file" | "managed_run" | "directory")
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
    let root_metadata = fs::symlink_metadata(&root.path)?;
    if !root_metadata.is_dir() || root_metadata.dev() != root.dev || root_metadata.ino() != root.ino
    {
        return Err(io::Error::other("Scratch root identity changed"));
    }
    crate::scratch_manifest::entry_metadata(&root.path, Path::new(relative), root.dev)
}

pub(crate) fn check_build_lease(root: &Path, relative: &Path) -> Result<(), &'static str> {
    let bundle = build_bundle(root, relative)?;
    check_completed_build(root, &bundle)
}

pub(crate) fn build_bundle(root: &Path, relative: &Path) -> Result<PathBuf, &'static str> {
    let parts: Vec<_> = relative.components().collect();
    if let [Component::Normal(name)] = parts.as_slice() {
        if name.as_encoded_bytes().starts_with(b"diskm-temp-")
            && scratch_lease::temp_path().is_ok_and(|temporary| root == temporary)
        {
            return Ok(root.join(name));
        }
    }
    if parts.len() < 5
        || parts[0].as_os_str() != "runs"
        || parts.iter().any(|part| {
            !matches!(part, std::path::Component::Normal(_))
                || part.as_os_str().as_encoded_bytes().starts_with(b".")
                || part.as_os_str() == "evidence"
        })
    {
        return Err("kept:unmanaged-or-protected");
    }
    Ok(root.join(parts[..4].iter().collect::<PathBuf>()))
}

pub(crate) fn check_completed_build(root: &Path, bundle: &Path) -> Result<(), &'static str> {
    let verified = scratch_lease::lookup_bundle_under_root(bundle, root).map_err(|error| {
        match error.kind() {
            io::ErrorKind::NotFound => "kept:lease-missing",
            _ => "deferred:lease-unavailable",
        }
    })?;
    if !matches!(
        verified.lease.kind,
        BundleKind::Build | BundleKind::TempFile
    ) {
        return Err("kept:protected-bundle-kind");
    }
    if !verified
        .finish
        .is_some_and(|finish| finish.outcome == FinishOutcome::Completed)
    {
        return Err("kept:build-not-completed");
    }
    match verified.owner_process_state {
        OwnerProcessState::Live => Err("kept:producer-still-live"),
        OwnerProcessState::Unavailable => Err("deferred:producer-identity-unavailable"),
        OwnerProcessState::Exited | OwnerProcessState::IdentityChanged => Ok(()),
    }
}

fn cleanup_policy(root: &Root, entry: &Entry, cutoff: i64) -> Result<FileIdentity, &'static str> {
    if entry.kind != "regular_file" {
        return Err("kept:native-file-only");
    }
    let relative = Path::new(&entry.path);
    if let Some(reason) =
        crate::preview::check_verdict_path(&root.path, &root.path.join(relative), root.dev)
    {
        return Err(if reason == "missing" {
            "already-absent"
        } else {
            reason
        });
    }
    check_build_lease(&root.path, relative)?;
    let metadata = match restored_entry_metadata(root, &entry.path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Err("already-absent"),
        Err(_) => return Err("deferred:identity-unavailable"),
    };
    let modified = i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec());
    let changed = i128::from(metadata.ctime()) * 1_000_000_000 + i128::from(metadata.ctime_nsec());
    if !metadata.is_file()
        || metadata.nlink() != 1
        || entry.dev != Some(metadata.dev())
        || entry.ino != Some(metadata.ino())
        || entry.size != Some(metadata.size())
        || entry.mtime_ns.map(i128::from) != Some(modified)
        || entry.ctime_ns.map(i128::from) != Some(changed)
    {
        return Err("kept:file-identity-changed");
    }
    if modified >= i128::from(cutoff) * 1_000_000_000 {
        return Err("kept:recent-activity");
    }
    entry
        .file_identity()
        .map_err(|_| "deferred:identity-unavailable")
}

fn acknowledge_restored(
    mut state: ResumeState,
    entries: &[Entry],
    relative: &str,
    resume_path: &Path,
    captured: Option<FileIdentity>,
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
    if let Some(stage) = state.native_stage.as_ref() {
        if !stage.starts_with(".diskm-remove-") || Path::new(stage).components().count() != 1 {
            return Err(io::Error::other("invalid native recovery stage name"));
        }
        let stage_path = path.with_file_name(stage);
        match fs::symlink_metadata(stage_path) {
            Ok(_) => return Err(io::Error::other("native recovery stage is still present")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    } else if !scratch_recovery::restore_is_settled(&path, identity)? {
        return Err(io::Error::other("quarantine recovery is still unresolved"));
    }
    let metadata = restored_entry_metadata(&state.root, relative)?;
    let expected_type = match entry.kind.as_str() {
        "regular_file" => metadata.is_file(),
        "managed_run" => metadata.is_dir(),
        _ => false,
    };
    let modified = i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec());
    let original_matches = expected_type
        && (metadata.dev(), metadata.ino()) == identity
        && entry.size == Some(metadata.size())
        && entry.mtime_ns.map(i128::from) == Some(modified);
    if !original_matches
        && !captured.is_some_and(|file| {
            metadata.is_file() && file.matches_after_rename(FileIdentity::read(&metadata))
        })
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
    state.native_stage = None;
    state.native_stage_identity = None;
    state.receipts.push(Receipt {
        path: relative.to_owned(),
        result: if original_matches {
            "kept:restored"
        } else {
            "kept:restored-replacement"
        }
        .into(),
        used_before_bytes: used_before,
        used_after_bytes: Some(used),
    });
    state.status = settled_status(&state, used, "in_progress");
    write_state(resume_path, &state, false)?;
    Ok(report(state))
}

fn settled_status(state: &ResumeState, used: u64, pending: &str) -> String {
    if used <= state.target_used_bytes {
        "target_reached"
    } else if state.pending_paths.is_empty() {
        "queue_exhausted"
    } else {
        pending
    }
    .into()
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
        native_recovery_stage: state.native_stage,
    }
}

fn report_recovery_required(state: ResumeState, entries: &[Entry]) -> Report {
    let recovery = state
        .pending_paths
        .front()
        .filter(|_| state.native_stage.is_none())
        .map(|path| {
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
    let mut report = report(state);
    report.status = if report.native_recovery_stage.is_some() {
        "recovery_required:check the recorded native stage before resume"
    } else {
        "recovery_required:check exact in-flight quarantine before resume"
    }
    .into();
    report.recovery = recovery;
    report
}

//! Bounded apply orchestration for one digest-bound Scratch manifest.

use crate::scratch_recovery::{self, RecoveryHint};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

// Match the existing quarantine actuator's 256 MiB manifest limit.
const MAX_MANIFEST_BYTES: u64 = 256 * 1024 * 1024;

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;
const F_GETFD: i32 = 1;
const F_SETFD: i32 = 2;
const FD_CLOEXEC: i32 = 1;
#[cfg(target_os = "linux")]
const O_NOFOLLOW: i32 = 0o400000;
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = 0x100;

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
    fn fcntl(fd: i32, command: i32, ...) -> i32;
    fn geteuid() -> u32;
}

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

struct ResumeLock(File);

impl Drop for ResumeLock {
    fn drop(&mut self) {
        // Closing the descriptor also releases the advisory lock on process exit.
        unsafe { flock(self.0.as_raw_fd(), LOCK_UN) };
    }
}

fn acquire_scratch_lock() -> io::Result<ResumeLock> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| io::Error::other("HOME unavailable for Scratch lock"))?;
    let home_meta = fs::symlink_metadata(&home)?;
    if !home_meta.is_dir()
        || home_meta.uid() != unsafe { geteuid() }
        || home_meta.mode() & 0o022 != 0
    {
        return Err(io::Error::other("unsafe HOME for Scratch lock"));
    }
    let lock_dir = home.join(".disk_magician_locks");
    match DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&lock_dir)
    {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let dir_meta = fs::symlink_metadata(&lock_dir)?;
    if !dir_meta.is_dir() || dir_meta.uid() != home_meta.uid() || dir_meta.mode() & 0o077 != 0 {
        return Err(io::Error::other("unsafe Scratch lock directory"));
    }
    let lock_path = lock_dir.join("scratch_cleanup.lock");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW)
        .open(&lock_path)?;
    let metadata = file.metadata()?;
    let current = fs::symlink_metadata(&lock_path)?;
    if !metadata.is_file()
        || metadata.uid() != home_meta.uid()
        || metadata.mode() & 0o077 != 0
        || metadata.dev() != current.dev()
        || metadata.ino() != current.ino()
    {
        return Err(io::Error::other("unsafe Scratch cleanup lock"));
    }
    let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
    if result != 0 {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "Scratch cleanup is already in progress",
        ));
    }
    Ok(ResumeLock(file))
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
    if std::env::var_os(crate::LEGACY_COMPAT_CLI).is_none() {
        return crate::volume_linux::mounted_usage(&root.path, root.dev, root.ino, filesystem_id);
    }
    let output = Command::new(crate::legacy_cli()?)
        .args(["volume", "status", "--snapshot"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("Scratch volume status unavailable"));
    }
    let document: Value = serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    let row = document["volumes"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["class"] == "scratch"))
        .ok_or_else(|| io::Error::other("Scratch status row unavailable"))?;
    let current_path = row["path"]
        .as_str()
        .ok_or_else(|| io::Error::other("Scratch path unavailable"))?;
    let observed_filesystem_id = row["filesystem_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| io::Error::other("Scratch filesystem identity unavailable"))?;
    if Path::new(current_path) != root.path || row["status"] != "active" {
        return Err(io::Error::other("Scratch mount identity changed"));
    }
    if filesystem_id.is_some_and(|expected| expected != observed_filesystem_id) {
        return Err(io::Error::other("Scratch filesystem identity changed"));
    }
    let verify = Command::new(crate::legacy_cli()?)
        .args(["volume", "verify-mount", current_path])
        .output()?;
    if !verify.status.success() {
        return Err(io::Error::other("Scratch mount verification failed"));
    }
    let mounted = fs::symlink_metadata(current_path)?;
    if !mounted.is_dir() || mounted.dev() != root.dev || mounted.ino() != root.ino {
        return Err(io::Error::other("Scratch root identity changed"));
    }
    let used = row["allocated_bytes"]
        .as_u64()
        .ok_or_else(|| io::Error::other("Scratch used-byte measurement unavailable"))?;
    Ok((observed_filesystem_id.to_owned(), used))
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
        .custom_flags(O_NOFOLLOW)
        .open(&temp)?;
    serde_json::to_writer(&mut file, state).map_err(io::Error::other)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temp, path)?;
    File::open(parent)?.sync_all()
}

fn legacy_apply(manifest: &Path, digest: &str, relative: &str, lock_fd: i32) -> io::Result<String> {
    let mut command = Command::new(crate::legacy_cli()?);
    command
        .args(["quarantine", "scratch-apply", "--manifest"])
        .arg(manifest)
        .args(["--manifest-sha256", digest, "--path", relative]);
    // Keep the writer alive across an interrupted parent only in the actuator.
    // Metadata and volume probes have no need to inherit the descriptor.
    unsafe {
        command.pre_exec(move || {
            let flags = fcntl(lock_fd, F_GETFD);
            if flags < 0 || fcntl(lock_fd, F_SETFD, flags & !FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let output = command.output()?;
    if !output.status.success() {
        return Err(io::Error::other("exact manifest apply failed"));
    }
    let report: Value = serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    let rows = report["results"]
        .as_array()
        .ok_or_else(|| io::Error::other("exact manifest apply result missing"))?;
    if rows.len() != 1 || rows[0]["path"] != relative {
        return Err(io::Error::other("exact manifest apply path mismatch"));
    }
    rows[0]["result"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| io::Error::other("exact manifest apply verdict missing"))
}

pub fn apply(
    manifest_path: &Path,
    digest: &str,
    resume_path: &Path,
    target_used_bytes: u64,
    selected_paths: &[String],
    all_entries: bool,
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
    let writer = acquire_scratch_lock();
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
    if let Some(state) = existing_state.as_ref() {
        if state.status.starts_with("applying:") {
            return Ok(report_recovery_required(
                state,
                &manifest.entries,
                writer.is_ok(),
            ));
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
    let lock = match writer {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            if let Some(state) = existing_state.as_ref() {
                return Ok(Report {
                    status: "deferred:scratch-cleanup-in-progress".into(),
                    complete: false,
                    target_reached: false,
                    target_used_bytes,
                    used_before_bytes: state.used_before_bytes,
                    used_after_bytes: state.used_after_bytes,
                    pending_paths: state.pending_paths.iter().cloned().collect(),
                    receipts: state.receipts.clone(),
                    recovery: None,
                });
            }
            return Ok(Report {
                status: "deferred:scratch-cleanup-in-progress".into(),
                complete: false,
                target_reached: false,
                target_used_bytes,
                used_before_bytes: None,
                used_after_bytes: None,
                pending_paths: initial_paths.clone().unwrap_or_default(),
                receipts: Vec::new(),
                recovery: None,
            });
        }
        Err(error) => return Err(error),
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

    let mut current_used = start_used;
    if state
        .receipts
        .last()
        .is_some_and(|receipt| receipt.used_after_bytes.is_none())
    {
        current_used = start_used;
        if let Some(receipt) = state.receipts.last_mut() {
            receipt.used_after_bytes = Some(current_used);
        }
        state.used_after_bytes = Some(current_used);
        state.status = if current_used <= target_used_bytes {
            "target_reached".into()
        } else if state.pending_paths.is_empty() {
            "queue_exhausted".into()
        } else {
            "in_progress".into()
        };
        write_state(resume_path, &state)?;
    }
    while let Some(path) = state.pending_paths.front().cloned() {
        let used_before = current_used;
        if used_before <= target_used_bytes {
            state.status = "target_reached".into();
            state.used_after_bytes = Some(used_before);
            write_state(resume_path, &state)?;
            return Ok(report(state));
        }
        state.status = format!("applying:{path}");
        state.in_flight_quarantine_id = None;
        state.used_after_bytes = Some(used_before);
        write_state(resume_path, &state)?;
        let result = match legacy_apply(manifest_path, digest, &path, lock.0.as_raw_fd()) {
            Ok(result) => result,
            Err(_) => return Ok(report_recovery_required(&state, &manifest.entries, true)),
        };
        if result == "deferred:operation-lock" {
            state.status = result;
            write_state(resume_path, &state)?;
            return Ok(report(state));
        }
        if result.starts_with("deferred:") || result.starts_with("kept:quarantine_partial_kept") {
            if let Some((_, id)) = result.rsplit_once(':') {
                if scratch_recovery::is_quarantine_id(id) {
                    state.in_flight_quarantine_id = Some(id.to_owned());
                    write_state(resume_path, &state)?;
                }
            }
            return Ok(report_recovery_required(&state, &manifest.entries, true));
        }
        state.pending_paths.pop_front();
        state.receipts.push(Receipt {
            path: path.clone(),
            result: result.clone(),
            used_before_bytes: used_before,
            used_after_bytes: None,
        });
        state.status = format!("receipt_pending_usage:{path}");
        write_state(resume_path, &state)?;
        let (after_id, used_after) = match mounted_usage(&state.root, Some(&state.filesystem_id)) {
            Ok(observation) => observation,
            Err(error) => {
                state.status = format!("deferred:{}", error);
                state.used_after_bytes = None;
                write_state(resume_path, &state)?;
                return Ok(report(state));
            }
        };
        if after_id != state.filesystem_id {
            state.status = "deferred:Scratch filesystem identity changed".into();
            write_state(resume_path, &state)?;
            return Ok(report(state));
        }
        current_used = used_after;
        if let Some(receipt) = state.receipts.last_mut() {
            receipt.used_after_bytes = Some(used_after);
        }
        state.used_after_bytes = Some(used_after);
        state.status = if used_after <= target_used_bytes {
            "target_reached".into()
        } else if state.pending_paths.is_empty() {
            "queue_exhausted".into()
        } else {
            "in_progress".into()
        };
        write_state(resume_path, &state)?;
        if state.status == "target_reached" || state.pending_paths.is_empty() {
            break;
        }
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

fn report_recovery_required(
    state: &ResumeState,
    entries: &[Entry],
    writer_available: bool,
) -> Report {
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
            writer_available,
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

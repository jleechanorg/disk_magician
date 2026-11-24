//! Lock-free metadata for managed Scratch bundles.
//! Immutable bundle and finish records let producers operate independently.

use crate::job_receipt::create_once;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::ffi::{OsStr, OsString};
use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::Command;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const RUNS_DIR: &str = "runs";
const RECORDS_DIR: &str = "scratch-runs";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BundleKind {
    Scratch,
    Build,
    Evidence,
    TempFile,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProcessOwner {
    pub pid: u32,
    pub uid: u32,
    /// Linux boot ID, which prevents a PID/start-tick pair surviving reboot.
    /// macOS uses the absolute process start string as its available identity.
    pub host_boot_id: Option<String>,
    pub started: String,
    pub command: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BundleLease {
    pub schema_version: u8,
    pub bundle_id: String,
    pub kind: BundleKind,
    pub filepath: PathBuf,
    pub root: PathBuf,
    pub repository: PathBuf,
    pub owner: ProcessOwner,
    pub created_epoch_nanos: i64,
    pub device: u64,
    pub inode: u64,
    pub filesystem_created_epoch_nanos: Option<i64>,
    pub filesystem_modified_epoch_nanos: Option<i64>,
    pub filesystem_times_observed_epoch_nanos: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum FinishOutcome {
    Completed,
    Abandoned,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FinishEvent {
    pub bundle_id: String,
    pub filepath: PathBuf,
    /// Always the lease's allocating owner, so readers can verify the record.
    pub owner: ProcessOwner,
    pub outcome: FinishOutcome,
    pub finished_epoch_nanos: i64,
    /// The process that recorded the finish; any process of the owning user
    /// may finish, because `$(diskm scratch-new ...)` makes the allocating
    /// owner a subshell that exits at once.
    #[serde(default)]
    pub finished_by: Option<ProcessOwner>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OwnerProcessState {
    Live,
    Exited,
    IdentityChanged,
    Unavailable,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VerifiedBundle {
    pub lease: BundleLease,
    pub finish: Option<FinishEvent>,
    pub owner_process_state: OwnerProcessState,
}

pub fn dispatch(args: &[OsString]) -> Option<ExitCode> {
    let command = args.first()?.to_str()?;
    let result = match command {
        "scratch-new" => create_bundle(&args[1..], false),
        "scratch-temp-file" => create_bundle(&args[1..], true),
        "scratch-finish" => finish_bundle(&args[1..]),
        "scratch-lease" => inspect_bundle(&args[1..]),
        _ => return None,
    };
    Some(match result {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("diskm {command}: {error}");
            if error.kind() == io::ErrorKind::InvalidInput {
                ExitCode::from(2)
            } else {
                ExitCode::from(75)
            }
        }
    })
}

fn now_ns() -> io::Result<i64> {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos(),
    )
    .map_err(io::Error::other)
}

fn to_ns(time: SystemTime) -> Option<i64> {
    i64::try_from(time.duration_since(UNIX_EPOCH).ok()?.as_nanos()).ok()
}

fn valid_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        && value != "."
        && value != ".."
}

fn scratch_root() -> io::Result<PathBuf> {
    crate::verified_scratch_volume(None, false)?
        .map_or_else(|| fs::canonicalize("/tmp"), |root| root.canonicalize())
}

pub(crate) fn temp_path() -> io::Result<PathBuf> {
    fs::canonicalize("/tmp")
}

fn state_records() -> io::Result<PathBuf> {
    let state = crate::job_receipt::state_dir(None)?;
    match fs::symlink_metadata(&state) {
        Ok(metadata)
            if metadata.is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.mode() & 0o077 == 0 => {}
        Ok(_) => return Err(io::Error::other("state directory must be a real directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(&state)?;
            fs::set_permissions(&state, fs::Permissions::from_mode(0o700))?;
        }
        Err(error) => return Err(error),
    }
    let records = state.join(RECORDS_DIR);
    match fs::create_dir(&records) {
        Ok(()) => fs::set_permissions(&records, fs::Permissions::from_mode(0o700))?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let metadata = fs::symlink_metadata(&records)?;
            if !metadata.is_dir()
                || metadata.file_type().is_symlink()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o077 != 0
            {
                return Err(io::Error::other("lease directory must be private and real"));
            }
        }
        Err(error) => return Err(error),
    }
    Ok(records)
}

#[cfg(target_os = "linux")]
fn owner_details(pid: u32) -> io::Result<(u32, Option<String>, String, String)> {
    let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .to_owned();
    let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let end = stat
        .rfind(')')
        .ok_or_else(|| io::Error::other("malformed process stat"))?;
    let fields: Vec<_> = stat[end + 1..].split_whitespace().collect();
    let start = fields
        .get(19)
        .ok_or_else(|| io::Error::other("process start time is unavailable"))?;
    let command = fs::read_to_string(format!("/proc/{pid}/comm"))?
        .trim()
        .to_owned();
    let uid = fs::metadata(format!("/proc/{pid}"))?.uid();
    Ok((
        uid,
        Some(format!("linux:{boot_id}")),
        format!("linux:{start}"),
        command,
    ))
}

#[cfg(target_os = "macos")]
fn owner_details(pid: u32) -> io::Result<(u32, Option<String>, String, String)> {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "uid=,lstart=,comm="])
        .env("LC_ALL", "C")
        .env("TZ", "UTC")
        .output()?;
    if !output.status.success() {
        // ps exit 1 alone cannot distinguish an absent PID from a probe failure.
        if unsafe { libc::kill(pid as libc::pid_t, 0) } == -1
            && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "producer has exited",
            ));
        }
        return Err(io::Error::other("producer process identity is unavailable"));
    }
    let value = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let mut fields = value.split_whitespace();
    let uid = fields
        .next()
        .ok_or_else(|| io::Error::other("producer user identity is unavailable"))?
        .parse::<u32>()
        .map_err(io::Error::other)?;
    let start = fields.by_ref().take(5).collect::<Vec<_>>().join(" ");
    let command = fields.collect::<Vec<_>>().join(" ");
    if start.is_empty() || command.is_empty() {
        return Err(io::Error::other("producer process identity is unavailable"));
    }
    Ok((uid, None, format!("macos:{start}"), command))
}

#[cfg(target_os = "linux")]
pub(crate) fn live_cwd_in(bundle: &Path) -> io::Result<bool> {
    Ok(fs::read_dir("/proc")?
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .as_encoded_bytes()
                .iter()
                .all(u8::is_ascii_digit)
        })
        .filter_map(|entry| fs::read_link(entry.path().join("cwd")).ok())
        .any(|cwd| cwd.starts_with(bundle)))
}

#[cfg(target_os = "macos")]
pub(crate) fn live_cwd_in(bundle: &Path) -> io::Result<bool> {
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Err(io::Error::other("process table unavailable"));
    }
    let mut pids = vec![0; count as usize * 2];
    let bytes = std::mem::size_of_val(pids.as_slice()) as libc::c_int;
    let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    if count <= 0 || count as usize >= pids.len() {
        return Err(io::Error::other("incomplete process table"));
    }
    Ok(pids.into_iter().take(count as usize).any(|pid| {
        let mut info = std::mem::MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
        if unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                info.as_mut_ptr().cast(),
                size,
            )
        } != size
        {
            return false;
        }
        let path = unsafe { info.assume_init() }.pvi_cdir.vip_path;
        let bytes = unsafe {
            std::slice::from_raw_parts(path.as_ptr().cast(), std::mem::size_of_val(&path))
        };
        std::ffi::CStr::from_bytes_until_nul(bytes)
            .is_ok_and(|cwd| Path::new(OsStr::from_bytes(cwd.to_bytes())).starts_with(bundle))
    }))
}

fn caller_owner() -> io::Result<ProcessOwner> {
    let pid = unsafe { libc::getppid() } as u32;
    if pid <= 1 {
        return Err(io::Error::other("producer process is unavailable"));
    }
    let (uid, host_boot_id, started, command) = owner_details(pid)?;
    Ok(ProcessOwner {
        pid,
        uid,
        host_boot_id,
        started,
        command,
    })
}

/// `staged` names where a bundle's directory now lives while `bundle` is the
/// path its lease was recorded under: identity is read from `staged`.
fn record_path(
    bundle: &Path,
    root: &Path,
    staged: Option<&Path>,
) -> io::Result<(PathBuf, BundleLease)> {
    let (absolute, metadata) = if let Some(staged) = staged {
        (bundle.to_path_buf(), fs::symlink_metadata(staged)?)
    } else {
        if fs::symlink_metadata(bundle)?.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "lease path cannot be a symlink",
            ));
        }
        let absolute = bundle.canonicalize()?;
        let metadata = fs::symlink_metadata(&absolute)?;
        (absolute, metadata)
    };
    let digest = Sha256::digest(absolute.as_os_str().as_bytes());
    let record = state_records()?.join(format!("{digest:x}.json"));
    let lease: BundleLease =
        serde_json::from_slice(&fs::read(&record)?).map_err(io::Error::other)?;
    let valid_kind = if matches!(lease.kind, BundleKind::TempFile) {
        absolute.parent() == Some(root)
            && root == temp_path()?
            && metadata.is_file()
            && metadata.uid() == unsafe { libc::geteuid() }
    } else {
        absolute.starts_with(root.join(RUNS_DIR)) && metadata.is_dir()
    };
    if !valid_kind
        || lease.schema_version != 1
        || lease.root != root
        || lease.filepath != absolute
        || (lease.device, lease.inode) != (metadata.dev(), metadata.ino())
    {
        return Err(io::Error::other(
            "lease does not match the current bundle identity",
        ));
    }
    Ok((record, lease))
}

/// Read and validate a lease against the current Scratch root, bundle path and
/// filesystem identity. A finish event is accepted only for this lease's exact
/// identity and original producer incarnation.
pub fn lookup_bundle(bundle: &Path) -> io::Result<VerifiedBundle> {
    let temporary = temp_path()?;
    if bundle.parent() == Some(temporary.as_path()) {
        return lookup_bundle_under_root(bundle, &temporary);
    }
    lookup_bundle_under_root(bundle, &scratch_root()?)
}

pub(crate) fn lookup_bundle_under_root(bundle: &Path, root: &Path) -> io::Result<VerifiedBundle> {
    lookup_bundle_at(bundle, root, None)
}

pub(crate) fn lookup_bundle_at(
    bundle: &Path,
    root: &Path,
    staged: Option<&Path>,
) -> io::Result<VerifiedBundle> {
    let (record_path, lease) = record_path(bundle, root, staged)?;
    let finish_path = record_path.with_extension("finished.json");
    let finish = match fs::read(finish_path) {
        Ok(bytes) => {
            let event: FinishEvent = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            if event.bundle_id != lease.bundle_id
                || event.filepath != lease.filepath
                || event.owner != lease.owner
                || event.finished_epoch_nanos < lease.created_epoch_nanos
            {
                return Err(io::Error::other(
                    "finish event does not match the verified bundle lease",
                ));
            }
            Some(event)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    let owner_process_state = owner_process_state(&lease.owner);
    Ok(VerifiedBundle {
        lease,
        finish,
        owner_process_state,
    })
}

fn owner_process_state(expected: &ProcessOwner) -> OwnerProcessState {
    match owner_details(expected.pid) {
        Ok((uid, boot_id, started, _))
            if uid == expected.uid
                && boot_id == expected.host_boot_id
                && started == expected.started =>
        {
            OwnerProcessState::Live
        }
        Ok(_) => OwnerProcessState::IdentityChanged,
        Err(error) if error.kind() == io::ErrorKind::NotFound => OwnerProcessState::Exited,
        Err(_) => OwnerProcessState::Unavailable,
    }
}

fn create_bundle(args: &[OsString], system_tmp: bool) -> io::Result<String> {
    if args.len() < 2 || (system_tmp && args.len() != 2) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: diskm scratch-new <repo> <purpose> [--kind scratch|build|evidence] [--owner-pid PID]",
        ));
    }
    let repository = PathBuf::from(&args[0]).canonicalize()?;
    if !repository.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "repository must be a directory",
        ));
    }
    let repo = repository
        .file_name()
        .and_then(OsStr::to_str)
        .filter(|value| valid_slug(value))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "repository name must be a filesystem slug",
            )
        })?;
    let purpose = args[1]
        .to_str()
        .filter(|value| valid_slug(value))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "purpose must be a filesystem slug",
            )
        })?;
    let (kind_args, owner_pid) = match &args[2..] {
        [rest @ .., flag, value] if flag == "--owner-pid" && !system_tmp => {
            let pid = value
                .to_str()
                .and_then(|value| value.parse::<u32>().ok())
                .filter(|pid| *pid > 1)
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--owner-pid requires a process id",
                    )
                })?;
            (rest, Some(pid))
        }
        rest => (rest, None),
    };
    let kind_value = match kind_args {
        [] if system_tmp => "temp_file",
        [] => "scratch",
        [flag, value] if flag == "--kind" => value
            .to_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "kind must be UTF-8"))?,
        [value] if !value.to_string_lossy().starts_with('-') => value
            .to_str()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "kind must be UTF-8"))?,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "usage: diskm scratch-new <repo> <purpose> [--kind scratch|build|evidence] [--owner-pid PID]",
            ))
        }
    };
    let kind = match kind_value {
        "temp_file" if system_tmp => BundleKind::TempFile,
        "scratch" => BundleKind::Scratch,
        "build" => BundleKind::Build,
        "evidence" => BundleKind::Evidence,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "kind must be scratch, build, or evidence",
            ))
        }
    };
    let root = if system_tmp {
        temp_path()?
    } else {
        scratch_root()?
    };
    let root_metadata = fs::metadata(&root)?;
    let owner = match owner_pid {
        Some(pid) => {
            let (uid, host_boot_id, started, command) = owner_details(pid)?;
            if uid != unsafe { libc::getuid() } {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "--owner-pid must name a process of the current user",
                ));
            }
            ProcessOwner {
                pid,
                uid,
                host_boot_id,
                started,
                command,
            }
        }
        None => caller_owner()?,
    };
    let created = now_ns()?;
    let date = crate::job_receipt::timestamp(SystemTime::now())?[..10].replace('-', "");
    let records = state_records()?;
    let mut id = format!("{purpose}-{}-{}", owner.pid, created);
    let path = if system_tmp {
        id = format!("diskm-temp-{id}");
        let path = root.join(&id);
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        path
    } else {
        let repo_dir = root.join(RUNS_DIR).join(date).join(repo);
        fs::create_dir_all(&repo_dir)?;
        let path = repo_dir.join(&id);
        fs::create_dir(&path)?;
        path
    };
    let metadata = fs::symlink_metadata(&path)?;
    if (system_tmp && !metadata.is_file())
        || (!system_tmp && !metadata.is_dir())
        || metadata.dev() != root_metadata.dev()
    {
        return Err(io::Error::other(
            "new bundle is not on the registered Scratch filesystem",
        ));
    }
    let lease = BundleLease {
        schema_version: 1,
        bundle_id: id.clone(),
        kind,
        filepath: path.clone(),
        root: root.clone(),
        repository,
        owner,
        created_epoch_nanos: created,
        device: metadata.dev(),
        inode: metadata.ino(),
        filesystem_created_epoch_nanos: metadata.created().ok().and_then(to_ns),
        filesystem_modified_epoch_nanos: metadata.modified().ok().and_then(to_ns),
        filesystem_times_observed_epoch_nanos: now_ns()?,
    };
    let digest = Sha256::digest(path.as_os_str().as_bytes());
    let record = records.join(format!("{digest:x}.json"));
    create_once(
        &record,
        &serde_json::to_vec(&lease).map_err(io::Error::other)?,
    )?;
    Ok(path.to_string_lossy().into_owned())
}

fn finish_bundle(args: &[OsString]) -> io::Result<String> {
    if !(1..=2).contains(&args.len()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: diskm scratch-finish <bundle-path> [completed|abandoned]",
        ));
    }
    let outcome = match args
        .get(1)
        .and_then(|value| value.to_str())
        .unwrap_or("completed")
    {
        "completed" => FinishOutcome::Completed,
        "abandoned" => FinishOutcome::Abandoned,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "outcome must be completed or abandoned",
            ))
        }
    };
    let verified = lookup_bundle(Path::new(&args[0]))?;
    let lease = verified.lease;
    let caller = caller_owner()?;
    if caller.uid != lease.owner.uid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "only the owning user may finish this run",
        ));
    }
    let event = FinishEvent {
        bundle_id: lease.bundle_id.clone(),
        filepath: lease.filepath.clone(),
        owner: lease.owner.clone(),
        outcome,
        finished_epoch_nanos: now_ns()?,
        finished_by: Some(caller),
    };
    let name = Path::new(&lease.filepath).as_os_str().as_bytes();
    let event_name = format!("{:x}.finished.json", Sha256::digest(name));
    let event_path = state_records()?.join(event_name);
    let data = serde_json::to_vec(&event).map_err(io::Error::other)?;
    match create_once(&event_path, &data) {
        Ok(()) => Ok(event_path.to_string_lossy().into_owned()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let saved: FinishEvent =
                serde_json::from_slice(&fs::read(event_path)?).map_err(io::Error::other)?;
            if saved.owner == event.owner && saved.outcome == event.outcome {
                Ok("already-finished".into())
            } else {
                Err(io::Error::other(
                    "bundle already has a different finish event",
                ))
            }
        }
        Err(error) => Err(error),
    }
}

fn inspect_bundle(args: &[OsString]) -> io::Result<String> {
    if args.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: diskm scratch-lease <bundle-path>",
        ));
    }
    let verified = lookup_bundle(Path::new(&args[0]))?;
    let mut lease = verified.lease;
    // This is a live observation of the directory's own mtime. Recursive content
    // freshness comes from the age scanner and has its own scan timestamp.
    let observed = fs::symlink_metadata(&lease.filepath)?;
    if observed.file_type().is_symlink()
        || (observed.dev(), observed.ino()) != (lease.device, lease.inode)
    {
        return Err(io::Error::other("bundle directory identity changed"));
    }
    lease.filesystem_modified_epoch_nanos = observed.modified().ok().and_then(to_ns);
    lease.filesystem_created_epoch_nanos = observed.created().ok().and_then(to_ns);
    lease.filesystem_times_observed_epoch_nanos = now_ns()?;
    serde_json::to_string(&serde_json::json!({
        "lease": lease,
        "finish": verified.finish,
        "owner_process_state": verified.owner_process_state,
    }))
    .map_err(io::Error::other)
}

/// What a lease written by the retired Python allocator says about a run.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum LegacyLease {
    Build { owner_live: bool },
    Worktree { owner_live: bool },
    OtherKind,
}

/// Reads `worktree_leases/*.json`, written by the retired Python allocator.
/// A record counts only when both its path and its recorded directory identity
/// match the run, so a replaced directory never inherits an old lease. Any
/// process holding a recorded owner PID keeps the run; a PID reused by an
/// unrelated process therefore errs toward keeping.
/// With `strict`, a record that cannot be read or parsed is an error rather
/// than skipped, so the caller cannot mistake it for "no lease".
pub(crate) fn legacy_lease(
    bundle: &Path,
    staged: Option<&Path>,
    strict: bool,
) -> io::Result<Option<LegacyLease>> {
    let directory = crate::job_receipt::state_dir(None)?.join("worktree_leases");
    let entries = match fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let metadata = fs::symlink_metadata(staged.unwrap_or(bundle))?;
    for entry in entries {
        let path = entry?.path();
        if path.extension() != Some(OsStr::new("json"))
            || path
                .file_name()
                .is_some_and(|n| n.as_encoded_bytes().starts_with(b"."))
        {
            continue;
        }
        let bytes = match crate::job_receipt::read_bounded(&path, 1 << 20) {
            Ok(bytes) => bytes,
            Err(error) if strict && error.kind() != io::ErrorKind::NotFound => return Err(error),
            Err(_) => continue,
        };
        let record = match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(record) => record,
            Err(error) if strict => return Err(io::Error::other(error)),
            Err(_) => continue,
        };
        // Only a record that clearly belongs to another path is skipped; with
        // `strict`, one that may be this run's but is mistyped is an error.
        let Some(recorded) = record["path"].as_str() else {
            if strict {
                return Err(io::Error::other("legacy lease record has no usable path"));
            }
            continue;
        };
        if Path::new(recorded) != bundle {
            continue;
        }
        let identity = (
            record["checkout_dev"].as_u64(),
            record["checkout_ino"].as_u64(),
        );
        if strict && (identity.0.is_none() || identity.1.is_none()) {
            return Err(io::Error::other(
                "legacy lease record has no usable identity",
            ));
        }
        if identity != (Some(metadata.dev()), Some(metadata.ino())) {
            continue;
        }
        if strict && !record["owners"].is_array() {
            return Err(io::Error::other("legacy lease record has no owners list"));
        }
        let kind = record["kind"].as_str();
        if !matches!(kind, Some("build" | "worktree")) {
            return Ok(Some(LegacyLease::OtherKind));
        }
        if kind == Some("worktree")
            && record["pending"].as_bool() == Some(false)
            && record.get("owner").is_some_and(serde_json::Value::is_null)
            && record["owners"].as_array().is_some_and(Vec::is_empty)
            && matches!(record["creator"].as_str(), Some("adopt" | "birth-audit"))
        {
            return Ok(Some(LegacyLease::Worktree { owner_live: false }));
        }
        // An owner entry without a usable PID is an unknown owner; keep the run.
        // Only an absent top-level `owner` key is skipped; a null entry counts
        // as an owner without a PID.
        let owners: Vec<&serde_json::Value> = record["owners"]
            .as_array()
            .into_iter()
            .flatten()
            .chain(record.get("owner"))
            .collect();
        let pids: Vec<u64> = owners
            .iter()
            .filter_map(|owner| owner["pid"].as_u64())
            .collect();
        let owner_live = if pids.len() != owners.len() || pids.is_empty() {
            true
        } else {
            pids.into_iter().any(|pid| {
                let Ok(pid) = libc::pid_t::try_from(pid) else {
                    return true;
                };
                pid <= 1
                    || unsafe { libc::kill(pid, 0) } == 0
                    || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
            })
        };
        return Ok(Some(if kind == Some("worktree") {
            LegacyLease::Worktree { owner_live }
        } else {
            LegacyLease::Build { owner_live }
        }));
    }
    Ok(None)
}

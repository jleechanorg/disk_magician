//! Lock-free metadata for managed Scratch bundles.
//!
//! Each bundle record and its optional finish event are immutable files
//! created once. Independent producers never contend on a shared lease lock.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
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
    pub owner: ProcessOwner,
    pub outcome: FinishOutcome,
    pub finished_epoch_nanos: i64,
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
        "scratch-new" => create_bundle(&args[1..]),
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

fn utc_date(seconds: i64) -> io::Result<String> {
    let z = seconds.div_euclid(86_400) + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }).div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    if !(2000..=9999).contains(&year) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "clock outside supported date range",
        ));
    }
    Ok(format!("{year:04}{month:02}{day:02}"))
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
        .map_or_else(|| Ok(PathBuf::from("/tmp")), |root| root.canonicalize())
}

fn state_records() -> io::Result<PathBuf> {
    let state = env::var_os("DISK_MAGICIAN_STATE_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME").map(|home| PathBuf::from(home).join(".disk_magician_state"))
        })
        .ok_or_else(|| io::Error::other("HOME or DISK_MAGICIAN_STATE_DIR is required"))?;
    if !state.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "state directory must be absolute",
        ));
    }
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
    Ok((
        uid,
        None,
        format!("macos:{}", start.trim()),
        command.trim().to_owned(),
    ))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn owner_details(_: u32) -> io::Result<(u32, Option<String>, String, String)> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "native owner identity is unsupported",
    ))
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

fn record_path(bundle: &Path, root: &Path) -> io::Result<(PathBuf, BundleLease)> {
    let supplied_metadata = fs::symlink_metadata(bundle)?;
    if supplied_metadata.file_type().is_symlink() || !supplied_metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bundle path must be a real directory",
        ));
    }
    let absolute = bundle.canonicalize()?;
    if !absolute.starts_with(root.join(RUNS_DIR)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "path is not a managed Scratch bundle",
        ));
    }
    let metadata = fs::symlink_metadata(&absolute)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bundle must be a real directory",
        ));
    }
    let digest = Sha256::digest(absolute.as_os_str().as_bytes());
    let record = state_records()?.join(format!("{digest:x}.json"));
    let lease: BundleLease =
        serde_json::from_slice(&fs::read(&record)?).map_err(io::Error::other)?;
    if lease.schema_version != 1
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
    lookup_bundle_under_root(bundle, &scratch_root()?)
}

pub(crate) fn lookup_bundle_under_root(bundle: &Path, root: &Path) -> io::Result<VerifiedBundle> {
    let (record_path, lease) = record_path(bundle, root)?;
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

fn create_once(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = path.with_extension(format!("tmp-{}-{}", std::process::id(), now_ns()?));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    if let Err(error) = fs::hard_link(&temp, path) {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    fs::remove_file(temp)?;
    File::open(
        path.parent()
            .ok_or_else(|| io::Error::other("lease record has no parent"))?,
    )?
    .sync_all()
}

fn create_bundle(args: &[OsString]) -> io::Result<String> {
    if args.len() < 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: diskm scratch-new <repo> <purpose> [--kind scratch|build|evidence]",
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
    let kind_value = match &args[2..] {
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
                "usage: diskm scratch-new <repo> <purpose> [--kind scratch|build|evidence]",
            ))
        }
    };
    let kind = match kind_value {
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
    let root = scratch_root()?;
    let root_metadata = fs::metadata(&root)?;
    let owner = caller_owner()?;
    let created = now_ns()?;
    let date = utc_date(created.div_euclid(1_000_000_000))?;
    let repo_dir = root.join(RUNS_DIR).join(date).join(repo);
    fs::create_dir_all(&repo_dir)?;
    let records = state_records()?;
    let id = format!("{purpose}-{}-{}", owner.pid, created);
    let path = repo_dir.join(&id);
    fs::create_dir(&path)?;
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
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
    let owner = caller_owner()?;
    if (
        owner.pid,
        owner.host_boot_id.as_deref(),
        owner.started.as_str(),
    ) != (
        lease.owner.pid,
        lease.owner.host_boot_id.as_deref(),
        lease.owner.started.as_str(),
    ) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "only the allocating producer may finish this run",
        ));
    }
    let event = FinishEvent {
        bundle_id: lease.bundle_id.clone(),
        filepath: lease.filepath.clone(),
        owner,
        outcome,
        finished_epoch_nanos: now_ns()?,
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
        || !observed.is_dir()
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

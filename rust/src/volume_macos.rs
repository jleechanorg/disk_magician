//! Verification of the APFS identity documents used to measure Scratch usage.

use serde_json::Value;
use std::io;
use std::path::Path;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ApfsScratch<'a> {
    pub(crate) container: &'a str,
    pub(crate) device: &'a str,
    pub(crate) uuid: &'a str,
    pub(crate) allocated_bytes: Option<u64>,
    pub(crate) encrypted: bool,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::other(message)
}

fn required_text<'a>(value: &'a Value, field: &str) -> io::Result<&'a str> {
    value[field]
        .as_str()
        .filter(|text| !text.is_empty())
        .ok_or_else(|| invalid("incomplete APFS identity"))
}

fn data_container<'a>(listing: &'a Value, data: &Value) -> io::Result<&'a Value> {
    let data_ref = required_text(data, "APFSContainerReference")?;
    let mut containers = listing["Containers"]
        .as_array()
        .ok_or_else(|| invalid("APFS containers unavailable"))?
        .iter()
        .filter(|row| row["ContainerReference"] == data_ref);
    containers
        .next()
        .filter(|_| containers.next().is_none())
        .ok_or_else(|| invalid("Data APFS container is missing or ambiguous"))
}

fn scratch_rows(container: &Value) -> io::Result<&[Value]> {
    container["Volumes"]
        .as_array()
        .filter(|rows| rows.iter().all(|row| required_text(row, "Name").is_ok()))
        .map(Vec::as_slice)
        .ok_or_else(|| invalid("Data APFS volume inventory unavailable"))
}

fn registered_scratch<'a>(
    container: &'a Value,
    entry: &Value,
    path: &Path,
    quota: u64,
    encrypted: bool,
) -> io::Result<ApfsScratch<'a>> {
    let container_uuid = required_text(container, "APFSContainerUUID")?;
    if entry["class"] != "scratch"
        || entry["name"] != "diskm-scratch"
        || entry["mountpoint"].as_str().map(Path::new) != Some(path)
        || entry["container_uuid"] != container_uuid
        || entry["quota_bytes"].as_u64() != Some(quota)
    {
        return Err(invalid("registered APFS Scratch identity mismatch"));
    }

    let mut volumes = scratch_rows(container)?
        .iter()
        .filter(|row| row["Name"] == "diskm-scratch");
    let volume = volumes
        .next()
        .filter(|_| volumes.next().is_none())
        .ok_or_else(|| invalid("Scratch APFS volume is missing or ambiguous"))?;
    let uuid = required_text(volume, "APFSVolumeUUID")?;
    if entry["uuid"] != uuid
        || !volume["Roles"].as_array().is_some_and(Vec::is_empty)
        || volume["CapacityQuota"].as_u64() != Some(quota)
        || (encrypted && (volume["Encryption"] != true || volume["Locked"] != false))
    {
        return Err(invalid(
            "Scratch APFS volume identity or lock state mismatch",
        ));
    }

    Ok(ApfsScratch {
        container: required_text(container, "ContainerReference")?,
        device: required_text(volume, "DeviceIdentifier")?,
        uuid,
        allocated_bytes: volume["CapacityInUse"].as_u64(),
        encrypted,
    })
}

pub(crate) fn verify_info(scratch: &ApfsScratch<'_>, info: &Value, path: &Path) -> io::Result<()> {
    if info["VolumeUUID"] != scratch.uuid
        || info["APFSContainerReference"] != scratch.container
        || info["DeviceIdentifier"] != scratch.device
        || info["MountPoint"].as_str().map(Path::new) != Some(path)
        || (scratch.encrypted && (info["Encryption"] != true || info["Locked"] != false))
    {
        return Err(invalid("mounted APFS Scratch identity mismatch"));
    }
    Ok(())
}

fn check_reclaim_headroom(
    listing: &Value,
    scratch: &ApfsScratch<'_>,
    swap_headroom: u64,
    alarm_floor: u64,
) -> io::Result<()> {
    const GIB: u64 = 1024 * 1024 * 1024;
    let container = listing["Containers"]
        .as_array()
        .and_then(|rows| {
            rows.iter()
                .find(|row| row["ContainerReference"] == scratch.container)
        })
        .ok_or_else(|| invalid("Data APFS container unavailable"))?;
    let ceiling = container["CapacityCeiling"]
        .as_u64()
        .filter(|bytes| *bytes > 0)
        .ok_or_else(|| invalid("Data APFS container capacity unavailable"))?;
    if container["CapacityFree"]
        .as_u64()
        .is_none_or(|free| free < 20 * GIB)
    {
        return Err(invalid("APFS container free-space alarm"));
    }
    let members = container["Volumes"]
        .as_array()
        .ok_or_else(|| invalid("Data APFS volume inventory unavailable"))?;
    let mut counts = [0u8; 3];
    let mut vm = 0;
    let mut other = 0u128;
    for member in members {
        let used = member["CapacityInUse"]
            .as_u64()
            .ok_or_else(|| invalid("APFS volume allocation unavailable"))?;
        let contains_role = |role| {
            member["Roles"]
                .as_array()
                .is_some_and(|roles| roles.iter().any(|item| item == role))
        };
        for (count, role) in counts.iter_mut().zip(["Data", "System", "VM"]) {
            if contains_role(role) {
                *count = count.saturating_add(1);
            }
        }
        if contains_role("VM") {
            vm = used;
        } else if member["APFSVolumeUUID"] != scratch.uuid {
            other += u128::from(used);
        }
    }
    let used = scratch
        .allocated_bytes
        .ok_or_else(|| invalid("Scratch APFS usage unavailable"))?;
    let fit =
        other + u128::from(vm.max(swap_headroom)) + u128::from(used) + u128::from(alarm_floor);
    // Reclaim releases blocks from the existing volume. The configured ceiling
    // can exceed current free space during the growth this operation addresses.
    if counts != [1, 1, 1] || fit > u128::from(ceiling) {
        return Err(invalid("APFS Scratch capacity alarm"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
#[derive(PartialEq, Eq)]
enum Purpose {
    Locate,
    Reclaim,
    Verify,
    Usage,
}

#[cfg(target_os = "macos")]
struct VerifiedMount {
    path: std::path::PathBuf,
    uuid: String,
    identity: (u64, u64),
    used: Option<u64>,
}

fn confirmed_absence(container: &Value) -> io::Result<()> {
    if scratch_rows(container)?
        .iter()
        .any(|row| row["Name"] == "diskm-scratch")
    {
        return Err(invalid(
            "live Scratch volume has no usable configuration or registry",
        ));
    }
    Ok(())
}

fn eligible_state(entry: &Value, allow_retired: bool) -> io::Result<bool> {
    match entry["state"].as_str() {
        Some("active") => Ok(true),
        Some("retired") => Ok(allow_retired),
        _ => Err(invalid("invalid APFS Scratch registry state")),
    }
}

#[cfg(target_os = "macos")]
fn verified_mount(expected: Option<&Path>, purpose: Purpose) -> io::Result<Option<VerifiedMount>> {
    use std::env;
    use std::fs::{self, OpenOptions};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::PathBuf;

    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let config = crate::volume_config::configuration(&home)?;
    if !config.is_object() {
        return Err(invalid("invalid APFS volume configuration"));
    }
    let listing = diskutil_document(&["apfs", "list", "-plist"])?;
    let data = diskutil_document(&["info", "-plist", "/System/Volumes/Data"])?;
    let container = data_container(&listing, &data)?;
    let Some(volumes) = config.get("volumes") else {
        confirmed_absence(container)?;
        return Ok(None);
    };
    let classes = volumes["classes"]
        .as_object()
        .filter(|classes| classes.len() == 1)
        .ok_or_else(|| invalid("unsupported volume classes"))?;
    let scratch = classes
        .get("scratch")
        .ok_or_else(|| invalid("Scratch configuration unavailable"))?;
    let encrypted = match volumes["encryption"].as_str() {
        Some("none") => false,
        Some("apfs-passphrase") => true,
        _ => return Err(invalid("unsupported APFS Scratch encryption mode")),
    };
    let positive = |value: &Value| value.as_u64().filter(|amount| *amount > 0);
    let path = scratch["mountpoint"]
        .as_str()
        .map(Path::new)
        .filter(|path| path.is_absolute() && *path != Path::new("/"))
        .ok_or_else(|| invalid("invalid APFS Scratch mountpoint"))?;
    if scratch["name"] != "diskm-scratch"
        || !matches!(
            scratch.get("backend").map(Value::as_str),
            None | Some(Some("fuse" | "native"))
        )
        || ["swap_headroom_gb", "alarm_floor_gb"]
            .into_iter()
            .any(|key| positive(&volumes[key]).is_none())
        || ["trigger_pct", "target_pct"].into_iter().any(|key| {
            scratch
                .get(key)
                .is_some_and(|value| positive(value).is_none())
        })
    {
        return Err(invalid("invalid APFS Scratch configuration"));
    }
    let in_bytes = |value| {
        positive(value)
            .and_then(|amount| amount.checked_mul(1024 * 1024 * 1024))
            .ok_or_else(|| invalid("invalid APFS Scratch capacity setting"))
    };
    let quota = in_bytes(&scratch["quota_gb"])?;
    let state = env::var_os("DISK_MAGICIAN_STATE_DIR")
        .map_or_else(|| home.join(".disk_magician_state"), PathBuf::from);
    let registry = match crate::volume_config::json_file(&state.join("volumes/registry.json")) {
        Ok(registry) => registry,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            confirmed_absence(container)?;
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    if registry["schema_version"].as_u64() != Some(1) || !registry["volumes"].is_object() {
        return Err(invalid("invalid APFS Scratch registry"));
    }
    let Some(entry) = registry["volumes"].get("scratch") else {
        confirmed_absence(container)?;
        return Ok(None);
    };
    let allowed = eligible_state(entry, matches!(purpose, Purpose::Verify | Purpose::Reclaim))?;
    if fs::canonicalize(path)? != path
        || expected
            .is_some_and(|expected| !fs::canonicalize(expected).is_ok_and(|root| root == path))
    {
        return Err(invalid(
            "APFS Scratch mountpoint differs from configuration",
        ));
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    let opened = directory.metadata()?;
    let identity = (opened.dev(), opened.ino());
    let scratch = registered_scratch(container, entry, path, quota, encrypted)?;
    let path_text = path
        .to_str()
        .ok_or_else(|| invalid("invalid Scratch mountpoint encoding"))?;
    verify_info(
        &scratch,
        &diskutil_document(&["info", "-plist", path_text])?,
        path,
    )?;
    let verify_current = || -> io::Result<()> {
        let current = fs::symlink_metadata(path)?;
        if !current.is_dir() || (current.dev(), current.ino()) != identity {
            return Err(invalid("Scratch mount changed during verification"));
        }
        Ok(())
    };
    if !allowed {
        verify_current()?;
        return Ok(None);
    }
    if purpose == Purpose::Usage {
        check_reclaim_headroom(
            &listing,
            &scratch,
            in_bytes(&volumes["swap_headroom_gb"])?,
            in_bytes(&volumes["alarm_floor_gb"])?,
        )?;
    }
    if purpose != Purpose::Verify {
        verify_ballast(&directory, purpose == Purpose::Reclaim)?;
    }
    verify_current()?;
    Ok(Some(VerifiedMount {
        path: path.to_path_buf(),
        uuid: scratch.uuid.to_owned(),
        identity,
        used: scratch.allocated_bytes,
    }))
}

#[cfg(any(target_os = "macos", test))]
fn verify_ballast(directory: &std::fs::File, optional: bool) -> io::Result<()> {
    use std::fs::File;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::fs::MetadataExt;

    // Bind the ballast check to the directory descriptor whose mount was verified.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c".diskm-ballast".as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        let error = io::Error::last_os_error();
        return if optional && error.kind() == io::ErrorKind::NotFound {
            Ok(())
        } else {
            Err(error)
        };
    }
    let ballast = unsafe { File::from_raw_fd(fd) }.metadata()?;
    const BALLAST_BYTES: u64 = 64 * 1024 * 1024;
    if !ballast.is_file()
        || ballast.len() != BALLAST_BYTES
        || ballast.blocks() < BALLAST_BYTES / 512
    {
        return Err(invalid("APFS Scratch ballast missing or unallocated"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
pub(crate) fn verified_root(
    expected: Option<&Path>,
    reclaim: bool,
) -> io::Result<Option<std::path::PathBuf>> {
    let purpose = if expected.is_some() {
        Purpose::Verify
    } else if reclaim {
        Purpose::Reclaim
    } else {
        Purpose::Locate
    };
    Ok(verified_mount(expected, purpose)?.map(|mount| mount.path))
}

#[cfg(target_os = "macos")]
pub(crate) fn mounted_usage(
    path: &Path,
    dev: u64,
    ino: u64,
    filesystem_id: Option<&str>,
) -> io::Result<(String, u64)> {
    let mount = verified_mount(Some(path), Purpose::Usage)?
        .ok_or_else(|| invalid("registered APFS Scratch mount unavailable"))?;
    if mount.identity != (dev, ino) || filesystem_id.is_some_and(|expected| expected != mount.uuid)
    {
        return Err(invalid("Scratch root or filesystem identity changed"));
    }
    let used = mount
        .used
        .ok_or_else(|| invalid("Scratch APFS used-byte measurement unavailable"))?;
    Ok((mount.uuid, used))
}

#[cfg(target_os = "macos")]
fn diskutil_document(args: &[&str]) -> io::Result<Value> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::thread;
    use std::time::Instant;

    const LIMIT: u64 = 8 * 1024 * 1024;
    let mut diskutil = Command::new("/usr/sbin/diskutil")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let output = diskutil.stdout.take().expect("piped diskutil stdout");
    let started = Instant::now();
    let converted = Command::new("/usr/bin/plutil")
        .args(["-convert", "json", "-o", "-", "-"])
        .stdin(Stdio::from(output))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut plutil = match converted {
        Ok(child) => child,
        Err(error) => {
            let _ = diskutil.kill();
            let _ = diskutil.wait();
            return Err(error);
        }
    };
    let stdout = plutil.stdout.take().expect("piped plutil stdout");
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(LIMIT + 1).read_to_end(&mut bytes)?;
        Ok::<_, io::Error>(bytes)
    });
    let status = loop {
        match (diskutil.try_wait(), plutil.try_wait()) {
            (Ok(Some(disk)), Ok(Some(plist))) => break Ok((disk, plist)),
            (Err(error), _) | (_, Err(error)) => break Err(error),
            _ if started.elapsed() >= crate::time_windows::VOLUME_PROBE_TIMEOUT => {
                break Err(invalid("APFS Scratch identity probe timed out"));
            }
            _ => thread::sleep(crate::time_windows::PROBE_POLL),
        }
    };
    if status.is_err() {
        let _ = diskutil.kill();
        let _ = plutil.kill();
        let _ = diskutil.wait();
        let _ = plutil.wait();
    }
    let (disk, plist) = status?;
    let bytes = reader
        .join()
        .map_err(|_| invalid("APFS identity output reader failed"))??;
    if !disk.success() || !plist.success() || bytes.len() as u64 > LIMIT {
        return Err(invalid("APFS Scratch identity document unavailable"));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}

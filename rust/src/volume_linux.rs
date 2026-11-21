//! Read-only Scratch mount identity on Linux.

use crate::volume_config::{configuration, json_file};
use serde_json::Value;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const GIB: u64 = 1024 * 1024 * 1024;

fn invalid(message: &'static str) -> io::Error {
    io::Error::other(message)
}

struct Scratch<'a> {
    image: &'a Path,
    mount: &'a Path,
    quota: u64,
    native: bool,
}

fn scratch_config(document: &Value) -> io::Result<Option<Scratch<'_>>> {
    if !document.is_object() {
        return Err(invalid("invalid quota configuration"));
    }
    let Some(volumes) = document.get("volumes") else {
        return Ok(None);
    };
    let classes = volumes["classes"]
        .as_object()
        .filter(|classes| classes.len() == 1)
        .ok_or_else(|| invalid("unsupported volume classes"))?;
    let scratch = classes
        .get("scratch")
        .ok_or_else(|| invalid("Scratch configuration unavailable"))?;
    let positive = |value: &Value| value.as_u64().filter(|number| *number > 0);
    if volumes["encryption"] != "none"
        || scratch["name"] != "diskm-scratch"
        || positive(&volumes["swap_headroom_gb"]).is_none()
        || positive(&volumes["alarm_floor_gb"]).is_none()
        || ["trigger_pct", "target_pct"].iter().any(|key| {
            scratch
                .get(*key)
                .is_some_and(|value| positive(value).is_none())
        })
    {
        return Err(invalid("invalid Scratch quota configuration"));
    }
    let native = match scratch.get("backend").map(Value::as_str) {
        None | Some(Some("fuse")) => false,
        Some(Some("native")) => true,
        _ => return Err(invalid("unsupported Scratch backend")),
    };
    let quota = positive(&scratch["quota_gb"])
        .and_then(|value| value.checked_mul(GIB))
        .ok_or_else(|| invalid("invalid Scratch quota"))?;
    let path = |key| {
        scratch
            .get(key)
            .and_then(Value::as_str)
            .map(Path::new)
            .filter(|path| path.is_absolute())
            .ok_or_else(|| invalid("missing absolute Scratch path"))
    };
    Ok(Some(Scratch {
        image: path("image_path")?,
        mount: path("mountpoint")?,
        quota,
        native,
    }))
}

// Linux encodes these four bytes in its mountinfo fields.
fn mount_field(path: &Path) -> io::Result<String> {
    let path = path
        .to_str()
        .ok_or_else(|| invalid("invalid Scratch mountpoint encoding"))?;
    Ok(path
        .replace('\\', "\\134")
        .replace('\t', "\\011")
        .replace(' ', "\\040")
        .replace('\n', "\\012"))
}

fn mount_record<'a>(
    mountinfo: &'a str,
    mount: &Path,
) -> io::Result<Option<(&'a str, &'a str, &'a str)>> {
    let escaped = mount_field(mount)?;
    let mut found = None;
    for line in mountinfo.lines() {
        let mut fields = line.split_whitespace();
        let mount_id = fields.next();
        if fields.nth(3) != Some(escaped.as_str()) {
            continue;
        }
        if found.is_some() {
            return Err(invalid("Scratch mountpoint has stacked mounts"));
        }
        if !fields.any(|field| field == "-") {
            return Err(invalid("invalid mountinfo row for Scratch"));
        }
        found = Some(match (mount_id, fields.next(), fields.next()) {
            (Some(id), Some(kind), Some(source)) => (id, kind, source),
            _ => return Err(invalid("incomplete Scratch mount record")),
        });
    }
    Ok(found)
}

fn loop_device(image: &Path) -> io::Result<PathBuf> {
    let mut device = None;
    for row in fs::read_dir("/sys/block")? {
        let row = row?;
        if !row.file_name().as_encoded_bytes().starts_with(b"loop") {
            continue;
        }
        let backing = match fs::read_to_string(row.path().join("loop/backing_file")) {
            Ok(backing) => backing,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        let backing = backing.trim_end_matches('\n').replace("\\040", " ");
        if !fs::canonicalize(Path::new(&backing)).is_ok_and(|path| path == image) {
            continue;
        }
        if device.is_some() {
            return Err(invalid("Scratch image has multiple loop mappings"));
        }
        device = Some(Path::new("/dev").join(row.file_name()));
    }
    device.ok_or_else(|| invalid("Scratch image has no verified loop mapping"))
}

fn probe_filesystem(path: &Path) -> io::Result<String> {
    let mut child = Command::new("blkid")
        .args(["-p", "-o", "export"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() >= Duration::from_secs(30) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(invalid("Scratch UUID probe timed out"));
        }
        thread::sleep(Duration::from_millis(20));
    };
    if !status.success() {
        return Err(invalid("Scratch UUID probe failed"));
    }
    let mut output = String::new();
    child
        .stdout
        .take()
        .ok_or_else(|| invalid("Scratch UUID output unavailable"))?
        .take(4097)
        .read_to_string(&mut output)?;
    if output.len() > 4096 {
        return Err(invalid(
            "Scratch filesystem metadata output exceeds its limit",
        ));
    }
    Ok(output)
}

fn filesystem_uuid(path: &Path) -> io::Result<String> {
    let output = probe_filesystem(path)?;
    let uuid = output
        .lines()
        .find_map(|line| line.strip_prefix("UUID="))
        .ok_or_else(|| invalid("Scratch filesystem UUID unavailable"))?
        .to_ascii_lowercase();
    if uuid.len() != 36
        || !uuid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err(invalid("invalid Scratch filesystem UUID"));
    }
    Ok(uuid)
}

fn absence_contains_scratch(
    mountinfo: &str,
    known_mounts: &[&Path],
    known_image: Option<&Path>,
    mut source_label: impl FnMut(&Path) -> io::Result<Option<String>>,
) -> io::Result<bool> {
    for mount in known_mounts {
        if mount_record(mountinfo, mount)?.is_some() {
            return Ok(true);
        }
    }
    let known_image = known_image.map(mount_field).transpose()?;
    let mut inspected = std::collections::HashSet::new();
    for row in mountinfo.lines() {
        let Some((_, mount)) = row.split_once(" - ") else {
            return Err(invalid("invalid Linux mount inventory"));
        };
        let mut fields = mount.split_whitespace();
        let Some((kind, source)) = fields.next().zip(fields.next()) else {
            return Err(invalid("incomplete Linux mount inventory"));
        };
        if known_image.as_deref() == Some(source) {
            return Ok(true);
        }
        if kind == "ext4" && source.starts_with("/dev/loop") || kind == "fuse.ext4" {
            // Mountinfo escapes path separators used as field delimiters.
            let decoded = source
                .replace("\\040", " ")
                .replace("\\011", "\t")
                .replace("\\012", "\n")
                .replace("\\134", "\\");
            if inspected.insert(decoded.clone())
                && source_label(Path::new(&decoded))?.as_deref() == Some("diskm-scratch")
            {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn confirm_absence(home: &Path, configured: Option<&Scratch<'_>>) -> io::Result<()> {
    let default_mount = home.join("Scratch");
    let mut mounts = vec![default_mount.as_path()];
    if let Some(scratch) = configured {
        mounts.push(scratch.mount);
    }
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")?;
    if absence_contains_scratch(
        &mountinfo,
        &mounts,
        configured.map(|scratch| scratch.image),
        |source| {
            if !source.is_absolute() {
                return Err(invalid(
                    "cannot verify the backing source of a possible Scratch mount",
                ));
            }
            let fields = probe_filesystem(source)?;
            Ok(fields
                .lines()
                .find_map(|line| line.strip_prefix("LABEL=").map(str::to_owned)))
        },
    )? {
        return Err(invalid(
            "live Scratch mount has no usable configuration or registry",
        ));
    }
    Ok(())
}

struct VerifiedMount {
    path: PathBuf,
    directory: File,
    uuid: String,
}

// Return None for an unconfigured volume; errors describe unavailable or changed identity.
fn verified_mount(expected: Option<&Path>) -> io::Result<Option<VerifiedMount>> {
    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let config = configuration(&home)?;
    let Some(scratch) = scratch_config(&config)? else {
        confirm_absence(&home, None)?;
        return Ok(None);
    };
    if expected.is_some_and(|expected| expected.as_os_str() != scratch.mount.as_os_str()) {
        return Err(invalid("Scratch mountpoint differs from configuration"));
    }
    let state = env::var_os("DISK_MAGICIAN_STATE_DIR")
        .map_or_else(|| home.join(".disk_magician_state"), PathBuf::from);
    let registry = match json_file(&state.join("volumes/registry.json")) {
        Ok(registry) => registry,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            confirm_absence(&home, Some(&scratch))?;
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    if registry["schema_version"].as_u64() != Some(1) || !registry["volumes"].is_object() {
        return Err(invalid("invalid Scratch registry"));
    }
    let Some(entry) = registry["volumes"].get("scratch") else {
        confirm_absence(&home, Some(&scratch))?;
        return Ok(None);
    };
    if fs::canonicalize(scratch.image)? != scratch.image
        || fs::canonicalize(scratch.mount)? != scratch.mount
        || scratch.image.starts_with(scratch.mount)
        || scratch.mount.starts_with(scratch.image)
        || entry["state"] != "active"
        || entry["image_path"].as_str().map(Path::new) != Some(scratch.image)
        || entry["mountpoint"].as_str().map(Path::new) != Some(scratch.mount)
        || entry["quota_bytes"].as_u64() != Some(scratch.quota)
        || fs::metadata(scratch.image)?.len() != scratch.quota
    {
        return Err(invalid("Scratch registry identity mismatch"));
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(scratch.mount)?;
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")?;
    let expected_type = if scratch.native { "ext4" } else { "fuse.ext4" };
    let device = if scratch.native {
        loop_device(scratch.image)?
    } else {
        scratch.image.to_path_buf()
    };
    let expected_source = mount_field(&device)?;
    let fdinfo = fs::read_to_string(format!("/proc/self/fdinfo/{}", directory.as_raw_fd()))?;
    let mount_id = fdinfo
        .lines()
        .find_map(|line| line.strip_prefix("mnt_id:").map(str::trim))
        .filter(|id| !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()))
        .ok_or_else(|| invalid("opened Scratch mount ID unavailable"))?;
    if mount_record(&mountinfo, scratch.mount)?
        != Some((mount_id, expected_type, expected_source.as_str()))
    {
        return Err(invalid("Scratch mount identity mismatch"));
    }
    let image_uuid = filesystem_uuid(scratch.image)?;
    if entry["filesystem_uuid"].as_str() != Some(image_uuid.as_str())
        || (scratch.native && filesystem_uuid(&device)? != image_uuid)
    {
        return Err(invalid("Scratch filesystem UUID mismatch"));
    }
    let opened = directory.metadata()?;
    let current = fs::symlink_metadata(scratch.mount)?;
    if !current.is_dir() || (opened.dev(), opened.ino()) != (current.dev(), current.ino()) {
        return Err(invalid("Scratch mount changed during verification"));
    }
    Ok(Some(VerifiedMount {
        path: scratch.mount.to_path_buf(),
        directory,
        uuid: image_uuid,
    }))
}

pub fn verified_root(expected: Option<&Path>) -> io::Result<Option<PathBuf>> {
    Ok(verified_mount(expected)?.map(|mount| mount.path))
}

fn allocated_bytes(
    total_blocks: u64,
    available_blocks: u64,
    fragment_bytes: u64,
) -> io::Result<u64> {
    total_blocks
        .checked_sub(available_blocks)
        .and_then(|blocks| blocks.checked_mul(fragment_bytes))
        .filter(|_| fragment_bytes > 0)
        .ok_or_else(|| invalid("invalid Scratch used-byte measurement"))
}

pub(crate) fn mounted_usage(
    path: &Path,
    dev: u64,
    ino: u64,
    filesystem_id: Option<&str>,
) -> io::Result<(String, u64)> {
    let mount = verified_mount(Some(path))?.ok_or_else(|| invalid("Scratch mount unavailable"))?;
    let metadata = mount.directory.metadata()?;
    if (metadata.dev(), metadata.ino()) != (dev, ino)
        || filesystem_id.is_some_and(|expected| expected != mount.uuid)
    {
        return Err(invalid("Scratch root or filesystem identity changed"));
    }
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // fstatvfs measures the same opened mount that passed the identity checks.
    if unsafe { libc::fstatvfs(mount.directory.as_raw_fd(), stats.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let stats = unsafe { stats.assume_init() };
    // Match legacy volume status: total minus space available to the caller,
    // including filesystem-reserved blocks in the usage against the target.
    #[allow(clippy::unnecessary_cast)] // The statvfs field widths vary by Linux architecture.
    let used = allocated_bytes(
        stats.f_blocks as u64,
        stats.f_bavail as u64,
        stats.f_frsize as u64,
    )?;
    Ok((mount.uuid, used))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_registration_requires_absence_of_configured_and_labeled_mounts() {
        let mountinfo = "36 25 7:2 / /custom/Scratch rw - ext4 /dev/loop2 rw";
        let known = Path::new("/custom/Scratch");
        assert!(absence_contains_scratch(mountinfo, &[known], None, |_| Ok(None)).unwrap());
        assert!(absence_contains_scratch(mountinfo, &[], None, |source| {
            assert_eq!(source, Path::new("/dev/loop2"));
            Ok(Some("diskm-scratch".into()))
        })
        .unwrap());
        assert!(
            !absence_contains_scratch(mountinfo, &[], None, |_| Ok(Some("unrelated".into())))
                .unwrap()
        );
        assert!(
            absence_contains_scratch(mountinfo, &[], None, |_| Err(invalid("unreadable label")))
                .is_err()
        );
    }

    #[test]
    fn configured_linux_mount_requires_valid_backend_quota_and_absolute_paths() {
        let mut config = serde_json::json!({
            "volumes": {
                "encryption": "none",
                "swap_headroom_gb": 8,
                "alarm_floor_gb": 20,
                "classes": {"scratch": {
                    "name": "diskm-scratch",
                    "backend": "native",
                    "image_path": "/home/test/scratch.ext4",
                    "mountpoint": "/home/test/Scratch",
                    "quota_gb": 200
                }}
            }
        });
        let scratch = scratch_config(&config).unwrap().unwrap();
        assert!(scratch.native);
        assert_eq!(scratch.quota, 200 * GIB);
        config["volumes"]["classes"]["scratch"]["backend"] = "fuse".into();
        assert!(!scratch_config(&config).unwrap().unwrap().native);
        config["volumes"]["classes"]["scratch"]["mountpoint"] = "relative".into();
        assert!(scratch_config(&config).is_err());
        assert!(scratch_config(&serde_json::json!({})).unwrap().is_none());
    }

    #[test]
    fn target_usage_counts_blocks_unavailable_to_the_caller() {
        assert_eq!(allocated_bytes(100, 70, 4096).unwrap(), 30 * 4096);
        assert!(allocated_bytes(70, 100, 4096).is_err());
        assert!(allocated_bytes(100, 70, 0).is_err());
        assert!(allocated_bytes(u64::MAX, 0, 4096).is_err());
    }

    #[test]
    fn mountinfo_requires_the_exact_mount_and_rejects_ambiguity() {
        let row = "36 25 7:0 / /home/test/Scratch\\040space rw - ext4 /dev/loop0 rw";
        let mount = Path::new("/home/test/Scratch space");
        assert_eq!(
            mount_record(row, mount).unwrap(),
            Some(("36", "ext4", "/dev/loop0"))
        );
        assert_eq!(
            mount_record(row, Path::new("/home/test/Scratch")).unwrap(),
            None
        );
        assert!(mount_record(&format!("{row}\n{row}"), mount).is_err());
        assert!(mount_record("36 25 7:0 / /home/test/Scratch\\040space rw", mount).is_err());
    }
}

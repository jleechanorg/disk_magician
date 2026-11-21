//! Read-only Scratch mount identity on Linux.

use serde_json::Value;
use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const GIB: u64 = 1024 * 1024 * 1024;

fn invalid(message: &'static str) -> io::Error {
    io::Error::other(message)
}

fn json_file(path: &Path) -> io::Result<Value> {
    serde_json::from_slice(&fs::read(path)?).map_err(io::Error::other)
}

fn configuration(home: &Path) -> io::Result<Value> {
    if let Some(path) = env::var_os("DISK_MAGICIAN_CONFIG").filter(|path| !path.is_empty()) {
        return json_file(Path::new(&path));
    }
    let user = env::var_os("XDG_CONFIG_HOME")
        .map_or_else(|| home.join(".config"), PathBuf::from)
        .join("disk-magician/config.json");
    let mut overlay_state = None;
    if user.is_file() {
        let document = json_file(&user)?;
        let overlay = document.as_object().is_some_and(|doc| {
            !doc.is_empty()
                && doc
                    .keys()
                    .all(|key| matches!(key.as_str(), "snapshot_measure" | "state_repo_path"))
        });
        if !overlay {
            return Ok(document);
        }
        overlay_state = document["state_repo_path"]
            .as_str()
            .filter(|path| !path.is_empty())
            .map(|path| match path {
                "~" => home.to_path_buf(),
                path if path.starts_with("~/") => home.join(&path[2..]),
                path => home.join(path),
            });
    }
    let state = env::var_os("DISK_MAGICIAN_STATE_REPO")
        .map(PathBuf::from)
        .or(overlay_state)
        .unwrap_or_else(|| {
            env::var_os("XDG_STATE_HOME")
                .map_or_else(|| home.join(".local/state"), PathBuf::from)
                .join("disk-magician")
        });
    let config = state.join("config/config.json");
    if config.is_file() {
        return json_file(&config);
    }
    serde_json::from_str(include_str!("../../config.json.template")).map_err(io::Error::other)
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

fn mount_record<'a>(mountinfo: &'a str, mount: &Path) -> io::Result<Option<(&'a str, &'a str)>> {
    let escaped = mount_field(mount)?;
    let mut found = None;
    for line in mountinfo.lines() {
        let mut fields = line.split_whitespace();
        if fields.nth(4) != Some(escaped.as_str()) {
            continue;
        }
        if found.is_some() {
            return Err(invalid("Scratch mountpoint has stacked mounts"));
        }
        if !fields.any(|field| field == "-") {
            return Err(invalid("invalid mountinfo row for Scratch"));
        }
        found = Some(
            fields
                .next()
                .zip(fields.next())
                .ok_or_else(|| invalid("incomplete Scratch mount record"))?,
        );
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

fn filesystem_uuid(path: &Path) -> io::Result<String> {
    let mut child = Command::new("blkid")
        .args(["-p", "-s", "UUID", "-o", "value"])
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
    let mut uuid = String::new();
    child
        .stdout
        .take()
        .ok_or_else(|| invalid("Scratch UUID output unavailable"))?
        .take(128)
        .read_to_string(&mut uuid)?;
    let uuid = uuid.trim().to_ascii_lowercase();
    if uuid.len() != 36
        || !uuid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err(invalid("invalid Scratch filesystem UUID"));
    }
    Ok(uuid)
}

/// Return None for an unconfigured volume; errors describe unavailable or changed identity.
pub fn verified_root(expected: Option<&Path>) -> io::Result<Option<PathBuf>> {
    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let config = configuration(&home)?;
    let Some(scratch) = scratch_config(&config)? else {
        return Ok(None);
    };
    if expected.is_some_and(|expected| expected.as_os_str() != scratch.mount.as_os_str()) {
        return Err(invalid("Scratch mountpoint differs from configuration"));
    }
    let state = env::var_os("DISK_MAGICIAN_STATE_DIR")
        .map_or_else(|| home.join(".disk_magician_state"), PathBuf::from);
    let registry = match json_file(&state.join("volumes/registry.json")) {
        Ok(registry) => registry,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if registry["schema_version"].as_u64() != Some(1) || !registry["volumes"].is_object() {
        return Err(invalid("invalid Scratch registry"));
    }
    let Some(entry) = registry["volumes"].get("scratch") else {
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
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")?;
    let expected_type = if scratch.native { "ext4" } else { "fuse.ext4" };
    let device = if scratch.native {
        loop_device(scratch.image)?
    } else {
        scratch.image.to_path_buf()
    };
    let expected_source = device
        .to_str()
        .ok_or_else(|| invalid("invalid Scratch source encoding"))?;
    if mount_record(&mountinfo, scratch.mount)? != Some((expected_type, expected_source)) {
        return Err(invalid("Scratch mount identity mismatch"));
    }
    let image_uuid = filesystem_uuid(scratch.image)?;
    if entry["filesystem_uuid"].as_str() != Some(image_uuid.as_str())
        || (scratch.native && filesystem_uuid(&device)? != image_uuid)
    {
        return Err(invalid("Scratch filesystem UUID mismatch"));
    }
    Ok(Some(scratch.mount.to_path_buf()))
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn mountinfo_requires_the_exact_mount_and_rejects_ambiguity() {
        let row = "36 25 7:0 / /home/test/Scratch\\040space rw - ext4 /dev/loop0 rw";
        let mount = Path::new("/home/test/Scratch space");
        assert_eq!(
            mount_record(row, mount).unwrap(),
            Some(("ext4", "/dev/loop0"))
        );
        assert_eq!(
            mount_record(row, Path::new("/home/test/Scratch")).unwrap(),
            None
        );
        assert!(mount_record(&format!("{row}\n{row}"), mount).is_err());
        assert!(mount_record("36 25 7:0 / /home/test/Scratch\\040space rw", mount).is_err());
    }
}

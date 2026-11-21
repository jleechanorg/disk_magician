//! Verification of the APFS identity documents used to measure Scratch usage.

use serde_json::Value;
use std::io;
use std::path::Path;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ApfsScratch<'a> {
    pub(crate) container: &'a str,
    pub(crate) device: &'a str,
    pub(crate) uuid: &'a str,
    pub(crate) allocated_bytes: u64,
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

pub(crate) fn registered_scratch<'a>(
    listing: &'a Value,
    data: &Value,
    entry: &Value,
    path: &Path,
    quota: u64,
    encrypted: bool,
) -> io::Result<ApfsScratch<'a>> {
    let data_ref = required_text(data, "APFSContainerReference")?;
    let mut containers = listing["Containers"]
        .as_array()
        .ok_or_else(|| invalid("APFS containers unavailable"))?
        .iter()
        .filter(|row| row["ContainerReference"] == data_ref);
    let container = containers
        .next()
        .filter(|_| containers.next().is_none())
        .ok_or_else(|| invalid("Data APFS container is missing or ambiguous"))?;
    let container_uuid = required_text(container, "APFSContainerUUID")?;
    if entry["state"] != "active"
        || entry["class"] != "scratch"
        || entry["name"] != "diskm-scratch"
        || entry["mountpoint"].as_str().map(Path::new) != Some(path)
        || entry["container_uuid"] != container_uuid
        || entry["quota_bytes"].as_u64() != Some(quota)
    {
        return Err(invalid("registered APFS Scratch identity mismatch"));
    }

    let mut volumes = container["Volumes"]
        .as_array()
        .ok_or_else(|| invalid("Data APFS volume inventory unavailable"))?
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
        allocated_bytes: volume["CapacityInUse"]
            .as_u64()
            .ok_or_else(|| invalid("Scratch APFS used-byte measurement unavailable"))?,
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

fn check_capacity(
    listing: &Value,
    scratch: &ApfsScratch<'_>,
    quota: u64,
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
    let fit = other
        + u128::from(vm.max(swap_headroom))
        + u128::from(scratch.allocated_bytes)
        + u128::from(alarm_floor);
    let provisioned = other + u128::from(vm) + u128::from(quota);
    if counts != [1, 1, 1] || fit > u128::from(ceiling) || provisioned > u128::from(ceiling) {
        return Err(invalid("APFS Scratch capacity alarm"));
    }
    if u128::from(scratch.allocated_bytes) * 10 >= u128::from(quota) * 9 {
        return Err(invalid("APFS Scratch volume usage alarm"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
pub(crate) fn mounted_usage(
    path: &Path,
    dev: u64,
    ino: u64,
    filesystem_id: Option<&str>,
) -> io::Result<(String, u64)> {
    use std::env;
    use std::fs::{self, OpenOptions};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::PathBuf;

    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    let config = crate::volume_config::configuration(&home)?;
    let volumes = &config["volumes"];
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
    if scratch["name"] != "diskm-scratch"
        || !matches!(
            scratch.get("backend").map(Value::as_str),
            None | Some(Some("fuse" | "native"))
        )
        || [("swap_headroom_gb", volumes), ("alarm_floor_gb", volumes)]
            .into_iter()
            .any(|(key, table)| positive(&table[key]).is_none())
        || ["trigger_pct", "target_pct"].into_iter().any(|key| {
            scratch
                .get(key)
                .is_some_and(|value| positive(value).is_none())
        })
        || !path.is_absolute()
        || scratch["mountpoint"].as_str().map(Path::new) != Some(path)
        || fs::canonicalize(path)? != path
    {
        return Err(invalid("invalid APFS Scratch configuration or root"));
    }
    let quota = positive(&scratch["quota_gb"])
        .and_then(|amount| amount.checked_mul(1024 * 1024 * 1024))
        .ok_or_else(|| invalid("invalid APFS Scratch quota"))?;
    let state = env::var_os("DISK_MAGICIAN_STATE_DIR")
        .map_or_else(|| home.join(".disk_magician_state"), PathBuf::from);
    let registry = crate::volume_config::json_file(&state.join("volumes/registry.json"))?;
    if registry["schema_version"].as_u64() != Some(1) {
        return Err(invalid("invalid APFS Scratch registry"));
    }

    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    let opened = directory.metadata()?;
    if (opened.dev(), opened.ino()) != (dev, ino) {
        return Err(invalid("Scratch root identity changed"));
    }

    let listing = diskutil_document(&["apfs", "list", "-plist"])?;
    let data = diskutil_document(&["info", "-plist", "/System/Volumes/Data"])?;
    let scratch = registered_scratch(
        &listing,
        &data,
        &registry["volumes"]["scratch"],
        path,
        quota,
        encrypted,
    )?;
    if filesystem_id.is_some_and(|expected| expected != scratch.uuid) {
        return Err(invalid("Scratch filesystem identity changed"));
    }
    let path_text = path
        .to_str()
        .ok_or_else(|| invalid("invalid Scratch mountpoint encoding"))?;
    let info = diskutil_document(&["info", "-plist", path_text])?;
    verify_info(&scratch, &info, path)?;
    // Preserve the alarm interlock of the legacy status probe used by target apply.
    let configured_bytes = |key| {
        positive(&volumes[key])
            .and_then(|amount| amount.checked_mul(1024 * 1024 * 1024))
            .ok_or_else(|| invalid("invalid APFS capacity setting"))
    };
    check_capacity(
        &listing,
        &scratch,
        quota,
        configured_bytes("swap_headroom_gb")?,
        configured_bytes("alarm_floor_gb")?,
    )?;
    let ballast = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path.join(".diskm-ballast"))?
        .metadata()?;
    const BALLAST_BYTES: u64 = 64 * 1024 * 1024;
    if !ballast.is_file()
        || ballast.len() != BALLAST_BYTES
        || ballast.blocks() < BALLAST_BYTES / 512
    {
        return Err(invalid("APFS Scratch ballast missing or unallocated"));
    }
    let current = fs::symlink_metadata(path)?;
    if !current.is_dir() || (current.dev(), current.ino()) != (dev, ino) {
        return Err(invalid("Scratch mount changed during verification"));
    }
    Ok((scratch.uuid.to_owned(), scratch.allocated_bytes))
}

#[cfg(target_os = "macos")]
fn diskutil_document(args: &[&str]) -> io::Result<Value> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::thread;
    use std::time::{Duration, Instant};

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
            _ if started.elapsed() >= Duration::from_secs(30) => {
                break Err(invalid("APFS Scratch identity probe timed out"));
            }
            _ => thread::sleep(Duration::from_millis(20)),
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn volumes() -> (Value, Value, Value, Value) {
        let listing = json!({
            "Containers": [
                {"ContainerReference":"disk7","APFSContainerUUID":"other-container","Volumes":[]},
                {"ContainerReference":"disk3","APFSContainerUUID":"data-container",
                "CapacityCeiling":1099511627776u64,"CapacityFree":21474836480u64,"Volumes":[{
                    "Name":"diskm-scratch","APFSVolumeUUID":"scratch-uuid","DeviceIdentifier":"disk3s7",
                    "CapacityQuota":512,"CapacityInUse":123,"Roles":[],"Encryption":true,"Locked":false
                }, {
                    "Name":"Data","APFSVolumeUUID":"data-uuid","CapacityInUse":1024,"Roles":["Data"]
                }, {
                    "Name":"System","APFSVolumeUUID":"system-uuid","CapacityInUse":1024,"Roles":["System"]
                }, {
                    "Name":"VM","APFSVolumeUUID":"vm-uuid","CapacityInUse":1024,"Roles":["VM"]
                }]}
            ]
        });
        let data = json!({"APFSContainerReference":"disk3"});
        let registry = json!({
            "class":"scratch","state":"active","name":"diskm-scratch","mountpoint":"/Volumes/diskm-scratch",
            "uuid":"scratch-uuid","container_uuid":"data-container","quota_bytes":512
        });
        let info = json!({
            "VolumeUUID":"scratch-uuid","APFSContainerReference":"disk3","DeviceIdentifier":"disk3s7",
            "MountPoint":"/Volumes/diskm-scratch","Encryption":true,"Locked":false
        });
        (listing, data, registry, info)
    }

    #[test]
    fn requires_both_apfs_documents_to_agree_on_the_registered_mount() {
        let (listing, data, entry, mut info) = volumes();
        let path = Path::new("/Volumes/diskm-scratch");
        let volume = registered_scratch(&listing, &data, &entry, path, 512, true).unwrap();
        assert_eq!(volume.allocated_bytes, 123);
        assert_eq!(volume.device, "disk3s7");
        assert!(verify_info(&volume, &info, path).is_ok());
        info["MountPoint"] = "/Volumes/diskm-scratch 1".into();
        assert!(verify_info(&volume, &info, path).is_err());
        info["MountPoint"] = "/Volumes/diskm-scratch".into();
        info["DeviceIdentifier"] = "disk7s1".into();
        assert!(verify_info(&volume, &info, path).is_err());
    }

    #[test]
    fn target_measurement_keeps_legacy_capacity_and_usage_alarms() {
        let (mut listing, data, entry, _) = volumes();
        let path = Path::new("/Volumes/diskm-scratch");
        let scratch = registered_scratch(&listing, &data, &entry, path, 512, true).unwrap();
        assert!(check_capacity(&listing, &scratch, 512, 1024, 1024).is_ok());
        assert!(check_capacity(&listing, &scratch, 512, u64::MAX, 1024).is_err());
        let mut alarm = listing.clone();
        alarm["Containers"][1]["CapacityFree"] = 10.into();
        assert!(check_capacity(&alarm, &scratch, 512, 1024, 1024).is_err());
        listing["Containers"][1]["Volumes"][0]["CapacityInUse"] = 500.into();
        let scratch = registered_scratch(&listing, &data, &entry, path, 512, true).unwrap();
        assert!(check_capacity(&listing, &scratch, 512, 1024, 1024).is_err());
    }

    #[test]
    fn rejects_duplicate_volume_wrong_quota_and_locked_encrypted_mount() {
        let (mut listing, data, entry, mut info) = volumes();
        let path = Path::new("/Volumes/diskm-scratch");
        assert!(registered_scratch(&listing, &data, &entry, path, 1024, true).is_err());
        let volume = registered_scratch(&listing, &data, &entry, path, 512, true).unwrap();
        info["Locked"] = true.into();
        assert!(verify_info(&volume, &info, path).is_err());
        listing["Containers"][1]["Volumes"][0]["Locked"] = true.into();
        assert!(registered_scratch(&listing, &data, &entry, path, 512, true).is_err());
        listing["Containers"][1]["Volumes"][0]["Locked"] = false.into();
        let duplicate = listing["Containers"][1]["Volumes"][0].clone();
        listing["Containers"][1]["Volumes"]
            .as_array_mut()
            .unwrap()
            .push(duplicate);
        assert!(registered_scratch(&listing, &data, &entry, path, 512, true).is_err());
    }
}

//! Native capacity snapshot using the existing history fields.

use crate::status;
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn collect(root: &Path) -> io::Result<Value> {
    let capacity = status::status(root, None)?.capacity;
    let date = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()?;
    if !date.status.success() {
        return Err(io::Error::other("cannot obtain snapshot timestamp"));
    }
    let timestamp = std::str::from_utf8(&date.stdout)
        .map_err(io::Error::other)?
        .trim();
    // A capacity sample does not claim coverage of the file inventory.
    let gib = |bytes| bytes as f64 / 1_073_741_824.0;
    Ok(json!({
        "timestamp": timestamp,
        "disk_total_gb": gib(capacity.total_bytes),
        "disk_used_gb": gib(capacity.used_bytes),
        "disk_free_gb": gib(capacity.available_bytes),
        "measurement_status": "partial",
        "snapshot_metadata": {
            "captured_at": timestamp,
            "measurement_status": "partial",
            "scope": "capacity_only",
            "mounted_at": capacity.mounted_at,
        },
    }))
}

pub fn publish(path: &Path, snapshot: &Value) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|part| !part.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let parent = fs::canonicalize(parent)?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::other("snapshot output needs a filename"))?;
    let destination = parent.join(name);
    match fs::symlink_metadata(&destination) {
        Ok(meta) if !meta.is_file() => {
            return Err(io::Error::other("snapshot output must be a regular file"))
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let staging = parent.join(format!(".diskm-snapshot-{}-{nonce}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staging)?;
    let result = (|| {
        serde_json::to_writer_pretty(&mut file, snapshot).map_err(io::Error::other)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&staging, &destination)?;
        File::open(&parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&staging);
    }
    result
}

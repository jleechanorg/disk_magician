//! Native capacity snapshot using the existing history fields.

use crate::{job_receipt, status};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn collect(root: &Path) -> io::Result<Value> {
    let capacity = status::status(root, None)?.capacity;
    let timestamp = job_receipt::timestamp(SystemTime::now())?;
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

/// Collect capacity, publish the snapshot locally, and record a native terminal
/// receipt. The report remains partial because this command does not scan files.
pub fn run(
    root: &Path,
    state_dir_override: Option<&Path>,
    output_override: Option<&Path>,
) -> io::Result<Value> {
    let started = SystemTime::now();
    let state_dir = job_receipt::state_dir(state_dir_override)?;
    let output = if let Some(output) = output_override {
        output.to_path_buf()
    } else {
        let snapshots = state_dir.join("snapshots");
        fs::create_dir_all(&snapshots)?;
        snapshots.join("disk_snapshot.json")
    };
    let before = status::status(root, None)?.capacity;
    let collected = collect(root);
    match collected {
        Ok(snapshot) => {
            if let Err(error) = publish(&output, &snapshot) {
                let post = json!({"snapshot_path":output,"published":false,"free_bytes":null,"freed_bytes":null});
                let _ = job_receipt::publish_terminal(
                    &state_dir,
                    "snapshot_commit",
                    started,
                    Err(&error.to_string()),
                    json!({"available_bytes":before.available_bytes}),
                    post,
                    json!({"committed":false,"pushed":false,"status":"local_write_failed"}),
                );
                return Err(error);
            }
            let available_after = status::status(root, None)
                .ok()
                .map(|report| report.capacity.available_bytes);
            let result = json!({
                "snapshot":snapshot,
                "snapshot_path":output,
                "postcondition":{
                    "available_bytes":available_after,
                    "allocated_bytes":null,
                    "freed_bytes":null
                }
            });
            let delta =
                available_after.map(|after| i128::from(after) - i128::from(before.available_bytes));
            job_receipt::publish_terminal(
                &state_dir,
                "snapshot_commit",
                started,
                Ok(()),
                json!({"available_bytes":before.available_bytes}),
                json!({
                    "available_bytes":available_after,
                    "df_delta_bytes":delta,
                    "freed_bytes":null,
                    "measurement_status":"partial",
                    "coverage_pct":null
                }),
                json!({"committed":false,"pushed":false,"status":"local_only"}),
            )?;
            Ok(result)
        }
        Err(error) => {
            let _ = job_receipt::publish_terminal(
                &state_dir,
                "snapshot_commit",
                started,
                Err(&error.to_string()),
                json!({"available_bytes":before.available_bytes}),
                json!({"available_bytes":null,"freed_bytes":null}),
                json!({"committed":false,"pushed":false,"status":"snapshot_failed"}),
            );
            Err(error)
        }
    }
}

//! Native capacity snapshot using the existing history fields.

use crate::{job_receipt, preview, status};
use serde_json::{json, Value};
use std::fs;
use std::io;
use std::path::Path;
use std::time::SystemTime;

pub fn collect(root: &Path) -> io::Result<Value> {
    format_sample(root, &status::status(root, None)?.capacity)
}

fn format_sample(root: &Path, capacity: &status::CapacityReport) -> io::Result<Value> {
    if cfg!(target_os = "macos")
        && root == Path::new("/System/Volumes/Data")
        && capacity.mounted_at != "/System/Volumes/Data"
    {
        return Err(io::Error::other(
            "Data volume is not mounted at /System/Volumes/Data",
        ));
    }
    let host = std::process::Command::new("hostname").output()?;
    let hostname = std::str::from_utf8(&host.stdout)
        .map_err(io::Error::other)?
        .trim();
    if !host.status.success() || hostname.is_empty() {
        return Err(io::Error::other("cannot identify snapshot host"));
    }
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
            "filesystem": capacity.filesystem,
            "hostname": hostname,
            "used_kib": capacity.used_bytes / 1024,
        },
    }))
}

pub fn publish(path: &Path, snapshot: &Value) -> io::Result<()> {
    let absolute = std::env::current_dir()?.join(path);
    preview::write_checkpoint(&absolute, snapshot)
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
    let output = output_override.map_or_else(
        || state_dir.join("snapshots/disk_snapshot.json"),
        Path::to_path_buf,
    );
    let mut before = None;
    let mut phase = "snapshot_failed";
    let result = (|| -> io::Result<Value> {
        let capacity = status::status(root, None)?.capacity;
        before = Some(capacity.available_bytes);
        let snapshot = format_sample(root, &capacity)?;
        phase = "local_write_failed";
        if output_override.is_none() {
            fs::create_dir_all(state_dir.join("snapshots"))?;
        }
        publish(&output, &snapshot)?;
        phase = "local_only";
        let available_after = status::status(root, None)
            .ok()
            .map(|report| report.capacity.available_bytes);
        Ok(
            json!({"snapshot":snapshot,"snapshot_path":output,"postcondition":{
                "available_bytes":available_after,"allocated_bytes":null,"freed_bytes":null
            }}),
        )
    })();
    let reason;
    let (completion, postcondition) = match &result {
        Ok(value) => {
            let available = value["postcondition"]["available_bytes"].as_u64();
            let delta = available
                .zip(before)
                .map(|(after, before)| i128::from(after) - i128::from(before));
            (
                job_receipt::Completion::Success,
                json!({
                    "available_bytes":available,"df_delta_bytes":delta,"freed_bytes":null,
                    "measurement_status":"partial","coverage_pct":null
                }),
            )
        }
        Err(error) => {
            reason = error.to_string();
            (
                job_receipt::Completion::Error(&reason),
                json!({
                    "snapshot_path":output,"published":false,"available_bytes":null,"freed_bytes":null
                }),
            )
        }
    };
    let receipt = job_receipt::publish_terminal(
        &state_dir,
        "snapshot_commit",
        started,
        completion,
        json!({"available_bytes":before}),
        postcondition,
        json!({"committed":false,"pushed":false,"status":phase}),
    );
    result.and_then(|value| receipt.map(|_| value))
}

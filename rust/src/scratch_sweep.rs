//! One native Scratch pressure pass. All mutation uses the exact actuator.

use crate::{job_receipt, preview, scan, scratch_manifest, scratch_target, volume_config};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub struct Options {
    pub clean: bool,
    pub min_hours: u32,
    pub limit: usize,
    pub deadline: Duration,
    pub paths: Vec<PathBuf>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            clean: false,
            min_hours: 48,
            limit: 20,
            deadline: Duration::from_secs(30),
            paths: Vec::new(),
        }
    }
}

pub fn run(options: &Options) -> io::Result<(Value, bool)> {
    let started = SystemTime::now();
    let state = job_receipt::state_dir(None)?;
    let mut precondition = Value::Null;
    let result = sweep(&state, options, started, &mut precondition);
    let reason;
    let (postcondition, completion) = match &result {
        Ok((report, true)) => (report.clone(), job_receipt::Completion::Success),
        Ok((report, false)) => (
            report.clone(),
            job_receipt::Completion::Partial(report["status"].as_str().unwrap_or("partial")),
        ),
        Err(error) => {
            reason = error.to_string();
            (Value::Null, job_receipt::Completion::Error(&reason))
        }
    };
    job_receipt::publish_terminal(
        &state,
        "scratch_sweep",
        started,
        completion,
        precondition,
        postcondition,
        json!({"committed":false,"pushed":false,"status":"local_only"}),
    )?;
    result
}

fn sweep(
    state: &Path,
    options: &Options,
    started: SystemTime,
    precondition: &mut Value,
) -> io::Result<(Value, bool)> {
    let (root, device) = preview::registered_scratch()?;
    let home = PathBuf::from(
        std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME is unavailable"))?,
    );
    let config = volume_config::configuration(&home)?;
    let scratch = &config["volumes"]["classes"]["scratch"];
    let quota = scratch["quota_gb"]
        .as_u64()
        .and_then(|amount| amount.checked_mul(1 << 30))
        .ok_or_else(|| io::Error::other("invalid Scratch quota"))?;
    let trigger = scratch["trigger_pct"].as_u64().unwrap_or(70);
    let target = scratch["target_pct"].as_u64().unwrap_or(50);
    if target == 0 || target > trigger || trigger > 100 || quota == 0 {
        return Err(io::Error::other("invalid Scratch trigger or target"));
    }
    let percent = |pct: u64| (u128::from(quota) * u128::from(pct) / 100) as u64;
    let used = scratch_target::measure_usage(&root, device)?;
    let target_used = percent(target);
    *precondition = json!({"root":root,"used_bytes":used,"quota_bytes":quota,"trigger_pct":trigger,"target_pct":target,"min_hours":options.min_hours});
    if used <= percent(trigger) {
        return Ok((
            json!({"status":"below_trigger","removed":0,"freed_bytes":null}),
            true,
        ));
    }

    let cutoff = preview::current_cutoff(options.min_hours)?;
    let scan_options = scan::ScanOptions {
        deadline: options.deadline,
        max_entries: usize::MAX,
    };
    let mut holds = BTreeMap::new();
    let (mut paths, scan_complete, gaps) = if options.paths.is_empty() {
        discover(&root, device, cutoff, scan_options, &mut holds)?
    } else {
        (options.paths.clone(), true, Vec::new())
    };
    let unchecked = paths.len().saturating_sub(options.limit);
    paths.truncate(options.limit);
    let qualification = (!paths.is_empty())
        .then(|| scratch_manifest::qualify_exact(&paths, cutoff, scan_options, 1))
        .transpose()?;
    let mut eligible: Vec<_> = qualification
        .iter()
        .flat_map(|report| &report.entries)
        .filter(|row| row.verdict == "remove")
        .collect();
    eligible.sort_unstable_by(|a, b| {
        a.modified_epoch_nanos
            .cmp(&b.modified_epoch_nanos)
            .then_with(|| a.path.cmp(&b.path))
    });
    let plan_complete = scan_complete
        && unchecked == 0
        && !holds.keys().any(|reason| reason.starts_with("deferred:"))
        && qualification.as_ref().is_none_or(|report| report.complete);
    let mut result = json!({"status":"dry_run","before_epoch_seconds":cutoff,"scan_complete":scan_complete,"gaps":gaps,"unchecked":unchecked,"discovery_holds":holds,
        "qualification":qualification,"eligible":eligible.len(),"removed":0,"freed_bytes":null});
    if !options.clean {
        return Ok((result, plan_complete));
    }
    if eligible.is_empty() {
        result["status"] = json!("pressure_unresolved");
        return Ok((result, false));
    }
    let paths: Vec<_> = eligible.iter().map(|row| row.path.clone()).collect();
    let manifest = scratch_manifest::create(&paths, cutoff)?;
    let state = state.canonicalize()?;
    if state.starts_with(&root) {
        return Err(io::Error::other("sweep state must be outside Scratch"));
    }
    let work = state.join("sweeps");
    fs::create_dir_all(&work)?;
    let nonce = started
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let attempt = work.join(format!("{}-{nonce}", std::process::id()));
    DirBuilder::new().mode(0o700).create(&attempt)?;
    let manifest_path = attempt.join("manifest.json");
    let resume = attempt.join("resume.json");
    let bytes = serde_json::to_vec(&manifest)?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    write_durable(&manifest_path, &bytes)?;
    write_durable(
        &attempt.join("request.json"),
        &serde_json::to_vec(&json!({"manifest_sha256":digest,"target_used_bytes":target_used}))?,
    )?;
    File::open(&attempt)?.sync_all()?;
    File::open(&work)?.sync_all()?;
    File::open(&state)?.sync_all()?;
    let applied = scratch_target::apply(
        &manifest_path,
        &digest,
        &resume,
        target_used,
        &[],
        true,
        None,
    )?;
    result["status"] = json!(&applied.status);
    result["attempt"] = json!(attempt);
    result["removed"] = json!(applied
        .receipts
        .iter()
        .filter(|row| row.result == "removed")
        .count());
    result["apply"] = serde_json::to_value(&applied)?;
    result["volume_used_delta_bytes"] = json!(applied
        .used_before_bytes
        .zip(applied.used_after_bytes)
        .map(|(before, after)| i128::from(after) - i128::from(before)));
    Ok((result, applied.target_reached))
}

fn discover(
    root: &Path,
    device: u64,
    cutoff: i64,
    options: scan::ScanOptions,
    holds: &mut BTreeMap<&'static str, usize>,
) -> io::Result<(Vec<PathBuf>, bool, Vec<scan::ScanGap>)> {
    let runs = root.join("runs");
    match fs::symlink_metadata(&runs) {
        Ok(metadata) if metadata.is_dir() && metadata.dev() == device => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok((Vec::new(), true, Vec::new()))
        }
        _ => return Err(io::Error::other("invalid native runs directory")),
    }
    let report = scan::scan(&runs, options)?;
    let mut old: Vec<_> = report
        .files
        .into_iter()
        .filter(|row| {
            row.kind == scan::FileKind::File
                && row
                    .modified_epoch_seconds
                    .is_some_and(|stamp| stamp < cutoff)
        })
        .collect();
    old.sort_unstable_by(|a, b| {
        a.modified_epoch_seconds
            .cmp(&b.modified_epoch_seconds)
            .then_with(|| a.path.cmp(&b.path))
    });
    let mut leases = HashMap::new();
    let mut paths = Vec::new();
    for row in old {
        if row.path_bytes_hex.is_some() {
            *holds.entry("kept:non-utf8").or_default() += 1;
            continue;
        }
        let path = PathBuf::from(row.path);
        let lease = path
            .strip_prefix(root)
            .map_err(|_| "kept:outside-scratch")
            .and_then(|relative| scratch_target::build_bundle(root, relative))
            .and_then(|bundle| {
                *leases
                    .entry(bundle.clone())
                    .or_insert_with(|| scratch_target::check_completed_build(root, &bundle))
            });
        match lease {
            Ok(()) => paths.push(path),
            Err(reason) => *holds.entry(reason).or_default() += 1,
        }
    }
    Ok((paths, report.complete, report.gaps))
}

fn write_durable(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

//! One native Scratch pressure pass. All mutation uses the exact actuator.

use crate::{
    job_receipt, preview, scan, scratch_lease, scratch_manifest, scratch_target, volume_config,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub struct Options {
    pub clean: bool,
    pub system_tmp: bool,
    pub min_hours: u32,
    pub limit: usize,
    pub deadline: Duration,
    pub paths: Vec<PathBuf>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            clean: false,
            system_tmp: false,
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
        if options.system_tmp {
            "tmp_sweep"
        } else {
            "scratch_sweep"
        },
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
    let (root, device) = if options.system_tmp {
        let root = scratch_lease::temp_path()?;
        let device = fs::symlink_metadata(&root)?.dev();
        (root, device)
    } else {
        preview::registered_scratch()?
    };
    let recovery = if options.clean && options.paths.is_empty() {
        scratch_target::recover_sweeps(state, &root)?
    } else {
        Vec::new()
    };
    let recovered = recovery.iter().all(|entry| entry.get("error").is_none());
    *precondition = json!({"root":root,"min_hours":options.min_hours});
    let target_used = if options.system_tmp {
        Some(1)
    } else {
        capacity_target(&root, device, precondition)?
    };
    let Some(target_used) = target_used else {
        return Ok((
            json!({"status":"below_trigger","removed":0,"freed_bytes":null,"recovery":recovery}),
            recovered,
        ));
    };

    let cutoff = preview::current_cutoff(options.min_hours)?;
    let scan_options = scan::ScanOptions {
        deadline: options.deadline,
        max_entries: usize::MAX,
    };
    let mut holds = BTreeMap::new();
    let (mut paths, scan_complete, gaps) = if !options.paths.is_empty() {
        (options.paths.clone(), true, Vec::new())
    } else if options.system_tmp {
        (
            discover_temp(&root, device, cutoff, &mut holds)?,
            true,
            Vec::new(),
        )
    } else {
        let checkpoint = options.clean.then(|| state.join("scratch-discovery.json"));
        discover(
            &root,
            device,
            cutoff,
            scan_options,
            &mut holds,
            checkpoint.as_deref(),
        )?
    };
    let cursor = (options.clean && options.paths.is_empty()).then(|| {
        state.join(if options.system_tmp {
            "tmp-cursor.json"
        } else {
            "scratch-cursor.json"
        })
    });
    if let Some(path) = &cursor {
        if let Some(Some((hours, next))) = preview::load_checkpoint::<Option<(u32, PathBuf)>>(path)?
        {
            if let Some(index) = paths
                .iter()
                .position(|path| *path == next && hours == options.min_hours)
            {
                paths.rotate_left(index);
            }
        }
    }
    let start_checks = Instant::now();
    let mut qualification: Option<scratch_manifest::QualificationReport> = None;
    for batch in paths.chunks(options.limit) {
        let report = scratch_manifest::qualify_under_roots(
            batch,
            cutoff,
            scan_options,
            1,
            vec![root.clone()],
            Some(root.clone()),
        )?;
        let ready = report.entries.iter().any(|row| row.verdict == "remove");
        if let Some(total) = &mut qualification {
            total.complete &= report.complete;
            total.entries.extend(report.entries);
        } else {
            qualification = Some(report);
        }
        if ready || !options.paths.is_empty() || start_checks.elapsed() >= options.deadline {
            break;
        }
    }
    let checked = qualification
        .as_ref()
        .map_or(0, |report| report.entries.len());
    let unchecked = paths.len() - checked;
    if let Some(path) = cursor.filter(|_| checked > 0) {
        preview::write_checkpoint(
            &path,
            &paths.get(checked).map(|next| (options.min_hours, next)),
        )?;
    }
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
        "qualification":qualification,"eligible":eligible.len(),"removed":0,"freed_bytes":null,"recovery":recovery});
    if !options.clean {
        return Ok((result, plan_complete));
    }
    if eligible.is_empty() {
        result["status"] = json!(if options.system_tmp {
            "age_pass"
        } else {
            "pressure_unresolved"
        });
        return Ok((result, options.system_tmp && plan_complete && recovered));
    }
    let paths: Vec<_> = eligible.iter().map(|row| row.path.clone()).collect();
    let manifest = scratch_manifest::create_in(&paths, cutoff, options.system_tmp)?;
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
    let complete = if options.system_tmp {
        applied.complete && plan_complete
    } else {
        applied.target_reached
    };
    Ok((result, complete && recovered))
}

fn capacity_target(root: &Path, device: u64, precondition: &mut Value) -> io::Result<Option<u64>> {
    let home = std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME is unavailable"))?;
    let config = volume_config::configuration(Path::new(&home))?;
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
    let used = scratch_target::measure_usage(root, device)?;
    precondition["used_bytes"] = json!(used);
    precondition["quota_bytes"] = json!(quota);
    precondition["trigger_pct"] = json!(trigger);
    precondition["target_pct"] = json!(target);
    Ok((used > percent(trigger)).then(|| percent(target)))
}

fn discover_temp(
    root: &Path,
    device: u64,
    cutoff: i64,
    holds: &mut BTreeMap<&'static str, usize>,
) -> io::Result<Vec<PathBuf>> {
    let mut old = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if !entry
            .file_name()
            .as_encoded_bytes()
            .starts_with(b"diskm-temp-")
        {
            continue;
        }
        let metadata = match fs::symlink_metadata(entry.path()) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if metadata.is_file() && metadata.dev() == device && metadata.mtime() < cutoff {
            let path = entry.path();
            match scratch_target::check_completed_build(root, &path) {
                Ok(()) => old.push((metadata.mtime(), metadata.mtime_nsec(), path)),
                Err(reason) => *holds.entry(reason).or_default() += 1,
            }
        }
    }
    old.sort_unstable();
    Ok(old.into_iter().map(|(_, _, path)| path).collect())
}

fn discover(
    root: &Path,
    device: u64,
    cutoff: i64,
    options: scan::ScanOptions,
    holds: &mut BTreeMap<&'static str, usize>,
    checkpoint: Option<&Path>,
) -> io::Result<(Vec<PathBuf>, bool, Vec<scan::ScanGap>)> {
    let runs = root.join("runs");
    let identity = match fs::symlink_metadata(&runs) {
        Ok(metadata) if metadata.is_dir() && metadata.dev() == device => (device, metadata.ino()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok((Vec::new(), true, Vec::new()))
        }
        _ => return Err(io::Error::other("invalid native runs directory")),
    };
    let report = if let Some(path) = checkpoint {
        let saved: Option<((u64, u64), Vec<scan::ScanGap>)> = preview::load_checkpoint(path)?;
        let deferred = saved
            .filter(|(scope, _)| *scope == identity)
            .map(|(_, gaps)| gaps)
            .unwrap_or_default();
        let retryable = |gap: &scan::ScanGap| {
            gap.path_bytes_hex.is_none() && gap.kind == scan::ScanGapKind::Deadline
        };
        let mut targets: Vec<_> = deferred
            .iter()
            .filter(|gap| retryable(gap))
            .map(|gap| PathBuf::from(&gap.path))
            .collect();
        targets.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        targets.dedup();
        let (mut report, _) = if targets.is_empty() {
            (scan::scan(&runs, options)?, Vec::new())
        } else {
            preview::scan_frontiers(&runs, device, &targets, options.deadline)?
        };
        if !targets.is_empty() {
            report
                .gaps
                .extend(deferred.into_iter().filter(|gap| !retryable(gap)));
            report.complete &= report.gaps.is_empty();
        }
        let pending = report.gaps.iter().any(retryable);
        preview::write_checkpoint(
            path,
            &(identity, if pending { report.gaps.as_slice() } else { &[] }),
        )?;
        report
    } else {
        scan::scan(&runs, options)?
    };
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

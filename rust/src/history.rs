//! Read-only floor selection from the canonical Git-backed top-down ledger.

use serde::Serialize;
use serde_json::Value;
use std::path::Path;
use std::process::Command;

const LEDGER_PATH: &str = "ledger/topdown-5g.json";
const SNAPSHOT_PATH: &str = "snapshots/disk_snapshot.json";
const MAX_LEDGER_BYTES: u64 = 8 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 32 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HistoryAvailability {
    Available,
    NoValidFloor,
    IncompleteHistory,
}

#[derive(Debug, Clone, Serialize)]
pub struct FloorSample {
    pub commit: String,
    pub captured_at: String,
    pub disk_used_kb: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct HistoryReport {
    pub scope: Option<Scope>,
    pub source: &'static str,
    pub requested_days: u32,
    pub availability: HistoryAvailability,
    pub floor: Option<FloorSample>,
    pub valid_samples: usize,
    pub incompatible_samples: usize,
    pub observed_dates: Vec<String>,
    pub observed_span_days: Option<f64>,
    pub coverage_status: &'static str,
    pub reason: Option<&'static str>,
}

#[derive(Debug)]
struct Candidate {
    sample: FloorSample,
    captured_epoch: i64,
    scope: Scope,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Scope {
    mounted_at: String,
    hostname: String,
    filesystem: Option<String>,
}

/// Read only complete top-down ledger observations.
pub fn history(state_repo: &Path, days: u32) -> std::io::Result<HistoryReport> {
    read_history(state_repo, days, LEDGER_PATH, 128)
}

pub fn capacity_history(state_repo: &Path, days: u32) -> std::io::Result<HistoryReport> {
    read_history(state_repo, days, SNAPSHOT_PATH, 256)
}

fn read_history(
    state_repo: &Path,
    days: u32,
    source: &'static str,
    max_commits: usize,
) -> std::io::Result<HistoryReport> {
    if days != 7 && days != 30 {
        return Ok(empty_report(
            source,
            days,
            HistoryAvailability::NoValidFloor,
            "history_window_unsupported",
        ));
    }

    let output = Command::new("git")
        .arg("-C")
        .arg(state_repo)
        .args([
            "log",
            "--since-as-filter",
            &format!("{days}.days.ago"),
            "-n",
            &(max_commits + 1).to_string(),
            "--format=%H",
        ])
        .arg("--")
        .arg(source)
        .output()?;
    if !output.status.success() {
        return Err(std::io::Error::other(
            "cannot read Disk Magician Git history",
        ));
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let commits: Vec<&str> = text.lines().filter(|line| !line.is_empty()).collect();
    let history_truncated = commits.len() > max_commits;
    let mut total_bytes = 0_u64;
    let mut candidates = Vec::new();

    for commit in commits.iter().take(max_commits) {
        let object = format!("{commit}:{source}");
        let size = git_blob_size(state_repo, &object)?;
        if size > MAX_LEDGER_BYTES || total_bytes.saturating_add(size) > MAX_TOTAL_BYTES {
            return Ok(incomplete_report(source, days, candidates));
        }
        total_bytes += size;
        let ledger = git_blob_json(state_repo, &object)?;
        let candidate = if source == SNAPSHOT_PATH {
            capacity_sample(&ledger, commit, days)
        } else {
            qualifying_sample(&ledger, commit, days)
        };
        if let Some(candidate) = candidate {
            candidates.push(candidate);
        }
    }

    if history_truncated {
        return Ok(incomplete_report(source, days, candidates));
    }
    if candidates.is_empty() {
        return Ok(empty_report(
            source,
            days,
            HistoryAvailability::NoValidFloor,
            if source == LEDGER_PATH {
                "no_complete_comparable_ledger"
            } else {
                "no_comparable_capacity_sample"
            },
        ));
    }

    let scope = candidates
        .iter()
        .rev()
        .max_by_key(|candidate| candidate.captured_epoch)
        .map(|candidate| candidate.scope.clone())
        .expect("candidates is non-empty");
    let before_scope_filter = candidates.len();
    candidates.retain(|candidate| candidate.scope == scope);
    let incompatible_samples = before_scope_filter - candidates.len();

    candidates.sort_by(|left, right| {
        left.sample
            .disk_used_kb
            .cmp(&right.sample.disk_used_kb)
            .then_with(|| left.sample.commit.cmp(&right.sample.commit))
    });
    Ok(report_from_candidates(
        source,
        days,
        HistoryAvailability::Available,
        candidates,
        incompatible_samples,
        None,
    ))
}

fn empty_report(
    source: &'static str,
    days: u32,
    availability: HistoryAvailability,
    reason: &'static str,
) -> HistoryReport {
    report_from_candidates(source, days, availability, Vec::new(), 0, Some(reason))
}

fn incomplete_report(source: &'static str, days: u32, candidates: Vec<Candidate>) -> HistoryReport {
    report_from_candidates(
        source,
        days,
        HistoryAvailability::IncompleteHistory,
        candidates,
        0,
        Some("history_read_budget_exceeded"),
    )
}

fn report_from_candidates(
    source: &'static str,
    days: u32,
    availability: HistoryAvailability,
    candidates: Vec<Candidate>,
    incompatible_samples: usize,
    reason: Option<&'static str>,
) -> HistoryReport {
    let mut observed_dates: Vec<String> = candidates
        .iter()
        .map(|candidate| candidate.sample.captured_at[..10].to_owned())
        .collect();
    observed_dates.sort();
    observed_dates.dedup();
    let epochs = || candidates.iter().map(|candidate| candidate.captured_epoch);
    let observed_span_days = epochs()
        .min()
        .zip(epochs().max())
        .map(|(first, last)| (last - first) as f64 / 86_400.0);
    let floor = if availability == HistoryAvailability::Available {
        candidates.first().map(|candidate| FloorSample {
            commit: candidate.sample.commit.clone(),
            captured_at: candidate.sample.captured_at.clone(),
            disk_used_kb: candidate.sample.disk_used_kb,
        })
    } else {
        None
    };
    let coverage_status = if availability == HistoryAvailability::Available {
        "observed_samples_only"
    } else if candidates.is_empty() {
        "none"
    } else {
        "incomplete"
    };
    HistoryReport {
        source,
        scope: candidates
            .first()
            .filter(|_| floor.is_some())
            .map(|c| c.scope.clone()),
        requested_days: days,
        availability,
        floor,
        valid_samples: candidates.len(),
        incompatible_samples,
        observed_dates,
        observed_span_days,
        coverage_status,
        reason,
    }
}

fn git_blob_size(state_repo: &Path, object: &str) -> std::io::Result<u64> {
    let output = Command::new("git")
        .arg("-C")
        .arg(state_repo)
        .args(["cat-file", "-s", object])
        .output()?;
    if !output.status.success() {
        return Ok(MAX_LEDGER_BYTES + 1);
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .unwrap_or(MAX_LEDGER_BYTES + 1))
}

fn git_blob_json(state_repo: &Path, object: &str) -> std::io::Result<Value> {
    let output = Command::new("git")
        .arg("-C")
        .arg(state_repo)
        .args(["show", object])
        .output()?;
    if !output.status.success() {
        return Ok(Value::Null);
    }
    Ok(serde_json::from_slice(&output.stdout).unwrap_or(Value::Null))
}

fn qualifying_sample(ledger: &Value, commit: &str, days: u32) -> Option<Candidate> {
    if !complete_and_balanced(ledger) {
        return None;
    }
    let captured_at = ledger.get("captured_at")?.as_str()?.to_owned();
    let captured_epoch = captured_in_window(&captured_at, days)?;
    let disk_used_kb = ledger.get("disk_used_kb")?.as_u64()?;
    let scope_root = ledger
        .get("scope")
        .and_then(|scope| scope.get("root"))
        .and_then(Value::as_str);
    let ledger_root = ledger.get("root").and_then(Value::as_str);
    if scope_root
        .zip(ledger_root)
        .is_some_and(|(scope, top)| scope != top)
    {
        return None;
    }
    let root = scope_root.or(ledger_root)?.to_owned();

    let scope_hostname = ledger
        .get("scope")
        .and_then(|scope| scope.get("hostname"))
        .and_then(Value::as_str);
    let ledger_hostname = ledger.get("hostname").and_then(Value::as_str);
    if scope_hostname
        .zip(ledger_hostname)
        .is_some_and(|(scope, top)| scope != top)
    {
        return None;
    }
    let hostname = scope_hostname.or(ledger_hostname)?.to_owned();
    if !root.starts_with('/') || hostname.is_empty() {
        return None;
    }
    Some(Candidate {
        sample: FloorSample {
            commit: commit.to_owned(),
            captured_at,
            disk_used_kb,
        },
        captured_epoch,
        scope: Scope {
            mounted_at: root,
            hostname,
            filesystem: None,
        },
    })
}

fn captured_in_window(captured_at: &str, days: u32) -> Option<i64> {
    let epoch = parse_utc(captured_at)?;
    (0..=i64::from(days) * 86_400)
        .contains(&unix_now().checked_sub(epoch)?)
        .then_some(epoch)
}

fn capacity_sample(value: &Value, commit: &str, days: u32) -> Option<Candidate> {
    let metadata = value.get("snapshot_metadata")?;
    let text = |key| {
        metadata
            .get(key)?
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned)
    };
    let captured_at = value.get("timestamp")?.as_str()?.to_owned();
    let captured_epoch = captured_in_window(&captured_at, days)?;
    let mounted_at = text("mounted_at")?;
    if text("scope")?.as_str() != "capacity_only" || !mounted_at.starts_with('/') {
        return None;
    }
    Some(Candidate {
        sample: FloorSample {
            commit: commit.to_owned(),
            captured_at,
            disk_used_kb: metadata.get("used_kib")?.as_u64()?,
        },
        captured_epoch,
        scope: Scope {
            mounted_at,
            hostname: text("hostname")?,
            filesystem: Some(text("filesystem")?),
        },
    })
}

fn complete_and_balanced(ledger: &Value) -> bool {
    if ledger.get("schema_version").and_then(Value::as_u64) != Some(2)
        || ledger.get("mode").and_then(Value::as_str) != Some("complete")
        || ledger.get("canonical").and_then(Value::as_bool) == Some(false)
        || ledger.get("publication_kind").and_then(Value::as_str) == Some("partial")
        || !ledger
            .get("opaque_intrinsic_gates")
            .and_then(Value::as_array)
            .is_some_and(|gates| gates.is_empty())
        || !ledger
            .get("frontier_unfinished")
            .and_then(Value::as_array)
            .is_some_and(Vec::is_empty)
    {
        return false;
    }

    let envelope = match ledger.get("coverage_envelope").and_then(Value::as_object) {
        Some(envelope) => envelope,
        None => return false,
    };
    let reachable = envelope
        .get("reachable_top_level_roots")
        .and_then(Value::as_u64);
    let measured = envelope
        .get("measured_top_level_roots")
        .and_then(Value::as_u64);
    if envelope.get("complete").and_then(Value::as_bool) != Some(true)
        || envelope.get("fda_preflight_status").and_then(Value::as_str) != Some("granted")
        || envelope
            .get("fda_user_preflight_status")
            .and_then(Value::as_str)
            != Some("granted")
        || reachable.is_none()
        || reachable != measured
        || envelope
            .get("unfinished_top_level_roots")
            .and_then(Value::as_u64)
            != Some(0)
    {
        return false;
    }

    let equation = match ledger.get("accounting_equation").and_then(Value::as_object) {
        Some(equation) => equation,
        None => return false,
    };
    if equation.get("displayed_balanced").and_then(Value::as_bool) != Some(true)
        || equation
            .get("display_ledger_valid")
            .and_then(Value::as_bool)
            != Some(true)
    {
        return false;
    }
    let keys = [
        "data_used_kb",
        "displayed_buckets_kb",
        "oversize_indivisible_files_kb",
        "sub_granularity_tail_kb",
        "purgeable_kb",
        "residual_kb",
    ];
    let values: Option<Vec<i128>> = keys
        .iter()
        .map(|key| equation.get(*key).and_then(Value::as_i64).map(i128::from))
        .collect();
    let values = match values {
        Some(values) if values.iter().all(|v| *v >= 0) => values,
        _ => return false,
    };
    let clone_shared = equation
        .get("clone_shared_kb")
        .or_else(|| equation.get("clone_shared_adjustment_kb"))
        .and_then(Value::as_i64)
        .map(i128::from);
    let clone_shared = match clone_shared {
        Some(value) if value <= 0 => value,
        _ => return false,
    };
    let used = match ledger.get("disk_used_kb").and_then(Value::as_i64) {
        Some(value) if value >= 0 => i128::from(value),
        _ => return false,
    };
    if values[0] != used || values[0] != values[1..].iter().sum::<i128>() + clone_shared {
        return false;
    }
    if bucket_sum(ledger, "granularity_buckets", "buckets") != Some(values[1])
        || bucket_sum(
            ledger,
            "oversize_indivisible_files",
            "oversize_indivisible_files",
        ) != Some(values[2])
    {
        return false;
    }
    small_directory_leaves(ledger)
}

fn bucket_sum(ledger: &Value, primary_key: &str, fallback_key: &str) -> Option<i128> {
    let rows = ledger
        .get(primary_key)
        .or_else(|| ledger.get(fallback_key))?
        .as_array()?;
    rows.iter().try_fold(0_i128, |sum, row| {
        let measured = row.get("measured_kb")?.as_u64()?;
        sum.checked_add(i128::from(measured))
    })
}

fn small_directory_leaves(ledger: &Value) -> bool {
    let buckets = match ledger
        .get("granularity_buckets")
        .or_else(|| ledger.get("buckets"))
        .and_then(Value::as_array)
    {
        Some(buckets) => buckets,
        None => return false,
    };
    for bucket in buckets {
        let kind = bucket.get("kind").and_then(Value::as_str).unwrap_or("dir");
        if kind == "direct_allocation_segment" {
            return false;
        }
        if kind != "file" {
            let bytes = bucket
                .get("apparent_bytes")
                .and_then(Value::as_u64)
                .or_else(|| {
                    bucket
                        .get("measured_kb")
                        .and_then(Value::as_u64)
                        .and_then(|kb| kb.checked_mul(1024))
                });
            if bytes.is_none_or(|bytes| bytes >= 100 * 1024 * 1024) {
                return false;
            }
        }
    }
    true
}

pub(crate) fn parse_utc(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return None;
    }
    let year = digits(bytes, 0, 4)?;
    let month = digits(bytes, 5, 7)?;
    let day = digits(bytes, 8, 10)?;
    let hour = digits(bytes, 11, 13)?;
    let minute = digits(bytes, 14, 16)?;
    let second = digits(bytes, 17, 19)?;
    let days = days_from_civil(year, month, day)?;
    if year == 0 || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    days.checked_mul(86_400)?
        .checked_add(i64::from(hour * 3600 + minute * 60 + second))
}

fn digits(bytes: &[u8], start: usize, end: usize) -> Option<u32> {
    let mut value = 0_u32;
    for byte in bytes.get(start..end)? {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value
            .checked_mul(10)?
            .checked_add(u32::from(*byte - b'0'))?;
    }
    Some(value)
}

fn days_from_civil(year: u32, month: u32, day: u32) -> Option<i64> {
    if !(1..=12).contains(&month) {
        return None;
    }
    let month_days = match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if day == 0 || day > month_days {
        return None;
    }
    let mut y = i64::from(year);
    if month <= 2 {
        y -= 1;
    }
    let era = y.div_euclid(400);
    let year_of_era = y - era * 400;
    let adjusted_month = i64::from(month) + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}
fn is_leap(year: u32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}
pub(crate) fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs().min(i64::MAX as u64) as i64)
}

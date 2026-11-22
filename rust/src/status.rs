//! Read-only status for live capacity and the two legacy observations.

use serde::Serialize;
use serde_json::{Map, Value};
use std::{
    fs, io,
    path::Path,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

const LEDGER_FILE: &str = "ledger/topdown-5g.status.json";
const SNAPSHOT_FILE: &str = "snapshots/disk_snapshot.json";
const STALE_AFTER: u64 = 36 * 60 * 60;
const MIN_COVERAGE: f64 = 70.0;

#[derive(Debug, Serialize)]
pub struct StatusReport {
    pub capacity: CapacityReport,
    pub snapshot: SnapshotReport,
    pub ledger: LedgerReport,
}

#[derive(Debug, Serialize)]
pub struct CapacityReport {
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
    pub percent_used: u8,
    pub mounted_at: String,
}

#[derive(Debug, Serialize)]
pub struct SnapshotReport {
    pub state: ObservationState,
    pub reason: Option<String>,
    pub sampled_at: Option<String>,
    pub age_seconds: Option<u64>,
    pub coverage_pct: Option<f64>,
    pub measurement_status: Option<String>,
    pub disk_total_gb: Option<f64>,
    pub disk_used_gb: Option<f64>,
    pub disk_free_gb: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct LedgerReport {
    pub state: ObservationState,
    /// Published means the status sidecar records a recent complete capture.
    pub authoritative: bool,
    pub reason: Option<String>,
    pub captured_at: Option<String>,
    pub age_seconds: Option<u64>,
    pub mode: Option<String>,
    pub measured_roots: Option<u64>,
    pub reachable_roots: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ObservationState {
    Fresh,
    Partial,
    Stale,
    Absent,
    Unreadable,
    Unknown,
}

pub fn status(root: &Path, legacy_state_dir: Option<&Path>) -> io::Result<StatusReport> {
    let capacity = read_capacity(root)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| io::Error::other(format!("clock error: {error}")))?
        .as_secs();
    let snapshot = legacy_state_dir.map_or_else(
        || empty_snapshot(ObservationState::Absent, "state_directory_not_supplied"),
        |dir| read_snapshot(dir, now),
    );
    let ledger = legacy_state_dir.map_or_else(
        || empty_ledger(ObservationState::Absent, "state_directory_not_supplied"),
        |dir| read_ledger(dir, now),
    );
    Ok(StatusReport {
        capacity,
        snapshot,
        ledger,
    })
}

fn read_capacity(root: &Path) -> io::Result<CapacityReport> {
    let output = Command::new("df")
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .args(["-Pk"])
        .arg(root)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "df -Pk failed: {}",
            output.status
        )));
    }
    parse_df_output(
        std::str::from_utf8(&output.stdout)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
    )
}

fn parse_df_output(output: &str) -> io::Result<CapacityReport> {
    let row = output
        .lines()
        .skip(1)
        .find(|line| !line.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "df returned no data row"))?;
    let fields: Vec<_> = row.split_whitespace().collect();
    if fields.len() < 6 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid df row"));
    }
    let kib = |index: usize, name: &str| {
        fields[index].parse::<u64>().map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid df {name}: {error}"),
            )
        })
    };
    let bytes = |index: usize, name: &str| {
        kib(index, name)?.checked_mul(1024).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, format!("df {name} overflow"))
        })
    };
    let percent_used = fields[4]
        .strip_suffix('%')
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "df percent missing %"))?
        .parse::<u8>()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    Ok(CapacityReport {
        total_bytes: bytes(1, "total")?,
        used_bytes: bytes(2, "used")?,
        available_bytes: bytes(3, "available")?,
        percent_used,
        mounted_at: fields[5..].join(" "),
    })
}

fn read_snapshot(dir: &Path, now: u64) -> SnapshotReport {
    let object = match read_object(&dir.join(SNAPSHOT_FILE)) {
        Ok(Some(object)) => object,
        Ok(None) => return empty_snapshot(ObservationState::Absent, "snapshot_missing"),
        Err(reason) => return empty_snapshot(ObservationState::Unreadable, &reason),
    };
    let sampled_at = snapshot_timestamp(&object);
    let Some(epoch) = sampled_at.as_deref().and_then(parse_timestamp) else {
        let reason = match sampled_at.as_deref() {
            None => "snapshot_timestamp_missing",
            Some(_) => "snapshot_timestamp_invalid",
        };
        return empty_snapshot(ObservationState::Unknown, reason);
    };
    let Some(age_seconds) = now.checked_sub(epoch) else {
        return empty_snapshot(ObservationState::Unknown, "snapshot_timestamp_in_future");
    };
    let (coverage_pct, coverage_error) = match snapshot_coverage(&object) {
        Ok(coverage) => (coverage, None),
        Err(reason) => (None, Some(reason)),
    };
    let (measurement_status, measurement_error) = match snapshot_measurement_status(&object) {
        Ok(value) => (value, None),
        Err(reason) => (None, Some(reason)),
    };
    let state = if age_seconds > STALE_AFTER {
        ObservationState::Stale
    } else if measurement_error.is_some() || coverage_error.is_some() || coverage_pct.is_none() {
        ObservationState::Unknown
    } else if coverage_pct.is_some_and(|coverage| coverage < MIN_COVERAGE)
        || measurement_status
            .as_deref()
            .is_some_and(|measurement| measurement != "complete")
    {
        ObservationState::Partial
    } else {
        ObservationState::Fresh
    };
    let reason = match state {
        ObservationState::Fresh => None,
        ObservationState::Partial if coverage_pct.is_some_and(|pct| pct < MIN_COVERAGE) => {
            Some("coverage_below_70_percent".into())
        }
        ObservationState::Partial => measurement_status
            .as_deref()
            .map(|measurement| format!("measurement_status_{measurement}")),
        ObservationState::Stale => Some("snapshot_older_than_36_hours".into()),
        ObservationState::Unknown => measurement_error
            .map(str::to_owned)
            .or_else(|| coverage_error.map(str::to_owned))
            .or_else(|| Some("snapshot_coverage_unavailable".into())),
        ObservationState::Absent | ObservationState::Unreadable => unreachable!(),
    };
    SnapshotReport {
        state,
        reason,
        sampled_at,
        age_seconds: Some(age_seconds),
        coverage_pct,
        measurement_status,
        disk_total_gb: number(&object, "disk_total_gb"),
        disk_used_gb: number(&object, "disk_used_gb"),
        disk_free_gb: number(&object, "disk_free_gb"),
    }
}

fn snapshot_timestamp(object: &Map<String, Value>) -> Option<String> {
    if let Some(value) = object.get("timestamp") {
        if !value.is_null() {
            return value.as_str().map(str::to_owned);
        }
    }
    object
        .get("snapshot_metadata")
        .and_then(Value::as_object)
        .and_then(|metadata| text(metadata, "captured_at"))
}

fn snapshot_coverage(object: &Map<String, Value>) -> Result<Option<f64>, &'static str> {
    if let Some(value) = object.get("snapshot_coverage_pct") {
        if !value.is_null() {
            return checked_coverage(value)
                .map(Some)
                .ok_or("snapshot_coverage_invalid");
        }
    }
    if let Some(value) = object
        .get("snapshot_metadata")
        .and_then(Value::as_object)
        .and_then(|metadata| metadata.get("coverage_pct"))
    {
        if !value.is_null() {
            return checked_coverage(value)
                .map(Some)
                .ok_or("snapshot_coverage_invalid");
        }
    }
    if let Some(value) = object.get("coverage_fresh_pct") {
        if !value.is_null() {
            return checked_coverage(value)
                .map(Some)
                .ok_or("snapshot_coverage_invalid");
        }
    }
    Ok(None)
}

fn snapshot_measurement_status(
    object: &Map<String, Value>,
) -> Result<Option<String>, &'static str> {
    let nested = object
        .get("snapshot_metadata")
        .and_then(Value::as_object)
        .and_then(|metadata| metadata.get("measurement_status"));
    let raw = nested
        .filter(|value| !value.is_null())
        .or_else(|| object.get("measurement_status"))
        .filter(|value| !value.is_null());

    let Some(raw) = raw else {
        // Older snapshot schemas do not include this field. Preserve the
        // previous coverage-only classification for those snapshots.
        return Ok(None);
    };

    match raw.as_str() {
        Some("complete" | "partial" | "timeout" | "empty") => Ok(raw.as_str().map(str::to_owned)),
        _ => Err("measurement_status_invalid"),
    }
}

fn checked_coverage(value: &Value) -> Option<f64> {
    let coverage = value.as_f64()?;
    (coverage.is_finite() && (0.0..=100.0).contains(&coverage)).then_some(coverage)
}

fn read_ledger(dir: &Path, now: u64) -> LedgerReport {
    let object = match read_object(&dir.join(LEDGER_FILE)) {
        Ok(Some(object)) => object,
        Ok(None) => return empty_ledger(ObservationState::Absent, "ledger_status_missing"),
        Err(reason) => return empty_ledger(ObservationState::Unreadable, &reason),
    };
    let publication = text(&object, "status");
    let reason = text(&object, "reason");
    let captured_at = text(&object, "captured_at");
    let mode = text(&object, "mode");
    let coverage = object.get("coverage_envelope").and_then(Value::as_object);
    let measured = coverage.and_then(|o| unsigned(o, "measured_top_level_roots"));
    let reachable = coverage.and_then(|o| unsigned(o, "reachable_top_level_roots"));

    if publication.as_deref() == Some("stale") {
        let age = captured_at
            .as_deref()
            .and_then(parse_timestamp)
            .and_then(|epoch| now.checked_sub(epoch));
        return ledger_report(
            ObservationState::Stale,
            reason.or_else(|| Some("ledger_marked_stale".into())),
            captured_at,
            age,
            mode,
            measured,
            reachable,
        );
    }
    let Some(captured) = captured_at.as_deref() else {
        let state = if publication.as_deref() == Some("partial") {
            ObservationState::Partial
        } else {
            ObservationState::Unknown
        };
        return ledger_report(
            state,
            reason.or_else(|| default_reason(state)),
            captured_at,
            None,
            mode,
            measured,
            reachable,
        );
    };
    let Some(epoch) = parse_timestamp(captured) else {
        return ledger_report(
            ObservationState::Unknown,
            Some("ledger_capture_time_invalid".into()),
            captured_at,
            None,
            mode,
            measured,
            reachable,
        );
    };
    let Some(age) = now.checked_sub(epoch) else {
        return ledger_report(
            ObservationState::Unknown,
            Some("ledger_capture_time_in_future".into()),
            captured_at,
            None,
            mode,
            measured,
            reachable,
        );
    };
    let state = match publication.as_deref() {
        _ if age > STALE_AFTER => ObservationState::Stale,
        Some("partial") => ObservationState::Partial,
        Some("published") if mode.as_deref() == Some("partial") => ObservationState::Partial,
        Some("published") if mode.as_deref() == Some("complete") => ObservationState::Fresh,
        _ => ObservationState::Unknown,
    };
    ledger_report(
        state,
        reason.or_else(|| default_reason(state)),
        captured_at,
        Some(age),
        mode,
        measured,
        reachable,
    )
}

fn read_object(path: &Path) -> Result<Option<Map<String, Value>>, String> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("state_read_failed:{}", error.kind())),
    };
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| "state_json_invalid".to_owned())?;
    value
        .as_object()
        .cloned()
        .map(Some)
        .ok_or_else(|| "state_json_not_object".to_owned())
}

fn empty_snapshot(state: ObservationState, reason: &str) -> SnapshotReport {
    SnapshotReport {
        state,
        reason: Some(reason.into()),
        sampled_at: None,
        age_seconds: None,
        coverage_pct: None,
        measurement_status: None,
        disk_total_gb: None,
        disk_used_gb: None,
        disk_free_gb: None,
    }
}

fn empty_ledger(state: ObservationState, reason: &str) -> LedgerReport {
    ledger_report(state, Some(reason.into()), None, None, None, None, None)
}

fn ledger_report(
    state: ObservationState,
    reason: Option<String>,
    captured_at: Option<String>,
    age_seconds: Option<u64>,
    mode: Option<String>,
    measured_roots: Option<u64>,
    reachable_roots: Option<u64>,
) -> LedgerReport {
    LedgerReport {
        state,
        authoritative: state == ObservationState::Fresh,
        reason,
        captured_at,
        age_seconds,
        mode,
        measured_roots,
        reachable_roots,
    }
}

fn default_reason(state: ObservationState) -> Option<String> {
    match state {
        ObservationState::Fresh => None,
        ObservationState::Partial => Some("latest_capture_is_partial".into()),
        ObservationState::Stale => Some("latest_capture_is_stale".into()),
        _ => Some("ledger_status_unrecognized".into()),
    }
}

fn text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}
fn number(object: &Map<String, Value>, key: &str) -> Option<f64> {
    object.get(key).and_then(Value::as_f64)
}
fn unsigned(object: &Map<String, Value>, key: &str) -> Option<u64> {
    object.get(key).and_then(Value::as_u64)
}

fn parse_timestamp(value: &str) -> Option<u64> {
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
    let year = value[0..4].parse::<i32>().ok()?;
    let month = value[5..7].parse::<u32>().ok()?;
    let day = value[8..10].parse::<u32>().ok()?;
    let hour = value[11..13].parse::<u32>().ok()?;
    let minute = value[14..16].parse::<u32>().ok()?;
    let second = value[17..19].parse::<u32>().ok()?;
    if !(1..=12).contains(&month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let month_days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap_year(year) => 29,
        2 => 28,
        _ => return None,
    };
    if day == 0 || day > month_days {
        return None;
    }
    let mut y = i64::from(year);
    let m = i64::from(month);
    y -= if m <= 2 { 1 } else { 0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let mp = m + if m > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    if days < 0 {
        return None;
    }
    u64::try_from(
        days.checked_mul(86_400)?
            .checked_add(i64::from(hour) * 3600)?
            .checked_add(i64::from(minute) * 60)?
            .checked_add(i64::from(second))?,
    )
    .ok()
}
fn leap_year(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

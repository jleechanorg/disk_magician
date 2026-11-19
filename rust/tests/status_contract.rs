use diskm_shadow::status::{status, ObservationState};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);
impl TempDir {
    fn new() -> Self {
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("diskm-status-{}-{nanos}-{id}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn now_utc() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let tod = seconds.rem_euclid(86_400);
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = days - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

fn state_dir(root: &Path, status: &str, mode: &str, coverage: f64) -> PathBuf {
    let state = root.join("state");
    fs::create_dir_all(state.join("ledger")).unwrap();
    fs::create_dir_all(state.join("snapshots")).unwrap();
    fs::write(
        state.join("ledger/topdown-5g.status.json"),
        format!(r#"{{"status":"{status}","reason":"fixture","captured_at":"{}","mode":"{mode}","coverage_envelope":{{"measured_top_level_roots":17,"reachable_top_level_roots":18}}}}"#, now_utc())
    ).unwrap();
    fs::write(
        state.join("snapshots/disk_snapshot.json"),
        format!(r#"{{"timestamp":"{}","snapshot_coverage_pct":{coverage},"disk_total_gb":926.0,"disk_used_gb":700.0,"disk_free_gb":54.0}}"#, now_utc())
    ).unwrap();
    state
}

#[test]
fn reads_capacity_and_keeps_partial_ledger_distinct() {
    let temp = TempDir::new();
    let state = state_dir(temp.path(), "partial", "partial", 100.0);
    let ledger_path = state.join("ledger/topdown-5g.status.json");
    let snapshot_path = state.join("snapshots/disk_snapshot.json");
    let ledger_before = fs::read(&ledger_path).unwrap();
    let snapshot_before = fs::read(&snapshot_path).unwrap();

    let report = status(Path::new("/"), Some(&state)).unwrap();

    assert!(report.capacity.total_bytes > 0);
    assert!(report.capacity.used_bytes > 0);
    assert!(report.capacity.available_bytes > 0);
    assert_eq!(report.snapshot.state, ObservationState::Fresh);
    assert_eq!(report.ledger.state, ObservationState::Partial);
    assert!(!report.ledger.authoritative);
    assert_eq!(report.ledger.measured_roots, Some(17));
    assert_eq!(report.ledger.reachable_roots, Some(18));
    assert_eq!(fs::read(ledger_path).unwrap(), ledger_before);
    assert_eq!(fs::read(snapshot_path).unwrap(), snapshot_before);
}

#[test]
fn low_coverage_snapshot_remains_partial_even_if_ledger_is_published() {
    let temp = TempDir::new();
    let state = state_dir(temp.path(), "published", "complete", 5.5);
    let report = status(Path::new("/"), Some(&state)).unwrap();
    assert_eq!(report.snapshot.state, ObservationState::Partial);
    assert_eq!(
        report.snapshot.reason.as_deref(),
        Some("coverage_below_70_percent")
    );
    assert!(report.ledger.authoritative);
}

#[test]
fn supports_nested_legacy_snapshot_timestamp_and_coverage() {
    let temp = TempDir::new();
    let state = state_dir(temp.path(), "published", "complete", 100.0);
    fs::write(
        state.join("snapshots/disk_snapshot.json"),
        r#"{"snapshot_metadata":{"captured_at":"2026-11-19T00:00:00Z","coverage_pct":85.5}}"#,
    )
    .unwrap();

    let report = status(Path::new("/"), Some(&state)).unwrap();

    assert_eq!(report.snapshot.state, ObservationState::Fresh);
    assert_eq!(
        report.snapshot.sampled_at.as_deref(),
        Some("2026-11-19T00:00:00Z")
    );
    assert_eq!(report.snapshot.coverage_pct, Some(85.5));
}

#[test]
fn supports_fresh_coverage_alias_but_does_not_hide_invalid_current_value() {
    let temp = TempDir::new();
    let state = state_dir(temp.path(), "published", "complete", 100.0);
    let snapshot = state.join("snapshots/disk_snapshot.json");
    let timestamp = now_utc();
    fs::write(
        &snapshot,
        format!(r#"{{"timestamp":"{timestamp}","coverage_fresh_pct":88.0}}"#),
    )
    .unwrap();
    let alias_report = status(Path::new("/"), Some(&state)).unwrap();
    assert_eq!(alias_report.snapshot.state, ObservationState.Fresh);
    assert_eq!(alias_report.snapshot.coverage_pct, Some(88.0));

    fs::write(
        &snapshot,
        format!(
            r#"{{"timestamp":"{timestamp}","snapshot_coverage_pct":"invalid","snapshot_metadata":{{"coverage_pct":100.0}}}}"#
        ),
    )
    .unwrap();
    let invalid_report = status(Path::new("/"), Some(&state)).unwrap();
    assert_eq!(invalid_report.snapshot.state, ObservationState::Unknown);
    assert_eq!(
        invalid_report.snapshot.reason.as_deref(),
        Some("snapshot_coverage_invalid")
    );
}

#[test]
fn missing_or_unreadable_state_is_reported_without_creation() {
    let temp = TempDir::new();
    let missing = temp.path().join("missing");
    let report = status(Path::new("/"), Some(&missing)).unwrap();
    assert_eq!(report.snapshot.state, ObservationState::Absent);
    assert_eq!(report.ledger.state, ObservationState::Absent);
    assert!(!missing.exists());

    let malformed = temp.path().join("malformed");
    fs::create_dir_all(malformed.join("ledger")).unwrap();
    fs::create_dir_all(malformed.join("snapshots")).unwrap();
    fs::write(malformed.join("ledger/topdown-5g.status.json"), b"{").unwrap();
    fs::write(malformed.join("snapshots/disk_snapshot.json"), b"[]").unwrap();
    let report = status(Path::new("/"), Some(&malformed)).unwrap();
    assert_eq!(report.snapshot.state, ObservationState::Unreadable);
    assert_eq!(report.ledger.state, ObservationState::Unreadable);
}

#[test]
fn stale_observations_are_not_promoted_to_fresh() {
    let temp = TempDir::new();
    let state = temp.path().join("state");
    state_dir(&state, "published", "complete", 100.0);
    fs::write(
        state.join("ledger/topdown-5g.status.json"),
        r#"{"status":"stale","reason":"fixture_stale","captured_at":"2000-01-01T00:00:00Z","mode":"complete"}"#,
    ).unwrap();
    fs::write(
        state.join("snapshots/disk_snapshot.json"),
        r#"{"timestamp":"2000-01-01T00:00:00Z","snapshot_coverage_pct":100.0}"#,
    )
    .unwrap();

    let report = status(Path::new("/"), Some(&state)).unwrap();

    assert_eq!(report.snapshot.state, ObservationState::Stale);
    assert_eq!(report.ledger.state, ObservationState::Stale);
    assert!(!report.ledger.authoritative);
}

#[test]
fn missing_state_argument_is_absent() {
    let report = status(Path::new("/"), None).unwrap();
    assert_eq!(report.snapshot.state, ObservationState::Absent);
    assert_eq!(report.ledger.state, ObservationState::Absent);
}

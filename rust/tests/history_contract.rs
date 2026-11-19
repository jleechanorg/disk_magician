use diskm_shadow::history::{history, HistoryAvailability};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct GitFixture(PathBuf);

impl GitFixture {
    fn new() -> Self {
        let nonce = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "diskm-history-contract-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&root).expect("create isolated Git fixture");
        run_git(&root, &["init", "-q"], None);
        run_git(&root, &["config", "user.name", "Disk Magician Test"], None);
        run_git(
            &root,
            &["config", "user.email", "diskm-test@example.invalid"],
            None,
        );
        Self(root)
    }

    fn commit_ledger(&self, ledger: &Value, captured_at: &str, age_days: u32) -> String {
        let ledger_path = self.0.join("ledger/topdown-5g.json");
        fs::create_dir_all(ledger_path.parent().unwrap()).unwrap();
        fs::write(&ledger_path, serde_json::to_vec(ledger).unwrap()).unwrap();
        run_git(&self.0, &["add", "ledger/topdown-5g.json"], None);

        let timestamp = timestamp_from_capture(captured_at) - i64::from(age_days) * 86_400;
        let date = format!("@{timestamp} +0000");
        run_git(
            &self.0,
            &["commit", "-q", "-m", "ledger sample"],
            Some((&date, &date)),
        );
        String::from_utf8(run_git(&self.0, &["rev-parse", "HEAD"], None).stdout)
            .unwrap()
            .trim()
            .to_owned()
    }

    fn root(&self) -> &Path {
        &self.0
    }
}

impl Drop for GitFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("remove owned Git fixture");
    }
}

fn run_git(root: &Path, args: &[&str], date: Option<(&str, &str)>) -> Output {
    let mut command = Command::new("git");
    command.arg("-C").arg(root).args(args);
    if let Some((author_date, committer_date)) = date {
        command.env("GIT_AUTHOR_DATE", author_date);
        command.env("GIT_COMMITTER_DATE", committer_date);
    }
    let output = command
        .output()
        .expect("git must be installed for history tests");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn complete_ledger(captured_at: &str, used_kb: u64, root: &str, hostname: &str) -> Value {
    let bucket_kb = used_kb.saturating_sub(50);
    let residual_kb = used_kb - bucket_kb;
    json!({
        "schema_version": 2,
        "mode": "complete",
        "canonical": true,
        "publication_kind": "complete",
        "root": root,
        "hostname": hostname,
        "scope": {"root": root, "hostname": hostname},
        "captured_at": captured_at,
        "disk_used_kb": used_kb,
        "residual_kb": residual_kb,
        "granularity_buckets": [{
            "path": format!("{root}/small-leaf"),
            "kind": "dir",
            "measured_kb": bucket_kb,
            "apparent_bytes": bucket_kb * 1024
        }],
        "oversize_indivisible_files": [],
        "opaque_intrinsic_gates": [],
        "frontier_unfinished": [],
        "coverage_envelope": {
            "complete": true,
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
            "reachable_top_level_roots": 12,
            "measured_top_level_roots": 12,
            "unfinished_top_level_roots": 0
        },
        "accounting_equation": {
            "displayed_balanced": true,
            "display_ledger_valid": true,
            "data_used_kb": used_kb,
            "displayed_buckets_kb": bucket_kb,
            "oversize_indivisible_files_kb": 0,
            "sub_granularity_tail_kb": 0,
            "purgeable_kb": 0,
            "residual_kb": residual_kb,
            "clone_shared_kb": 0
        }
    })
}

fn partial_ledger(captured_at: &str, used_kb: u64) -> Value {
    let mut ledger = complete_ledger(captured_at, used_kb, "/fixture", "fixture-host");
    ledger["mode"] = json!("partial");
    ledger["canonical"] = json!(false);
    ledger["publication_kind"] = json!("partial");
    ledger["coverage_envelope"]["complete"] = json!(false);
    ledger["coverage_envelope"]["unfinished_top_level_roots"] = json!(3);
    ledger["frontier_unfinished"] = json!([{"path": "/fixture/unmeasured"}]);
    ledger
}

fn utc_from_epoch(timestamp: i64) -> String {
    let days = timestamp.div_euclid(86_400);
    let seconds = timestamp.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        seconds / 3600,
        seconds % 3600 / 60,
        seconds % 60
    )
}

fn timestamp_from_capture(captured_at: &str) -> i64 {
    // Tests use this inverse only for generated UTC timestamps.
    let bytes = captured_at.as_bytes();
    let year = captured_at[0..4].parse::<i64>().unwrap();
    let month = captured_at[5..7].parse::<i64>().unwrap();
    let day = captured_at[8..10].parse::<i64>().unwrap();
    let hour = captured_at[11..13].parse::<i64>().unwrap();
    let minute = captured_at[14..16].parse::<i64>().unwrap();
    let second = captured_at[17..19].parse::<i64>().unwrap();
    assert_eq!(bytes[19], b'Z');
    let adjusted_year = year - i64::from(month <= 2);
    let era = adjusted_year.div_euclid(400);
    let year_of_era = adjusted_year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    (era * 146_097 + day_of_era - 719_468) * 86_400 + hour * 3600 + minute * 60 + second
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}

#[test]
fn floor_uses_only_recent_complete_samples_and_reports_observed_coverage() {
    let fixture = GitFixture::new();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let captured_now = utc_from_epoch(now);
    let captured_two_days_ago = utc_from_epoch(now - 2 * 86_400);
    let captured_three_days_ago = utc_from_epoch(now - 3 * 86_400);
    let captured_old = utc_from_epoch(now - 45 * 86_400);

    let _higher = fixture.commit_ledger(
        &complete_ledger(&captured_three_days_ago, 900, "/fixture", "fixture-host"),
        &captured_three_days_ago,
        3,
    );
    let minimum = fixture.commit_ledger(
        &complete_ledger(&captured_two_days_ago, 700, "/fixture", "fixture-host"),
        &captured_two_days_ago,
        2,
    );
    fixture.commit_ledger(&partial_ledger(&captured_now, 100), &captured_now, 0);
    fixture.commit_ledger(
        &complete_ledger(&captured_old, 10, "/fixture", "fixture-host"),
        &captured_old,
        45,
    );

    let report = history(fixture.root(), 7).unwrap();
    assert_eq!(report.availability, HistoryAvailability::Available);
    assert_eq!(report.floor.as_ref().unwrap().commit, minimum);
    assert_eq!(report.floor.as_ref().unwrap().disk_used_kb, 700);
    assert_eq!(report.valid_samples, 2);
    assert_eq!(report.observed_dates.len(), 2);
    assert_eq!(report.coverage_status, "observed_samples_only");
    assert!(report.observed_span_days.unwrap() > 0.9);
}

#[test]
fn observations_from_older_root_are_not_compared_to_newest_root() {
    let fixture = GitFixture::new();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let older = utc_from_epoch(now - 2 * 86_400);
    let newer = utc_from_epoch(now - 86_400);
    fixture.commit_ledger(
        &complete_ledger(&older, 100, "/old-root", "fixture-host"),
        &older,
        2,
    );
    let newest_scope = fixture.commit_ledger(
        &complete_ledger(&newer, 600, "/new-root", "fixture-host"),
        &newer,
        1,
    );
    let report = history(fixture.root(), 7).unwrap();
    assert_eq!(report.availability, HistoryAvailability::Available);
    assert_eq!(report.floor.as_ref().unwrap().commit, newest_scope);
    assert_eq!(report.floor.as_ref().unwrap().disk_used_kb, 600);
    assert_eq!(report.valid_samples, 1);
    assert_eq!(report.incompatible_samples, 1);
}

#[test]
fn seven_and_thirty_day_windows_filter_by_capture_time() {
    let fixture = GitFixture::new();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let twenty_days_ago = utc_from_epoch(now - 20 * 86_400);
    let commit = fixture.commit_ledger(
        &complete_ledger(&twenty_days_ago, 321, "/fixture", "fixture-host"),
        &twenty_days_ago,
        1,
    );

    let seven_days = history(fixture.root(), 7).unwrap();
    assert_eq!(seven_days.availability, HistoryAvailability::NoValidFloor);
    assert!(seven_days.floor.is_none());

    let thirty_days = history(fixture.root(), 30).unwrap();
    assert_eq!(thirty_days.availability, HistoryAvailability::Available);
    assert_eq!(thirty_days.floor.as_ref().unwrap().commit, commit);
    assert_eq!(thirty_days.floor.as_ref().unwrap().disk_used_kb, 321);
}

#[test]
fn partial_only_history_never_synthesizes_a_floor() {
    let fixture = GitFixture::new();
    let captured = utc_from_epoch(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64,
    );
    fixture.commit_ledger(&partial_ledger(&captured, 100), &captured, 0);
    let report = history(fixture.root(), 30).unwrap();
    assert_eq!(report.availability, HistoryAvailability::NoValidFloor);
    assert!(report.floor.is_none());
    assert_eq!(report.valid_samples, 0);
    assert_eq!(report.reason, Some("no_complete_comparable_ledger"));
}

#[test]
fn missing_scope_identity_is_not_a_comparable_floor() {
    let fixture = GitFixture::new();
    let captured = utc_from_epoch(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64,
    );
    let mut ledger = complete_ledger(&captured, 100, "/fixture", "fixture-host");
    ledger.as_object_mut().unwrap().remove("scope");
    ledger.as_object_mut().unwrap().remove("root");
    ledger.as_object_mut().unwrap().remove("hostname");
    fixture.commit_ledger(&ledger, &captured, 0);
    let report = history(fixture.root(), 7).unwrap();
    assert_eq!(report.availability, HistoryAvailability::NoValidFloor);
    assert!(report.floor.is_none());
}

#[test]
fn disagreeing_scope_and_top_level_identity_is_not_qualifying() {
    let fixture = GitFixture::new();
    let captured = utc_from_epoch(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64,
    );
    let mut ledger = complete_ledger(&captured, 100, "/fixture", "fixture-host");
    ledger["scope"]["root"] = json!("/other-root");
    fixture.commit_ledger(&ledger, &captured, 0);
    let report = history(fixture.root(), 7).unwrap();
    assert_eq!(report.availability, HistoryAvailability::NoValidFloor);
    assert!(report.floor.is_none());
}

#[test]
fn refuses_unsupported_window_and_non_repository_errors_are_explicit() {
    let fixture = GitFixture::new();
    let report = history(fixture.root(), 14).unwrap();
    assert_eq!(report.availability, HistoryAvailability::NoValidFloor);
    assert_eq!(report.reason, Some("history_window_unsupported"));
    assert!(history(&fixture.root().join("missing"), 7).is_err());
}

#[test]
fn invalid_equation_does_not_enter_the_floor() {
    let fixture = GitFixture::new();
    let captured = utc_from_epoch(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64,
    );
    let mut ledger = complete_ledger(&captured, 100, "/fixture", "fixture-host");
    ledger["accounting_equation"]["displayed_buckets_kb"] = json!(9_999);
    fixture.commit_ledger(&ledger, &captured, 0);
    assert_eq!(
        history(fixture.root(), 7).unwrap().availability,
        HistoryAvailability::NoValidFloor
    );
}

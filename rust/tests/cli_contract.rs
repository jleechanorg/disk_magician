use serde_json::Value;
use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args(args)
        .output()
        .expect("candidate executable starts")
}

#[test]
fn help_names_the_separate_read_only_executable() {
    let output = run(&["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.starts_with("diskm "));
    assert!(help.contains("status"));
    assert!(help.contains("scan"));
    assert!(help.contains("history"));
}

#[test]
fn status_produces_a_single_json_object() {
    let output = run(&["status", env!("CARGO_MANIFEST_DIR"), "--json"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(report.is_object());
}

#[test]
fn bounded_scan_reports_incomplete_before_exiting_temporary_failure() {
    let output = run(&["scan", env!("CARGO_MANIFEST_DIR"), "--max-entries", "1"]);
    assert_eq!(
        output.status.code(),
        Some(75),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["complete"], false);
}

#[test]
fn invalid_options_and_mutating_commands_fail_as_usage_errors() {
    for args in [
        &["scan", ".", "--max-entries", "0"][..],
        &["scan", ".", "--deadline-ms", "invalid"],
        &["status", ".", "--max-entries", "1"],
        &["history", "--days", "10", "--state-dir", "."],
        &["reclaim", ".", "--apply"],
    ] {
        let output = run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
    }
}

#[test]
fn preview_deadline_is_restricted_to_six_hour_scratch() {
    for args in [
        &[
            "preview",
            "--scope",
            "tmp",
            "--min-hours",
            "6",
            "--deadline-ms",
            "250",
        ][..],
        &[
            "preview",
            "--scope",
            "all",
            "--min-hours",
            "6",
            "--state-dir",
            ".",
            "--deadline-ms",
            "250",
        ],
        &[
            "preview",
            "--scope",
            "scratch",
            "--min-hours",
            "48",
            "--state-dir",
            ".",
            "--deadline-ms",
            "250",
        ],
        &[
            "preview",
            "--scope",
            "scratch",
            "--min-hours",
            "6",
            "--state-dir",
            ".",
            "--deadline-ms",
            "0",
        ],
    ] {
        let output = run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
    }
}

#[test]
fn scan_matches_legacy_apparent_bytes_on_the_same_fixture_tree() {
    let crate_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture_root = crate_root.join("tests");
    let fixture = fixture_root.to_str().unwrap();
    let legacy = Command::new("bash")
        .arg(crate_root.join("../scripts/measure_files.sh"))
        .arg(fixture)
        .env_remove("ACT_CURSOR")
        .env_remove("ACT_DEADLINE_AT")
        .output()
        .expect("legacy measurement starts");
    assert!(
        legacy.status.success(),
        "{}",
        String::from_utf8_lossy(&legacy.stderr)
    );
    let mut expected_bytes = 0;
    for line in String::from_utf8(legacy.stdout).unwrap().lines() {
        let fields: Vec<_> = line.splitn(5, '\t').collect();
        assert_eq!(fields.len(), 5, "{line}");
        assert!(matches!(fields[3], "A" | "F"), "{line}");
        expected_bytes += fields[0].parse::<u64>().unwrap();
    }
    assert!(expected_bytes > 0);

    let candidate = run(&["scan", fixture]);
    assert!(candidate.status.success());
    let report: Value = serde_json::from_slice(&candidate.stdout).unwrap();
    assert_eq!(report["complete"], true);
    assert_eq!(report["apparent_bytes"], expected_bytes);
}

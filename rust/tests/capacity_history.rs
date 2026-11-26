use serde_json::{json, Value};
use std::{fs, path::Path, process::Command};

fn git(root: &Path, args: &[&str]) {
    assert!(Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap()
        .status
        .success());
}

fn history(root: &Path, args: &[&str]) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .arg("history")
        .arg("--state-dir")
        .arg(root)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn mac_timer_targets_data() {
    let template =
        include_str!("../../launchd/com.jleechanorg.disk-magician-snapshot.plist.template");
    assert!(template.contains("<string>/System/Volumes/Data</string>"));
}

#[test]
fn capacity_history_compares_a_month_and_reports_its_scope() {
    let root = std::env::temp_dir().join(format!("diskm-capacity-history-{}", std::process::id()));
    fs::create_dir_all(root.join("snapshots")).unwrap();
    git(&root, &["init", "-q"]);
    git(&root, &["config", "user.name", "fixture"]);
    git(&root, &["config", "user.email", "fixture@example.test"]);
    let now = std::time::SystemTime::now();
    let capture = |ago, used, host, source, mounted_at| {
        let timestamp =
            diskm_shadow::job_receipt::timestamp(now - std::time::Duration::from_secs(ago))
                .unwrap();
        let sample = json!({"timestamp": timestamp, "disk_used_gb":0.0,
            "snapshot_metadata":{"scope":"capacity_only","hostname":host,"filesystem":source,"mounted_at":mounted_at,"used_kib":used}});
        fs::write(
            root.join("snapshots/disk_snapshot.json"),
            sample.to_string(),
        )
        .unwrap();
        git(&root, &["add", "snapshots"]);
        git(&root, &["commit", "-qm", "capture"]);
    };
    for idx in (0..180).rev() {
        capture(
            5 + idx * 14_400,
            700_000_000 + idx,
            "mac",
            "/dev/disk3s5",
            "/System/Volumes/Data",
        );
    }
    capture(4, 2, "other", "/dev/test", "/");
    capture(3, 12_000_000, "mac", "/dev/disk3s1", "/");
    let newer = history(&root, &["--capacity", "--days", "30"]);
    assert_eq!(newer["floor"]["disk_used_kb"], 12_000_000);
    assert_eq!(newer["scope"]["mounted_at"], "/");
    capture(
        2,
        710_000_000,
        "mac",
        "/dev/disk3s5",
        "/System/Volumes/Data",
    );
    capture(
        1,
        710_000_001,
        "mac",
        "/dev/disk3s5",
        "/System/Volumes/Data",
    );
    let report = history(&root, &["--capacity", "--days", "30"]);
    assert_eq!(report["availability"], "available");
    assert_eq!(report["coverage_status"], "observed_samples_only");
    assert_eq!(report["valid_samples"], 182);
    assert_eq!(report["incompatible_samples"], 2);
    assert_eq!(report["scope"]["mounted_at"], "/System/Volumes/Data");
    assert_eq!(report["floor"]["disk_used_kb"], 700_000_000);
    assert_eq!(history(&root, &[])["availability"], "no_valid_floor");
    for idx in 0..75 {
        capture(0, idx, "mac", "/dev/disk3s5", "/System/Volumes/Data");
    }
    let over = history(&root, &["--capacity", "--days", "30"]);
    assert_eq!(over["availability"], "incomplete_history");
    assert!(over["floor"].is_null());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn actual_snapshot_reaches_git_capacity_history() {
    let parent = std::env::temp_dir().join(format!("diskm-native-snapshot-{}", std::process::id()));
    let state = parent.join("state");
    let repo = parent.join("backup");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-qb", "main"]);
    let run = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice::<Value>(&out.stdout).unwrap()
    };
    let state_str = state.to_str().unwrap();
    let sample = run(&["snapshot", "--path", "/", "--state-dir", state_str]);
    assert_eq!(sample["snapshot"]["measurement_status"], "partial");
    let metadata = &sample["snapshot"]["snapshot_metadata"];
    assert!(metadata["used_kib"].is_u64());
    assert!(metadata["hostname"].as_str().is_some_and(|s| !s.is_empty()));
    run(&[
        "state-commit",
        "--repo",
        repo.to_str().unwrap(),
        "--state-dir",
        state_str,
    ]);
    let report = history(&repo, &["--capacity"]);
    assert_eq!(report["floor"]["disk_used_kb"], metadata["used_kib"]);
    for k in ["hostname", "filesystem", "mounted_at"] {
        assert_eq!(metadata[k], report["scope"][k]);
    }
    assert_eq!(history(&repo, &[])["availability"], "no_valid_floor");
    fs::remove_dir_all(parent).unwrap();
}

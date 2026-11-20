use serde_json::{json, Value};
use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn preview_ledger_reports_known_locations_without_qualifying_them() {
    let tree = std::env::temp_dir().join(format!(
        "diskm-ledger-contract-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&tree).unwrap();
    fs::create_dir(tree.join("reclaim")).unwrap();
    let known_root = "/example/previously-cleaned-root";
    fs::write(
        tree.join("reclaim/directory-ledger.json"),
        json!({"rows":[{"row_type":"cleanup_root","canonical_path":known_root}]}).to_string(),
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_diskm-rust"))
        .args(["preview", "--scope", "ledger", "--state-dir"])
        .arg(&tree)
        .arg("--dry-run")
        .output()
        .unwrap();
    fs::remove_dir_all(&tree).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(report.to_string().contains(known_root));
    assert!(!report.to_string().contains(r#""eligible":true"#));
}

#[test]
fn preview_scope_accepts_named_places_rather_than_arbitrary_paths() {
    let output = Command::new(env!("CARGO_BIN_EXE_diskm-rust"))
        .args(["preview", "--scope", "/"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("--scope"));
}

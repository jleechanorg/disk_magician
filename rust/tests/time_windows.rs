use diskm_shadow::scratch_sweep::Options;
use diskm_shadow::time_windows::{CONTENT_FLOOR_HOURS, SCAN_DEADLINE};
use std::process::Command;

#[test]
fn sweep_defaults_come_from_time_windows() {
    let options = Options::default();
    assert_eq!(options.min_hours, CONTENT_FLOOR_HOURS);
    assert_eq!(options.deadline, SCAN_DEADLINE);
}

#[test]
fn templates_do_not_restate_the_content_floor() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let output = Command::new("git")
        .arg("-C")
        .arg(&root)
        .args(["grep", "-n", "--", "--min-hours", "launchd", "systemd"])
        .output()
        .unwrap();
    let found = String::from_utf8_lossy(&output.stdout);
    assert!(
        found.trim().is_empty(),
        "templates restate --min-hours:\n{found}"
    );
}

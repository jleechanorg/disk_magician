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

/// Active native scheduler templates: their windows must be placeholders.
const ACTIVE_TEMPLATES: &[&str] = &[
    "launchd/com.jleechanorg.disk-magician-snapshot.plist.template",
    "launchd/com.jleechanorg.disk-magician-scratch-pressure.plist.template",
    "launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template",
    "launchd/com.jleechanorg.disk-magician-state-commit.plist.template",
    "launchd/com.jleechanorg.disk-magician-evidence-holds.plist.template",
    "systemd/disk-magician-snapshot.timer.in",
    "systemd/disk-magician-state-commit.timer.in",
    "systemd/disk-magician-evidence-holds.timer.in",
    "systemd/diskm-temp-clean.timer.in",
    "systemd/diskm-scratch-reclaim.timer.in",
    "systemd/diskm-scratch-reclaim.service.in",
    "launchd/com.jleechanorg.disk-magician-scratch-expired.plist.template",
    "systemd/diskm-scratch-expired.service.in",
    "systemd/diskm-scratch-expired.timer.in",
    "launchd/com.jleechanorg.disk-magician-worktree-hygiene.plist.template",
    "systemd/disk-magician-worktree-hygiene.service.in",
    "systemd/disk-magician-worktree-hygiene.timer.in",
];

#[test]
fn active_templates_take_every_window_from_time_windows() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let names: Vec<String> = diskm_shadow::time_windows::listing()
        .into_iter()
        .map(|(name, _)| format!("@{name}_SECONDS@"))
        .collect();
    for template in ACTIVE_TEMPLATES {
        let text = std::fs::read_to_string(root.join(template)).unwrap();
        for line in text.lines() {
            let window_line = line.contains("<integer>")
                || line.starts_with("OnBootSec=")
                || line.starts_with("OnUnitActiveSec=")
                || line.starts_with("OnCalendar=")
                || line.starts_with("TimeoutStartSec=");
            if window_line {
                assert!(
                    names.iter().any(|name| line.contains(name)),
                    "{template}: window not taken from time_windows: {line}"
                );
            }
        }
    }
}

#[test]
fn expired_sweep_windows_are_listed() {
    let listing: std::collections::HashMap<_, _> =
        diskm_shadow::time_windows::listing().into_iter().collect();
    let secs = |name: &str| listing[name].as_secs();
    assert_eq!(secs("EXPIRED_SWEEP_INTERVAL"), 3600);
    assert_eq!(secs("EXPIRED_SWEEP_DEADLINE"), 600);
    assert_eq!(secs("GIT_REMOTE_PROBE_TIMEOUT"), 20);
}

#[test]
fn expired_templates_run_the_expired_sweep() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let read = |name: &str| std::fs::read_to_string(root.join(name)).unwrap();
    for template in [
        "launchd/com.jleechanorg.disk-magician-scratch-expired.plist.template",
        "systemd/diskm-scratch-expired.service.in",
    ] {
        let text = read(template);
        assert!(
            text.contains("scratch-sweep")
                && text.contains("--expired")
                && text.contains("--clean"),
            "{template} must run scratch-sweep --expired --clean"
        );
    }
    let timer = read("systemd/diskm-scratch-expired.timer.in");
    for key in ["OnBootSec=", "OnUnitActiveSec="] {
        assert!(
            timer
                .lines()
                .any(|l| l.starts_with(key) && l.contains("@EXPIRED_SWEEP_INTERVAL_SECONDS@")),
            "timer {key} must use the interval placeholder"
        );
    }
    assert!(
        !timer.contains("scratch-sweep"),
        "a timer carries no command"
    );
}

#[test]
fn worktree_hygiene_windows_are_exposed_by_cli() {
    let output = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .arg("time-windows")
        .output()
        .unwrap();
    assert!(output.status.success(), "diskm time-windows failed");
    let windows: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(windows["WORKTREE_FLOOR_SECONDS"], 604_800);
    assert_eq!(windows["WORKTREE_HYGIENE_INTERVAL_SECONDS"], 21_600);
}

#[test]
fn content_floor_env_var_reaches_a_real_run() {
    // A real subprocess proves the variable is read, without depending on a Scratch
    // volume being configured (CI has none, and `scratch-qualify` errors out there).
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let run = |value: Option<&str>| {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_diskm"));
        cmd.current_dir(&root)
            .arg("time-windows")
            .stdout(std::process::Stdio::piped());
        match value {
            Some(v) => cmd.env("DISK_MAGICIAN_CONTENT_FLOOR_HOURS", v),
            None => cmd.env_remove("DISK_MAGICIAN_CONTENT_FLOOR_HOURS"),
        };
        assert!(
            cmd.output().unwrap().status.success(),
            "time-windows failed"
        );
        String::from_utf8_lossy(&cmd.output().unwrap().stdout).to_string()
    };
    assert!(run(None).contains("CONTENT_FLOOR_SECONDS"));
    // Malformed and out-of-range values must not change the reported window.
    for bad in ["bogus", "", "0", "99999", "-5"] {
        assert!(
            run(Some(bad)).contains("43200"),
            "value {bad:?} must fall back to 12 h"
        );
    }
}

#[test]
fn malformed_floor_env_falls_back_to_the_constant() {
    use diskm_shadow::time_windows::{resolved_content_floor_hours, CONTENT_FLOOR_HOURS};
    for bad in ["", "bogus", "0", "99999"] {
        // SAFETY: single-threaded assertion helper; no other thread reads this var.
        std::env::set_var("DISK_MAGICIAN_CONTENT_FLOOR_HOURS", bad);
        assert_eq!(
            resolved_content_floor_hours(),
            CONTENT_FLOOR_HOURS,
            "value {bad:?} must fall back to the constant"
        );
    }
    std::env::set_var("DISK_MAGICIAN_CONTENT_FLOOR_HOURS", "6");
    assert_eq!(resolved_content_floor_hours(), 6);
    std::env::remove_var("DISK_MAGICIAN_CONTENT_FLOOR_HOURS");
}

#[test]
fn expired_service_has_terminal_receipt_headroom() {
    let template = include_str!("../../systemd/diskm-scratch-expired.service.in");
    let listing: std::collections::HashMap<_, _> =
        diskm_shadow::time_windows::listing().into_iter().collect();
    assert!(template.contains("TimeoutStartSec=@EXPIRED_SWEEP_SERVICE_TIMEOUT_SECONDS@"));
    assert!(listing["EXPIRED_SWEEP_SERVICE_TIMEOUT"] > listing["EXPIRED_SWEEP_DEADLINE"]);
}

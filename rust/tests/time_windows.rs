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

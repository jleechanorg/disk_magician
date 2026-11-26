use diskm_shadow::scan::{scan_with_age_inventory, ScanGapKind, ScanOptions};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct TempRoot(PathBuf);

impl TempRoot {
    fn new(label: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "diskm-scan-test-{label}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        if let Ok(entries) = fs::read_dir(&self.0) {
            for entry in entries.flatten() {
                let _ = fs::set_permissions(entry.path(), fs::Permissions::from_mode(0o700));
            }
        }
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn skips_unreadable_macos_volume_metadata_at_root() {
    let root = TempRoot::new("apfs-meta");
    fs::write(root.0.join("keep.txt"), b"hello").unwrap();
    let meta_dir = root.0.join(".Spotlight-V100");
    fs::create_dir(&meta_dir).unwrap();
    fs::set_permissions(&meta_dir, fs::Permissions::from_mode(0o000)).unwrap();

    let (report, inventory) = scan_with_age_inventory(
        &root.0,
        ScanOptions {
            deadline: Duration::from_secs(10),
            max_entries: 1000,
        },
    )
    .unwrap();

    if cfg!(target_os = "macos") {
        assert!(
            report.complete,
            "expected complete scan on macOS when only APFS metadata dir is unreadable; gaps={:?}",
            report.gaps
        );
        assert!(inventory.complete);
        assert!(report.gaps.is_empty());
    } else {
        assert!(!report.complete);
        assert!(report
            .gaps
            .iter()
            .any(|g| g.kind == ScanGapKind::ReadDirectory));
    }

    // A normal unreadable directory must STILL mark the scan incomplete.
    let normal_unreadable = root.0.join("restricted");
    fs::create_dir(&normal_unreadable).unwrap();
    fs::set_permissions(&normal_unreadable, fs::Permissions::from_mode(0o000)).unwrap();
    let (report2, inventory2) = scan_with_age_inventory(
        &root.0,
        ScanOptions {
            deadline: Duration::from_secs(10),
            max_entries: 1000,
        },
    )
    .unwrap();
    assert!(!report2.complete);
    assert!(!inventory2.complete);
    assert!(report2
        .gaps
        .iter()
        .any(|g| g.kind == ScanGapKind::ReadDirectory && g.path.ends_with("restricted")));
}

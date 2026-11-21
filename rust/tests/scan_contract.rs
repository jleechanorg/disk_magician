use diskm_shadow::scan::{scan, FileKind, ScanGapKind, ScanOptions};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

const ITEMIZATION_THRESHOLD: u64 = 100 * 1024 * 1024;

struct Fixture(PathBuf);

impl Fixture {
    fn new(label: &str) -> Self {
        let parent = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
            .map(PathBuf::from)
            .expect("tests require a directory allocated on managed Scratch");
        let parent = fs::canonicalize(parent).expect("Scratch fixture parent exists");
        let unique = format!(
            "scan-contract-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock is after the epoch")
                .as_nanos()
        );
        let path = parent.join(unique);
        fs::create_dir(&path).expect("create unique Scratch fixture");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(parent) = self.0.parent() {
            if let (Ok(parent), Ok(canonical)) =
                (fs::canonicalize(parent), fs::canonicalize(&self.0))
            {
                if canonical.parent() == Some(parent.as_path())
                    && self
                        .0
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with("scan-contract-"))
                {
                    let _ = fs::remove_dir_all(canonical);
                }
            }
        }
    }
}

fn options(max_entries: usize) -> ScanOptions {
    ScanOptions {
        deadline: Duration::from_secs(10),
        max_entries,
    }
}

fn has_file(report: &diskm_shadow::scan::ScanReport, path: &Path) -> bool {
    report
        .files
        .iter()
        .any(|entry| Path::new(&entry.path) == path)
}

#[test]
fn itemises_directory_at_exactly_one_hundred_mib() {
    let fixture = Fixture::new("exact-threshold");
    let payload = fixture.path().join("payload.bin");
    File::create(&payload)
        .expect("create sparse fixture file")
        .set_len(ITEMIZATION_THRESHOLD)
        .expect("set exact apparent size");

    let report = scan(fixture.path(), options(16)).expect("scan fixture");

    assert!(report.complete, "gaps: {:?}", report.gaps);
    assert_eq!(report.threshold_bytes, ITEMIZATION_THRESHOLD);
    assert_eq!(report.apparent_bytes, ITEMIZATION_THRESHOLD);
    assert!(
        has_file(&report, &payload),
        "large directory content remains visible as a file leaf"
    );
    let root = report
        .directories
        .iter()
        .find(|directory| directory.path == fixture.path().to_string_lossy().as_ref())
        .expect("root directory was measured");
    assert_eq!(
        root.must_itemize,
        Some(true),
        "exactly 100 MiB requires itemization"
    );
    assert_eq!(root.apparent_bytes, ITEMIZATION_THRESHOLD);
}

#[test]
fn directory_below_one_hundred_mib_keeps_file_level_evidence() {
    let fixture = Fixture::new("below-threshold");
    let payload = fixture.path().join("payload.bin");
    File::create(&payload)
        .expect("create sparse fixture file")
        .set_len(ITEMIZATION_THRESHOLD - 1)
        .expect("set apparent size");

    let report = scan(fixture.path(), options(16)).expect("scan fixture");

    assert!(report.complete, "gaps: {:?}", report.gaps);
    assert_eq!(report.apparent_bytes, ITEMIZATION_THRESHOLD - 1);
    assert!(has_file(&report, &payload));
    let root = report
        .directories
        .iter()
        .find(|directory| directory.path == fixture.path().to_string_lossy().as_ref())
        .expect("root directory was measured");
    assert_eq!(root.must_itemize, Some(false));
    assert_eq!(root.apparent_bytes, ITEMIZATION_THRESHOLD - 1);
}

#[cfg(unix)]
#[test]
fn symlink_root_is_reported_without_canonicalizing_its_target() {
    use std::os::unix::fs::symlink;

    let fixture = Fixture::new("symlink-root");
    let target = fixture.path().join("large-target");
    File::create(&target)
        .expect("create target")
        .set_len(ITEMIZATION_THRESHOLD + 1)
        .expect("make target large");
    let root_link = fixture.path().join("root-link");
    symlink(&target, &root_link).expect("create root symlink");

    let report = scan(&root_link, options(16)).expect("report root symlink leaf");

    assert!(report.complete);
    assert_eq!(report.files.len(), 1);
    assert_eq!(report.files[0].path, root_link.to_string_lossy().as_ref());
    assert_eq!(report.files[0].kind, FileKind::Symlink);
    assert_eq!(
        report.apparent_bytes,
        fs::symlink_metadata(&root_link).unwrap().len()
    );
    assert!(
        !has_file(&report, &target),
        "root symlink target was not inspected"
    );
}

#[cfg(unix)]
#[test]
fn special_files_are_counted_as_typed_leaves() {
    use std::os::unix::net::UnixListener;

    let fixture = Fixture::new("special-file");
    let socket = fixture.path().join("local.sock");
    let listener = UnixListener::bind(&socket).expect("create Unix socket fixture");

    let report = scan(fixture.path(), options(16)).expect("scan socket leaf");
    drop(listener);
    let entry = report
        .files
        .iter()
        .find(|entry| entry.path == socket.to_string_lossy().as_ref())
        .expect("socket is represented as a file-system leaf");
    assert_eq!(entry.kind, FileKind::Special);
    assert_eq!(
        entry.special_type,
        Some(diskm_shadow::scan::SpecialFileKind::Socket)
    );
}

#[cfg(unix)]
#[test]
fn symlink_is_a_leaf_and_its_target_is_never_walked() {
    use std::os::unix::fs::symlink;

    let fixture = Fixture::new("symlink");
    let scope = fixture.path().join("scope");
    fs::create_dir(&scope).expect("create scan scope");
    let target = fixture.path().join("outside-target");
    fs::create_dir(&target).expect("create symlink target directory");
    let outside_file = target.join("private.bin");
    File::create(&outside_file)
        .expect("create target file")
        .set_len(ITEMIZATION_THRESHOLD + 1)
        .expect("make target a traversal sentinel");
    let link = scope.join("link");
    symlink(&target, &link).expect("create directory symlink");

    let report = scan(&scope, options(16)).expect("scan fixture");

    assert!(report.complete, "gaps: {:?}", report.gaps);
    let link_entry = report
        .files
        .iter()
        .find(|entry| entry.path == link.to_string_lossy().as_ref())
        .expect("symlink is reported as a leaf");
    assert_eq!(link_entry.kind, FileKind::Symlink);
    assert!(
        !has_file(&report, &outside_file),
        "symlink target is not traversed"
    );
    assert_eq!(
        report.apparent_bytes,
        fs::symlink_metadata(&link).unwrap().len()
    );
}

#[test]
fn entry_budget_exhaustion_is_an_explicit_incomplete_gap() {
    let fixture = Fixture::new("entry-budget");
    fs::write(fixture.path().join("one"), b"1").expect("create child");
    fs::write(fixture.path().join("two"), b"2").expect("create child");

    let report = scan(fixture.path(), options(2)).expect("bounded scan returns its partial report");

    assert!(!report.complete);
    assert!(report
        .gaps
        .iter()
        .any(|gap| gap.kind == ScanGapKind::EntryLimit));
}

#[test]
fn preexpired_deadline_retains_a_partial_root_gap() {
    let fixture = Fixture::new("deadline");
    fs::write(fixture.path().join("one"), b"1").expect("create child");
    let expired = ScanOptions {
        deadline: Duration::ZERO,
        max_entries: 16,
    };

    let report = scan(fixture.path(), expired).expect("expired scan returns a partial report");

    assert!(!report.complete);
    assert!(report
        .gaps
        .iter()
        .any(|gap| gap.kind == ScanGapKind::Deadline));
    assert_eq!(report.apparent_bytes, 0, "unvisited bytes are not guessed");
}

#[cfg(unix)]
#[test]
fn allocated_total_deduplicates_hardlinks_while_apparent_total_keeps_paths() {
    use std::fs::hard_link;

    let fixture = Fixture::new("hardlinks");
    let first = fixture.path().join("first.bin");
    let second = fixture.path().join("second.bin");
    let mut data = File::create(&first).expect("create hardlink target");
    data.write_all(&vec![7; 2 * 1024 * 1024])
        .expect("write allocated data");
    hard_link(&first, &second).expect("create second name for same inode");

    let report = scan(fixture.path(), options(16)).expect("scan fixture");

    assert!(report.complete, "gaps: {:?}", report.gaps);
    assert_eq!(report.apparent_bytes, (4 * 1024 * 1024) as u64);
    assert!(report.allocated_bytes > 0);
    assert!(report.allocated_bytes < report.apparent_bytes);
}

#[cfg(unix)]
#[test]
fn unreadable_directory_is_a_gap_when_running_unprivileged() {
    use std::os::unix::fs::PermissionsExt;

    // Root may enumerate mode-000 directories, so it cannot exercise this case.
    if unsafe { effective_uid() } == 0 {
        return;
    }
    let fixture = Fixture::new("unreadable");
    let blocked = fixture.path().join("blocked");
    fs::create_dir(&blocked).expect("create blocked directory");
    fs::set_permissions(&blocked, fs::Permissions::from_mode(0o000))
        .expect("make directory unreadable");

    let report = scan(fixture.path(), options(16)).expect("inaccessible child is reported");
    fs::set_permissions(&blocked, fs::Permissions::from_mode(0o700))
        .expect("restore fixture permissions before cleanup");

    assert!(!report.complete);
    assert!(report.gaps.iter().any(|gap| {
        gap.kind == ScanGapKind::ReadDirectory && gap.path == blocked.to_string_lossy().as_ref()
    }));
}

#[cfg(unix)]
unsafe fn effective_uid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    // SAFETY: geteuid reads the effective uid of the current process.
    unsafe { geteuid() }
}

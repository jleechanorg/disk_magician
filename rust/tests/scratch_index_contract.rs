use diskm_shadow::scan::{AgeInventoryReport, AgeKind, AgeMeasurement};
use diskm_shadow::scratch_index::ScratchIndex;
use serde_json::Value;
use std::fs::{self, File, FileTimes};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::ffi::{OsStrExt, OsStringExt};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    base: PathBuf,
    root: PathBuf,
    state: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let parent = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
            .map(PathBuf::from)
            .expect("tests require DISKM_SCRATCH_TEST_DIR on registered Scratch");
        let parent = fs::canonicalize(parent).expect("Scratch test parent exists");
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let base = parent.join(format!(
            "scratch-index-contract-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&base).expect("create owned fixture");
        let root = base.join("system-tmp");
        let state = base.join("state");
        fs::create_dir(&root).expect("create scan root");
        fs::create_dir(&state).expect("create index state directory");
        Self { base, root, state }
    }

    fn refresh(&self, root_path: &Path) -> Output {
        self.refresh_with(root_path, &[])
    }

    fn refresh_with(&self, root_path: &Path, extra: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args(["scratch-index", "refresh", "--root", "system-tmp"])
            .arg("--root-path")
            .arg(root_path)
            .arg("--state-dir")
            .arg(&self.state)
            .args(extra)
            .output()
            .expect("age index refresh starts")
    }

    fn search(&self, extra: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args(["scratch-search", "--root", "system-tmp", "--state-dir"])
            .arg(&self.state)
            .args(extra)
            .output()
            .expect("age index search starts")
    }

    fn search_json(&self, extra: &[&str]) -> Value {
        let output = self.search(extra);
        assert!(
            output.status.success(),
            "search failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("search emits JSON")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let parent = self.base.parent().expect("fixture parent");
        let canonical_parent = fs::canonicalize(parent).expect("canonical fixture parent");
        let canonical_base = fs::canonicalize(&self.base).expect("canonical fixture base");
        assert_eq!(canonical_base.parent(), Some(canonical_parent.as_path()));
        assert!(canonical_base
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("scratch-index-contract-"));
        fs::remove_dir_all(canonical_base).expect("remove only this test-owned fixture");
    }
}

fn set_mtime(path: &Path, epoch_seconds: u64) {
    let file = fs::OpenOptions::new()
        .write(true)
        .open(path)
        .expect("open fixture file for timestamp update");
    file.set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(epoch_seconds)))
        .expect("set deterministic fixture mtime");
}

fn refresh_ok(fixture: &Fixture, root_path: &Path) -> Value {
    let output = fixture.refresh(root_path);
    assert!(
        output.status.success(),
        "refresh failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("refresh emits generation receipt JSON")
}

fn entry_named<'a>(page: &'a Value, name: &str) -> &'a Value {
    page["entries"]
        .as_array()
        .expect("entries array")
        .iter()
        .find(|entry| {
            entry["path"]
                .as_str()
                .is_some_and(|path| path.ends_with(name))
        })
        .unwrap_or_else(|| panic!("no indexed entry ends in {name:?}: {}", page["entries"]))
}

#[test]
fn search_uses_published_paths_and_cutoff_without_rewalking_root() {
    let fixture = Fixture::new();
    let mixed = fixture.root.join("mixed parent");
    fs::create_dir(&mixed).unwrap();
    let old = mixed.join("old.cache");
    File::create(&old).unwrap();
    set_mtime(&old, 1_600_000_000);
    let fresh = mixed.join("fresh.cache");
    File::create(&fresh).unwrap();

    let receipt = refresh_ok(&fixture, &fixture.root);
    let generation = receipt["generation"].as_u64().expect("generation number");
    let page = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "any",
        "--limit",
        "100",
    ]);

    assert_eq!(page["generation"], generation);
    assert_eq!(page["root"], fixture.root.to_string_lossy().as_ref());
    assert_eq!(page["coverage_complete"], true);
    assert!(page["gaps"].as_array().unwrap().is_empty());
    let old_entry = entry_named(&page, "old.cache");
    assert_eq!(
        old_entry["effective_modified_epoch_nanos"],
        1_600_000_000_i64 * 1_000_000_000
    );
    assert!(page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .all(|entry| entry["path"].as_str().unwrap().ends_with("old.cache")));
    assert_eq!(old_entry["qualification"], "pending");

    let renamed = fixture.base.join("root-after-refresh");
    fs::rename(&fixture.root, &renamed).expect("move root to prove query uses index");
    let cached = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "any",
        "--limit",
        "100",
    ]);
    assert_eq!(cached["generation"], generation);
    assert_eq!(entry_named(&cached, "old.cache")["path"], old_entry["path"]);
    assert_eq!(cached["coverage_complete"], true);
}

#[test]
fn root_prefix_and_keyset_cursor_return_stable_pages() {
    let fixture = Fixture::new();
    let nested = fixture.root.join("group");
    fs::create_dir(&nested).unwrap();
    for name in ["a.cache", "b.cache"] {
        let file = nested.join(name);
        File::create(&file).unwrap();
        set_mtime(&file, 1_600_000_000);
    }
    let elsewhere = fixture.root.join("other.cache");
    File::create(&elsewhere).unwrap();
    set_mtime(&elsewhere, 1_600_000_000);
    refresh_ok(&fixture, &fixture.root);

    let first = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "file",
        "--prefix",
        "group",
        "--limit",
        "1",
    ]);
    assert_eq!(first["entries"].as_array().unwrap().len(), 1);
    let cursor = first["next_cursor"]
        .as_str()
        .expect("first page has continuation cursor");
    let second = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "file",
        "--prefix",
        "group",
        "--limit",
        "1",
        "--cursor",
        cursor,
    ]);
    assert_eq!(second["generation"], first["generation"]);
    assert_eq!(second["entries"].as_array().unwrap().len(), 1);
    assert_ne!(first["entries"][0]["path"], second["entries"][0]["path"]);
    assert!(second["next_cursor"].is_null());

    let all = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "file",
        "--prefix",
        "group",
        "--all",
    ]);
    assert_eq!(all["entries"].as_array().unwrap().len(), 2);
}

#[test]
fn failed_refresh_preserves_the_last_published_generation() {
    let fixture = Fixture::new();
    let file = fixture.root.join("old.cache");
    File::create(&file).unwrap();
    set_mtime(&file, 1_600_000_000);
    let first = refresh_ok(&fixture, &fixture.root);

    let missing = fixture.base.join("missing-root");
    let failed = fixture.refresh(&missing);
    assert!(!failed.status.success(), "refresh of absent root must fail");

    let page = fixture.search_json(&["--before-epoch", "1700000000", "--type", "any", "--all"]);
    assert_eq!(page["generation"], first["generation"]);
    assert_eq!(page["entries"].as_array().unwrap().len(), 1);
    assert!(entry_named(&page, "old.cache").is_object());
}

#[test]
fn entry_limited_refresh_publishes_explicit_partial_coverage() {
    let fixture = Fixture::new();
    for name in ["a.cache", "b.cache", "c.cache"] {
        File::create(fixture.root.join(name)).unwrap();
    }

    let receipt = fixture.refresh_with(&fixture.root, &["--max-entries", "1"]);
    assert!(
        receipt.status.success(),
        "partial scan should publish its explicit coverage: {}",
        String::from_utf8_lossy(&receipt.stderr)
    );
    let receipt: Value = serde_json::from_slice(&receipt.stdout).unwrap();
    assert_eq!(receipt["coverage_complete"], false);

    let page = fixture.search_json(&["--before-epoch", "1700000000", "--type", "any", "--all"]);
    assert_eq!(page["generation"], receipt["generation"]);
    assert_eq!(page["coverage_complete"], false);
    assert!(!page["gaps"].as_array().unwrap().is_empty());
    assert!(page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .all(|entry| { entry["coverage_complete"] == false || entry["kind"] == "directory" }));
}

#[cfg(unix)]
#[test]
fn search_preserves_non_utf8_names_as_hex_path_bytes() {
    let fixture = Fixture::new();
    let name = std::ffi::OsString::from_vec(vec![b'n', b'o', b'n', b'u', b't', b'f', b'8', 0xff]);
    let file = fixture.root.join(&name);
    match File::create(&file) {
        Ok(_) => {
            set_mtime(&file, 1_600_000_000);
            refresh_ok(&fixture, &fixture.root);
        }
        Err(error) if error.raw_os_error() == Some(libc::EILSEQ) => {
            // macOS volumes can reject these names. Exercise the real index and output
            // with the byte sequence directly, while Linux exercises the scanner too.
            let (_, mut inventory) = diskm_shadow::scan::scan_with_age_inventory(
                &fixture.root,
                diskm_shadow::scan::ScanOptions {
                    deadline: Duration::from_secs(5),
                    max_entries: 16,
                },
            )
            .unwrap();
            let mut entry = inventory.entries[0].clone();
            entry.path_bytes = file.as_os_str().as_bytes().to_vec();
            entry.kind = AgeKind::File;
            entry.modified_epoch_nanos = Some(1_600_000_000_000_000_000);
            entry.effective_modified_epoch_nanos = entry.modified_epoch_nanos;
            inventory.entries.push(entry);
            ScratchIndex::open(fixture.state.join("scratch-age.sqlite3"))
                .unwrap()
                .publish("system-tmp", 1, &inventory)
                .unwrap();
        }
        Err(error) => panic!("create byte-path fixture: {error}"),
    }

    let page = fixture.search_json(&["--before-epoch", "1700000000", "--type", "file", "--all"]);
    let bytes = file.as_os_str().as_bytes();
    let expected_hex = bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    assert!(page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["path_bytes_hex"] == expected_hex));
}

#[test]
#[ignore = "explicit one-million-row indexed-search performance qualification"]
fn first_indexed_page_over_one_million_rows_completes_under_two_seconds() {
    // This ignored acceptance run seeds a local fixture index in one publication
    // transaction and times the actual CLI, including database open and JSON output.
    let fixture = Fixture::new();
    let root = fixture.root.canonicalize().unwrap();
    let root_metadata = fs::metadata(&root).unwrap();
    let root_bytes = root.as_os_str().as_bytes().to_vec();
    let root_entry = AgeMeasurement {
        path_bytes: root_bytes.clone(),
        kind: AgeKind::Directory,
        created_epoch_nanos: None,
        modified_epoch_nanos: Some(1),
        changed_epoch_nanos: Some(1),
        allocated_bytes: 0,
        apparent_bytes: 0,
        device: root_metadata.dev(),
        inode: root_metadata.ino(),
        effective_modified_epoch_nanos: Some(1),
        complete: true,
    };
    let mut entries = Vec::with_capacity(1_000_001);
    entries.push(root_entry);
    for row in 0..1_000_000_u64 {
        let path = root.join(format!("fixture-{row:07}.cache"));
        entries.push(AgeMeasurement {
            path_bytes: path.as_os_str().as_bytes().to_vec(),
            kind: AgeKind::File,
            created_epoch_nanos: Some(1),
            modified_epoch_nanos: Some(1),
            changed_epoch_nanos: Some(1),
            allocated_bytes: 16,
            apparent_bytes: 16,
            device: root_metadata.dev(),
            inode: row + 1,
            effective_modified_epoch_nanos: Some(1),
            complete: true,
        });
    }
    let inventory = AgeInventoryReport {
        root_path_bytes: root_bytes,
        root_device: root_metadata.dev(),
        root_inode: root_metadata.ino(),
        entries,
        gaps: Vec::new(),
        complete: true,
    };
    let mut index = ScratchIndex::open(fixture.state.join("scratch-age.sqlite3"))
        .expect("open performance fixture index");
    index
        .publish("system-tmp", 1, &inventory)
        .expect("publish million-row fixture in one generation");
    drop(index);

    let started = std::time::Instant::now();
    let page = fixture.search_json(&[
        "--before-epoch",
        "1700000000",
        "--type",
        "any",
        "--limit",
        "100",
    ]);
    assert_eq!(page["entries"].as_array().unwrap().len(), 100);
    let elapsed = started.elapsed();
    println!("First indexed page, one million entries: {elapsed:?}");
    assert!(
        elapsed < Duration::from_secs(2),
        "first page took {elapsed:?}"
    );
}

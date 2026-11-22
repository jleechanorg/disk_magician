use diskm_shadow::scratch_target::check_completed_build;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

/// `check_completed_build` reads the process-wide state-dir variable.
static STATE_ENV: Mutex<()> = Mutex::new(());

struct Fixture {
    base: PathBuf,
    root: PathBuf,
    state: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

fn fixture(name: &str) -> Fixture {
    let base = std::env::temp_dir().join(format!("diskm-legacy-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let root = base.join("scratch");
    let state = base.join("state");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(state.join("worktree_leases")).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    Fixture { base, root, state }
}

/// A run directory plus a legacy lease record in the retired allocator's format.
fn legacy_run(f: &Fixture, id: &str, kind: &str, owner_pid: u32) -> PathBuf {
    let run = f.root.join("runs/20261101/repo").join(id);
    fs::create_dir_all(&run).unwrap();
    fs::write(run.join("out.bin"), "x").unwrap();
    let metadata = fs::metadata(&run).unwrap();
    let record = json!({
        "schema_version": 1,
        "path": run,
        "creator": "scratch-new",
        "kind": kind,
        "owner": {"pid": owner_pid, "start_epoch": 1, "comm": "codex"},
        "owners": [{"pid": owner_pid, "start_epoch": 1, "comm": "codex"}],
        "checkout_dev": metadata.dev(),
        "checkout_ino": metadata.ino(),
        "released_at": null,
    });
    fs::write(
        f.state.join("worktree_leases").join(format!("{id}.json")),
        serde_json::to_vec(&record).unwrap(),
    )
    .unwrap();
    run
}

fn exited_pid() -> u32 {
    let mut child = Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

fn verdict(f: &Fixture, run: &Path) -> Result<(), &'static str> {
    let _guard = STATE_ENV
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    std::env::set_var("DISK_MAGICIAN_STATE_DIR", &f.state);
    check_completed_build(&f.root, run)
}

#[test]
fn legacy_build_run_with_exited_owner_qualifies() {
    let f = fixture("exited");
    let run = legacy_run(&f, "build-exited", "build", exited_pid());
    assert_eq!(verdict(&f, &run), Ok(()));
}

#[test]
fn legacy_build_run_with_live_owner_is_kept() {
    let f = fixture("live");
    let run = legacy_run(&f, "build-live", "build", std::process::id());
    assert_eq!(verdict(&f, &run), Err("kept:producer-still-live"));
}

#[test]
fn legacy_evidence_run_is_kept() {
    let f = fixture("evidence");
    let run = legacy_run(&f, "evidence-run", "evidence", exited_pid());
    assert_eq!(verdict(&f, &run), Err("kept:protected-bundle-kind"));
}

#[test]
fn run_without_any_lease_stays_lease_missing() {
    let f = fixture("missing");
    let run = f.root.join("runs/20261101/repo/no-lease");
    fs::create_dir_all(&run).unwrap();
    assert_eq!(verdict(&f, &run), Err("kept:lease-missing"));
}

#[test]
fn legacy_record_for_a_replaced_directory_is_ignored() {
    let f = fixture("replaced");
    let run = legacy_run(&f, "build-replaced", "build", exited_pid());
    // Simulate a different directory at the same path: the recorded inode no
    // longer matches. Deterministic, unlike deleting and recreating it, which
    // can reuse the inode on Linux.
    let record_path = f.state.join("worktree_leases/build-replaced.json");
    let mut record: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    let inode = record["checkout_ino"].as_u64().unwrap();
    record["checkout_ino"] = json!(inode + 1);
    fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
    assert_eq!(verdict(&f, &run), Err("kept:lease-missing"));
}

#[test]
fn legacy_owner_without_a_pid_keeps_the_run() {
    let f = fixture("unknown-owner");
    let run = legacy_run(&f, "build-unknown", "build", exited_pid());
    let record_path = f.state.join("worktree_leases/build-unknown.json");
    let mut record: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    record["owners"]
        .as_array_mut()
        .unwrap()
        .push(json!({"comm": "codex"}));
    fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
    assert_eq!(verdict(&f, &run), Err("kept:producer-still-live"));
}

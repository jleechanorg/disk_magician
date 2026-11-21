use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
static PROCESS_ENV_LOCK: Mutex<()> = Mutex::new(());

struct Fixture {
    root: PathBuf,
    scratch: PathBuf,
    state: PathBuf,
    bin: PathBuf,
    calls: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let nonce = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "diskm-preview-contract-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&root).expect("create isolated preview fixture");
        let root = fs::canonicalize(root).expect("resolve fixture root");
        let scratch = root.join("scratch");
        fs::create_dir(&scratch).expect("create scratch fixture");
        let state = root.join("state");
        fs::create_dir_all(state.join("reclaim")).expect("create state fixture");
        let bin = root.join("bin");
        fs::create_dir(&bin).expect("create fake command directory");
        let calls = root.join("calls.log");
        Self {
            root,
            scratch,
            state,
            bin,
            calls,
        }
    }

    fn write_ledger(&self, rows: Value) {
        fs::write(
            self.state.join("reclaim/directory-ledger.json"),
            serde_json::to_vec(&json!({"rows": rows})).unwrap(),
        )
        .unwrap();
    }

    fn install_diskm(&self) {
        let executable = self.bin.join("disk-magician");
        fs::write(
            &executable,
            r##"#!/bin/sh
set -eu
printf 'AGE=%s' "${DISK_MAGICIAN_AGE_FLOOR_MINUTES-unset}" >> "$CALL_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
if [ "$#" -eq 3 ] && [ "$1" = volume ] && [ "$2" = path ] && [ "$3" = scratch ]; then
  printf '%s\n' "$FAKE_SCRATCH_ROOT"
  exit 0
fi
if [ "$#" -eq 7 ] && [ "$1" = quarantine ] && [ "$2" = verdict ] && [ "$4" = --kind ] && [ "$5" = ephemeral ] && [ "$6" = --deadline-at ]; then
  case "${3##*/}" in
    held-live*) printf 'kept:live-owner\n' ;;
    held-open*) printf 'kept:open-file\n' ;;
    held-unknown*) printf 'kept:owner-unknown\n' ;;
    removable*) printf 'remove\n' ;;
    *) printf 'kept:recent-activity\n' ;;
  esac
  exit 0
fi
printf 'unexpected fake diskm arguments\n' >&2
exit 64
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(executable, permissions).unwrap();
    }

    fn run(&self, extra: &[&str]) -> Output {
        let _env_guard = PROCESS_ENV_LOCK.lock().unwrap();
        Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args(["preview", "--state-dir"])
            .arg(&self.state)
            .args(extra)
            .env(
                "PATH",
                std::env::join_paths(std::iter::once(self.bin.clone()).chain(
                    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
                ))
                .unwrap(),
            )
            .env("CALL_LOG", &self.calls)
            .env("FAKE_SCRATCH_ROOT", &self.scratch)
            .env_remove("DISK_MAGICIAN_AGE_FLOOR_MINUTES")
            .output()
            .expect("candidate executable starts")
    }

    fn report_with_checkpoint(&self, deadline: Duration, checkpoint: &Path) -> Value {
        let deadline_ms = deadline.as_millis().to_string();
        report(&self.run(&[
            "--deadline-ms",
            &deadline_ms,
            "--resume-state",
            checkpoint.to_str().unwrap(),
        ]))
    }

    fn calls(&self) -> String {
        fs::read_to_string(&self.calls).unwrap_or_default()
    }

    fn scratch_path(&self, name: &str) -> PathBuf {
        let path = self.scratch.join(name);
        fs::write(&path, b"fixture").unwrap();
        path
    }

    fn mark_old(path: &Path) {
        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1);
        fs::File::open(path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(old))
            .unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove owned preview fixture");
    }
}

fn report(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("preview emits JSON")
}

#[test]
fn preview_reads_history_and_only_current_remove_verdicts_are_eligible() {
    let fixture = Fixture::new();
    let removable = fixture.scratch_path("removable-cache");
    let protected = fixture.scratch_path("protected-output");
    let absent = fixture.scratch.join("gone-cache");
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":removable},
        {"row_type":"cleanup_event", "canonical_path":protected},
        {"row_type":"cleanup_root", "canonical_path":removable},
        {"row_type":"cleanup_event", "canonical_path":absent}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&[]));
    assert_eq!(
        result["scratch_root"],
        fixture.scratch.to_string_lossy().as_ref()
    );
    assert_eq!(result["min_hours"], 48);
    let candidates = result["candidates"].as_array().unwrap();
    assert_eq!(
        candidates.len(),
        3,
        "duplicate historical paths are collapsed"
    );
    let accepted = candidates
        .iter()
        .find(|candidate| candidate["path"] == removable.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(accepted["verdict"], "remove");
    assert_eq!(accepted["eligible"], true);
    let kept = candidates
        .iter()
        .find(|candidate| candidate["path"] == protected.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(kept["verdict"], "kept:recent-activity");
    assert_eq!(kept["eligible"], false);
    let missing = candidates
        .iter()
        .find(|candidate| candidate["path"] == absent.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(missing["verdict"], "missing");
    assert_eq!(missing["eligible"], false);
    assert!(fixture.calls().contains("AGE=unset\tquarantine\tverdict"));
    assert!(!fixture.calls().contains("\tcleanup\t"));
}

#[test]
fn explicit_six_hour_preview_passes_scoped_age_to_each_verdict() {
    let fixture = Fixture::new();
    let candidate = fixture.scratch_path("removable-old-cache");
    Fixture::mark_old(&candidate);
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":candidate}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    assert_eq!(result["min_hours"], 6);
    assert_eq!(result["candidates"][0]["eligible"], true);
    assert!(fixture.calls().contains("AGE=360\tquarantine\tverdict"));
}

#[test]
fn outside_and_symlink_paths_are_never_sent_to_the_verdict_checker() {
    let fixture = Fixture::new();
    let outside = fixture.root.join("outside");
    fs::write(&outside, b"outside fixture").unwrap();
    let target = fixture.scratch_path("target");
    let link = fixture.scratch.join("linked-cache");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":outside},
        {"row_type":"cleanup_event", "canonical_path":link}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&[]));
    {
        let path = &link;
        let candidate = result["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["path"] == path.to_string_lossy().as_ref())
            .unwrap();
        assert_eq!(candidate["eligible"], false);
    }
    assert!(!result["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["path"] == outside.to_string_lossy().as_ref()));
    assert!(!fixture.calls().contains(outside.to_str().unwrap()));
    assert!(!fixture.calls().contains(link.to_str().unwrap()));
}

#[test]
fn malformed_history_and_unavailable_scratch_fail_closed() {
    let fixture = Fixture::new();
    fixture.install_diskm();
    fs::write(
        fixture.state.join("reclaim/directory-ledger.json"),
        b"{malformed",
    )
    .unwrap();
    let malformed = fixture.run(&[]);
    assert!(!malformed.status.success());
    assert!(malformed.stdout.is_empty());

    fixture.write_ledger(json!([]));
    let diskm = fixture.bin.join("disk-magician");
    fs::write(
        &diskm,
        "#!/bin/sh\nif [ \"$1\" = volume ]; then exit 75; fi\nexit 64\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&diskm).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(diskm, permissions).unwrap();
    let unavailable = fixture.run(&[]);
    assert!(!unavailable.status.success());
    assert!(unavailable.stdout.is_empty());
}

#[test]
fn candidate_limit_is_enforced_and_invalid_age_is_rejected() {
    let fixture = Fixture::new();
    let first = fixture.scratch_path("removable-first");
    let second = fixture.scratch_path("removable-second");
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":first},
        {"row_type":"cleanup_event", "canonical_path":second}
    ]));
    fixture.install_diskm();

    let bounded = report(&fixture.run(&["--max-candidates", "1"]));
    assert_eq!(bounded["candidates"].as_array().unwrap().len(), 1);
    assert_eq!(bounded["complete"], false);

    let invalid = fixture.run(&["--min-hours", "5"]);
    assert_eq!(invalid.status.code(), Some(2));
    assert!(invalid.stdout.is_empty());
}

#[test]
fn missing_historical_paths_do_not_consume_the_verdict_budget() {
    let fixture = Fixture::new();
    let missing = fixture.scratch.join("already-deleted");
    let extant = fixture.scratch_path("eligible");
    let unrecorded = fixture.scratch_path("unrecorded-old.cache");
    Fixture::mark_old(&unrecorded);
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":missing},
        {"row_type":"cleanup_event", "canonical_path":extant}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--max-candidates", "1"]));
    assert_eq!(result["missing_paths"], 1);
    assert_eq!(result["candidates"][0]["path"], extant.to_str().unwrap());
    assert_eq!(result["candidates"].as_array().unwrap().len(), 1);
    assert_eq!(result["complete"], false);
    assert_eq!(result["discovery"]["files_measured"], 0);
    assert_eq!(result["discovery"]["gaps"][0]["kind"], "not_scanned");
}

#[test]
fn six_hour_preview_leaves_nested_repositories_to_the_worktree_route() {
    let fixture = Fixture::new();
    let container = fixture.scratch.join("old-container");
    let repository = container.join("checkout");
    fs::create_dir_all(&repository).unwrap();
    let git_marker = repository.join(".git");
    fs::write(&git_marker, "gitdir: /unavailable/admin").unwrap();
    Fixture::mark_old(&git_marker);
    Fixture::mark_old(&repository);
    Fixture::mark_old(&container);
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":container}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    assert_eq!(
        result["candidates"][0]["verdict"],
        "kept:repository-use-worktree-route"
    );
    assert_eq!(result["candidates"][0]["eligible"], false);
    assert!(!fixture.calls().contains("\tquarantine\tverdict"));
}

#[test]
fn six_hour_preview_discovers_old_scratch_artifacts_without_ledger_rows() {
    let fixture = Fixture::new();
    let old_file = fixture.scratch_path("removable-old-file.cache");
    Fixture::mark_old(&old_file);

    let old_directory = fixture.scratch.join("removable-old-directory");
    fs::create_dir(&old_directory).unwrap();
    let directory_payload = old_directory.join("payload.cache");
    fs::write(&directory_payload, b"old generated content").unwrap();
    Fixture::mark_old(&directory_payload);
    Fixture::mark_old(&old_directory);

    let mixed_directory = fixture.scratch.join("mixed-siblings");
    fs::create_dir(&mixed_directory).unwrap();
    let stale_sibling = mixed_directory.join("removable-stale-sibling.cache");
    fs::write(&stale_sibling, b"old generated content").unwrap();
    Fixture::mark_old(&stale_sibling);
    let recent_sibling = mixed_directory.join("recent-sibling.cache");
    fs::write(&recent_sibling, b"recent generated content").unwrap();

    fixture.write_ledger(json!([]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    assert_eq!(result["min_hours"], 6);
    assert_eq!(result["complete"], true);
    let candidates = result["candidates"].as_array().unwrap();
    for path in [&old_file, &old_directory, &stale_sibling] {
        let candidate = candidates
            .iter()
            .find(|entry| entry["path"] == path.to_string_lossy().as_ref())
            .unwrap_or_else(|| panic!("missing discovered candidate {}", path.display()));
        assert_eq!(candidate["eligible"], true, "{}", path.display());
        assert_eq!(candidate["verdict"], "remove", "{}", path.display());
    }
    assert!(!candidates
        .iter()
        .any(|entry| entry["path"] == recent_sibling.to_string_lossy().as_ref()));

    assert_eq!(result["discovery"]["complete"], true);
    assert_eq!(result["discovery"]["files_measured"], 4);
    let directory = candidates
        .iter()
        .find(|entry| entry["path"] == old_directory.to_string_lossy().as_ref())
        .unwrap();
    assert!(directory["allocated_bytes"].as_u64().is_some());
    assert!(result["discovery"]["allocated_bytes_semantics"]
        .as_str()
        .unwrap()
        .contains("sum allocations per pathname"));
    assert!(!fixture.calls().contains(recent_sibling.to_str().unwrap()));
}

#[test]
fn six_hour_discovery_never_marks_symlinks_or_nested_git_content_eligible() {
    let fixture = Fixture::new();
    let symlink_target = fixture.scratch_path("removable-symlink-target.cache");
    Fixture::mark_old(&symlink_target);
    let symlink = fixture.scratch.join("removable-old-symlink.cache");
    std::os::unix::fs::symlink(&symlink_target, &symlink).unwrap();

    let repository = fixture.scratch.join("removable-old-repository");
    fs::create_dir_all(&repository).unwrap();
    fs::write(repository.join(".git"), "gitdir: /unavailable/admin").unwrap();
    let tracked_looking_content = repository.join("removable-inside-repository.cache");
    fs::write(&tracked_looking_content, b"repository content").unwrap();
    Fixture::mark_old(&tracked_looking_content);
    Fixture::mark_old(&repository);

    fixture.write_ledger(json!([]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    let candidates = result["candidates"].as_array().unwrap();
    assert!(!candidates
        .iter()
        .any(|entry| entry["path"] == symlink.to_string_lossy().as_ref()));
    assert!(!candidates.iter().any(|entry| {
        entry["path"] == tracked_looking_content.to_string_lossy().as_ref()
            && entry["eligible"] == true
    }));
    assert!(!candidates.iter().any(|entry| {
        entry["path"] == repository.to_string_lossy().as_ref() && entry["eligible"] == true
    }));
    assert!(!fixture.calls().contains(symlink.to_str().unwrap()));
    assert!(!fixture.calls().contains(repository.to_str().unwrap()));
    assert!(!fixture
        .calls()
        .contains(tracked_looking_content.to_str().unwrap()));
}

#[test]
fn preview_verifies_allocated_space_before_sparse_apparent_size() {
    let fixture = Fixture::new();
    let sparse = fixture.scratch.join("removable-sparse.cache");
    let sparse_file = fs::File::create(&sparse).unwrap();
    sparse_file.set_len(32 * 1024 * 1024).unwrap();
    Fixture::mark_old(&sparse);

    let allocated = fixture.scratch.join("removable-allocated.cache");
    let mut allocated_file = fs::File::create(&allocated).unwrap();
    allocated_file.write_all(&vec![b'x'; 256 * 1024]).unwrap();
    Fixture::mark_old(&allocated);
    let tie_b = fixture.scratch_path("removable-tie-b.cache");
    let tie_a = fixture.scratch_path("removable-tie-a.cache");
    fs::write(&tie_a, b"").unwrap();
    fs::write(&tie_b, b"").unwrap();
    Fixture::mark_old(&tie_a);
    Fixture::mark_old(&tie_b);
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6", "--max-candidates", "1"]));
    let candidates = result["candidates"].as_array().unwrap();
    let first = &candidates[0];
    let sparse_candidate = candidates
        .iter()
        .find(|candidate| candidate["path"] == sparse.to_string_lossy().as_ref())
        .unwrap();
    let allocated_candidate = candidates
        .iter()
        .find(|candidate| candidate["path"] == allocated.to_string_lossy().as_ref())
        .unwrap();

    assert_eq!(first["path"], allocated.to_string_lossy().as_ref());
    assert_eq!(first["verdict"], "remove");
    assert_eq!(candidates[1]["verdict"], "deferred:verification-limit");
    assert!(
        allocated_candidate["apparent_bytes"].as_u64().unwrap()
            < sparse_candidate["apparent_bytes"].as_u64().unwrap()
    );
    assert!(
        allocated_candidate["allocated_bytes"].as_u64().unwrap()
            > sparse_candidate["allocated_bytes"].as_u64().unwrap()
    );
    assert!(sparse_candidate["apparent_bytes"].as_u64().unwrap() > 0);
    assert!(
        sparse_candidate["allocated_bytes"].as_u64().unwrap()
            < sparse_candidate["apparent_bytes"].as_u64().unwrap()
    );
}

#[test]
fn six_hour_scratch_preview_accepts_an_explicit_scan_deadline() {
    let fixture = Fixture::new();
    let candidate = fixture.scratch_path("removable-old-cache");
    Fixture::mark_old(&candidate);
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6", "--deadline-ms", "1000"]));

    assert_eq!(result["min_hours"], 6);
    assert_eq!(result["complete"], true);
}

#[test]
fn incomplete_scan_reports_and_checks_only_the_measured_frontier() {
    let fixture = Fixture::new();
    let eligible = fixture.scratch_path("removable-old-cache");
    let held = fixture.scratch_path("held-unknown-cache");
    Fixture::mark_old(&eligible);
    Fixture::mark_old(&held);
    let frontier = fixture.scratch.join("unvisited-directory");
    fs::create_dir(&frontier).unwrap();
    for index in 0..50_000 {
        fs::write(frontier.join(format!("filler-{index}")), b"x").unwrap();
    }
    fixture.install_diskm();

    let checkpoint = fixture.root.join("scratch-resume.json");
    let result = fixture.report_with_checkpoint(Duration::from_millis(20), &checkpoint);
    assert_eq!(result["min_hours"], 48);
    let candidates = result["candidates"].as_array().unwrap();

    assert_eq!(result["complete"], false);
    assert_eq!(result["discovery"]["complete"], false);
    assert!(checkpoint.is_file());
    let saved: Value = serde_json::from_slice(&fs::read(&checkpoint).unwrap()).unwrap();
    assert_eq!(saved["complete"], false);
    assert!(saved["unfinished_scan_paths"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| {
            row["path"] == frontier.to_string_lossy().as_ref()
                || row["path"] == fixture.scratch.to_string_lossy().as_ref()
        }));
    let eligible_row = candidates
        .iter()
        .find(|row| row["path"] == eligible.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(eligible_row["verdict"], "remove");
    assert_eq!(eligible_row["eligible"], true);
    let held_row = candidates
        .iter()
        .find(|row| row["path"] == held.to_string_lossy().as_ref())
        .unwrap();
    assert_eq!(held_row["verdict"], "kept:owner-unknown");
    assert_eq!(held_row["eligible"], false);
    assert!(!fixture.calls().contains(frontier.to_str().unwrap()));

    let resumed = fixture.report_with_checkpoint(Duration::from_secs(10), &checkpoint);
    assert_eq!(resumed["complete"], true);
    assert_eq!(
        resumed["resumable"]["unfinished_scan_paths"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    let resumed_candidates = resumed["candidates"].as_array().unwrap();
    assert_eq!(
        resumed_candidates
            .iter()
            .filter(|row| row["path"] == eligible.to_string_lossy().as_ref())
            .count(),
        1
    );
    assert_eq!(
        resumed_candidates
            .iter()
            .filter(|row| row["path"] == held.to_string_lossy().as_ref())
            .count(),
        1
    );
}

#[test]
fn completed_checkpoint_reports_prior_remove_as_historical_after_replacement() {
    let fixture = Fixture::new();
    let path = fixture.scratch_path("removable-prior.cache");
    Fixture::mark_old(&path);
    fixture.install_diskm();
    let checkpoint = fixture.root.join("completed-checkpoint.json");

    let first = fixture.report_with_checkpoint(Duration::from_secs(2), &checkpoint);
    assert_eq!(first["complete"], true);
    assert_eq!(first["candidates"][0]["eligible"], true);
    fs::write(&path, b"replacement content").unwrap();
    let resumed = fixture.report_with_checkpoint(Duration::from_secs(2), &checkpoint);
    assert_eq!(
        resumed["candidates"][0]["path"],
        path.to_string_lossy().as_ref()
    );
    assert_eq!(resumed["candidates"][0]["verdict"], "historical:remove");
    assert_eq!(resumed["candidates"][0]["eligible"], false);
}

#[test]
fn whole_scratch_discovery_outlives_an_explicit_verdict_limit() {
    let fixture = Fixture::new();
    let first = fixture.scratch_path("removable-a.cache");
    let second = fixture.scratch_path("removable-b.cache");
    Fixture::mark_old(&first);
    Fixture::mark_old(&second);
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6", "--max-candidates", "1"]));
    assert_eq!(result["discovery"]["complete"], true);
    assert_eq!(result["discovery"]["files_measured"], 2);
    assert_eq!(result["complete"], false);
    let candidates = result["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 2);
    assert_eq!(candidates[0]["verdict"], "remove");
    assert_eq!(candidates[1]["verdict"], "deferred:verification-limit");
    assert!(!fixture.calls().contains(second.to_str().unwrap()));
}

#[test]
fn whole_scratch_preview_preserves_bare_repository_packs() {
    let fixture = Fixture::new();
    let repository = fixture.scratch.join("generated-mirror");
    assert!(Command::new("git")
        .args(["init", "--bare", "--quiet"])
        .arg(&repository)
        .status()
        .unwrap()
        .success());
    let pack = repository.join("objects/pack/removable-cache.pack");
    fs::write(&pack, b"fixture pack payload").unwrap();
    Fixture::mark_old(&pack);
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    let candidates = result["candidates"].as_array().unwrap();
    assert!(!candidates.iter().any(|entry| {
        let path = Path::new(entry["path"].as_str().unwrap());
        path.starts_with(&repository) && entry["eligible"] == true
    }));
    assert!(!fixture.calls().contains(repository.to_str().unwrap()));
}

#[test]
fn six_hour_preview_preserves_checker_vetoes_and_evidence_scope() {
    let fixture = Fixture::new();
    let held = [
        ("held-live.cache", "kept:live-owner"),
        ("held-open.cache", "kept:open-file"),
        ("held-unknown.cache", "kept:owner-unknown"),
    ];
    for (name, _) in held {
        Fixture::mark_old(&fixture.scratch_path(name));
    }
    let container = fixture.scratch.join("removable-containing-evidence");
    let evidence = container.join("evidence");
    fs::create_dir_all(&evidence).unwrap();
    let capture = evidence.join("removable-capture.avi");
    fs::write(&capture, b"fixture capture").unwrap();
    for path in [&container, &evidence, &capture] {
        Fixture::mark_old(path);
    }
    fixture.install_diskm();

    let result = report(&fixture.run(&["--min-hours", "6"]));
    let candidates = result["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), held.len());
    for (name, reason) in held {
        let path = fixture.scratch.join(name);
        assert!(candidates.iter().any(|row| {
            row["path"] == path.to_str().unwrap()
                && row["verdict"] == reason
                && row["eligible"] == false
        }));
    }
    assert!(!fixture.calls().contains(container.to_str().unwrap()));
}

#[test]
fn explicit_recheck_revalidates_only_selected_checkpoint_files() {
    let fixture = Fixture::new();
    let unchanged = fixture.scratch_path("removable-unchanged.cache");
    let changed = fixture.scratch_path("removable-replaced.cache");
    Fixture::mark_old(&unchanged);
    Fixture::mark_old(&changed);
    fixture.install_diskm();
    let checkpoint = fixture.root.join("exact-recheck.json");
    let initial = fixture.report_with_checkpoint(Duration::from_secs(2), &checkpoint);
    assert_eq!(initial["complete"], true);
    let original = fs::read(&checkpoint).unwrap();

    fs::write(&changed, b"new content").unwrap();
    let unrecorded = fixture.scratch_path("removable-unrecorded.cache");
    Fixture::mark_old(&unrecorded);
    let checkpoint_str = checkpoint.to_str().unwrap();
    let unchanged_str = unchanged.to_str().unwrap();
    let changed_str = changed.to_str().unwrap();
    let before = fixture
        .calls()
        .lines()
        .filter(|line| line.contains("quarantine"))
        .count();

    let fresh = report(&fixture.run(&[
        "--resume-state",
        checkpoint_str,
        "--recheck",
        unchanged_str,
        "--recheck",
        changed_str,
    ]));
    assert!(fresh["before_epoch_seconds"].as_i64().is_some());
    assert_eq!(fresh["candidates"].as_array().unwrap().len(), 2);
    assert_eq!(fresh["candidates"][0]["eligible"], true);
    assert!(fresh["candidates"][0]["allocated_bytes"].as_u64().is_some());
    assert_eq!(
        fresh["candidates"][1]["verdict"],
        "kept:outside-date-window"
    );
    assert_eq!(fresh["candidates"][1]["eligible"], false);

    let invalid = fixture.run(&[
        "--resume-state",
        checkpoint_str,
        "--recheck",
        unchanged_str,
        "--recheck",
        unrecorded.to_str().unwrap(),
    ]);
    assert!(!invalid.status.success());
    assert!(invalid.stdout.is_empty());
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("path is absent from the checkpoint"));

    let over_budget = fixture.run(&[
        "--resume-state",
        checkpoint_str,
        "--max-candidates",
        "1",
        "--recheck",
        unchanged_str,
        "--recheck",
        changed_str,
    ]);
    assert!(!over_budget.status.success());
    assert!(String::from_utf8_lossy(&over_budget.stderr).contains("exceed --max-candidates"));
    let after = fixture
        .calls()
        .lines()
        .filter(|line| line.contains("quarantine"))
        .count();
    assert_eq!(after, before + 1);
    assert_eq!(fs::read(&checkpoint).unwrap(), original);
}

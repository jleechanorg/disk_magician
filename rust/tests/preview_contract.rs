use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

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
        let executable = self.bin.join("diskm");
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
        Command::new(env!("CARGO_BIN_EXE_diskm-rust"))
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

    fn calls(&self) -> String {
        fs::read_to_string(&self.calls).unwrap_or_default()
    }

    fn scratch_path(&self, name: &str) -> PathBuf {
        let path = self.scratch.join(name);
        fs::write(&path, b"fixture").unwrap();
        path
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
    let diskm = fixture.bin.join("diskm");
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
    fixture.write_ledger(json!([
        {"row_type":"cleanup_event", "canonical_path":missing},
        {"row_type":"cleanup_event", "canonical_path":extant}
    ]));
    fixture.install_diskm();

    let result = report(&fixture.run(&["--max-candidates", "1"]));
    assert_eq!(result["missing_paths"], 1);
    assert_eq!(result["candidates"][0]["path"], extant.to_str().unwrap());
    assert_eq!(result["complete"], true);
}

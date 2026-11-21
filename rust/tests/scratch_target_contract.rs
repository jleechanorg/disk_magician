use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);
const GIB: u64 = 1024 * 1024 * 1024;

struct Fixture {
    root: PathBuf,
    scratch: PathBuf,
    bin: PathBuf,
    manifest: PathBuf,
    resume: PathBuf,
    status_index: PathBuf,
    applies: PathBuf,
    entries: Vec<String>,
    digest: String,
}

impl Fixture {
    fn new(count: usize) -> Self {
        let root = std::env::temp_dir().join(format!(
            "diskm-target-contract-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).expect("create isolated target fixture");
        let scratch = root.join("scratch");
        let bin = root.join("bin");
        fs::create_dir(&scratch).unwrap();
        fs::create_dir(&bin).unwrap();
        let manifest = root.join("manifest.json");
        let resume = root.join("resume.json");
        let status_index = root.join("status-index");
        let applies = root.join("applies.log");
        let mut entries = Vec::new();
        let mut rows = Vec::new();
        for index in 0..count {
            let relative = format!("old-file-{index}.cache");
            let file = scratch.join(&relative);
            fs::write(&file, format!("fixture-{index}")).unwrap();
            let metadata = file.metadata().unwrap();
            rows.push(json!({
                "path": relative,
                "kind": "regular_file",
                "dev": metadata.dev(),
                "ino": metadata.ino(),
                "size": metadata.len(),
                "mtime_ns": metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec(),
                "ctime_ns": metadata.ctime() * 1_000_000_000 + metadata.ctime_nsec()
            }));
            entries.push(relative);
        }
        let root_metadata = scratch.metadata().unwrap();
        let manifest_value = json!({
            "version": 1,
            "root": {"path": scratch, "dev": root_metadata.dev(), "ino": root_metadata.ino()},
            "before_epoch_seconds": 1,
            "entries": rows
        });
        fs::write(&manifest, serde_json::to_vec(&manifest_value).unwrap()).unwrap();
        let digest = Command::new("python3")
            .args([
                "-c",
                "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())",
            ])
            .arg(&manifest)
            .output()
            .expect("hash fixture manifest");
        let digest = String::from_utf8(digest.stdout).unwrap().trim().to_owned();
        let blocked_python = bin.join("python3");
        fs::write(&blocked_python, "#!/bin/sh\nexit 91\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&blocked_python, fs::Permissions::from_mode(0o755)).unwrap();

        let script = bin.join("disk-magician");
        fs::write(
            &script,
            r##"#!/bin/bash
set -eu
if [[ "$1" == volume && "$2" == path && "$3" == scratch ]]; then
  printf '%s\n' "$FAKE_SCRATCH_ROOT"
elif [[ "$1" == volume && "$2" == verify-mount ]]; then
  [[ "$3" == "$FAKE_SCRATCH_ROOT" ]]
elif [[ "$1" == volume && "$2" == status ]]; then
  [[ "${FAKE_STATUS_FAIL:-0}" == 0 ]] || exit 75
  index=0
  [[ ! -f "$STATUS_INDEX" ]] || index="$(cat "$STATUS_INDEX")"
  index=$((index+1))
  printf '%s\n' "$index" > "$STATUS_INDEX"
  IFS=, read -r -a usages <<< "$FAKE_USED_SEQUENCE"
  IFS=, read -r -a ids <<< "$FAKE_ID_SEQUENCE"
  slot=$((index-1))
  ((slot < ${#usages[@]})) || slot=$((${#usages[@]}-1))
  ((slot < ${#ids[@]})) || slot=$((${#ids[@]}-1))
  printf '{"volumes":[{"class":"scratch","path":"%s","status":"active","filesystem_id":"%s","allocated_bytes":%s,"quota_bytes":214748364800,"available":false}]}\n' "$FAKE_SCRATCH_ROOT" "${ids[$slot]}" "${usages[$slot]}"
elif [[ "$1" == quarantine && "$2" == scratch-apply ]]; then
  shift 2
  manifest=""; digest=""; selected=""
  while (($#)); do
    case "$1" in
      --manifest) manifest="$2"; shift 2 ;;
      --manifest-sha256) digest="$2"; shift 2 ;;
      --path) selected="$2"; shift 2 ;;
      *) exit 64 ;;
    esac
  done
  printf '%s\n' "$selected" >> "$APPLIES"
  printf '{"results":[{"path":"%s","result":"%s"}]}\n' "$selected" "${FAKE_APPLY_RESULT:-removed:fixture}"
else
  exit 64
fi
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(script, permissions).unwrap();
        Self {
            root,
            scratch,
            bin,
            manifest,
            resume,
            status_index,
            applies,
            entries,
            digest,
        }
    }

    fn run(&self, used: &[u64], ids: &[&str], extra: &[&str]) -> Output {
        self.run_env(used, ids, extra, "removed:fixture", false)
    }

    fn run_result(&self, used: &[u64], ids: &[&str], extra: &[&str], result: &str) -> Output {
        self.run_env(used, ids, extra, result, false)
    }

    fn run_env(
        &self,
        used: &[u64],
        ids: &[&str],
        extra: &[&str],
        result: &str,
        status_failure: bool,
    ) -> Output {
        let _ = fs::remove_file(&self.status_index);
        let sequence = used
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let id_sequence = ids.join(",");
        let mut search_path = vec![self.bin.clone()];
        search_path.extend(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ));
        let search_path = std::env::join_paths(search_path).unwrap();
        Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args([
                "scratch-target-apply",
                "--manifest",
                self.manifest.to_str().unwrap(),
                "--manifest-sha256",
                &self.digest,
                "--resume-state",
                self.resume.to_str().unwrap(),
                "--target-used-bytes",
                &(100 * GIB).to_string(),
            ])
            .args(extra)
            .env("PATH", search_path)
            .env("HOME", &self.root)
            .env("FAKE_SCRATCH_ROOT", &self.scratch)
            .env("STATUS_INDEX", &self.status_index)
            .env("APPLIES", &self.applies)
            .env("FAKE_USED_SEQUENCE", sequence)
            .env("FAKE_ID_SEQUENCE", id_sequence)
            .env("FAKE_APPLY_RESULT", result)
            .env("FAKE_STATUS_FAIL", if status_failure { "1" } else { "0" })
            .output()
            .expect("target apply executable starts")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove only this test-owned fixture");
    }
}

fn report(output: &Output) -> Value {
    assert!(
        output.status.success() || output.status.code() == Some(75),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("target apply emits JSON")
}

#[test]
fn stops_at_target_and_checkpoints_the_exact_remaining_selection() {
    let fixture = Fixture::new(2);
    let output = fixture.run(&[101 * GIB, 100 * GIB], &["volume-a"; 2], &["--all"]);
    let result = report(&output);
    assert_eq!(result["status"], "target_reached");
    assert_eq!(result["target_reached"], true);
    assert_eq!(result["receipts"].as_array().unwrap().len(), 1);
    assert_eq!(result["receipts"][0]["path"], fixture.entries[0]);
    assert_eq!(result["pending_paths"], json!([fixture.entries[1]]));
    assert_eq!(
        fs::read_to_string(&fixture.applies).unwrap(),
        format!("{}\n", fixture.entries[0])
    );
    let persisted: Value = serde_json::from_slice(&fs::read(&fixture.resume).unwrap()).unwrap();
    assert_eq!(persisted["pending_paths"], json!([fixture.entries[1]]));
}

#[test]
fn resume_keeps_the_digest_bound_selection_and_reaches_target_on_next_batch() {
    let fixture = Fixture::new(2);
    let first = fixture.run(&[101 * GIB, 100 * GIB], &["volume-a"; 2], &["--all"]);
    assert_eq!(report(&first)["pending_paths"], json!([fixture.entries[1]]));
    let second = fixture.run(&[101 * GIB, 100 * GIB], &["volume-a"; 2], &[]);
    let result = report(&second);
    assert_eq!(result["target_reached"], true);
    assert!(result["pending_paths"].as_array().unwrap().is_empty());
    assert_eq!(result["receipts"].as_array().unwrap().len(), 2);
}

#[test]
fn volume_identity_change_stops_before_the_next_manifest_entry() {
    let fixture = Fixture::new(2);
    let output = fixture.run(
        &[101 * GIB, 101 * GIB],
        &["volume-a", "volume-b"],
        &["--all"],
    );
    let result = report(&output);
    assert!(result["status"].as_str().unwrap().starts_with("deferred:"));
    assert_eq!(result["pending_paths"], json!([fixture.entries[1]]));
    assert_eq!(
        fs::read_to_string(&fixture.applies).unwrap(),
        format!("{}\n", fixture.entries[0])
    );
}

#[test]
fn partial_quarantine_requires_recovery_and_keeps_the_in_flight_path() {
    let fixture = Fixture::new(2);
    let output = fixture.run_result(
        &[101 * GIB],
        &["volume-a"],
        &["--all"],
        "kept:quarantine_partial_kept:deadbeefdeadbeef",
    );
    let result = report(&output);
    assert!(result["status"]
        .as_str()
        .unwrap()
        .starts_with("recovery_required:"));
    assert_eq!(
        result["pending_paths"],
        json!([fixture.entries[0], fixture.entries[1]])
    );
    let apply_calls = fs::read_to_string(&fixture.applies).unwrap();
    assert_eq!(apply_calls, format!("{}\n", fixture.entries[0]));

    let resumed = fixture.run(&[101 * GIB], &["volume-a"], &[]);
    assert!(report(&resumed)["status"]
        .as_str()
        .unwrap()
        .starts_with("recovery_required:"));
    assert_eq!(fs::read_to_string(&fixture.applies).unwrap(), apply_calls);
}

#[test]
fn unavailable_first_volume_read_persists_the_exact_queue_for_resume() {
    let fixture = Fixture::new(2);
    let blocked = fixture.run_env(&[], &[], &["--all"], "removed:fixture", true);
    let blocked = report(&blocked);
    assert!(blocked["status"].as_str().unwrap().starts_with("deferred:"));
    assert_eq!(blocked["pending_paths"], json!(fixture.entries));
    let saved: Value = serde_json::from_slice(&fs::read(&fixture.resume).unwrap()).unwrap();
    assert_eq!(saved["filesystem_id"], "");

    let resumed = fixture.run(&[101 * GIB, 100 * GIB], &["volume-a"; 2], &[]);
    let resumed = report(&resumed);
    assert_eq!(resumed["target_reached"], true);
    assert_eq!(resumed["pending_paths"], json!([fixture.entries[1]]));
}

#[test]
fn existing_scratch_cleanup_lock_defers_without_touching_the_queue() {
    let fixture = Fixture::new(2);
    let lock_dir = fixture.root.join(".disk_magician_locks");
    fs::create_dir(&lock_dir).unwrap();
    fs::set_permissions(&lock_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let lock_path = lock_dir.join("scratch_cleanup.lock");
    let ready = fixture.root.join("lock-ready");
    let mut holder = Command::new("python3")
        .args([
            "-c",
            "import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2], 'w').close(); time.sleep(20)",
        ])
        .arg(&lock_path)
        .arg(&ready)
        .env("HOME", &fixture.root)
        .spawn()
        .expect("start isolated lock holder");
    let wait_until = std::time::Instant::now() + std::time::Duration::from_secs(3);
    while !ready.exists() && std::time::Instant::now() < wait_until {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(ready.exists(), "lock holder acquired the fixture lock");

    let output = fixture.run(&[101 * GIB], &["volume-a"], &["--all"]);
    let result = report(&output);
    assert_eq!(result["status"], "deferred:scratch-cleanup-in-progress");
    assert_eq!(result["pending_paths"], json!(fixture.entries));
    assert!(!fixture.applies.exists());

    holder.kill().unwrap();
    holder.wait().unwrap();
}

#[test]
fn interrupted_in_flight_quarantine_requires_exact_recovery_without_global_reconcile() {
    let fixture = Fixture::new(2);
    let first = fixture.run(&[101 * GIB, 100 * GIB], &["volume-a"; 2], &["--all"]);
    assert_eq!(report(&first)["pending_paths"], json!([fixture.entries[1]]));
    let mut state: Value = serde_json::from_slice(&fs::read(&fixture.resume).unwrap()).unwrap();
    state["status"] = json!(format!("applying:{}", fixture.entries[1]));
    fs::write(&fixture.resume, serde_json::to_vec(&state).unwrap()).unwrap();
    let previous_apply_count = fs::read_to_string(&fixture.applies)
        .unwrap()
        .lines()
        .count();

    let resumed = fixture.run(&[101 * GIB], &["volume-a"], &[]);
    let result = report(&resumed);
    assert_eq!(
        result["status"],
        "recovery_required:check exact in-flight quarantine before resume"
    );
    assert_eq!(result["pending_paths"], json!([fixture.entries[1]]));
    assert_eq!(
        fs::read_to_string(&fixture.applies)
            .unwrap()
            .lines()
            .count(),
        previous_apply_count
    );
}

#[test]
fn unverified_or_oversized_manifest_never_reaches_the_volume_or_actuator() {
    let fixture = Fixture::new(1);
    fs::write(&fixture.manifest, b"changed manifest bytes").unwrap();
    let invalid = fixture.run(&[101 * GIB], &["fixture-volume"], &["--all"]);
    assert!(!invalid.status.success());
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("manifest digest mismatch"));
    assert!(!fixture.status_index.exists());
    assert!(!fixture.applies.exists());

    fs::OpenOptions::new()
        .write(true)
        .open(&fixture.manifest)
        .unwrap()
        .set_len(256 * 1024 * 1024 + 1)
        .unwrap();
    let large = fixture.run(&[101 * GIB], &["fixture-volume"], &["--all"]);
    assert!(!large.status.success());
    assert!(
        String::from_utf8_lossy(&large.stderr).contains("manifest exceeds the actuator size limit")
    );
    assert!(!fixture.status_index.exists());
    assert!(!fixture.applies.exists());
}

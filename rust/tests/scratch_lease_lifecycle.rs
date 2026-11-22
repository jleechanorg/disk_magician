use diskm_shadow::scratch_target::check_completed_build;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const DISKM: &str = env!("CARGO_BIN_EXE_diskm");

/// `check_completed_build` reads the process-wide state-dir variable.
static STATE_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// A private state directory plus every run this test allocated.
struct Fixture {
    state: PathBuf,
    runs: Vec<PathBuf>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for run in &self.runs {
            let _ = fs::remove_dir_all(run);
        }
        let _ = fs::remove_dir_all(&self.state);
    }
}

fn fixture(name: &str) -> Fixture {
    let state = std::env::temp_dir().join(format!("diskm-lease-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&state);
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    // A host with a registered Scratch volume keeps its registry in the state
    // directory; carry it over so lookups verify the same volume.
    let registry = PathBuf::from(std::env::var_os("HOME").unwrap())
        .join(".disk_magician_state/volumes/registry.json");
    if registry.is_file() {
        fs::create_dir_all(state.join("volumes")).unwrap();
        fs::copy(&registry, state.join("volumes/registry.json")).unwrap();
    }
    if cfg!(target_os = "linux") {
        fs::create_dir_all(state.join("repo/config")).unwrap();
        fs::write(state.join("repo/config/config.json"), "{}").unwrap();
    }
    Fixture {
        state,
        runs: Vec::new(),
    }
}

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Environment every diskm call in a fixture uses.
fn env(f: &Fixture) -> Vec<(&'static str, PathBuf)> {
    let mut vars = vec![("DISK_MAGICIAN_STATE_DIR", f.state.clone())];
    if cfg!(target_os = "linux") {
        vars.push(("DISK_MAGICIAN_STATE_REPO", f.state.join("repo")));
    }
    vars
}

fn diskm(f: &Fixture, args: &[&str]) -> Output {
    Command::new(DISKM)
        .args(args)
        .envs(env(f))
        .output()
        .unwrap()
}

/// Runs `check_completed_build` with this fixture's process-wide environment.
fn in_fixture_env<T>(f: &Fixture, action: impl FnOnce() -> T) -> T {
    let _guard = STATE_ENV
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    for (name, value) in env(f) {
        std::env::set_var(name, value);
    }
    action()
}

/// Allocates through a short-lived `sh`, as `$(diskm scratch-new ...)` does,
/// so the recorded owner exits as soon as allocation returns.
fn allocate(f: &mut Fixture, kind: &str, extra: &[&str]) -> PathBuf {
    let output = Command::new("sh")
        .arg("-c")
        .arg(r#"exec_out=$("$0" scratch-new "$@") || exit $?; printf '%s' "$exec_out""#)
        .arg(DISKM)
        .arg(repo())
        .arg("lease-lifecycle")
        .arg("--kind")
        .arg(kind)
        .args(extra)
        .envs(env(&*f))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "scratch-new failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let run = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
    f.runs.push(run.clone());
    run
}

fn lease(f: &Fixture, run: &Path) -> serde_json::Value {
    let output = diskm(f, &["scratch-lease", run.to_str().unwrap()]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn verdict(f: &Fixture, run: &Path) -> Result<(), &'static str> {
    let root = PathBuf::from(lease(f, run)["lease"]["root"].as_str().unwrap());
    in_fixture_env(f, || check_completed_build(&root, run))
}

fn finish(f: &Fixture, run: &Path, outcome: &str) -> Output {
    diskm(f, &["scratch-finish", run.to_str().unwrap(), outcome])
}

#[test]
fn finish_from_a_different_process_of_the_same_user_succeeds() {
    let mut f = fixture("finish");
    let run = allocate(&mut f, "build", &[]);
    let output = finish(&f, &run, "completed");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let inspected = lease(&f, &run);
    assert_eq!(inspected["finish"]["outcome"], "completed");
    assert!(
        inspected["finish"]["finished_by"].is_object(),
        "{inspected}"
    );
    assert_eq!(verdict(&f, &run), Ok(()));
}

#[test]
fn finish_twice_with_different_outcomes_fails() {
    let mut f = fixture("refinish");
    let run = allocate(&mut f, "build", &[]);
    assert!(finish(&f, &run, "completed").status.success());
    assert!(finish(&f, &run, "completed").status.success());
    assert!(!finish(&f, &run, "abandoned").status.success());
}

#[test]
fn owner_pid_records_the_given_live_process() {
    let mut f = fixture("ownerpid");
    let pid = std::process::id().to_string();
    let run = allocate(&mut f, "build", &["--owner-pid", &pid]);
    assert_eq!(
        lease(&f, &run)["lease"]["owner"]["pid"].as_u64(),
        Some(u64::from(std::process::id()))
    );
}

#[test]
fn owner_pid_rejects_a_missing_process() {
    let f = fixture("ownerpid-missing");
    let output = diskm(
        &f,
        &[
            "scratch-new",
            repo().to_str().unwrap(),
            "lease-lifecycle",
            "--kind",
            "build",
            "--owner-pid",
            "2147483646",
        ],
    );
    assert!(!output.status.success());
}

#[test]
fn unfinished_build_with_exited_owner_qualifies() {
    let mut f = fixture("abandoned");
    let run = allocate(&mut f, "build", &[]);
    assert_eq!(lease(&f, &run)["owner_process_state"], "exited");
    assert_eq!(verdict(&f, &run), Ok(()));
}

#[test]
fn unfinished_build_with_live_owner_is_kept() {
    let mut f = fixture("live");
    let pid = std::process::id().to_string();
    let run = allocate(&mut f, "build", &["--owner-pid", &pid]);
    assert_eq!(verdict(&f, &run), Err("kept:producer-still-live"));
}

#[test]
fn abandoned_finish_qualifies() {
    let mut f = fixture("abandon-finish");
    let run = allocate(&mut f, "build", &[]);
    assert!(finish(&f, &run, "abandoned").status.success());
    assert_eq!(verdict(&f, &run), Ok(()));
}

#[test]
fn unfinished_evidence_run_is_kept() {
    let mut f = fixture("evidence");
    let run = allocate(&mut f, "evidence", &[]);
    assert_eq!(verdict(&f, &run), Err("kept:protected-bundle-kind"));
}

#[test]
fn completed_build_still_qualifies() {
    let mut f = fixture("completed");
    let run = allocate(&mut f, "build", &[]);
    assert!(finish(&f, &run, "completed").status.success());
    assert_eq!(verdict(&f, &run), Ok(()));
}

#[test]
fn unfinished_temp_file_is_kept() {
    let f = fixture("tempfile");
    let output = Command::new("sh")
        .arg("-c")
        .arg(r#"out=$("$0" scratch-temp-file "$@") || exit $?; printf '%s' "$out""#)
        .arg(DISKM)
        .arg(repo())
        .arg("lease-lifecycle")
        .envs(env(&f))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let file = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
    let root = PathBuf::from(lease(&f, &file)["lease"]["root"].as_str().unwrap());
    let verdict = in_fixture_env(&f, || check_completed_build(&root, &file));
    let _ = fs::remove_file(&file);
    assert_eq!(verdict, Err("kept:build-not-completed"));
}

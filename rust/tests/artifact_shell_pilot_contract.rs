use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct TestRoot(PathBuf);

impl TestRoot {
    fn new() -> Self {
        let base = std::env::var_os("DISKM_SCRATCH_TEST_DIR")
            .expect("set DISKM_SCRATCH_TEST_DIR to an existing isolated test directory");
        let path = PathBuf::from(base).join(format!("diskm-artifact-shell-{}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(fs::canonicalize(path).unwrap())
    }

    fn executable(&self, name: &str, text: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, text).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn preview(fixture: &TestRoot, native: Option<&Path>, simulate_failure: bool) -> Output {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/cleanup_scratch_top_level.sh");
    let mut command = Command::new("/bin/bash");
    command
        .arg(script)
        .args([
            "--dry-run",
            "--budget-pct",
            "35",
            "--budget-preserve-content-keeps",
        ])
        .env_clear()
        .env("HOME", fixture.0.join("home"))
        .env("TMPDIR", &fixture.0)
        .env(
            "PATH",
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
        )
        .env("DISK_MAGICIAN_DISKM_BIN", fixture.0.join("fixture-volume"))
        .env("DISK_MAGICIAN_STATE_DIR", fixture.0.join("state"))
        .env(
            "DISK_MAGICIAN_DELETION_LOG",
            fixture.0.join("deletions.log"),
        )
        .env("DISK_MAGICIAN_SCRATCH_DETAIL", "off")
        .env("FIXTURE_ROOT", fixture.0.join("scratch"))
        .env("CALL_LOG", fixture.0.join("native.log"))
        .env("NATIVE_BINARY", env!("CARGO_BIN_EXE_diskm"));
    if let Some(native) = native {
        command.env("DISK_MAGICIAN_RUST_ARTIFACT_BIN", native);
    }
    if simulate_failure {
        command.env("FAIL_VALIDATION", "1");
    }
    command.output().unwrap()
}

#[test]
fn registered_preview_uses_native_artifact_pilot_only_when_selected() {
    let root = TestRoot::new();
    let artifact = root.0.join("scratch/project/build");
    fs::create_dir_all(&artifact).unwrap();
    fs::write(artifact.join("fresh.txt"), "retained").unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(root.0.join("home"))
        .unwrap();
    fs::create_dir(root.0.join("state")).unwrap();
    root.executable(
        "fixture-volume",
        "#!/bin/sh\ncase \"$1:$2\" in\nvolume:path) printf '%s\\n' \"$FIXTURE_ROOT\" ;;\nvolume:verify-mount) [ \"$3\" = \"$FIXTURE_ROOT\" ] ;;\nvolume:status) printf '%s\\n' '{\"volumes\":[{\"class\":\"scratch\",\"allocated_bytes\":10000000,\"quota_bytes\":20000000}]}' ;;\n*) exit 2 ;;\nesac\n",
    );
    let native = root.executable(
        "fixture-native",
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$CALL_LOG\"\nif [ \"$1\" = scratch-artifact-validate ] && [ \"$FAIL_VALIDATION\" = 1 ]; then\n  printf '%s\\0' \"$FIXTURE_ROOT/project/build\"\n  printf '%s\\n' symlink-component >&2\n  exit 75\nfi\nexec \"$NATIVE_BINARY\" \"$@\"\n",
    );

    let legacy = preview(&root, None, false);
    assert!(!root.0.join("native.log").exists());
    let selected = preview(&root, Some(&native), false);
    assert_eq!(
        fs::read_to_string(root.0.join("native.log")).unwrap(),
        "scratch-artifact-discover\nscratch-artifact-validate\n",
        "{}",
        String::from_utf8_lossy(&selected.stderr)
    );
    assert_eq!(
        selected.status.code(),
        legacy.status.code(),
        "{}",
        String::from_utf8_lossy(&selected.stderr)
    );
    for output in [&legacy, &selected] {
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("lru: stop="), "{stdout}");
        assert!(stdout.contains("kept:recent-activity"), "{stdout}");
    }

    let fallback = root.executable(
        "fixture-legacy-fallback",
        r#"#!/bin/sh
if [ "$1" = scratch-artifact-discover ]; then
  printf '%s\n' legacy-required >> "$CALL_LOG"
  exit 76
fi
printf '%s\n' "$1" >> "$CALL_LOG"
exec "$NATIVE_BINARY" "$@"
"#,
    );
    let fallback = preview(&root, Some(&fallback), false);
    assert_eq!(fallback.status.code(), legacy.status.code());
    let fallback_stdout = String::from_utf8_lossy(&fallback.stdout);
    assert!(fallback_stdout.contains("lru: stop="), "{fallback_stdout}");
    assert!(
        fallback_stdout.contains("kept:recent-activity"),
        "{fallback_stdout}"
    );
    assert!(fs::read_to_string(root.0.join("native.log"))
        .unwrap()
        .ends_with("legacy-required\nscratch-artifact-validate\n"));

    let failed = preview(&root, Some(&native), true);
    let stdout = String::from_utf8_lossy(&failed.stdout);
    assert_eq!(failed.status.code(), Some(75), "{stdout}");
    assert!(
        stdout.contains("deferred:artifact-discovery-symlink-component"),
        "{stdout}"
    );
    assert!(!stdout.contains("would-remove:"), "{stdout}");
    assert_eq!(
        fs::read_to_string(artifact.join("fresh.txt")).unwrap(),
        "retained"
    );
    assert!(!root.0.join("deletions.log").exists());
}

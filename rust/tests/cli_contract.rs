use serde_json::Value;
use std::ffi::OsString;
use std::fs;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_LEGACY: AtomicU64 = AtomicU64::new(0);

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args(args)
        .env_remove("DISKM_LEGACY_COMPAT_CLI")
        .env_remove("DISKM_LEGACY_COMPAT_ACTIVE")
        .output()
        .expect("candidate executable starts")
}

fn run_os(args: &[OsString], envs: &[(&str, &std::ffi::OsStr)]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_diskm"));
    command.args(args);
    command
        .env_remove("DISKM_LEGACY_COMPAT_CLI")
        .env_remove("DISKM_LEGACY_COMPAT_ACTIVE");
    for (name, value) in envs {
        command.env(name, value);
    }
    command.output().expect("candidate executable starts")
}

struct LegacyFixture {
    root: PathBuf,
    scratch: PathBuf,
    backend: PathBuf,
    record: PathBuf,
}

impl LegacyFixture {
    fn new(source: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "diskm-legacy-compat-{}-{}",
            std::process::id(),
            NEXT_LEGACY.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let scratch = root.join("scratch");
        fs::create_dir(&scratch).unwrap();
        let backend = root.join("legacy-backend");
        let record = root.join("argv.bin");
        fs::write(&backend, source).unwrap();
        let mut permissions = fs::metadata(&backend).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&backend, permissions).unwrap();
        Self {
            root,
            scratch,
            backend,
            record,
        }
    }

    fn run(&self, args: &[OsString]) -> Output {
        run_os(
            args,
            &[
                ("DISKM_LEGACY_COMPAT_CLI", self.backend.as_os_str()),
                ("LEGACY_ARGV_RECORD", self.record.as_os_str()),
                ("FAKE_SCRATCH_ROOT", self.scratch.as_os_str()),
            ],
        )
    }

    fn captured_args(&self) -> Vec<Vec<u8>> {
        let bytes = fs::read(&self.record).unwrap();
        if bytes.is_empty() {
            return Vec::new();
        }
        bytes
            .split(|byte| *byte == 0)
            .map(|part| part.to_vec())
            .collect()
    }
}

impl Drop for LegacyFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove only this test-owned fixture");
    }
}

const CAPTURE_LEGACY_ARGS: &str = r##"#!/usr/bin/env python3
import os, sys
with open(os.environ["LEGACY_ARGV_RECORD"], "wb") as output:
    output.write(b"\0".join(os.fsencode(arg) for arg in sys.argv[1:]))
if sys.argv[1:] == ["volume", "path", "scratch"]:
    print(os.environ["FAKE_SCRATCH_ROOT"])
    sys.exit(0)
sys.exit(int(os.environ.get("LEGACY_EXIT_CODE", "0")))
"##;

#[test]
fn help_names_the_separate_read_only_executable() {
    let output = run(&["--help"]);
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.starts_with("diskm "));
    assert!(help.contains("status"));
    assert!(help.contains("scan"));
    assert!(help.contains("history"));
}

#[test]
fn status_produces_a_single_json_object() {
    let output = run(&["status", env!("CARGO_MANIFEST_DIR"), "--json"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(report.is_object());
}

#[test]
fn bounded_scan_reports_incomplete_before_exiting_temporary_failure() {
    let output = run(&["scan", env!("CARGO_MANIFEST_DIR"), "--max-entries", "1"]);
    assert_eq!(
        output.status.code(),
        Some(75),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["complete"], false);
}

#[test]
fn invalid_options_and_mutating_commands_fail_as_usage_errors() {
    for args in [
        &["scan", ".", "--max-entries", "0"][..],
        &["scan", ".", "--deadline-ms", "invalid"],
        &["status", ".", "--max-entries", "1"],
        &["history", "--days", "10", "--state-dir", "."],
        &["reclaim", ".", "--apply"],
    ] {
        let output = run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
    }
}

#[test]
fn preview_deadline_is_restricted_to_six_hour_scratch() {
    for args in [
        &[
            "preview",
            "--scope",
            "tmp",
            "--min-hours",
            "6",
            "--deadline-ms",
            "250",
        ][..],
        &[
            "preview",
            "--scope",
            "all",
            "--min-hours",
            "6",
            "--state-dir",
            ".",
            "--deadline-ms",
            "250",
        ],
        &[
            "preview",
            "--scope",
            "scratch",
            "--min-hours",
            "48",
            "--state-dir",
            ".",
            "--deadline-ms",
            "250",
        ],
        &[
            "preview",
            "--scope",
            "scratch",
            "--min-hours",
            "6",
            "--state-dir",
            ".",
            "--deadline-ms",
            "0",
        ],
    ] {
        let output = run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
    }
}

#[test]
fn scan_matches_legacy_apparent_bytes_on_the_same_fixture_tree() {
    let crate_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture_root = crate_root.join("tests");
    let fixture = fixture_root.to_str().unwrap();
    let legacy = Command::new("bash")
        .arg(crate_root.join("../scripts/measure_files.sh"))
        .arg(fixture)
        .env_remove("ACT_CURSOR")
        .env_remove("ACT_DEADLINE_AT")
        .output()
        .expect("legacy measurement starts");
    assert!(
        legacy.status.success(),
        "{}",
        String::from_utf8_lossy(&legacy.stderr)
    );
    let mut expected_bytes = 0;
    for line in String::from_utf8(legacy.stdout).unwrap().lines() {
        let fields: Vec<_> = line.splitn(5, '\t').collect();
        assert_eq!(fields.len(), 5, "{line}");
        assert!(matches!(fields[3], "A" | "F"), "{line}");
        expected_bytes += fields[0].parse::<u64>().unwrap();
    }
    assert!(expected_bytes > 0);

    let candidate = run(&["scan", fixture]);
    assert!(candidate.status.success());
    let report: Value = serde_json::from_slice(&candidate.stdout).unwrap();
    assert_eq!(report["complete"], true);
    assert_eq!(report["apparent_bytes"], expected_bytes);
}

#[test]
fn legacy_compat_exec_preserves_argument_bytes_and_exit_status() {
    let fixture = LegacyFixture::new(CAPTURE_LEGACY_ARGS);
    let args = vec![
        OsString::from("snapshot"),
        OsString::from("--scope"),
        OsString::from("path with spaces"),
        OsString::from_vec(vec![b'\xff', b'x']),
    ];
    let output = fixture.run(&args);
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(
        fixture.captured_args(),
        vec![
            b"snapshot".to_vec(),
            b"--scope".to_vec(),
            b"path with spaces".to_vec(),
            vec![b'\xff', b'x'],
        ]
    );

    let nonzero = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .arg("snapshot")
        .env("DISKM_LEGACY_COMPAT_CLI", &fixture.backend)
        .env("LEGACY_ARGV_RECORD", &fixture.record)
        .env("LEGACY_EXIT_CODE", "23")
        .output()
        .unwrap();
    assert_eq!(nonzero.status.code(), Some(23));
}

#[test]
fn compatibility_routes_legacy_ambiguous_forms_and_preserves_native_verbs() {
    let fixture = LegacyFixture::new(CAPTURE_LEGACY_ARGS);
    for args in [
        vec![OsString::from("status"), OsString::from("--json")],
        vec![
            OsString::from("history"),
            OsString::from("diff"),
            OsString::from("--days"),
            OsString::from("7"),
        ],
        vec![
            OsString::from("tmp-scratch-sweep"),
            OsString::from("--scratch-only"),
        ],
        vec![OsString::from("--legacy-option")],
        vec![OsString::from("--help")],
        Vec::new(),
    ] {
        let output = fixture.run(&args);
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            fixture.captured_args(),
            args.iter()
                .map(|arg| arg.as_encoded_bytes().to_vec())
                .collect::<Vec<_>>()
        );
    }

    let native = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args(["scan", ".", "--not-a-scan-option"])
        .env("DISKM_LEGACY_COMPAT_CLI", &fixture.backend)
        .env("LEGACY_ARGV_RECORD", &fixture.record)
        .output()
        .unwrap();
    assert_eq!(native.status.code(), Some(2));
    assert_eq!(fixture.captured_args(), Vec::<Vec<u8>>::new());
}

#[test]
fn native_manifest_subcommand_uses_the_same_selected_legacy_backend() {
    let fixture = LegacyFixture::new(CAPTURE_LEGACY_ARGS);
    let candidate = fixture.scratch.join("old-output.cache");
    std::fs::write(&candidate, b"test fixture").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "scratch-manifest",
            "--before-epoch",
            "4102444800",
            "--path",
            candidate.to_str().unwrap(),
        ])
        .env("DISKM_LEGACY_COMPAT_CLI", &fixture.backend)
        .env("LEGACY_ARGV_RECORD", &fixture.record)
        .env("FAKE_SCRATCH_ROOT", &fixture.scratch)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let manifest: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(manifest["root"]["path"], fixture.scratch.to_str().unwrap());
    assert_eq!(manifest["entries"][0]["path"], "old-output.cache");
    assert_eq!(
        fixture.captured_args(),
        vec![b"volume".to_vec(), b"path".to_vec(), b"scratch".to_vec(),]
    );
}

#[test]
fn native_worktree_preview_uses_the_same_selected_legacy_backend() {
    let fixture = LegacyFixture::new(CAPTURE_LEGACY_ARGS);
    let output = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args(["preview", "--scope", "worktrees", "--dry-run"])
        .env("DISKM_LEGACY_COMPAT_CLI", &fixture.backend)
        .env("LEGACY_ARGV_RECORD", &fixture.record)
        .env("FAKE_SCRATCH_ROOT", &fixture.scratch)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["command_complete"], true);
    assert_eq!(
        fixture.captured_args(),
        vec![b"cleanup-worktrees".to_vec(), b"--dry-run".to_vec()]
    );
}

#[test]
fn legacy_compat_rejects_self_recursion_and_preserves_signal_exit() {
    let self_path = PathBuf::from(env!("CARGO_BIN_EXE_diskm"));
    let recursive = Command::new(&self_path)
        .arg("snapshot")
        .env("DISKM_LEGACY_COMPAT_CLI", &self_path)
        .output()
        .unwrap();
    assert_eq!(recursive.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&recursive.stderr).contains("self-recursive"));

    let wrapper = LegacyFixture::new("#!/bin/sh\nexec \"$RUST_DISKM\" snapshot\n");
    let recursive_wrapper = Command::new(&self_path)
        .arg("snapshot")
        .env("DISKM_LEGACY_COMPAT_CLI", &wrapper.backend)
        .env_remove("DISKM_LEGACY_COMPAT_ACTIVE")
        .env("RUST_DISKM", &self_path)
        .output()
        .unwrap();
    assert_eq!(recursive_wrapper.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&recursive_wrapper.stderr).contains("recursive"));

    let root = std::env::temp_dir().join(format!(
        "diskm-legacy-signal-{}-{}",
        std::process::id(),
        NEXT_LEGACY.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    let backend = root.join("legacy-signal");
    fs::write(
        &backend,
        "#!/usr/bin/env python3\nimport os,signal\nos.kill(os.getpid(), signal.SIGTERM)\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&backend).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&backend, permissions).unwrap();
    let signaled = Command::new(self_path)
        .arg("snapshot")
        .env("DISKM_LEGACY_COMPAT_CLI", &backend)
        .output()
        .unwrap();
    fs::remove_dir_all(&root).unwrap();
    assert_eq!(signaled.status.signal(), Some(15));
}

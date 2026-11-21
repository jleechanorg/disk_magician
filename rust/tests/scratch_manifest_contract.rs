use serde_json::Value;
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture {
    root: PathBuf,
    scratch: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(
            std::env::var_os("DISKM_SCRATCH_TEST_DIR").expect("managed Scratch test directory"),
        )
        .join(format!("manifest-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let scratch = root.join("scratch");
        fs::create_dir(&scratch).unwrap();
        let diskm = root.join("disk-magician");
        fs::write(
            &diskm,
            r#"#!/bin/sh
if [ "$*" = 'volume path scratch' ]; then
  printf '%s\n' "$TEST_SCRATCH"
  exit 0
fi
if [ "$1 $2 $3" = 'quarantine scratch-apply --fingerprint-run' ]; then
  printf '%064d\n' 0
  exit 0
fi
exit 64
"#,
        )
        .unwrap();
        fs::set_permissions(&diskm, fs::Permissions::from_mode(0o700)).unwrap();
        Self { root, scratch }
    }

    fn plan(&self, path: &Path, cutoff: i64) -> Output {
        self.plan_with("--path", path, cutoff)
    }

    fn plan_with(&self, option: &str, path: &Path, cutoff: i64) -> Output {
        Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args([
                "scratch-manifest",
                "--before-epoch",
                &cutoff.to_string(),
                option,
            ])
            .arg(path)
            .env("PATH", &self.root)
            .env("DISKM_LEGACY_COMPAT_CLI", self.root.join("disk-magician"))
            .env("TEST_SCRATCH", &self.scratch)
            .output()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn exact_manifest_records_identity_and_excludes_boundary_and_symlinks() {
    let fixture = Fixture::new();
    let file = fixture.scratch.join("artifact with spaces.log");
    fs::write(&file, "disposable fixture").unwrap();
    let metadata = fs::metadata(&file).unwrap();
    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
        + 5;
    let output = fixture.plan(&file, cutoff);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let manifest: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(manifest["version"], 1);
    assert_eq!(manifest["root"]["path"], fixture.scratch.to_str().unwrap());
    assert_eq!(
        manifest["root"]["ino"],
        fs::metadata(&fixture.scratch).unwrap().ino()
    );
    assert_eq!(manifest["before_epoch_seconds"], cutoff);
    let [entry] = manifest["entries"].as_array().unwrap().as_slice() else {
        panic!("expected one manifest entry");
    };
    assert_eq!(entry["path"], "artifact with spaces.log");
    assert_eq!(entry["kind"], "regular_file");
    assert_eq!(entry["dev"], metadata.dev());
    assert_eq!(entry["ino"], metadata.ino());
    assert_eq!(entry["size"], metadata.len());
    assert_eq!(
        entry["mtime_ns"],
        metadata.mtime() * 1_000_000_000 + metadata.mtime_nsec()
    );
    assert_eq!(
        entry["ctime_ns"],
        metadata.ctime() * 1_000_000_000 + metadata.ctime_nsec()
    );
    assert!(!fixture.plan(&file, metadata.mtime()).status.success());

    let outside = fixture.root.join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("keep"), "outside").unwrap();
    let link = fixture.scratch.join("link");
    symlink(&outside, &link).unwrap();
    assert!(!fixture.plan(&outside.join("keep"), cutoff).status.success());
    assert!(!fixture.plan(&link.join("keep"), cutoff).status.success());
    assert!(!fixture.plan(&link, cutoff).status.success());
    let another = fixture.scratch.join("file\nwith newline");
    fs::write(&another, "another disposable fixture").unwrap();
    let list = fixture.root.join("selected-paths");
    let mut paths = file.as_os_str().as_encoded_bytes().to_vec();
    paths.push(0);
    paths.extend_from_slice(another.as_os_str().as_encoded_bytes());
    paths.push(0);
    fs::write(&list, &paths).unwrap();
    let output = fixture.plan_with("--paths-from", &list, cutoff);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let manifest: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(manifest["entries"].as_array().unwrap().len(), 2);
    paths.pop();
    fs::write(&list, paths).unwrap();
    assert!(!fixture
        .plan_with("--paths-from", &list, cutoff)
        .status
        .success());
    assert!(file.exists());

    let repo = fixture.scratch.join("runs/20261120/disk-magician");
    let run = repo.join("build-20261120T120000Z-123-456");
    fs::create_dir_all(&run).unwrap();
    let output = fixture.plan(&run, cutoff);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let manifest: Value = serde_json::from_slice(&output.stdout).unwrap();
    let entry = &manifest["entries"][0];
    assert_eq!(entry["kind"], "managed_run");
    assert_eq!(entry["inventory_sha256"], "0".repeat(64));
    assert!(!fixture.plan(&repo, cutoff).status.success());
}

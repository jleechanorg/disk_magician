use diskm_shadow::{frontier, history};
use serde_json::Value;
use std::fs::{self, File};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "diskm-frontier-test-{label}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        fn restore_perms(dir: &Path) {
            if let Ok(entries) = fs::read_dir(dir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    if let Ok(meta) = fs::symlink_metadata(&p) {
                        if meta.is_dir() {
                            let _ = fs::set_permissions(&p, fs::Permissions::from_mode(0o700));
                            restore_perms(&p);
                        }
                    }
                }
            }
        }
        restore_perms(&self.0);
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn write_mb_file(path: &Path, mib: usize) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let mut f = File::create(path).unwrap();
    let chunk = vec![b'x'; 1024 * 1024];
    for _ in 0..mib {
        f.write_all(&chunk).unwrap();
    }
    f.sync_all().unwrap();
}

fn git(repo: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args([
            "-c",
            "user.name=tester",
            "-c",
            "user.email=tester@example.test",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn complete_frontier_fixture_passes_history_qualifying_sample() {
    let tmp = TempDir::new("complete");
    let fixture = tmp.0.join("fixture");
    let out_file = tmp.0.join("out/ledger/topdown-5g.json");

    write_mb_file(&fixture.join("alpha/a.bin"), 2);
    write_mb_file(&fixture.join("beta/b.bin"), 3);
    write_mb_file(&fixture.join("gamma/g.bin"), 2);
    // Symlink must not be followed or double-counted.
    std::os::unix::fs::symlink(fixture.join("beta"), fixture.join("beta_link")).unwrap();
    // On macOS, APFS root metadata dir must be skipped cleanly without partial gaps.
    let apfs_meta = fixture.join(".Spotlight-V100");
    fs::create_dir(&apfs_meta).unwrap();
    fs::set_permissions(&apfs_meta, fs::Permissions::from_mode(0o000)).unwrap();

    let out = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "frontier",
            "--root",
            fixture.to_str().unwrap(),
            "--min-mb",
            "1",
            "--output",
            out_file.to_str().unwrap(),
            "--json",
        ])
        .output()
        .unwrap();

    if cfg!(target_os = "macos") {
        assert!(
            out.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let written: Value = serde_json::from_slice(&fs::read(&out_file).unwrap()).unwrap();
        let stdout_val: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(written, stdout_val);
        assert_eq!(written["mode"], "complete");
        assert!(written["gaps"].as_array().unwrap().is_empty());
        assert!(written["unfinished"].as_array().unwrap().is_empty());
        assert!(written["disk_used_gb"].as_f64().unwrap() > 0.0);

        let entries = written["entries"].as_array().unwrap();
        let paths: Vec<&str> = entries
            .iter()
            .map(|e| e["path"].as_str().unwrap())
            .collect();
        // fixture (7 MiB) > beta (3 MiB) > alpha (2 MiB) > gamma (2 MiB, tie sorted path asc)
        assert_eq!(
            paths,
            vec![
                fixture.to_str().unwrap(),
                fixture.join("beta").to_str().unwrap(),
                fixture.join("alpha").to_str().unwrap(),
                fixture.join("gamma").to_str().unwrap(),
            ]
        );
        assert!(
            history::qualifying_sample(&written, "c1", 7).is_some(),
            "complete frontier ledger must pass history::qualifying_sample()"
        );
    } else {
        // Non-macOS treats .Spotlight-V100 as normal unreadable directory.
        assert_eq!(out.status.code(), Some(75));
        let written: Value = serde_json::from_slice(&fs::read(&out_file).unwrap()).unwrap();
        assert_eq!(written["mode"], "partial");
        assert!(history::qualifying_sample(&written, "c1", 7).is_none());
    }
}

#[test]
fn two_committed_frontier_ledgers_produce_valid_history_floor() {
    let tmp = TempDir::new("git-history");
    let fixture = tmp.0.join("fixture");
    let state_repo = tmp.0.join("state_repo");
    fs::create_dir_all(&state_repo).unwrap();
    git(&state_repo, &["init", "-q", "-b", "main"]);

    write_mb_file(&fixture.join("first/f1.bin"), 2);

    let run1 = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "frontier",
            "--root",
            fixture.to_str().unwrap(),
            "--min-mb",
            "1",
            "--state-dir",
            state_repo.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        run1.status.success(),
        "{}",
        String::from_utf8_lossy(&run1.stderr)
    );
    git(&state_repo, &["add", "ledger/topdown-5g.json"]);
    git(&state_repo, &["commit", "-qm", "frontier 1"]);

    write_mb_file(&fixture.join("second/f2.bin"), 3);
    let run2 = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "frontier",
            "--root",
            fixture.to_str().unwrap(),
            "--min-mb",
            "1",
            "--state-dir",
            state_repo.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        run2.status.success(),
        "{}",
        String::from_utf8_lossy(&run2.stderr)
    );
    git(&state_repo, &["add", "ledger/topdown-5g.json"]);
    git(&state_repo, &["commit", "-qm", "frontier 2"]);

    let hist = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "history",
            "--state-dir",
            state_repo.to_str().unwrap(),
            "--days",
            "7",
            "--json",
        ])
        .output()
        .unwrap();
    assert!(
        hist.status.success(),
        "{}",
        String::from_utf8_lossy(&hist.stderr)
    );
    let report: Value = serde_json::from_slice(&hist.stdout).unwrap();
    assert_eq!(report["availability"], "available", "report: {report}");
    assert_eq!(report["valid_samples"], 2);
    assert!(report["floor"]["disk_used_kb"].as_u64().is_some());
    assert_eq!(report["scope"]["mounted_at"], fixture.to_str().unwrap());
}

#[test]
fn unreadable_subdirectory_sets_partial_and_rejected_by_history() {
    let tmp = TempDir::new("unreadable");
    let fixture = tmp.0.join("fixture");
    let out_file = tmp.0.join("ledger.json");
    write_mb_file(&fixture.join("ok/file.bin"), 2);
    let restricted = fixture.join("restricted");
    fs::create_dir_all(&restricted).unwrap();
    fs::set_permissions(&restricted, fs::Permissions::from_mode(0o000)).unwrap();

    let out = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "frontier",
            "--root",
            fixture.to_str().unwrap(),
            "--min-mb",
            "1",
            "--output",
            out_file.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    assert_eq!(out.status.code(), Some(75));
    let ledger: Value = serde_json::from_slice(&fs::read(&out_file).unwrap()).unwrap();
    assert_eq!(ledger["mode"], "partial");
    assert!(ledger["unfinished"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p.as_str().unwrap().ends_with("restricted")));
    assert!(history::qualifying_sample(&ledger, "c1", 7).is_none());
}

#[test]
fn expired_deadline_sets_partial_and_rejected_by_history() {
    let tmp = TempDir::new("deadline");
    let fixture = tmp.0.join("fixture");
    let out_file = tmp.0.join("ledger.json");
    write_mb_file(&fixture.join("sub/file.bin"), 2);

    let (ledger, complete) = frontier::run(&frontier::Options {
        roots: vec![fixture.clone()],
        min_mb: 1,
        deadline: Duration::ZERO,
        output: Some(out_file.clone()),
        state_dir: None,
    })
    .unwrap();

    assert!(!complete);
    assert_eq!(ledger["mode"], "partial");
    assert!(!ledger["gaps"].as_array().unwrap().is_empty());
    assert!(!ledger["unfinished"].as_array().unwrap().is_empty());
    assert!(out_file.exists());
    assert!(history::qualifying_sample(&ledger, "c1", 7).is_none());
}

#[test]
fn hardlinks_deduplicated_and_large_dir_itemized_for_history() {
    let tmp = TempDir::new("hardlinks");
    let fixture = tmp.0.join("fixture");
    let file_a = fixture.join("d1/shared.bin");
    write_mb_file(&file_a, 2);
    fs::create_dir_all(fixture.join("d2")).unwrap();
    fs::hard_link(&file_a, fixture.join("d2/shared.bin")).unwrap();

    let (ledger, complete) = frontier::run(&frontier::Options {
        roots: vec![fixture],
        min_mb: 1,
        deadline: Duration::from_secs(10),
        output: None,
        state_dir: None,
    })
    .unwrap();

    assert!(complete);
    // Global deduplication counts the 2 MiB hardlinked inode once (~2048 KiB, not 4096 KiB).
    let measured = ledger["measured_total_kb"].as_u64().unwrap();
    assert!(
        (2048..4000).contains(&measured),
        "expected hardlink-deduped measured_total_kb near 2048, got {measured}"
    );
    assert!(history::qualifying_sample(&ledger, "c1", 7).is_some());
}

#[test]
fn oversize_sparse_file_subdivides_parent_dir_and_passes_history() {
    let tmp = TempDir::new("oversize");
    let fixture = tmp.0.join("fixture");
    let state_repo = tmp.0.join("state");
    fs::create_dir_all(fixture.join("bigdir")).unwrap();
    let sparse = File::create(fixture.join("bigdir/huge_sparse.bin")).unwrap();
    sparse.set_len(105 * 1024 * 1024).unwrap();
    write_mb_file(&fixture.join("bigdir/real.bin"), 2);

    let (ledger, complete) = frontier::run(&frontier::Options {
        roots: vec![fixture],
        min_mb: 1,
        deadline: Duration::from_secs(10),
        output: None,
        state_dir: Some(state_repo.clone()),
    })
    .unwrap();

    assert!(complete);
    assert_eq!(
        ledger["oversize_indivisible_files"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(history::qualifying_sample(&ledger, "c1", 7).is_some());

    let status_out = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "status",
            "--state-dir",
            state_repo.to_str().unwrap(),
            "--json",
        ])
        .output()
        .unwrap();
    assert!(status_out.status.success());
    let status_json: Value = serde_json::from_slice(&status_out.stdout).unwrap();
    assert_eq!(status_json["ledger"]["state"], "fresh");
    assert_eq!(status_json["ledger"]["authoritative"], true);
}

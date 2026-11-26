use diskm_shadow::scratch_expired::{open_pids_in_proc, sweep, Run};
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static SEQ: AtomicUsize = AtomicUsize::new(0);

struct TempTree {
    root: PathBuf,
}

impl TempTree {
    fn new(tag: &str) -> Self {
        let id = SEQ.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "diskm-proc-probe-{tag}-{}-{id}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    fn pid_dir(&self, pid: u32) -> PathBuf {
        let dir = self.root.join(pid.to_string());
        fs::create_dir_all(dir.join("fd")).unwrap();
        dir
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        fn restore_perms(path: &Path) {
            if let Ok(meta) = fs::symlink_metadata(path) {
                if meta.is_dir() && !meta.file_type().is_symlink() {
                    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
                    if let Ok(entries) = fs::read_dir(path) {
                        for entry in entries.flatten() {
                            restore_perms(&entry.path());
                        }
                    }
                }
            }
        }
        restore_perms(&self.root);
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn proc_scan_detects_held_fd_deleted_fd_and_ignores_similar_prefixes() {
    let proc = TempTree::new("fd");
    let p1 = proc.pid_dir(101);
    symlink("/scratch/cand/file.log", p1.join("fd/3")).unwrap();
    let p2 = proc.pid_dir(202);
    symlink("/scratch/cand (deleted)", p2.join("fd/4")).unwrap();
    let p3 = proc.pid_dir(303);
    symlink("/scratch/cand2/file.log", p3.join("fd/3")).unwrap();
    symlink("/scratch/cand other/file.log", p3.join("fd/4")).unwrap();

    let mut pids = open_pids_in_proc(&proc.root, Path::new("/scratch/cand")).unwrap();
    pids.sort();
    assert_eq!(pids, vec![101, 202]);

    assert!(open_pids_in_proc(&proc.root, Path::new("/scratch/can"))
        .unwrap()
        .is_empty());
    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/cand/"))
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn proc_scan_detects_cwd_root_exe_and_maps() {
    let proc = TempTree::new("links-maps");
    let p_cwd = proc.pid_dir(11);
    symlink("/scratch/work/sub", p_cwd.join("cwd")).unwrap();
    let p_exe = proc.pid_dir(12);
    symlink("/scratch/bin-dir/tool", p_exe.join("exe")).unwrap();
    let p_root = proc.pid_dir(13);
    symlink("/scratch/chroot", p_root.join("root")).unwrap();
    let p_map = proc.pid_dir(14);
    fs::write(
        p_map.join("maps"),
        concat!(
            "7f0000-7f1000 r-xp 00000000 00:00 0          [vdso]\n",
            "7f1000-7f2000 r--p 00000000 08:01 1234       /scratch/mapped/dir with space/lib.so (deleted)\n",
        ),
    )
    .unwrap();

    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/work")).unwrap(),
        vec![11]
    );
    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/bin-dir")).unwrap(),
        vec![12]
    );
    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/chroot")).unwrap(),
        vec![13]
    );
    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/mapped")).unwrap(),
        vec![14]
    );
    assert!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/unrelated"))
            .unwrap()
            .is_empty()
    );
}

#[test]
fn proc_scan_fails_closed_on_unreadable_empty_or_malformed_proc() {
    let missing = Path::new("/nonexistent/diskm-proc-root");
    assert!(open_pids_in_proc(missing, Path::new("/scratch/a")).is_err());

    let empty = TempTree::new("empty");
    assert!(open_pids_in_proc(&empty.root, Path::new("/scratch/a")).is_err());

    let denied_root = TempTree::new("denied-root");
    fs::set_permissions(&denied_root.root, fs::Permissions::from_mode(0o000)).unwrap();
    assert!(open_pids_in_proc(&denied_root.root, Path::new("/scratch/a")).is_err());

    let all_denied = TempTree::new("all-denied");
    let p1 = all_denied.pid_dir(501);
    fs::set_permissions(p1.join("fd"), fs::Permissions::from_mode(0o000)).unwrap();
    assert!(open_pids_in_proc(&all_denied.root, Path::new("/scratch/a")).is_err());

    let malformed = TempTree::new("malformed");
    let p2 = malformed.pid_dir(502);
    // `cwd` as a regular file causes `read_link` to fail with EINVAL (not ENOENT/EACCES).
    fs::write(p2.join("cwd"), b"not-a-symlink").unwrap();
    assert!(open_pids_in_proc(&malformed.root, Path::new("/scratch/a")).is_err());

    let valid = TempTree::new("empty-target");
    valid.pid_dir(503);
    assert!(open_pids_in_proc(&valid.root, Path::new("")).is_err());
}

#[test]
fn proc_scan_skips_unreadable_foreign_pid_when_other_pids_are_readable() {
    let proc = TempTree::new("partial-perm");
    let foreign = proc.pid_dir(1);
    fs::set_permissions(foreign.join("fd"), fs::Permissions::from_mode(0o000)).unwrap();
    let own = proc.pid_dir(2);
    symlink("/elsewhere", own.join("cwd")).unwrap();

    assert!(open_pids_in_proc(&proc.root, Path::new("/scratch/a"))
        .unwrap()
        .is_empty());

    symlink("/scratch/a/held", own.join("fd/3")).unwrap();
    assert_eq!(
        open_pids_in_proc(&proc.root, Path::new("/scratch/a")).unwrap(),
        vec![2]
    );
}

#[test]
fn sweep_restores_when_proc_scan_sees_staged_rename_or_original_path() {
    let fx = TempTree::new("staged-restore");
    let root = fs::canonicalize(&fx.root).unwrap();
    let cand = root.join("old-job");
    fs::create_dir_all(&cand).unwrap();
    fs::write(cand.join("data.txt"), b"payload").unwrap();

    let proc = TempTree::new("staged-proc");
    let holder = proc.pid_dir(777);
    symlink("/elsewhere", holder.join("cwd")).unwrap();

    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64
        + Duration::from_secs(60).as_nanos() as i64;
    let dev = fs::symlink_metadata(&root).unwrap().dev();
    let mut run = Run::new(&root, dev, cutoff);
    run.clean = true;
    run.log = root.join(".audit.log");
    let proc_for_open = proc.root.clone();
    run.hooks.open = Box::new(move |targets| {
        for target in targets {
            if !open_pids_in_proc(&proc_for_open, target)?.is_empty() {
                return Ok(true);
            }
        }
        Ok(false)
    });
    let holder_fd = holder.join("fd/9");
    run.hooks.after_stage = Box::new(move |_original, staged_item| {
        symlink(staged_item.join("data.txt"), &holder_fd).unwrap();
    });

    let report = sweep(&run).unwrap();
    assert!(report.removed.is_empty());
    assert!(cand.join("data.txt").exists());
    assert!(
        report
            .deferred
            .iter()
            .any(|(p, r)| p == &cand && r == "deferred:restored:open-file"),
        "expected restored open-file deferral, got: {:?}",
        report.deferred
    );
}

#[cfg(target_os = "linux")]
#[test]
fn real_linux_proc_probe_detects_open_fd_and_cwd_and_clears_unheld() {
    use diskm_shadow::scratch_expired::open_paths;
    use std::process::Command;

    let fx = TempTree::new("real-linux");
    let root = fs::canonicalize(&fx.root).unwrap();
    let open_dir = root.join("held-fd");
    let cwd_dir = root.join("held-cwd");
    let free_dir = root.join("disposable");
    for d in [&open_dir, &cwd_dir, &free_dir] {
        fs::create_dir_all(d).unwrap();
        fs::write(d.join("f"), b"hello").unwrap();
    }

    let mut fd_child = Command::new("sh")
        .args([
            "-c",
            &format!("exec 3< '{}'; sleep 30", open_dir.join("f").display()),
        ])
        .spawn()
        .unwrap();
    let mut cwd_child = Command::new("sh")
        .args(["-c", &format!("cd '{}' && sleep 30", cwd_dir.display())])
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(300));

    let started = std::time::Instant::now();
    let held_fd = open_paths(&open_dir).unwrap();
    let held_cwd = open_paths(&cwd_dir).unwrap();
    let held_free = open_paths(&free_dir).unwrap();
    let elapsed = started.elapsed();

    let _ = fd_child.kill();
    let _ = fd_child.wait();
    let _ = cwd_child.kill();
    let _ = cwd_child.wait();

    assert!(held_fd, "expected open_paths to detect held fd");
    assert!(held_cwd, "expected open_paths to detect live cwd");
    assert!(!held_free, "expected open_paths to report unheld dir free");
    assert!(
        elapsed < Duration::from_secs(2),
        "three /proc probes took too long: {elapsed:?}"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn real_linux_expired_sweep_parity_with_controls_and_terminal_receipt() {
    use diskm_shadow::job_receipt::{self, Completion};
    use serde_json::json;
    use std::process::Command;

    let fx = TempTree::new("real-linux-parity");
    let root = fs::canonicalize(&fx.root).unwrap();
    let state = TempTree::new("real-linux-state");

    let eligible = root.join("eligible-disposable");
    let open_dir = root.join("control-open-file");
    let cwd_dir = root.join("control-live-cwd");
    let ev_dir = root.join("control-evidence");
    let git_dir = root.join("control-unpushed-git");

    for d in [&eligible, &open_dir, &cwd_dir, &git_dir] {
        fs::create_dir_all(d).unwrap();
        fs::write(d.join("f.txt"), b"fixture").unwrap();
    }
    fs::create_dir_all(ev_dir.join("evidence")).unwrap();
    fs::write(ev_dir.join("evidence/proof.txt"), b"keep").unwrap();

    for args in [
        &["init", "-q"][..],
        &["config", "user.email", "test@example.com"],
        &["config", "user.name", "Test"],
        &["add", "f.txt"],
        &["commit", "-q", "-m", "unpushed"],
    ] {
        assert!(Command::new("git")
            .args(args)
            .current_dir(&git_dir)
            .status()
            .unwrap()
            .success());
    }

    let mut fd_child = Command::new("sh")
        .args([
            "-c",
            &format!("exec 3< '{}'; sleep 30", open_dir.join("f.txt").display()),
        ])
        .spawn()
        .unwrap();
    let mut cwd_child = Command::new("sh")
        .args(["-c", &format!("cd '{}' && sleep 30", cwd_dir.display())])
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(300));

    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64
        + Duration::from_secs(60).as_nanos() as i64;
    let dev = fs::symlink_metadata(&root).unwrap().dev();
    let mut run = Run::new(&root, dev, cutoff);
    run.clean = true;
    run.log = state.root.join("deletions.tsv");
    run.holds = state.root.join("evidence-holds.json");

    let started = SystemTime::now();
    let t0 = std::time::Instant::now();
    let report = sweep(&run).unwrap();
    let elapsed = t0.elapsed();

    let _ = fd_child.kill();
    let _ = fd_child.wait();
    let _ = cwd_child.kill();
    let _ = cwd_child.wait();

    assert!(
        report.complete(),
        "expected complete sweep: {:?}",
        report.summary()
    );
    assert!(!report.timed_out);
    assert!(
        elapsed < Duration::from_secs(5),
        "isolated Linux parity sweep took too long: {elapsed:?}"
    );
    assert!(
        !eligible.exists(),
        "eligible disposable dir must be removed"
    );
    assert_eq!(report.removed.len(), 1);
    assert_eq!(report.removed[0].0, eligible);
    assert!(
        open_dir.join("f.txt").exists(),
        "open-file control must be retained"
    );
    assert!(
        cwd_dir.join("f.txt").exists(),
        "live-cwd control must be retained"
    );
    assert!(
        ev_dir.join("evidence/proof.txt").exists(),
        "evidence control must be retained"
    );
    assert!(
        git_dir.join("f.txt").exists(),
        "unpushed git control must be retained"
    );

    let doc = job_receipt::publish_terminal(
        &state.root,
        "scratch_sweep",
        started,
        Completion::Success,
        json!({"root": root, "expired": true}),
        report.summary(),
        json!({}),
    )
    .unwrap();
    assert_eq!(doc["outcome"], "success");
    let receipt_files: Vec<_> = fs::read_dir(state.root.join("receipts/scratch_sweep"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    assert_eq!(receipt_files.len(), 1);
    eprintln!(
        "LINUX_PARITY_RECEIPT elapsed_ms={} removed={} deferred={} kept={} receipt_id={}",
        elapsed.as_millis(),
        report.removed.len(),
        report.deferred.len(),
        report.kept.len(),
        doc["id"]
    );
}

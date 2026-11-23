use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

const DISKM: &str = env!("CARGO_BIN_EXE_diskm");

struct TempRoot(PathBuf);

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn temp_root(name: &str) -> TempRoot {
    let path = std::env::temp_dir().join(format!("diskm-wt-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    TempRoot(path)
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@localhost",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?} failed in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn init_origin_and_repo(base: &Path, name: &str) -> (PathBuf, PathBuf) {
    let origin = base.join(format!("{name}-origin.git"));
    let repo = base.join("repos").join(name);
    fs::create_dir_all(&origin).unwrap();
    fs::create_dir_all(&repo).unwrap();
    git(&origin, &["init", "--bare", "-q", "-b", "main"]);
    git(&repo, &["init", "-q", "-b", "main"]);
    git(
        &repo,
        &["remote", "add", "origin", origin.to_str().unwrap()],
    );
    fs::write(repo.join("README.md"), "base\n").unwrap();
    git(&repo, &["add", "README.md"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    git(&repo, &["push", "-q", "-u", "origin", "main"]);
    (origin, repo)
}

fn add_worktree(repo: &Path, wt: &Path, branch: &str) {
    fs::create_dir_all(wt.parent().unwrap()).unwrap();
    git(
        repo,
        &["worktree", "add", "-q", "-b", branch, wt.to_str().unwrap()],
    );
}

fn age_files(dir: &Path, days: u64) {
    let cutoff = SystemTime::now() - Duration::from_secs(days * 86_400);
    let mut stack = vec![dir.to_path_buf()];
    while let Some(cur) = stack.pop() {
        for entry in fs::read_dir(&cur).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if entry.file_name() == ".git" {
                continue;
            }
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                stack.push(path);
            } else if meta.is_file() {
                OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .unwrap()
                    .set_modified(cutoff)
                    .unwrap();
            }
        }
    }
}

fn run_diskm(args: &[&str], envs: &[(&str, &str)], cwd: Option<&Path>) -> Value {
    let mut cmd = Command::new(DISKM);
    cmd.args(args);
    cmd.env_remove("WORKTREE_APPROVED");
    for (k, v) in envs {
        cmd.env(k, v);
    }
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "diskm {args:?} failed ({:?}):\nstdout: {}\nstderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

fn find_wt<'a>(report: &'a Value, wt: &Path) -> &'a Value {
    let canon = fs::canonicalize(wt).unwrap_or_else(|_| wt.to_path_buf());
    report["worktrees"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| {
            let p = Path::new(item["path"].as_str().unwrap());
            fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()) == canon
        })
        .unwrap_or_else(|| panic!("missing {} in report: {report}", wt.display()))
}

#[test]
fn slim_skips_missing_worktree_config_and_dirty_trees() {
    let root = temp_root("slim");
    let wt_root = root.0.join("worktrees");
    let state = root.0.join("state");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();

    let (_orig1, repo_no_cfg) = init_origin_and_repo(&root.0, "no_cfg");
    let wt_no_cfg = wt_root.join("no_cfg/wt1");
    add_worktree(&repo_no_cfg, &wt_no_cfg, "b-nocfg");

    let (_orig2, roadmap) = init_origin_and_repo(&root.0, "roadmap");
    git(&roadmap, &["config", "extensions.worktreeConfig", "true"]);
    fs::create_dir_all(roadmap.join("dashboards/prw/telemetry")).unwrap();
    fs::write(
        roadmap.join("dashboards/prw/telemetry/big.bin"),
        vec![b'a'; 4096],
    )
    .unwrap();
    git(&roadmap, &["add", "."]);
    git(&roadmap, &["commit", "-q", "-m", "add telemetry"]);

    let wt_dirty = wt_root.join("roadmap/wt-dirty");
    add_worktree(&roadmap, &wt_dirty, "b-dirty");
    fs::write(wt_dirty.join("README.md"), "modified\n").unwrap();

    let wt_clean = wt_root.join("roadmap/wt-clean");
    add_worktree(&roadmap, &wt_clean, "b-clean");

    let cfg = root.0.join("config.json");
    fs::write(
        &cfg,
        serde_json::to_vec(&json!({
            "worktree_sparse_excludes": {
                "no_cfg": ["dashboards"],
                "roadmap": ["dashboards/prw/telemetry"]
            }
        }))
        .unwrap(),
    )
    .unwrap();

    let dry = run_diskm(
        &[
            "worktree-slim",
            "--root",
            wt_root.to_str().unwrap(),
            "--config",
            cfg.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
        ],
        &[],
        None,
    );
    assert_eq!(
        find_wt(&dry, &wt_no_cfg)["reason"],
        "missing_worktree_config"
    );
    assert_eq!(find_wt(&dry, &wt_dirty)["reason"], "dirty");
    assert_eq!(find_wt(&dry, &wt_clean)["status"], "candidate");
    assert!(wt_clean.join("dashboards/prw/telemetry/big.bin").exists());

    let clean = run_diskm(
        &[
            "worktree-slim",
            "--root",
            wt_root.to_str().unwrap(),
            "--config",
            cfg.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
            "--clean",
        ],
        &[],
        None,
    );
    assert_eq!(find_wt(&clean, &wt_clean)["status"], "slimmed");
    assert!(
        find_wt(&clean, &wt_clean)["apparent_delta_bytes"]
            .as_u64()
            .unwrap()
            >= 4096
    );
    assert!(!wt_clean.join("dashboards/prw/telemetry/big.bin").exists());
    assert!(wt_clean.join("README.md").exists());
    assert!(git(&wt_clean, &["status", "--porcelain"]).trim().is_empty());
    assert!(state.join("receipts/worktree-slim").exists());
}

#[test]
fn archive_refuses_without_approval_and_on_holds() {
    let root = temp_root("archive-holds");
    let wt_root = root.0.join("worktrees");
    let state = root.0.join("state");
    fs::create_dir_all(state.join("worktree_leases")).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();

    let (origin, repo) = init_origin_and_repo(&root.0, "app");

    let wt_recent = wt_root.join("app/wt-recent");
    add_worktree(&repo, &wt_recent, "b-recent");

    let wt_dirty = wt_root.join("app/wt-dirty");
    add_worktree(&repo, &wt_dirty, "b-dirty");
    age_files(&wt_dirty, 10);
    fs::write(wt_dirty.join("untracked.txt"), "dirty\n").unwrap();

    let wt_locked = wt_root.join("app/wt-locked");
    add_worktree(&repo, &wt_locked, "b-locked");
    age_files(&wt_locked, 10);
    git(&repo, &["worktree", "lock", wt_locked.to_str().unwrap()]);

    let wt_env = wt_root.join("app/wt-env");
    add_worktree(&repo, &wt_env, "b-env");
    fs::write(wt_env.join(".gitignore"), ".env*\n").unwrap();
    git(&wt_env, &["add", ".gitignore"]);
    git(&wt_env, &["commit", "-q", "-m", "gitignore"]);
    fs::write(wt_env.join(".env.local"), "SECRET=1\n").unwrap();
    age_files(&wt_env, 10);

    let wt_ao_marker = wt_root.join("app/wt-ao-marker");
    add_worktree(&repo, &wt_ao_marker, "b-ao-m");
    fs::write(wt_ao_marker.join(".ao-owner"), "ao\n").unwrap();
    age_files(&wt_ao_marker, 10);

    let wt_ao_path = wt_root.join(".ao/wt-ao-path");
    add_worktree(&repo, &wt_ao_path, "b-ao-p");
    age_files(&wt_ao_path, 10);

    let wt_ev = wt_root.join("app/wt-ev-hold");
    add_worktree(&repo, &wt_ev, "b-ev");
    age_files(&wt_ev, 10);
    fs::write(
        state.join("evidence-holds.json"),
        serde_json::to_vec(&json!({
            wt_ev.to_string_lossy().to_string(): "auto:https://github.com/o/r/pull/1"
        }))
        .unwrap(),
    )
    .unwrap();

    let wt_lease = wt_root.join("app/wt-lease");
    add_worktree(&repo, &wt_lease, "b-lease");
    age_files(&wt_lease, 10);
    let lease_meta = fs::metadata(&wt_lease).unwrap();
    fs::write(
        state.join("worktree_leases/wt-lease.json"),
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "path": wt_lease,
            "kind": "build",
            "owner": {"pid": std::process::id()},
            "owners": [{"pid": std::process::id()}],
            "checkout_dev": lease_meta.dev(),
            "checkout_ino": lease_meta.ino(),
        }))
        .unwrap(),
    )
    .unwrap();

    let wt_cwd = wt_root.join("app/wt-cwd");
    add_worktree(&repo, &wt_cwd, "b-cwd");
    age_files(&wt_cwd, 10);

    let wt_ready = wt_root.join("app/wt-ready");
    add_worktree(&repo, &wt_ready, "b-ready");
    fs::write(wt_ready.join("work.txt"), "unpushed\n").unwrap();
    git(&wt_ready, &["add", "work.txt"]);
    git(&wt_ready, &["commit", "-q", "-m", "ready commit"]);
    age_files(&wt_ready, 10);

    let dry = run_diskm(
        &[
            "worktree-archive",
            "--root",
            wt_root.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
        ],
        &[("DISK_MAGICIAN_STATE_DIR", state.to_str().unwrap())],
        Some(&wt_cwd),
    );
    assert_eq!(find_wt(&dry, &wt_recent)["reason"], "too_recent");
    assert_eq!(find_wt(&dry, &wt_dirty)["reason"], "dirty");
    assert_eq!(find_wt(&dry, &wt_locked)["reason"], "locked");
    assert_eq!(find_wt(&dry, &wt_env)["reason"], "secret_env");
    assert_eq!(find_wt(&dry, &wt_ao_marker)["reason"], "ao_owned");
    assert_eq!(find_wt(&dry, &wt_ao_path)["reason"], "ao_owned");
    assert_eq!(find_wt(&dry, &wt_ev)["reason"], "held");
    assert_eq!(find_wt(&dry, &wt_lease)["reason"], "held");
    assert_eq!(find_wt(&dry, &wt_cwd)["reason"], "open_files");
    assert_eq!(find_wt(&dry, &wt_ready)["status"], "candidate");
    assert!(
        git(&origin, &["ls-remote", ".", "refs/heads/archive/wt-ready"])
            .trim()
            .is_empty()
    );

    let no_approval = run_diskm(
        &[
            "worktree-archive",
            "--root",
            wt_root.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
            "--clean",
        ],
        &[("DISK_MAGICIAN_STATE_DIR", state.to_str().unwrap())],
        None,
    );
    assert_eq!(
        find_wt(&no_approval, &wt_ready)["reason"],
        "missing_approval"
    );
    assert!(wt_ready.exists());

    let push_only = run_diskm(
        &[
            "worktree-archive",
            "--root",
            wt_root.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
            "--push-only",
        ],
        &[("DISK_MAGICIAN_STATE_DIR", state.to_str().unwrap())],
        None,
    );
    assert_eq!(find_wt(&push_only, &wt_ready)["status"], "pushed");
    assert!(wt_ready.exists());
    assert!(
        !git(&origin, &["ls-remote", ".", "refs/heads/archive/wt-ready"])
            .trim()
            .is_empty()
    );
}

#[test]
fn archive_pushes_detached_head_checks_collision_and_removes() {
    let root = temp_root("archive-clean");
    let wt_root = root.0.join("worktrees");
    let state = root.0.join("state");
    let del_log = root.0.join("deletions.log");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();

    let (origin, repo) = init_origin_and_repo(&root.0, "proj");

    let wt_det = wt_root.join("proj/wt-detached");
    add_worktree(&repo, &wt_det, "b-det");
    git(&wt_det, &["checkout", "-q", "--detach"]);
    fs::write(wt_det.join("det.txt"), "detached work\n").unwrap();
    git(&wt_det, &["add", "det.txt"]);
    git(&wt_det, &["commit", "-q", "-m", "detached commit"]);
    let det_sha = git(&wt_det, &["rev-parse", "HEAD"]).trim().to_owned();
    age_files(&wt_det, 10);

    // Pre-populate unrelated commit on origin/archive/wt-collide
    let wt_other = wt_root.join("proj/wt-helper");
    add_worktree(&repo, &wt_other, "b-other");
    git(&wt_other, &["checkout", "-q", "--orphan", "orphan-b"]);
    fs::write(wt_other.join("other.txt"), "unrelated\n").unwrap();
    git(&wt_other, &["add", "other.txt"]);
    git(&wt_other, &["commit", "-q", "-m", "unrelated"]);
    let other_sha = git(&wt_other, &["rev-parse", "HEAD"]).trim().to_owned();
    git(
        &wt_other,
        &["push", "-q", "origin", "HEAD:refs/heads/archive/wt-collide"],
    );
    git(&repo, &["worktree", "remove", wt_other.to_str().unwrap()]);

    let wt_collide = wt_root.join("proj/wt-collide");
    add_worktree(&repo, &wt_collide, "b-collide");
    fs::write(wt_collide.join("c.txt"), "local\n").unwrap();
    git(&wt_collide, &["add", "c.txt"]);
    git(&wt_collide, &["commit", "-q", "-m", "local"]);
    age_files(&wt_collide, 10);

    let res = run_diskm(
        &[
            "worktree-archive",
            "--root",
            wt_root.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
            "--clean",
        ],
        &[
            ("WORKTREE_APPROVED", "1"),
            ("DISK_MAGICIAN_DELETION_LOG", del_log.to_str().unwrap()),
            ("DISK_MAGICIAN_STATE_DIR", state.to_str().unwrap()),
        ],
        None,
    );
    assert_eq!(find_wt(&res, &wt_det)["status"], "archived");
    assert!(!wt_det.exists());
    assert_eq!(
        git(&origin, &["rev-parse", "refs/heads/archive/wt-detached"]).trim(),
        det_sha
    );

    assert_eq!(find_wt(&res, &wt_collide)["reason"], "ref_collision");
    assert!(wt_collide.exists());
    assert_eq!(
        git(&origin, &["rev-parse", "refs/heads/archive/wt-collide"]).trim(),
        other_sha
    );

    let log_text = fs::read_to_string(&del_log).unwrap();
    assert!(log_text.contains("wt-detached"));
    assert!(state.join("receipts/worktree-archive").exists());

    let suffixed = run_diskm(
        &[
            "worktree-archive",
            "--root",
            wt_root.to_str().unwrap(),
            "--state-dir",
            state.to_str().unwrap(),
            "--archive-suffix",
            "v2",
            "--clean",
        ],
        &[
            ("WORKTREE_APPROVED", "1"),
            ("DISK_MAGICIAN_DELETION_LOG", del_log.to_str().unwrap()),
            ("DISK_MAGICIAN_STATE_DIR", state.to_str().unwrap()),
        ],
        None,
    );
    assert_eq!(find_wt(&suffixed, &wt_collide)["status"], "archived");
    assert!(!wt_collide.exists());
    assert!(!git(
        &origin,
        &["ls-remote", ".", "refs/heads/archive/wt-collide-v2"]
    )
    .trim()
    .is_empty());
}

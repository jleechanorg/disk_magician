//! Hourly expired Scratch sweep. Fixtures use the real clock: files are made,
//! two seconds pass, and the cutoff is one second ago, so every fixture is
//! stale by both mtime and ctime until a test touches it.
use diskm_shadow::scratch_expired::{independent, lease_protects, observe, plan, Plan, Run};
use diskm_shadow::scratch_lease::{BundleKind, OwnerProcessState};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Fx {
    root: PathBuf,
}

impl Fx {
    fn new(name: &str) -> Fx {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("diskm-expired-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        Fx { root }
    }
    fn device(&self) -> u64 {
        fs::symlink_metadata(&self.root).unwrap().dev()
    }
    fn file(&self, relative: &str) -> PathBuf {
        let path = self.root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"x").unwrap();
        path
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn now_ns() -> i64 {
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    t.as_secs() as i64 * 1_000_000_000 + i64::from(t.subsec_nanos())
}

/// Two seconds pass; the returned cutoff is one second ago.
fn age() -> i64 {
    std::thread::sleep(Duration::from_secs(2));
    now_ns() - 1_000_000_000
}

fn far() -> Instant {
    Instant::now() + Duration::from_secs(60)
}

#[test]
fn newest_includes_directory_activity() {
    let fx = Fx::new("dir-activity");
    fx.file("u/sub/old");
    let cutoff = age();
    assert!(observe(&fx.root.join("u"), fx.device(), far()).newest < cutoff);
    fs::write(fx.root.join("u/sub/tmp"), b"y").unwrap();
    fs::remove_file(fx.root.join("u/sub/tmp")).unwrap();
    assert!(observe(&fx.root.join("u"), fx.device(), far()).newest > cutoff);
}

#[test]
fn descendant_ctime_counts() {
    let fx = Fx::new("ctime");
    let file = fx.file("u/sub/old");
    let cutoff = age();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    assert!(observe(&fx.root.join("u"), fx.device(), far()).newest > cutoff);
}

#[test]
fn unit_root_ctime_ignored() {
    let fx = Fx::new("root-ctime");
    fx.file("u/old");
    let cutoff = age();
    fs::rename(fx.root.join("u"), fx.root.join("renamed")).unwrap();
    let seen = observe(&fx.root.join("renamed"), fx.device(), far());
    assert!(seen.complete && seen.newest < cutoff);
}

#[test]
fn git_contents_are_not_activity() {
    let fx = Fx::new("git-activity");
    fx.file("u/src/main.rs");
    fx.file("u/.git/index");
    let cutoff = age();
    fs::write(fx.root.join("u/.git/index"), b"fresh").unwrap();
    fs::write(fx.root.join("u/.git/lock"), b"fresh").unwrap();
    let seen = observe(&fx.root.join("u"), fx.device(), far());
    assert!(seen.complete && seen.newest < cutoff);
    assert_eq!(seen.repos, vec![fx.root.join("u/.git")]);
}

#[test]
fn unreadable_subtree_is_incomplete() {
    let fx = Fx::new("unreadable");
    fx.file("u/locked/f");
    let locked = fx.root.join("u/locked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let seen = observe(&fx.root.join("u"), fx.device(), far());
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(!seen.complete && !seen.gaps.is_empty());
}

#[test]
fn cross_device_entry_is_incomplete() {
    let fx = Fx::new("cross-device");
    fx.file("u/f");
    let seen = observe(&fx.root.join("u"), fx.device() + 1, far());
    assert!(!seen.complete);
}

#[test]
fn non_utf8_name_is_incomplete() {
    use std::os::unix::ffi::OsStrExt;
    let fx = Fx::new("non-utf8");
    fs::create_dir_all(fx.root.join("u")).unwrap();
    let odd = fx
        .root
        .join("u")
        .join(std::ffi::OsStr::from_bytes(b"bad\xff"));
    if fs::write(odd, b"x").is_err() {
        return; // the filesystem refuses non-UTF-8 names (APFS)
    }
    assert!(!observe(&fx.root.join("u"), fx.device(), far()).complete);
}

#[test]
fn deadline_marks_incomplete() {
    let fx = Fx::new("deadline");
    fx.file("u/f");
    assert!(!observe(&fx.root.join("u"), fx.device(), Instant::now()).complete);
}

// ---- planning ----

fn run_for(fx: &Fx, cutoff: i64) -> Run {
    std::env::set_var("GIT_CONFIG_GLOBAL", "/dev/null");
    std::env::set_var("GIT_CONFIG_NOSYSTEM", "1");
    let mut run = Run::new(&fx.root, fx.device(), cutoff);
    run.deadline = far();
    run.holds = fx.root.parent().unwrap().join(format!(
        "{}-holds.json",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    run.hooks.lease = Box::new(|_, _| None);
    run
}

fn planned(fx: &Fx, cutoff: i64) -> Plan {
    plan(&run_for(fx, cutoff)).unwrap()
}

fn kept<'a>(plan: &'a Plan, path: &Path) -> Option<&'a str> {
    plan.kept
        .iter()
        .find(|(kept, _)| kept == path)
        .map(|(_, reason)| reason.as_str())
}

#[test]
fn stale_folder_is_one_removal() {
    let fx = Fx::new("one-removal");
    fx.file("a/deep/f");
    let cutoff = age();
    assert_eq!(planned(&fx, cutoff).removals, vec![fx.root.join("a")]);
}

#[test]
fn fresh_file_does_not_shelter_stale_sibling_folder() {
    let fx = Fx::new("siblings");
    fx.file("old/f");
    let cutoff = age();
    fx.file("fresh/f");
    let plan = planned(&fx, cutoff);
    assert_eq!(plan.removals, vec![fx.root.join("old")]);
    assert_eq!(kept(&plan, &fx.root.join("fresh")), Some("kept:fresh"));
}

#[test]
fn old_parent_with_evidence_descendant_is_kept_whole() {
    let fx = Fx::new("evidence-descendant");
    fx.file("task/evidence/e");
    fx.file("task/scratch/f");
    fx.file("task/notes");
    let cutoff = age();
    let plan = planned(&fx, cutoff);
    let mut removals = plan.removals.clone();
    removals.sort();
    assert_eq!(
        removals,
        vec![fx.root.join("task/notes"), fx.root.join("task/scratch")]
    );
    assert!(kept(&plan, &fx.root.join("task/evidence"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
    assert!(kept(&plan, &fx.root.join("task"))
        .unwrap()
        .starts_with("kept:protected-descendant"));
}

#[test]
fn evidence_holds_inside_and_containing_block_ancestors() {
    let fx = Fx::new("holds");
    fx.file("h1/inner/f");
    fx.file("h1/other/f");
    fx.file("h2/f");
    let cutoff = age();
    let run = run_for(&fx, cutoff);
    let holds = serde_json::json!({
        fx.root.join("h1/inner").to_str().unwrap(): "pr 1",
        fx.root.join("h2").to_str().unwrap(): "pr 2",
    });
    fs::write(&run.holds, holds.to_string()).unwrap();
    let plan = plan(&run).unwrap();
    assert_eq!(plan.removals, vec![fx.root.join("h1/other")]);
    assert!(kept(&plan, &fx.root.join("h2"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
    assert!(kept(&plan, &fx.root.join("h1/inner"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
    fs::remove_file(&run.holds).unwrap();
}

#[test]
fn hidden_first_component_not_candidate_but_descendants_are_ordinary() {
    let fx = Fx::new("hidden");
    fx.file(".diskm-ballast/f");
    fx.file("x/.venv/lib/f");
    let cutoff = age();
    assert_eq!(planned(&fx, cutoff).removals, vec![fx.root.join("x")]);
}

#[test]
fn runs_descend_to_run_level_and_leases_protect() {
    let fx = Fx::new("runs");
    fx.file("runs/2026-11-22/repo/done/f");
    fx.file("runs/2026-11-22/repo/live/f");
    let cutoff = age();
    let mut run = run_for(&fx, cutoff);
    run.hooks.lease = Box::new(|_, path| {
        path.ends_with("live")
            .then_some("kept:live-or-unknown-owner")
    });
    let plan = plan(&run).unwrap();
    assert_eq!(
        plan.removals,
        vec![fx.root.join("runs/2026-11-22/repo/done")]
    );
    assert!(kept(&plan, &fx.root.join("runs/2026-11-22/repo/live"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
}

#[test]
fn lease_protection_by_kind_and_owner_state() {
    use BundleKind::{Build, Evidence, Scratch};
    use OwnerProcessState::{Exited, IdentityChanged, Live, Unavailable};
    for kind in [Scratch, Build] {
        assert!(lease_protects(&kind, &Live).is_some());
        assert!(lease_protects(&kind, &Unavailable).is_some());
        assert!(lease_protects(&kind, &Exited).is_none());
        assert!(lease_protects(&kind, &IdentityChanged).is_none());
    }
    for state in [Live, Unavailable, Exited, IdentityChanged] {
        assert!(lease_protects(&Evidence, &state).is_some());
    }
}

#[test]
fn depth_limit_is_reported() {
    let fx = Fx::new("depth");
    fx.file("a/b/c/d/e/old");
    fx.file("a/b/c/d/sibling");
    fx.file("a/b/c/side");
    fx.file("a/b/side");
    fx.file("a/side");
    let cutoff = age();
    fx.file("a/b/c/d/fresh");
    let plan = planned(&fx, cutoff);
    assert_eq!(
        kept(&plan, &fx.root.join("a/b/c/d")),
        Some("kept:depth-limit")
    );
    let mut removals = plan.removals.clone();
    removals.sort();
    assert_eq!(
        removals,
        vec![
            fx.root.join("a/b/c/side"),
            fx.root.join("a/b/side"),
            fx.root.join("a/side"),
        ]
    );
}

#[test]
fn symlink_is_a_link_candidate() {
    let fx = Fx::new("symlink");
    let target = fx.file("target-dir/f");
    std::os::unix::fs::symlink(target.parent().unwrap(), fx.root.join("link")).unwrap();
    let cutoff = age();
    let mut removals = planned(&fx, cutoff).removals;
    removals.sort();
    assert_eq!(
        removals,
        vec![fx.root.join("link"), fx.root.join("target-dir")]
    );
}

// ---- git protection ----

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

fn init(path: &Path) {
    fs::create_dir_all(path).unwrap();
    git(path, &["init", "-q", "-b", "main"]);
    fs::write(path.join("f"), b"1").unwrap();
    git(path, &["add", "f"]);
    git(path, &["commit", "-qm", "one"]);
}

/// A bare repository outside the fixture root that stands in for a hosted
/// remote; the classifier and probe are injected so no network is needed.
fn hosted(fx: &Fx, repo: &Path) -> PathBuf {
    let bare = fx.root.parent().unwrap().join(format!(
        "{}-remote.git",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    let _ = fs::remove_dir_all(&bare);
    git(
        repo,
        &["clone", "-q", "--bare", ".", bare.to_str().unwrap()],
    );
    git(repo, &["remote", "add", "origin", bare.to_str().unwrap()]);
    git(repo, &["fetch", "-q", "origin"]);
    bare
}

fn probe(bare: PathBuf) -> Box<dyn Fn(&Path, &str) -> std::io::Result<Vec<String>>> {
    Box::new(move |_, _| {
        let listing = git(
            &bare,
            &[
                "for-each-ref",
                "--format=%(objectname)",
                "refs/heads",
                "refs/tags",
            ],
        );
        Ok(listing.lines().map(str::to_owned).collect())
    })
}

fn git_run(fx: &Fx, cutoff: i64, bare: Option<PathBuf>) -> Run {
    let mut run = run_for(fx, cutoff);
    if let Some(bare) = bare {
        run.hooks.independent = Box::new(|_, _| true);
        run.hooks.tips = probe(bare);
    }
    run
}

/// The reason the repository's folder is kept, or `None` when it is removed.
fn held(fx: &Fx, setup: impl FnOnce(&Path, &Fx) -> Option<PathBuf>) -> Option<String> {
    let unit = fx.root.join("u");
    let repo = unit.join("repo");
    init(&repo);
    let bare = setup(&repo, fx);
    let cutoff = age();
    let plan = plan(&git_run(fx, cutoff, bare)).unwrap();
    if plan.removals.contains(&unit) {
        return None;
    }
    plan.kept
        .iter()
        .find(|(path, _)| path.starts_with(&unit) && path.ends_with("repo"))
        .map(|(_, reason)| reason.clone())
}

fn why(plan: &Plan, reason: &str) -> bool {
    plan.kept.iter().any(|(_, kept)| kept.ends_with(reason))
}

fn assert_unrecovered(reason: Option<String>) {
    assert_eq!(
        reason.as_deref(),
        Some("kept:protected-subtree:git-unrecovered-commits")
    );
}

#[test]
fn pushed_clean_repo_does_not_hold() {
    let fx = Fx::new("pushed");
    assert_eq!(held(&fx, |repo, fx| Some(hosted(fx, repo))), None);
    let _ = fs::remove_dir_all(fx.root.parent().unwrap().join(format!(
        "diskm-expired-pushed-{}-remote.git",
        std::process::id()
    )));
}

#[test]
fn uncommitted_edits_do_not_hold() {
    let fx = Fx::new("dirty");
    assert_eq!(
        held(&fx, |repo, fx| {
            let bare = hosted(fx, repo);
            fs::write(repo.join("f"), b"edited").unwrap();
            fs::write(repo.join("untracked"), b"u").unwrap();
            Some(bare)
        }),
        None
    );
}

#[test]
fn no_remote_with_commits_holds() {
    let fx = Fx::new("no-remote");
    assert_unrecovered(held(&fx, |_, _| None));
}

#[test]
fn unpushed_branch_commit_holds() {
    let fx = Fx::new("unpushed");
    assert_unrecovered(held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        git(repo, &["checkout", "-qb", "work"]);
        fs::write(repo.join("g"), b"2").unwrap();
        git(repo, &["add", "g"]);
        git(repo, &["commit", "-qm", "two"]);
        Some(bare)
    }));
}

#[test]
fn detached_head_commit_holds() {
    let fx = Fx::new("detached");
    assert_unrecovered(held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        git(repo, &["checkout", "-q", "--detach"]);
        fs::write(repo.join("g"), b"2").unwrap();
        git(repo, &["add", "g"]);
        git(repo, &["commit", "-qm", "two"]);
        Some(bare)
    }));
}

#[test]
fn tag_only_commit_holds() {
    let fx = Fx::new("tag-only");
    assert_unrecovered(held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        fs::write(repo.join("g"), b"2").unwrap();
        git(repo, &["add", "g"]);
        git(repo, &["commit", "-qm", "two"]);
        git(repo, &["tag", "keep"]);
        git(repo, &["reset", "-q", "--hard", "HEAD~1"]);
        git(repo, &["reflog", "expire", "--expire=now", "--all"]);
        Some(bare)
    }));
}

#[test]
fn reflog_only_commit_holds() {
    let fx = Fx::new("reflog-only");
    assert_unrecovered(held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        fs::write(repo.join("g"), b"2").unwrap();
        git(repo, &["add", "g"]);
        git(repo, &["commit", "-qm", "two"]);
        git(repo, &["reset", "-q", "--hard", "HEAD~1"]);
        Some(bare)
    }));
}

#[test]
fn stash_holds() {
    let fx = Fx::new("stash");
    assert_unrecovered(held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        fs::write(repo.join("f"), b"stashed").unwrap();
        git(repo, &["stash", "-q"]);
        git(repo, &["reflog", "expire", "--expire=now", "--all"]);
        Some(bare)
    }));
}

#[test]
fn stale_remote_tracking_ref_does_not_prove_recovery() {
    let fx = Fx::new("stale-tracking");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    hosted(&fx, &unit.join("repo"));
    // The cached origin/main contains the commit, but the live remote no
    // longer lists any branch.
    let cutoff = age();
    let mut run = git_run(&fx, cutoff, None);
    run.hooks.independent = Box::new(|_, _| true);
    run.hooks.tips = Box::new(|_, _| Ok(Vec::new()));
    assert!(!plan(&run).unwrap().removals.contains(&unit));
}

#[test]
fn remote_probe_failure_holds() {
    let fx = Fx::new("probe-failure");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    hosted(&fx, &unit.join("repo"));
    let cutoff = age();
    let mut run = git_run(&fx, cutoff, None);
    run.hooks.independent = Box::new(|_, _| true);
    run.hooks.tips = Box::new(|_, _| Err(std::io::Error::other("unreachable")));
    assert!(!plan(&run).unwrap().removals.contains(&unit));
}

#[test]
fn local_bare_remote_is_never_independent() {
    let fx = Fx::new("local-remote");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    hosted(&fx, &unit.join("repo"));
    let cutoff = age();
    // Default classifier: a local-path remote cannot prove recovery.
    let plan = plan(&run_for(&fx, cutoff)).unwrap();
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-unrecovered-commits"), "{:?}", plan.kept);
}

#[test]
fn insteadof_rewritten_to_a_file_url_is_not_independent() {
    let fx = Fx::new("insteadof");
    let unit = fx.root.join("u");
    let repo = unit.join("repo");
    init(&repo);
    let bare = hosted(&fx, &repo);
    git(
        &repo,
        &["remote", "set-url", "origin", "https://example.test/x.git"],
    );
    git(
        &repo,
        &[
            "config",
            &format!("url.file://{}.insteadOf", bare.display()),
            "https://example.test/x.git",
        ],
    );
    let cutoff = age();
    let plan = plan(&run_for(&fx, cutoff)).unwrap();
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-unrecovered-commits"), "{:?}", plan.kept);
}

#[test]
fn remote_classifier_rejects_loopback_private_and_local_forms() {
    let ssh = |_: &str, _: &str, host: &str| Some(host.to_owned());
    for url in [
        "https://localhost/x.git",
        "https://127.0.0.1/x.git",
        "https://[::1]/x.git",
        "https://10.1.2.3/x.git",
        "https://192.168.1.5:8443/x.git",
        "https://169.254.1.1/x.git",
        "https://100.64.0.9/x.git",
        "git://127.0.0.1/x.git",
        "ssh://git@127.0.0.1/x.git",
        "git@localhost:x.git",
        "/srv/git/x.git",
        "file:///srv/git/x.git",
        "../x.git",
        "https://gitbox/x.git",
        "https://nas.local/x.git",
    ] {
        assert!(!independent(url, &ssh), "{url}");
    }
    for url in [
        "https://github.com/a/b.git",
        "ssh://git@github.com:22/a/b.git",
        "git@github.com:a/b.git",
        "https://[2606:4700::1111]/x.git",
    ] {
        assert!(independent(url, &ssh), "{url}");
    }
}

#[test]
fn ssh_destination_is_resolved_with_the_actual_user_and_port() {
    let seen = std::cell::RefCell::new(Vec::new());
    let resolve = |user: &str, port: &str, host: &str| {
        seen.borrow_mut()
            .push((user.to_owned(), port.to_owned(), host.to_owned()));
        // A `Match user git` block maps only that user to loopback.
        Some(
            if user == "git" {
                "127.0.0.1"
            } else {
                "203.0.113.9"
            }
            .to_owned(),
        )
    };
    assert!(!independent(
        "ssh://git@code.example.test:2222/a.git",
        &resolve
    ));
    assert!(independent(
        "ssh://deploy@code.example.test/a.git",
        &resolve
    ));
    assert_eq!(
        seen.borrow()[0],
        ("git".into(), "2222".into(), "code.example.test".into())
    );
    assert!(!independent("ssh://h/x", &|_: &str,
                                        _: &str,
                                        _: &str|
     -> Option<String> { None }));
}

#[test]
fn linked_worktree_outside_the_candidate_holds() {
    let fx = Fx::new("linked");
    let main = fx
        .root
        .parent()
        .unwrap()
        .join(format!("diskm-expired-linked-{}-main", std::process::id()));
    let _ = fs::remove_dir_all(&main);
    init(&main);
    git(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            fx.root.join("u/wt").to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let removals = planned(&fx, cutoff).removals;
    let _ = fs::remove_dir_all(&main);
    assert!(removals.is_empty());
}

#[test]
fn common_repo_with_external_worktree_holds() {
    let fx = Fx::new("common-external");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-common-external-{}-wt",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&outside);
    git(
        &unit.join("repo"),
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "side",
            outside.to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&outside);
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-external-worktree"), "{:?}", plan.kept);
}

#[test]
fn common_repo_with_internal_worktree_does_not_hold_by_itself() {
    let fx = Fx::new("common-internal");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    git(
        &unit.join("repo"),
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            unit.join("wt").to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    assert!(plan.removals.contains(&unit));
}

#[test]
fn core_worktree_outside_the_candidate_holds() {
    let fx = Fx::new("core-worktree");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-core-worktree-{}-tree",
        std::process::id()
    ));
    fs::create_dir_all(&outside).unwrap();
    git(
        &unit.join("repo"),
        &["config", "core.worktree", outside.to_str().unwrap()],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&outside);
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-external-worktree"), "{:?}", plan.kept);
}

#[test]
fn separate_git_dir_with_external_tree_holds() {
    let fx = Fx::new("separate-git-dir");
    let unit = fx.root.join("u");
    fs::create_dir_all(&unit).unwrap();
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-separate-{}-tree",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&outside);
    fs::create_dir_all(&outside).unwrap();
    git(
        &outside,
        &[
            "init",
            "-q",
            "-b",
            "main",
            "--separate-git-dir",
            unit.join("gitdir").to_str().unwrap(),
        ],
    );
    fs::write(outside.join("f"), b"1").unwrap();
    git(&outside, &["add", "f"]);
    git(&outside, &["commit", "-qm", "one"]);
    let bare = hosted(&fx, &outside);
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&outside);
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-external-worktree"), "{:?}", plan.kept);
}

#[test]
fn alternates_dependent_repo_in_the_root_holds() {
    let fx = Fx::new("alternates");
    let lender = fx.root.join("lender/repo");
    init(&lender);
    let bare = hosted(&fx, &lender);
    let borrower = fx.root.join("borrower/repo");
    git(
        &fx.root,
        &[
            "clone",
            "-q",
            "--shared",
            lender.to_str().unwrap(),
            borrower.to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    assert!(!plan.removals.contains(&fx.root.join("lender")));
}

#[test]
fn bare_repo_with_unpushed_commits_holds() {
    let fx = Fx::new("bare");
    let src = fx
        .root
        .parent()
        .unwrap()
        .join(format!("diskm-expired-bare-{}-src", std::process::id()));
    let _ = fs::remove_dir_all(&src);
    init(&src);
    git(
        &fx.root,
        &[
            "clone",
            "-q",
            "--bare",
            src.to_str().unwrap(),
            fx.root.join("u/mirror.git").to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let removals = planned(&fx, cutoff).removals;
    let _ = fs::remove_dir_all(&src);
    assert!(removals.is_empty());
}

#[test]
fn nested_repo_at_depth_holds() {
    let fx = Fx::new("nested");
    init(&fx.root.join("u/a/b/c/repo"));
    fx.file("u/other/f");
    let cutoff = age();
    let plan = planned(&fx, cutoff);
    assert!(!plan.removals.contains(&fx.root.join("u")));
    assert!(plan.removals.contains(&fx.root.join("u/other")));
}

#[test]
fn corrupt_git_dir_holds() {
    let fx = Fx::new("corrupt");
    fx.file("u/repo/.git/garbage");
    let cutoff = age();
    assert!(planned(&fx, cutoff).removals.is_empty());
}

#[test]
fn descent_never_enters_a_protected_repo() {
    let fx = Fx::new("opaque");
    init(&fx.root.join("task/repo"));
    fx.file("task/repo/src/old");
    fx.file("task/scratch/f");
    let cutoff = age();
    let plan = planned(&fx, cutoff);
    assert_eq!(plan.removals, vec![fx.root.join("task/scratch")]);
    assert!(kept(&plan, &fx.root.join("task/repo"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
    assert!(plan
        .kept
        .iter()
        .all(|(path, _)| !path.starts_with(fx.root.join("task/repo/src"))));
}

//! Hourly expired Scratch sweep. Fixtures use the real clock: files are made,
//! two seconds pass, and the cutoff is one second ago, so every fixture is
//! stale by both mtime and ctime until a test touches it.
use diskm_shadow::scratch_expired::{
    apply, independent, lease_protects, observe, open_paths_with, plan, run_capture, sweep, Intent,
    Plan, Report, Run,
};
use diskm_shadow::scratch_lease::{BundleKind, OwnerProcessState};
use std::fs;
use std::net::IpAddr;
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
    run.hooks.lease = Box::new(|_, _, _| None);
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
fn protected_descendant_keeps_whole_candidate_and_no_child_is_removed() {
    let fx = Fx::new("evidence-descendant");
    fx.file("task/evidence/e");
    fx.file("task/scratch/f");
    fx.file("task/notes");
    let cutoff = age();
    let plan = planned(&fx, cutoff);
    assert!(plan.removals.is_empty(), "{:?}", plan.removals);
    assert!(kept(&plan, &fx.root.join("task"))
        .unwrap()
        .starts_with("kept:protected-descendant:evidence"));
    assert!(plan
        .kept
        .iter()
        .all(|(path, _)| path.parent() == Some(&fx.root)));
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
    assert!(plan.removals.is_empty(), "{:?}", plan.removals);
    assert!(kept(&plan, &fx.root.join("h2"))
        .unwrap()
        .starts_with("kept:protected-subtree"));
    assert!(kept(&plan, &fx.root.join("h1"))
        .unwrap()
        .starts_with("kept:protected-descendant"));
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
    run.hooks.lease = Box::new(|_, path, _| {
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
fn stale_child_dir_beside_fresh_file_is_kept_with_its_parent() {
    let fx = Fx::new("child-dir");
    fx.file("a/old-dir/f");
    let cutoff = age();
    fx.file("a/fresh");
    let plan = planned(&fx, cutoff);
    assert!(plan.removals.is_empty(), "{:?}", plan.removals);
    assert_eq!(kept(&plan, &fx.root.join("a")), Some("kept:fresh"));
    assert!(kept(&plan, &fx.root.join("a/old-dir")).is_none());
}

#[test]
fn fresh_candidate_kept_whole() {
    let fx = Fx::new("fresh-whole");
    fx.file("a/f");
    let cutoff = age();
    fx.file("b/f");
    let plan = planned(&fx, cutoff);
    assert_eq!(plan.removals, vec![fx.root.join("a")]);
    assert_eq!(kept(&plan, &fx.root.join("b")), Some("kept:fresh"));
}

#[test]
fn report_lists_are_capped_and_kept_paths_are_counted() {
    let mut report = Report::default();
    for index in 0..600 {
        report
            .removed
            .push((PathBuf::from(format!("/r/{index}")), 1));
    }
    report.kept.insert("kept:fresh".into(), 15_000);
    report
        .deferred
        .push((PathBuf::from("/d"), "deferred:changed".into()));
    let summary = report.summary();
    assert_eq!(summary["removed"].as_array().unwrap().len(), 500);
    assert_eq!(summary["truncated"]["removed"], 100);
    assert_eq!(summary["kept"]["kept:fresh"], 15_000);
    assert_eq!(summary["deferred"].as_array().unwrap().len(), 1);
    assert!(summary["truncated"]["deferred"].is_null() || summary["truncated"]["deferred"] == 0);
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

#[allow(clippy::type_complexity)]
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
        .find(|(path, _)| *path == unit)
        .map(|(_, reason)| reason.clone())
}

fn why(plan: &Plan, reason: &str) -> bool {
    plan.kept.iter().any(|(_, kept)| kept.ends_with(reason))
}

fn assert_unrecovered(reason: Option<String>) {
    assert_eq!(
        reason.as_deref(),
        Some("kept:protected-descendant:git-unrecovered-commits")
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
    assert_eq!(
        held(&fx, |repo, fx| {
            let bare = hosted(fx, repo);
            fs::write(repo.join("f"), b"stashed").unwrap();
            git(repo, &["stash", "-q"]);
            git(repo, &["reflog", "expire", "--expire=now", "--all"]);
            Some(bare)
        })
        .as_deref(),
        Some("kept:protected-descendant:git-stash")
    );
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
    let dns = |host: &str| match host {
        "github.com" => Some(vec![IpAddr::from([140, 82, 112, 3])]),
        _ => None,
    };
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
        assert!(!independent(url, &ssh, &dns), "{url}");
    }
    for url in [
        "https://github.com/a/b.git",
        "ssh://git@github.com:22/a/b.git",
        "git@github.com:a/b.git",
        "https://[2606:4700::1111]/x.git",
    ] {
        assert!(independent(url, &ssh, &dns), "{url}");
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
    let dns = |_: &str| Some(vec![IpAddr::from([203, 0, 113, 9])]);
    assert!(!independent(
        "ssh://git@code.example.test:2222/a.git",
        &resolve,
        &dns
    ));
    assert!(independent(
        "ssh://deploy@code.example.test/a.git",
        &resolve,
        &dns
    ));
    assert_eq!(
        seen.borrow()[0],
        ("git".into(), "2222".into(), "code.example.test".into())
    );
    assert!(!independent(
        "ssh://h/x",
        &|_: &str, _: &str, _: &str| -> Option<String> { None },
        &dns
    ));
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
fn internal_linked_worktree_holds() {
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
    // A linked worktree is held without exception, even beside its repository.
    assert!(!plan.removals.contains(&unit));
    assert!(why(&plan, "git-linked-worktree"), "{:?}", plan.kept);
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
    assert!(planned(&fx, cutoff).removals.is_empty());
}

#[test]
fn corrupt_git_dir_holds() {
    let fx = Fx::new("corrupt");
    fx.file("u/repo/.git/garbage");
    let cutoff = age();
    assert!(planned(&fx, cutoff).removals.is_empty());
}

#[test]
fn protected_repo_keeps_its_whole_candidate() {
    let fx = Fx::new("opaque");
    init(&fx.root.join("task/repo"));
    fx.file("task/repo/src/old");
    fx.file("task/scratch/f");
    let cutoff = age();
    let plan = planned(&fx, cutoff);
    assert!(plan.removals.is_empty());
    assert!(kept(&plan, &fx.root.join("task"))
        .unwrap()
        .starts_with("kept:protected-descendant"));
}

// ---- transaction, recovery and command line ----

fn log_of(fx: &Fx) -> PathBuf {
    fx.root.parent().unwrap().join(format!(
        "{}-deletions.log",
        fx.root.file_name().unwrap().to_str().unwrap()
    ))
}

fn clean_run(fx: &Fx, cutoff: i64) -> Run {
    let mut run = run_for(fx, cutoff);
    run.clean = true;
    run.log = log_of(fx);
    run.hooks.open = Box::new(|_| Ok(false));
    run
}

fn rows(fx: &Fx) -> Vec<String> {
    fs::read_to_string(log_of(fx))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn dead_pid() -> u32 {
    let mut child = Command::new("true").spawn().unwrap();
    child.wait().unwrap();
    child.id()
}

/// A stage left by process `pid`, holding `original` in `state`.
fn stage(fx: &Fx, pid: u32, state: &str, original: &str, with_item: bool) -> (PathBuf, String) {
    let nonce = format!("{pid}-{}", now_ns());
    let dir = fx.root.join(".diskm-expired");
    let item = dir.join(&nonce).join("item");
    let original_path = fx.root.join(original);
    if with_item {
        fs::create_dir_all(&item).unwrap();
        fs::write(item.join("f"), b"x").unwrap();
    } else {
        fs::create_dir_all(dir.join(&nonce)).unwrap();
    }
    let info = fs::symlink_metadata(if with_item { &item } else { &fx.root }).unwrap();
    let intent = Intent {
        state: state.into(),
        original: original.into(),
        device: info.dev(),
        inode: info.ino(),
        newest: i64::MAX,
        bytes: 1024,
        row: format!(
            "2026-11-22T00:00:00Z\tdiskm-expired\tremove\t1\t{}\t{nonce}\n",
            original_path.display()
        ),
    };
    fs::write(
        dir.join(format!("{nonce}.intent")),
        serde_json::to_vec(&intent).unwrap(),
    )
    .unwrap();
    (item, nonce)
}

#[test]
fn dry_run_removes_nothing_and_lists_interrupted_stages() {
    let fx = Fx::new("dry-run");
    fx.file("a/f");
    let (item, nonce) = stage(&fx, dead_pid(), "staged", "gone", true);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.clean = false;
    let report = sweep(&run).unwrap();
    assert!(fx.root.join("a/f").exists() && item.exists());
    assert_eq!(report.would_remove, vec![fx.root.join("a")]);
    assert_eq!(report.interrupted, vec![nonce]);
    assert!(rows(&fx).is_empty());
}

#[test]
fn clean_removes_a_stale_folder_and_logs_one_row() {
    let fx = Fx::new("clean");
    fx.file("a/deep/f");
    fx.file("fresh-later/f");
    let cutoff = age();
    let report = sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(!fx.root.join("a").exists());
    assert_eq!(report.removed.len(), 2);
    let rows = rows(&fx);
    assert_eq!(rows.len(), 2);
    assert!(rows[0].contains("\tdiskm-expired\tremove\t"));
    assert!(rows
        .iter()
        .any(|row| row.contains(fx.root.join("a").to_str().unwrap())));
    // The stage and intent are gone once the receipt is durable.
    assert_eq!(
        fs::read_dir(fx.root.join(".diskm-expired"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn read_only_tree_is_removed() {
    let fx = Fx::new("read-only");
    let file = fx.file("a/ro/f");
    fs::set_permissions(&file, fs::Permissions::from_mode(0o400)).unwrap();
    fs::set_permissions(file.parent().unwrap(), fs::Permissions::from_mode(0o500)).unwrap();
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(!fx.root.join("a").exists());
}

#[test]
fn symlink_is_unlinked_and_its_target_preserved() {
    let fx = Fx::new("symlink-clean");
    let outside = Fx::new("symlink-target");
    let target = outside.file("keep/f");
    std::os::unix::fs::symlink(target.parent().unwrap(), fx.root.join("link")).unwrap();
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(fs::symlink_metadata(fx.root.join("link")).is_err());
    assert!(target.exists());
}

#[test]
fn candidate_with_a_protected_descendant_is_untouched_by_clean() {
    let fx = Fx::new("parent-stays");
    fx.file("task/evidence/e");
    fx.file("task/scratch/f");
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(fx.root.join("task/evidence/e").exists());
    assert!(fx.root.join("task/scratch/f").exists());
}

#[test]
fn incomplete_unit_and_ancestors_are_never_removed() {
    let fx = Fx::new("incomplete");
    fx.file("u/locked/f");
    fx.file("u/ok/f");
    let locked = fx.root.join("u/locked");
    let cutoff = age();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let report = sweep(&clean_run(&fx, cutoff));
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    report.unwrap();
    assert!(fx.root.join("u").is_dir() && locked.is_dir());
    assert!(fx.root.join("u/ok").exists());
}

#[test]
fn deadline_stops_without_unverified_removal() {
    let fx = Fx::new("deadline-clean");
    fx.file("a/f");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.deadline = Instant::now();
    let report = sweep(&run).unwrap();
    assert!(report.timed_out && !report.complete());
    assert!(fx.root.join("a/f").exists());
}

#[test]
fn probe_failure_restores() {
    let fx = Fx::new("probe-fail");
    fx.file("a/f");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(|_| Err(std::io::Error::other("lsof failed")));
    let report = sweep(&run).unwrap();
    assert!(fx.root.join("a/f").exists() && report.removed.is_empty());
    assert!(rows(&fx).is_empty());
}

#[test]
fn staged_tree_with_fresh_content_restores() {
    let fx = Fx::new("fresh-staged");
    fx.file("a/f");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.after_stage = Box::new(|_, item| fs::write(item.join("late"), b"new").unwrap());
    sweep(&run).unwrap();
    assert!(fx.root.join("a/f").exists() && fx.root.join("a/late").exists());
}

#[test]
fn hold_added_after_stage_restores() {
    let fx = Fx::new("hold-after-stage");
    fx.file("a/f");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    let (holds, original) = (run.holds.clone(), fx.root.join("a"));
    run.hooks.after_stage = Box::new(move |_, _| {
        fs::write(
            &holds,
            serde_json::json!({original.to_str().unwrap(): "pr"}).to_string(),
        )
        .unwrap();
    });
    sweep(&run).unwrap();
    let _ = fs::remove_file(&run.holds);
    assert!(fx.root.join("a/f").exists());
}

#[test]
fn hold_added_between_plan_and_stage_keeps_the_candidate() {
    let fx = Fx::new("hold-before-stage");
    fx.file("a/f");
    let cutoff = age();
    let run = clean_run(&fx, cutoff);
    let planned = plan(&run).unwrap();
    fs::write(
        &run.holds,
        serde_json::json!({fx.root.join("a").to_str().unwrap(): "pr"}).to_string(),
    )
    .unwrap();
    let report = apply(&run, &planned).unwrap();
    let _ = fs::remove_file(&run.holds);
    assert!(fx.root.join("a/f").exists());
    assert_eq!(report.deferred[0].1, "deferred:changed");
}

#[test]
fn content_changed_between_plan_and_stage_defers() {
    let fx = Fx::new("changed");
    fx.file("a/f");
    let cutoff = age();
    let run = clean_run(&fx, cutoff);
    let planned = plan(&run).unwrap();
    fs::write(fx.root.join("a/f"), b"new").unwrap();
    let report = apply(&run, &planned).unwrap();
    assert!(fx.root.join("a/f").exists());
    assert_eq!(report.deferred[0].1, "deferred:changed");
}

fn pushed_repo(fx: &Fx) -> (PathBuf, PathBuf) {
    let repo = fx.root.join("u/repo");
    init(&repo);
    (repo.clone(), hosted(fx, &repo))
}

#[test]
fn git_state_changed_between_plan_and_stage_defers() {
    let fx = Fx::new("git-changed");
    let (repo, bare) = pushed_repo(&fx);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.independent = Box::new(|_, _| true);
    run.hooks.tips = probe(bare);
    let planned = plan(&run).unwrap();
    assert!(planned.removals.contains(&fx.root.join("u")));
    // Only .git changes: identity and every watched timestamp stay as planned.
    git(&repo, &["checkout", "-qb", "late"]);
    git(&repo, &["commit", "--allow-empty", "-qm", "late"]);
    let report = apply(&run, &planned).unwrap();
    assert!(repo.join("f").exists());
    assert_eq!(report.deferred[0].1, "deferred:changed");
}

#[test]
fn commit_created_after_revalidation_before_staged_check_restores() {
    let fx = Fx::new("git-staged");
    let (_, bare) = pushed_repo(&fx);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.independent = Box::new(|_, _| true);
    run.hooks.tips = probe(bare);
    run.hooks.after_stage = Box::new(|_, item| {
        let repo = item.join("repo");
        // Only .git changes: identity and every watched timestamp stay as is.
        git(&repo, &["checkout", "-qb", "late"]);
        git(&repo, &["commit", "--allow-empty", "-qm", "late"]);
    });
    let report = sweep(&run).unwrap();
    assert_eq!(report.deferred[0].1, "deferred:restored");
    assert!(fx.root.join("u/repo/f").exists());
    assert!(rows(&fx).is_empty());
}

#[test]
fn remote_branch_disappearing_between_probes_restores() {
    let fx = Fx::new("tips-vanish");
    let (_, bare) = pushed_repo(&fx);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    let calls = std::rc::Rc::new(std::cell::Cell::new(0));
    let seen = calls.clone();
    let live = probe(bare);
    run.hooks.independent = Box::new(|_, _| true);
    // Planning and revalidation see the branch; the staged check does not.
    run.hooks.tips = Box::new(move |repo, name| {
        seen.set(seen.get() + 1);
        if seen.get() >= 3 {
            Ok(Vec::new())
        } else {
            live(repo, name)
        }
    });
    sweep(&run).unwrap();
    assert!(fx.root.join("u/repo/f").exists());
}

#[test]
fn crash_after_removal_replays_the_receipt_once() {
    let fx = Fx::new("crash-replay");
    fx.file("a/f");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.crash = Box::new(|point| point == "removed");
    assert!(sweep(&run).is_err());
    assert!(!fx.root.join("a").exists() && rows(&fx).is_empty());
    let intents = || {
        fs::read_dir(fx.root.join(".diskm-expired"))
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".intent"))
            .count()
    };
    assert_eq!(intents(), 1);
    // The crashed process is gone; recovery in a later run reconciles it.
    let mut again = clean_run(&fx, cutoff);
    again.hooks.crash = Box::new(|_| false);
    let nonce_pid = std::process::id();
    let dir = fx.root.join(".diskm-expired");
    for entry in fs::read_dir(&dir).unwrap().filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        let renamed = name.replacen(&format!("{nonce_pid}-"), &format!("{}-", dead_pid()), 1);
        fs::rename(dir.join(&name), dir.join(renamed)).unwrap();
    }
    sweep(&again).unwrap();
    sweep(&again).unwrap();
    assert_eq!(rows(&fx).len(), 1);
    assert_eq!(intents(), 0);
}

#[test]
fn interrupted_staged_dead_pid_is_restored_not_deleted() {
    let fx = Fx::new("recover-staged");
    let (item, _) = stage(&fx, dead_pid(), "staged", "back", true);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(|_| Ok(false));
    sweep(&run).unwrap();
    assert!(fx.root.join("back/f").exists() && !item.exists());
    assert!(rows(&fx).is_empty());
}

#[test]
fn interrupted_deleting_dead_pid_is_finished_when_checks_pass() {
    let fx = Fx::new("recover-deleting");
    let (item, _) = stage(&fx, dead_pid(), "deleting", "gone", true);
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(!item.exists() && !fx.root.join("gone").exists());
    assert_eq!(rows(&fx).len(), 1);
}

#[test]
fn deleting_stage_with_item_absent_reconciles_the_receipt_once() {
    let fx = Fx::new("recover-absent");
    let (_, nonce) = stage(&fx, dead_pid(), "deleting", "gone", false);
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert_eq!(
        rows(&fx).iter().filter(|row| row.contains(&nonce)).count(),
        1
    );
}

#[test]
fn deleting_stage_with_a_new_hold_is_restored_then_kept() {
    let fx = Fx::new("recover-hold");
    let (item, _) = stage(&fx, dead_pid(), "deleting", "held", true);
    let cutoff = age();
    let run = clean_run(&fx, cutoff);
    fs::write(
        &run.holds,
        serde_json::json!({fx.root.join("held").to_str().unwrap(): "pr"}).to_string(),
    )
    .unwrap();
    sweep(&run).unwrap();
    let restored = fx.root.join("held/f").exists();
    sweep(&run).unwrap();
    let _ = fs::remove_file(&run.holds);
    assert!(restored && fx.root.join("held/f").exists() && !item.exists());
}

#[test]
fn deleting_stage_with_an_unpushed_commit_is_restored() {
    let fx = Fx::new("recover-git");
    let (item, _) = stage(&fx, dead_pid(), "deleting", "repo-back", true);
    fs::remove_dir_all(&item).unwrap();
    init(&item);
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(fx.root.join("repo-back/f").exists());
    assert!(rows(&fx).is_empty());
}

#[test]
fn restore_blocked_keeps_the_stage_and_intent() {
    let fx = Fx::new("restore-blocked");
    let (item, nonce) = stage(&fx, dead_pid(), "staged", "taken", true);
    let cutoff = age();
    fx.file("taken");
    let run = clean_run(&fx, cutoff);
    for _ in 0..2 {
        sweep(&run).unwrap();
        assert!(item.exists());
        assert!(fx
            .root
            .join(format!(".diskm-expired/{nonce}.intent"))
            .exists());
        assert!(fx.root.join("taken").exists());
    }
}

#[test]
fn live_pid_stage_is_untouched() {
    let fx = Fx::new("live-stage");
    let (item, _) = stage(&fx, std::process::id(), "deleting", "gone", true);
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(item.exists());
}

#[test]
fn pressure_sweep_staging_is_never_read_or_removed() {
    let fx = Fx::new("coexist");
    let live = fx.file(&format!(".diskm-remove-{}-root-1/item", std::process::id()));
    let dead = fx.file(&format!(".diskm-remove-{}-root-2/item", dead_pid()));
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(live.exists() && dead.exists());
}

fn keep_alive(args: &str) -> std::process::Child {
    let child = Command::new("sh").args(["-c", args]).spawn().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    child
}

#[test]
fn open_file_in_the_candidate_restores() {
    let fx = Fx::new("open-file");
    let file = fx.file("a/f");
    let mut child = keep_alive(&format!("exec 3< '{}'; sleep 30", file.display()));
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(diskm_shadow::scratch_expired::open_paths);
    let report = sweep(&run).unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(file.exists() && report.removed.is_empty());
}

#[test]
fn process_working_directory_in_the_candidate_restores() {
    let fx = Fx::new("cwd");
    fx.file("a/f");
    let mut child = keep_alive(&format!("cd '{}' && sleep 30", fx.root.join("a").display()));
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(diskm_shadow::scratch_expired::open_paths);
    let report = sweep(&run).unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(fx.root.join("a/f").exists() && report.removed.is_empty());
}

#[test]
fn expired_with_a_conflicting_option_is_a_usage_error() {
    for args in [["--root", "system-tmp"], ["--path", "/tmp/x"]] {
        let output = Command::new(env!("CARGO_BIN_EXE_diskm"))
            .args(["scratch-sweep", "--expired"])
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let message = String::from_utf8_lossy(&output.stderr);
        assert!(message.contains("--expired works only"), "{message}");
    }
}

#[test]
fn expired_without_a_registered_scratch_volume_is_a_usage_error() {
    let home = Fx::new("no-registry");
    if cfg!(target_os = "linux") {
        fs::create_dir_all(home.root.join("repo/config")).unwrap();
        fs::write(home.root.join("repo/config/config.json"), "{}").unwrap();
    }
    let output = Command::new(env!("CARGO_BIN_EXE_diskm"))
        .args([
            "scratch-sweep",
            "--expired",
            "--min-hours",
            "1",
            "--deadline-ms",
            "5",
        ])
        .env("HOME", &home.root)
        .env("DISK_MAGICIAN_STATE_DIR", &home.root)
        .env("DISK_MAGICIAN_STATE_REPO", home.root.join("repo"))
        .output()
        .unwrap();
    let message = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(2), "{message}");
    assert!(message.contains("Scratch"), "{message}");
}

// ---- review round: drain, gitfiles, leases, freshness, alternates, races ----

#[test]
fn run_capture_drains_a_listing_larger_than_the_pipe() {
    let mut command = Command::new("sh");
    command.args(["-c", "head -c 8000000 /dev/zero | tr '\\0' x"]);
    let (status, out, _) = run_capture(&mut command, None, Duration::from_secs(20)).unwrap();
    assert!(status.success());
    assert_eq!(out.len(), 8_000_000);
}

#[test]
fn run_capture_times_out_a_stuck_command() {
    let mut command = Command::new("sleep");
    command.arg("5");
    let error = run_capture(&mut command, None, Duration::from_millis(200)).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
}

#[test]
fn clean_with_the_real_open_file_probe_removes_a_stale_folder() {
    let fx = Fx::new("real-probe");
    fx.file("a/deep/f");
    let cutoff = age();
    let mut run = run_for(&fx, cutoff);
    run.clean = true;
    run.log = log_of(&fx);
    let report = sweep(&run).unwrap();
    assert!(!fx.root.join("a").exists(), "{:?}", report.deferred);
    assert_eq!(rows(&fx).len(), 1);
}

#[test]
fn corrupt_gitfile_holds() {
    let fx = Fx::new("corrupt-gitfile");
    let unit = fx.root.join("u");
    fs::create_dir_all(unit.join("repo")).unwrap();
    for text in ["garbage", "gitdir:", ""] {
        fs::write(unit.join("repo/.git"), text).unwrap();
        assert!(planned_after_age(&fx).removals.is_empty(), "{text:?}");
    }
}

fn planned_after_age(fx: &Fx) -> Plan {
    std::thread::sleep(Duration::from_secs(2));
    plan(&run_for(fx, now_ns() - 1_000_000_000)).unwrap()
}

#[test]
fn unpublished_submodule_commit_holds() {
    let fx = Fx::new("submodule");
    let outside = fx.root.parent().unwrap();
    let source = outside.join(format!(
        "diskm-expired-submodule-{}-src",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&source);
    init(&source);
    let superproject = fx.root.join("u/super");
    init(&superproject);
    git(
        &superproject,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            source.to_str().unwrap(),
            "sub",
        ],
    );
    git(&superproject, &["commit", "-qm", "add sub"]);
    let bare = hosted(&fx, &superproject);
    let sub = superproject.join("sub");
    git(&sub, &["commit", "--allow-empty", "-qm", "unpublished"]);
    let cutoff = age();
    let mut run = git_run(&fx, cutoff, Some(bare.clone()));
    let super_tips = probe(bare);
    // The superproject is fully pushed; the submodule's remote has nothing.
    run.hooks.tips = Box::new(move |dir, name| {
        if dir.to_string_lossy().contains("/modules/") {
            Ok(Vec::new())
        } else {
            super_tips(dir, name)
        }
    });
    let plan = plan(&run).unwrap();
    let _ = fs::remove_dir_all(&source);
    assert!(
        !plan.removals.contains(&fx.root.join("u")),
        "{:?}",
        plan.kept
    );
    assert!(why(&plan, "git-unrecovered-commits"), "{:?}", plan.kept);
}

fn lease_after_plan(reason: &'static str) -> impl Fn(&Path, &Path, &Path) -> Option<&'static str> {
    // Free while planning and revalidating; marked once the tree is staged.
    move |_, original, actual| (original != actual).then_some(reason)
}

#[test]
fn lease_taken_after_planning_restores_the_staged_run() {
    for reason in ["kept:evidence-run", "kept:live-or-unknown-owner"] {
        let fx = Fx::new("lease-staged");
        fx.file("runs/2026-11-22/repo/run1/f");
        let cutoff = age();
        let mut run = clean_run(&fx, cutoff);
        run.hooks.lease = Box::new(lease_after_plan(reason));
        let report = sweep(&run).unwrap();
        assert!(
            fx.root.join("runs/2026-11-22/repo/run1/f").exists(),
            "{reason}"
        );
        assert!(report.removed.is_empty() && rows(&fx).is_empty());
    }
}

#[test]
fn deleting_stage_recovery_rechecks_the_lease() {
    let fx = Fx::new("lease-recover");
    let original = "runs/2026-11-22/repo/run1";
    fs::create_dir_all(fx.root.join(original).parent().unwrap()).unwrap();
    let (item, _) = stage(&fx, dead_pid(), "deleting", original, true);
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.lease = Box::new(lease_after_plan("kept:live-or-unknown-owner"));
    sweep(&run).unwrap();
    assert!(fx.root.join(original).join("f").exists() && !item.exists());
    assert!(rows(&fx).is_empty());
}

fn set_newest(fx: &Fx, nonce: &str, newest: i64) {
    let path = fx.root.join(format!(".diskm-expired/{nonce}.intent"));
    let mut intent: Intent = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    intent.newest = newest;
    fs::write(path, serde_json::to_vec(&intent).unwrap()).unwrap();
}

#[test]
fn deleting_stage_with_a_file_written_during_downtime_is_restored() {
    let fx = Fx::new("recover-fresh-file");
    let (item, nonce) = stage(&fx, dead_pid(), "deleting", "late", true);
    set_newest(&fx, &nonce, now_ns());
    std::thread::sleep(Duration::from_millis(50));
    fs::write(item.join("closed-new-file"), b"authored while down").unwrap();
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(fx.root.join("late/closed-new-file").exists());
    assert!(rows(&fx).is_empty());
}

#[test]
fn deleting_stage_with_only_our_own_removals_is_finished() {
    let fx = Fx::new("recover-partial");
    let (item, nonce) = stage(&fx, dead_pid(), "deleting", "half", true);
    fs::create_dir_all(item.join("gone")).unwrap();
    fs::write(item.join("gone/x"), b"x").unwrap();
    set_newest(&fx, &nonce, now_ns());
    std::thread::sleep(Duration::from_millis(50));
    // The interrupted removal had already deleted one entry: only directory
    // times moved.
    fs::remove_file(item.join("gone/x")).unwrap();
    let cutoff = age();
    sweep(&clean_run(&fx, cutoff)).unwrap();
    assert!(!item.exists() && !fx.root.join("half").exists());
    assert_eq!(rows(&fx).len(), 1);
}

#[test]
fn hidden_borrower_holds_the_lender() {
    let fx = Fx::new("hidden-borrower");
    let lender = fx.root.join("lender/repo");
    init(&lender);
    let bare = hosted(&fx, &lender);
    git(
        &fx.root,
        &[
            "clone",
            "-q",
            "--shared",
            lender.to_str().unwrap(),
            fx.root.join(".hid/repo").to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    assert!(
        !plan.removals.contains(&fx.root.join("lender")),
        "{:?}",
        plan.kept
    );
    assert!(why(&plan, "git-alternates-dependent"), "{:?}", plan.kept);
}

#[test]
fn unreadable_alternates_file_holds_every_repository() {
    let fx = Fx::new("alternates-unreadable");
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
    let alternates = borrower.join(".git/objects/info/alternates");
    let cutoff = age();
    fs::set_permissions(&alternates, fs::Permissions::from_mode(0o000)).unwrap();
    let plan = plan(&git_run(&fx, cutoff, Some(bare)));
    fs::set_permissions(&alternates, fs::Permissions::from_mode(0o600)).unwrap();
    let plan = plan.unwrap();
    assert!(
        !plan.removals.contains(&fx.root.join("lender")),
        "{:?}",
        plan.kept
    );
}

#[test]
fn borrower_created_after_planning_defers_the_lender() {
    let fx = Fx::new("alternates-late");
    let lender = fx.root.join("lender/repo");
    init(&lender);
    let bare = hosted(&fx, &lender);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    let cutoff = age();
    let mut run = git_run(&fx, cutoff, Some(bare));
    run.clean = true;
    run.log = log_of(&fx);
    run.hooks.open = Box::new(|_| Ok(false));
    let planned = plan(&run).unwrap();
    assert!(planned.removals.contains(&fx.root.join("lender")));
    fs::write(
        borrower.join(".git/objects/info/alternates"),
        format!("{}\n", lender.join(".git/objects").display()),
    )
    .unwrap();
    let report = apply(&run, &planned).unwrap();
    assert!(lender.join("f").exists());
    assert!(report
        .deferred
        .iter()
        .any(|(path, why)| path == &fx.root.join("lender") && why == "deferred:changed"));
}

#[test]
fn restore_never_overwrites_a_destination_created_during_the_restore() {
    let fx = Fx::new("restore-race");
    fx.file("a");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(|_| Err(std::io::Error::other("probe failed")));
    let target = fx.root.join("a");
    run.hooks.crash = Box::new(move |point| {
        if point == "restore" {
            fs::write(&target, b"keep me").unwrap();
        }
        false
    });
    let report = sweep(&run).unwrap();
    assert_eq!(fs::read(fx.root.join("a")).unwrap(), b"keep me");
    assert!(report
        .deferred
        .iter()
        .any(|(_, why)| why == "deferred:restore-blocked"));
    let stages = fs::read_dir(fx.root.join(".diskm-expired"))
        .unwrap()
        .count();
    assert_eq!(stages, 2, "stage directory and intent are both kept");
}

#[test]
fn hostnames_are_classified_by_what_they_resolve_to() {
    let ssh = |_: &str, _: &str, host: &str| Some(host.to_owned());
    let dns = |host: &str| match host {
        "loop.example" => Some(vec![IpAddr::from([127, 0, 0, 1])]),
        "priv.example" => Some(vec![IpAddr::from([10, 2, 3, 4])]),
        "mixed.example" => Some(vec![
            IpAddr::from([8, 8, 8, 8]),
            IpAddr::from([10, 0, 0, 1]),
        ]),
        "pub.example" => Some(vec![IpAddr::from([8, 8, 8, 8])]),
        "empty.example" => Some(Vec::new()),
        _ => None,
    };
    for host in ["loop", "priv", "mixed", "empty", "unresolvable"] {
        assert!(
            !independent(&format!("https://{host}.example/x.git"), &ssh, &dns),
            "{host}"
        );
    }
    assert!(independent("https://pub.example/x.git", &ssh, &dns));
    assert!(independent("git@pub.example:x.git", &ssh, &dns));
}

#[test]
fn stash_reachable_from_a_pushed_remote_still_holds() {
    let fx = Fx::new("stash-pushed");
    let reason = held(&fx, |repo, fx| {
        let bare = hosted(fx, repo);
        fs::write(repo.join("f"), b"stashed").unwrap();
        git(repo, &["stash", "-q"]);
        git(
            repo,
            &["push", "-q", "origin", "refs/stash:refs/heads/stashed"],
        );
        Some(bare)
    });
    assert_eq!(
        reason.as_deref(),
        Some("kept:protected-descendant:git-stash")
    );
}

#[test]
fn hidden_entries_under_runs_are_not_candidates() {
    let fx = Fx::new("runs-hidden");
    fx.file("runs/2026-11-22/.DS_Store");
    fx.file("runs/2026-11-22/repo/done/f");
    let cutoff = age();
    assert_eq!(
        planned(&fx, cutoff).removals,
        vec![fx.root.join("runs/2026-11-22/repo/done")]
    );
}

// ---- round three: submodule stores, fresh scans, linked worktrees, deadline ----

fn lender_with_bare(fx: &Fx) -> (PathBuf, PathBuf) {
    let lender = fx.root.join("lender/repo");
    init(&lender);
    let bare = hosted(fx, &lender);
    (lender, bare)
}

fn borrow_from(borrower_git_store: &Path, lender: &Path) {
    let info = borrower_git_store.join("objects/info");
    fs::create_dir_all(&info).unwrap();
    fs::write(
        info.join("alternates"),
        format!("{}\n", lender.join(".git/objects").display()),
    )
    .unwrap();
}

#[test]
fn submodule_borrower_elsewhere_holds_the_lender() {
    for checked_out in [true, false] {
        submodule_borrower_case(checked_out);
    }
}

/// With the submodule checked out its gitfile leads to the module store;
/// without it only `.git/modules` does.
fn submodule_borrower_case(checked_out: bool) {
    let fx = Fx::new(if checked_out {
        "sub-borrower-in"
    } else {
        "sub-borrower-out"
    });
    let (lender, bare) = lender_with_bare(&fx);
    let source = fx.root.parent().unwrap().join(format!(
        "diskm-expired-submodule-borrower-{}-src",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&source);
    init(&source);
    let superproject = fx.root.join("other/super");
    init(&superproject);
    git(
        &superproject,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            source.to_str().unwrap(),
            "sub",
        ],
    );
    borrow_from(&superproject.join(".git/modules/sub"), &lender);
    if !checked_out {
        fs::remove_dir_all(superproject.join("sub")).unwrap();
    }
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&source);
    assert!(
        !plan.removals.contains(&fx.root.join("lender")),
        "{:?}",
        plan.kept
    );
    assert!(why(&plan, "git-alternates-dependent"), "{:?}", plan.kept);
}

fn lender_run(fx: &Fx, cutoff: i64, bare: PathBuf) -> Run {
    let mut run = git_run(fx, cutoff, Some(bare));
    run.clean = true;
    run.log = log_of(fx);
    run.hooks.open = Box::new(|_| Ok(false));
    run
}

#[test]
fn a_new_borrower_repository_created_after_planning_restores_the_lender() {
    let fx = Fx::new("new-borrower");
    let (lender, bare) = lender_with_bare(&fx);
    let cutoff = age();
    let run = lender_run(&fx, cutoff, bare);
    let planned = plan(&run).unwrap();
    assert!(planned.removals.contains(&fx.root.join("lender")));
    git(
        &fx.root,
        &[
            "clone",
            "-q",
            "--shared",
            lender.to_str().unwrap(),
            fx.root.join("brand-new/repo").to_str().unwrap(),
        ],
    );
    let report = apply(&run, &planned).unwrap();
    assert!(lender.join("f").exists(), "{:?}", report.deferred);
    assert!(report
        .removed
        .iter()
        .all(|(path, _)| path != &fx.root.join("lender")));
}

#[test]
fn alternates_added_after_staging_restore_the_lender() {
    let fx = Fx::new("alternates-after-stage");
    let (lender, bare) = lender_with_bare(&fx);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    let cutoff = age();
    let mut run = lender_run(&fx, cutoff, bare);
    let target = borrower.clone();
    let original = lender.clone();
    run.hooks.after_stage = Box::new(move |path, _| {
        if path.ends_with("lender") {
            borrow_from(&target.join(".git"), &original);
        }
    });
    sweep(&run).unwrap();
    assert!(lender.join("f").exists());
    assert!(rows(&fx).iter().all(|row| !row.contains("lender")));
}

fn recovery_stage_with_repo(fx: &Fx) -> (PathBuf, PathBuf) {
    let (item, _) = stage(fx, dead_pid(), "deleting", "lender-back", true);
    // Keep the item directory itself: the intent records its identity.
    init(&item.join("repo"));
    let bare = hosted(fx, &item.join("repo"));
    (item, bare)
}

#[test]
fn deleting_stage_recovery_is_finished_without_a_borrower() {
    let fx = Fx::new("recover-no-borrower");
    let (item, bare) = recovery_stage_with_repo(&fx);
    let cutoff = age();
    let report = sweep(&lender_run(&fx, cutoff, bare)).unwrap();
    assert!(!item.exists(), "{:?}", report.deferred);
    assert!(!fx.root.join("lender-back").exists());
}

#[test]
fn deleting_stage_recovery_rescans_borrowers() {
    let fx = Fx::new("recover-borrower");
    let (item, bare) = recovery_stage_with_repo(&fx);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    // The borrower points at the stage's original location.
    borrow_from(&borrower.join(".git"), &fx.root.join("lender-back/repo"));
    let cutoff = age();
    sweep(&lender_run(&fx, cutoff, bare)).unwrap();
    assert!(fx.root.join("lender-back/repo/f").exists() && !item.exists());
}

#[test]
fn run_capture_does_not_wait_for_a_descendant_holding_the_pipe() {
    let mut command = Command::new("sh");
    command.args(["-c", "sleep 30 & exit 0"]);
    let started = Instant::now();
    let error = run_capture(&mut command, None, Duration::from_millis(500)).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(10));
}

// ---- the open-file probe against a fake lsof ----

fn fake_lsof(fx: &Fx, script: &str) -> PathBuf {
    let path = fx.root.parent().unwrap().join(format!(
        "{}-fake-lsof",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    // A fork in another test thread can briefly hold the script's write
    // descriptor ("text file busy"); run it once until it starts.
    for _ in 0..100 {
        if Command::new(&path).output().is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    path
}

#[test]
fn lsof_warnings_beside_a_complete_listing_do_not_fail_the_probe() {
    let fx = Fx::new("fake-lsof-warn");
    // Linux lsof warns about unreadable mounts yet exits 0 with a full listing.
    let lsof = fake_lsof(
        &fx,
        "echo 'lsof: WARNING: cannot stat() fuse file system' >&2\nprintf 'p1\\nn/elsewhere/x\\np2\\nn/held/dir/file\\n'\nexit 0",
    );
    assert!(open_paths_with(Path::new("/held/dir"), &lsof).unwrap());
    assert!(!open_paths_with(Path::new("/held/other"), &lsof).unwrap());
    assert!(!open_paths_with(Path::new("/held/di"), &lsof).unwrap());
}

#[test]
fn a_partial_listing_with_a_failing_status_fails_closed() {
    let fx = Fx::new("fake-lsof-partial");
    // Exit 1 means lsof could not read everything: the candidate may be missing.
    for script in [
        "printf 'p1\\nn/elsewhere/x\\n'\nexit 1",
        "echo 'lsof: error' >&2\nprintf 'p1\\nn/elsewhere/x\\n'\nexit 1",
        "printf 'p1\\nn/elsewhere/x\\n'\nexit 2",
    ] {
        let lsof = fake_lsof(&fx, script);
        assert!(
            open_paths_with(Path::new("/held/dir"), &lsof).is_err(),
            "{script}"
        );
    }
}

#[test]
fn a_candidate_missing_from_a_partial_listing_is_kept() {
    let fx = Fx::new("fake-lsof-kept");
    fx.file("a/f");
    let lsof = fake_lsof(&fx, "printf 'p1\\nn/elsewhere\\n'\nexit 1");
    let cutoff = age();
    let mut run = clean_run(&fx, cutoff);
    run.hooks.open = Box::new(move |path| open_paths_with(path, &lsof));
    let report = sweep(&run).unwrap();
    assert!(fx.root.join("a/f").exists() && report.removed.is_empty());
}

#[test]
fn an_unparsable_or_failed_lsof_fails_closed() {
    let fx = Fx::new("fake-lsof-bad");
    for script in [
        "echo 'garbage output'",
        "printf 'p1\\nn/x\\n42rubbish\\n'",
        "echo 'lsof: error' >&2\nexit 2",
        "echo 'lsof: error' >&2\nexit 1",
        "exit 0",
    ] {
        let lsof = fake_lsof(&fx, script);
        assert!(
            open_paths_with(Path::new("/held"), &lsof).is_err(),
            "{script}"
        );
    }
    assert!(open_paths_with(Path::new("/held"), Path::new("/nonexistent/lsof")).is_err());
}

#[test]
fn macos_shaped_listing_with_field_lines_is_parsed() {
    let fx = Fx::new("fake-lsof-macos");
    // macOS lsof also emits `f` (descriptor) lines between `p` and `n`.
    let lsof = fake_lsof(
        &fx,
        "printf 'p123\\nfcwd\\nn/some/dir\\nftxt\\nn/bin/x\\np124\\nf3\\ntREG\\nn/other\\n'",
    );
    assert!(open_paths_with(Path::new("/some/dir"), &lsof).unwrap());
    assert!(open_paths_with(Path::new("/bin/x"), &lsof).unwrap());
    assert!(!open_paths_with(Path::new("/nowhere"), &lsof).unwrap());
    // Only `n` lines are paths: a descriptor or type value is never matched.
    assert!(!open_paths_with(
        Path::new("/some"),
        &fake_lsof(&fx, "printf 'p1\\nf/some\\nfcwd\\n'")
    )
    .unwrap());
}

#[test]
fn a_listing_without_a_process_line_or_with_stray_lines_fails_closed() {
    let fx = Fx::new("fake-lsof-shape");
    for script in [
        "printf 'fcwd\\nn/x\\n'",
        "printf 'p1\\n/x\\n'",
        "printf 'p1\\n 7\\n'",
        "printf 'p1\\n9\\n'",
        "printf '\\n\\n'",
    ] {
        let lsof = fake_lsof(&fx, script);
        assert!(open_paths_with(Path::new("/x"), &lsof).is_err(), "{script}");
    }
}

// ---- round four: relative alternates, module repositories, errors, names ----

/// `alternates` text pointing at the lender by a path relative to the
/// borrower's `objects` directory.
fn borrow_relative(borrower_store: &Path, lender_store_objects: &Path) {
    let base = borrower_store.join("objects");
    let up = base
        .strip_prefix(lender_store_objects.ancestors().nth(4).unwrap())
        .unwrap();
    let ups = "../".repeat(up.components().count());
    let tail = lender_store_objects
        .strip_prefix(lender_store_objects.ancestors().nth(4).unwrap())
        .unwrap();
    fs::create_dir_all(base.join("info")).unwrap();
    fs::write(
        base.join("info/alternates"),
        format!("{ups}{}\n", tail.display()),
    )
    .unwrap();
}

#[test]
fn relative_alternates_protect_the_lender_at_planning() {
    let fx = Fx::new("relative-plan");
    let (lender, bare) = lender_with_bare(&fx);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    borrow_relative(&borrower.join(".git"), &lender.join(".git/objects"));
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    assert!(
        !plan.removals.contains(&fx.root.join("lender")),
        "{:?}",
        plan.kept
    );
    assert!(why(&plan, "git-alternates-dependent"), "{:?}", plan.kept);
}

#[test]
fn relative_alternates_protect_the_lender_after_staging() {
    let fx = Fx::new("relative-stage");
    let (lender, bare) = lender_with_bare(&fx);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    let cutoff = age();
    let mut run = lender_run(&fx, cutoff, bare);
    let (target, objects) = (borrower.clone(), lender.join(".git/objects"));
    run.hooks.after_stage = Box::new(move |path, _| {
        if path.ends_with("lender") {
            borrow_relative(&target.join(".git"), &objects);
        }
    });
    sweep(&run).unwrap();
    assert!(lender.join("f").exists());
    assert!(rows(&fx).iter().all(|row| !row.contains("lender")));
}

#[test]
fn relative_alternates_protect_the_lender_in_recovery() {
    let fx = Fx::new("relative-recover");
    let (item, bare) = recovery_stage_with_repo(&fx);
    let borrower = fx.root.join("borrower/repo");
    init(&borrower);
    borrow_relative(
        &borrower.join(".git"),
        &fx.root.join("lender-back/repo/.git/objects"),
    );
    let cutoff = age();
    sweep(&lender_run(&fx, cutoff, bare)).unwrap();
    assert!(fx.root.join("lender-back/repo/f").exists() && !item.exists());
}

fn deinitialized_submodule(fx: &Fx) -> (PathBuf, PathBuf, PathBuf) {
    let source = fx.root.parent().unwrap().join(format!(
        "diskm-expired-deinit-{}-src",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    let _ = fs::remove_dir_all(&source);
    init(&source);
    let superproject = fx.root.join("u/super");
    init(&superproject);
    git(
        &superproject,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            source.to_str().unwrap(),
            "sub",
        ],
    );
    git(&superproject, &["commit", "-qm", "add sub"]);
    let bare = hosted(fx, &superproject);
    git(
        &superproject.join("sub"),
        &["commit", "--allow-empty", "-qm", "unpublished"],
    );
    git(&superproject, &["submodule", "deinit", "-q", "-f", "sub"]);
    (source, superproject, bare)
}

fn module_blind_tips(bare: PathBuf) -> Box<dyn Fn(&Path, &str) -> std::io::Result<Vec<String>>> {
    let super_tips = probe(bare);
    Box::new(move |dir, name| {
        if dir.to_string_lossy().contains("/modules/") {
            Ok(Vec::new())
        } else {
            super_tips(dir, name)
        }
    })
}

#[test]
fn deinitialized_submodule_with_unpublished_commits_holds() {
    let fx = Fx::new("deinit");
    let (source, superproject, bare) = deinitialized_submodule(&fx);
    assert!(
        !superproject.join("sub/.git").exists(),
        "deinit left a gitfile"
    );
    let cutoff = age();
    let mut run = git_run(&fx, cutoff, Some(bare.clone()));
    run.hooks.tips = module_blind_tips(bare);
    let plan = plan(&run).unwrap();
    let _ = fs::remove_dir_all(&source);
    assert!(
        !plan.removals.contains(&fx.root.join("u")),
        "{:?}",
        plan.kept
    );
    assert!(why(&plan, "git-unrecovered-commits"), "{:?}", plan.kept);
}

#[test]
fn module_commit_created_after_staging_restores() {
    let fx = Fx::new("deinit-staged");
    let (source, superproject, bare) = deinitialized_submodule(&fx);
    let module = superproject.join(".git/modules/sub");
    // Publish the module's commits so planning finds everything recoverable.
    let module_remote = fx.root.parent().unwrap().join(format!(
        "{}-module-remote.git",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    let _ = fs::remove_dir_all(&module_remote);
    git(
        &module,
        &[
            "clone",
            "-q",
            "--bare",
            ".",
            module_remote.to_str().unwrap(),
        ],
    );
    git(
        &module,
        &[
            "remote",
            "set-url",
            "origin",
            module_remote.to_str().unwrap(),
        ],
    );
    let cutoff = age();
    let mut run = lender_run(&fx, cutoff, bare.clone());
    let (super_tips, module_tips) = (probe(bare), probe(module_remote.clone()));
    run.hooks.tips = Box::new(move |dir, name| {
        if dir.to_string_lossy().contains("/modules/") {
            module_tips(dir, name)
        } else {
            super_tips(dir, name)
        }
    });
    let planned = plan(&run).unwrap();
    assert!(
        planned.removals.contains(&fx.root.join("u")),
        "{:?}",
        planned.kept
    );
    // Only .git/modules changes: identity and every watched time stay put.
    run.hooks.after_stage = Box::new(|_, item| {
        let module = item.join("super/.git/modules/sub");
        let tree = git(&module, &["rev-parse", "HEAD^{tree}"]);
        let late = git(
            &module,
            &["commit-tree", "-m", "late", "-p", "HEAD", tree.trim()],
        );
        git(&module, &["update-ref", "refs/heads/late", late.trim()]);
    });
    apply(&run, &planned).unwrap();
    let _ = fs::remove_dir_all(&source);
    let _ = fs::remove_dir_all(&module_remote);
    assert!(superproject.join("f").exists());
}

#[test]
fn unreadable_worktrees_directory_holds() {
    let fx = Fx::new("worktrees-unreadable");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-worktrees-unreadable-{}-wt",
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
    let worktrees = unit.join("repo/.git/worktrees");
    let cutoff = age();
    fs::set_permissions(&worktrees, fs::Permissions::from_mode(0o000)).unwrap();
    let plan = plan(&git_run(&fx, cutoff, Some(bare)));
    fs::set_permissions(&worktrees, fs::Permissions::from_mode(0o700)).unwrap();
    let _ = fs::remove_dir_all(&outside);
    let plan = plan.unwrap();
    assert!(!plan.removals.contains(&unit), "{:?}", plan.kept);
}

#[test]
fn report_with_non_utf8_paths_does_not_panic() {
    use std::os::unix::ffi::OsStrExt;
    let odd = PathBuf::from(std::ffi::OsStr::from_bytes(b"/r/bad\xff"));
    let mut report = Report::default();
    report.removed.push((odd.clone(), 1));
    report.would_remove.push(odd.clone());
    report.deferred.push((odd, "deferred:incomplete".into()));
    let summary = report.summary();
    assert!(summary["removed"][0][0]
        .as_str()
        .unwrap()
        .starts_with("/r/bad"));
}

#[test]
fn a_non_utf8_run_name_is_deferred_not_removed() {
    use std::os::unix::ffi::OsStrExt;
    let fx = Fx::new("non-utf8-run");
    let dir = fx.root.join("runs/2026-11-22/repo");
    fs::create_dir_all(&dir).unwrap();
    let odd = dir.join(std::ffi::OsStr::from_bytes(b"run\xff"));
    if fs::create_dir(&odd).is_err() {
        return; // the filesystem refuses non-UTF-8 names (APFS)
    }
    fs::write(odd.join("f"), b"x").unwrap();
    let cutoff = age();
    let report = sweep(&clean_run(&fx, cutoff)).unwrap();
    report.summary();
    assert!(odd.join("f").exists());
    assert!(
        report
            .kept
            .keys()
            .any(|reason| reason == "deferred:incomplete"),
        "{:?}",
        report.kept
    );
}

// ---- round five: real lease lookup, physical worktree containment ----

static LEASE_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// A run under `runs/` with a retired-allocator lease record owned by `pid`,
/// planned through the REAL lease lookup (not the stubbed hook).
fn legacy_lease_plan(fx: &Fx, damage: impl FnOnce(&Path), pid: u32) -> Plan {
    let _guard = LEASE_ENV
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let state = fx.root.parent().unwrap().join(format!(
        "{}-state",
        fx.root.file_name().unwrap().to_str().unwrap()
    ));
    let _ = fs::remove_dir_all(&state);
    fs::create_dir_all(state.join("worktree_leases")).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    std::env::set_var("DISK_MAGICIAN_STATE_DIR", &state);
    if cfg!(target_os = "linux") {
        fs::create_dir_all(state.join("repo/config")).unwrap();
        fs::write(state.join("repo/config/config.json"), "{}").unwrap();
        std::env::set_var("DISK_MAGICIAN_STATE_REPO", state.join("repo"));
    }
    let run_dir = fx
        .file("runs/20261101/repo/r1/out")
        .parent()
        .unwrap()
        .to_path_buf();
    let info = fs::metadata(&run_dir).unwrap();
    let record = state.join("worktree_leases/r1.json");
    fs::write(
        &record,
        serde_json::json!({
            "schema_version": 1, "path": run_dir, "creator": "scratch-new", "kind": "build",
            "owner": {"pid": pid, "start_epoch": 1, "comm": "codex"},
            "owners": [{"pid": pid, "start_epoch": 1, "comm": "codex"}],
            "checkout_dev": info.dev(), "checkout_ino": info.ino(), "released_at": null,
        })
        .to_string(),
    )
    .unwrap();
    damage(&record);
    let cutoff = age();
    let mut run = run_for(fx, cutoff);
    run.hooks.lease = diskm_shadow::scratch_expired::Hooks::default().lease;
    let planned = plan(&run);
    let _ = fs::set_permissions(&record, fs::Permissions::from_mode(0o600));
    let _ = fs::remove_dir_all(&state);
    planned.unwrap()
}

#[test]
fn a_legacy_lease_record_made_unreadable_keeps_the_run() {
    let fx = Fx::new("lease-unreadable");
    let plan = legacy_lease_plan(
        &fx,
        |record| fs::set_permissions(record, fs::Permissions::from_mode(0o000)).unwrap(),
        std::process::id(),
    );
    assert!(plan.removals.is_empty(), "{:?}", plan.kept);
    assert!(why(&plan, "lease-unavailable"), "{:?}", plan.kept);
}

#[test]
fn a_malformed_legacy_lease_record_keeps_the_run() {
    let fx = Fx::new("lease-malformed");
    let plan = legacy_lease_plan(
        &fx,
        |record| fs::write(record, b"{ not json").unwrap(),
        std::process::id(),
    );
    assert!(plan.removals.is_empty(), "{:?}", plan.kept);
    assert!(why(&plan, "lease-unavailable"), "{:?}", plan.kept);
}

#[test]
fn legacy_leases_still_decide_by_owner_when_readable() {
    let fx = Fx::new("lease-live");
    let plan = legacy_lease_plan(&fx, |_| {}, std::process::id());
    assert!(
        plan.removals.is_empty() && why(&plan, "live-or-unknown-owner"),
        "{:?}",
        plan.kept
    );
    let fx = Fx::new("lease-exited");
    let plan = legacy_lease_plan(&fx, |_| {}, dead_pid());
    assert_eq!(plan.removals, vec![fx.root.join("runs/20261101/repo/r1")]);
}

#[test]
fn a_run_with_no_lease_record_at_all_is_unchanged() {
    let fx = Fx::new("lease-absent");
    let plan = legacy_lease_plan(
        &fx,
        |record| fs::remove_file(record).unwrap(),
        std::process::id(),
    );
    assert_eq!(plan.removals, vec![fx.root.join("runs/20261101/repo/r1")]);
}

#[test]
fn core_worktree_through_an_internal_symlink_to_outside_holds() {
    let fx = Fx::new("core-worktree-symlink");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-core-symlink-{}-tree",
        std::process::id()
    ));
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, unit.join("repo/tree")).unwrap();
    git(&unit.join("repo"), &["config", "core.worktree", "../tree"]);
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&outside);
    assert!(!plan.removals.contains(&unit), "{:?}", plan.kept);
    assert!(why(&plan, "git-external-worktree"), "{:?}", plan.kept);
}

// ---- round six: searchability, Git's own worktree resolution ----

fn unsearchable_module_case(target: impl Fn(&Path) -> PathBuf, label: &str) {
    let fx = Fx::new(label);
    let (source, superproject, bare) = deinitialized_submodule(&fx);
    let locked = target(&superproject.join(".git/modules"));
    let cutoff = age();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o600)).unwrap();
    let mut run = git_run(&fx, cutoff, Some(bare.clone()));
    run.hooks.tips = module_blind_tips(bare);
    let plan = plan(&run);
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    let _ = fs::remove_dir_all(&source);
    let plan = plan.unwrap();
    assert!(
        !plan.removals.contains(&fx.root.join("u")),
        "{:?}",
        plan.kept
    );
}

#[test]
fn unsearchable_modules_directory_keeps_the_candidate() {
    unsearchable_module_case(|modules| modules.to_path_buf(), "modules-0600");
}

#[test]
fn unsearchable_module_directory_keeps_the_candidate() {
    unsearchable_module_case(|modules| modules.join("sub"), "module-sub-0600");
}

#[test]
fn core_worktree_with_dotdot_after_a_symlink_is_resolved_by_git() {
    let fx = Fx::new("core-dotdot");
    let unit = fx.root.join("u");
    init(&unit.join("repo"));
    let bare = hosted(&fx, &unit.join("repo"));
    let outside = fx.root.parent().unwrap().join(format!(
        "diskm-expired-core-dotdot-{}-out",
        std::process::id()
    ));
    fs::create_dir_all(outside.join("nested")).unwrap();
    fs::create_dir_all(outside.join("tree")).unwrap();
    std::os::unix::fs::symlink(outside.join("nested"), unit.join("repo/link")).unwrap();
    // Lexically this is repo/tree (inside); Git follows the link to outside/tree.
    fs::create_dir_all(unit.join("repo/tree")).unwrap();
    git(
        &unit.join("repo"),
        &["config", "core.worktree", "../link/../tree"],
    );
    let cutoff = age();
    let plan = plan(&git_run(&fx, cutoff, Some(bare))).unwrap();
    let _ = fs::remove_dir_all(&outside);
    assert!(!plan.removals.contains(&unit), "{:?}", plan.kept);
    assert!(why(&plan, "git-external-worktree"), "{:?}", plan.kept);
}

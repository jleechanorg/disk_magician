use diskm_shadow::evidence_holds::{self, Fetched, Holds, PullRequest, AUTO};
use diskm_shadow::state_commit;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn temp(name: &str) -> Dir {
    let path = std::env::temp_dir().join(format!("diskm-followup-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    Dir(path)
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
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
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?} failed");
    String::from_utf8(output.stdout).unwrap()
}

/// A repo on main with one commit and a state dir holding a snapshot.
fn repo_and_state(name: &str) -> (Dir, PathBuf, PathBuf) {
    let root = temp(name);
    let repo = root.0.join("repo");
    let state = root.0.join("state");
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(state.join("snapshots")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("README"), "backup\n").unwrap();
    git(&repo, &["add", "README"]);
    git(&repo, &["commit", "-q", "-m", "base"]);
    fs::write(state.join("snapshots/disk_snapshot.json"), "{\"free\":1}\n").unwrap();
    (root, repo, state)
}

fn head(repo: &Path) -> String {
    git(repo, &["rev-parse", "HEAD"]).trim().to_owned()
}

#[test]
fn commits_a_changed_snapshot_then_reports_unchanged() {
    let (_root, repo, state) = repo_and_state("commit");
    let first = state_commit::commit(&repo, &state, "main")
        .unwrap()
        .unwrap();
    let commit = first.expect("expected a commit");
    assert_eq!(head(&repo), commit);
    let files = git(&repo, &["show", "--name-only", "--format=", "HEAD"]);
    assert_eq!(files.trim(), "snapshots/disk_snapshot.json");
    assert_eq!(
        state_commit::commit(&repo, &state, "main").unwrap(),
        Ok(None)
    );
}

fn assert_held_unchanged(repo: &Path, state: &Path, branch: &str, reason: &str) {
    let before = (head(repo), git(repo, &["status", "--porcelain"]));
    assert_eq!(
        state_commit::commit(repo, state, branch).unwrap(),
        Err(reason.to_owned())
    );
    assert_eq!((head(repo), git(repo, &["status", "--porcelain"])), before);
}

#[test]
fn refuses_unrelated_staged_changes_without_writing() {
    let (_root, repo, state) = repo_and_state("staged");
    fs::write(repo.join("other.txt"), "x\n").unwrap();
    git(&repo, &["add", "other.txt"]);
    assert_held_unchanged(&repo, &state, "main", "unrelated_staged_changes");
}

#[test]
fn refuses_wrong_branch_and_detached_head() {
    let (_root, repo, state) = repo_and_state("branch");
    git(&repo, &["checkout", "-q", "-b", "side"]);
    assert_held_unchanged(&repo, &state, "main", "wrong_branch");
    git(&repo, &["checkout", "-q", "--detach"]);
    assert_held_unchanged(&repo, &state, "main", "detached_head");
}

#[test]
fn refuses_a_linked_target_directory() {
    let (root, repo, state) = repo_and_state("link");
    let outside = root.0.join("outside");
    fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, repo.join("snapshots")).unwrap();
    assert_held_unchanged(&repo, &state, "main", "target_path_unsafe");
    assert!(fs::read_dir(&outside).unwrap().next().is_none());
}

#[test]
fn refuses_a_missing_or_linked_source() {
    let (root, repo, state) = repo_and_state("source");
    let real = root.0.join("real.json");
    fs::write(&real, "{}\n").unwrap();
    fs::remove_file(state.join("snapshots/disk_snapshot.json")).unwrap();
    assert_held_unchanged(&repo, &state, "main", "source_unreadable");
    std::os::unix::fs::symlink(&real, state.join("snapshots/disk_snapshot.json")).unwrap();
    assert_held_unchanged(&repo, &state, "main", "source_unreadable");
}

fn roots() -> Vec<(String, String)> {
    vec![
        ("/Volumes/scratch".into(), "/Volumes/scratch".into()),
        ("/tmp".into(), "/private/tmp".into()),
    ]
}

#[test]
fn extracts_paths_from_markdown_code_and_links() {
    let text = "See `/tmp/review evidence/video.mp4` and [run](/Volumes/scratch/runs/a b/log.txt).\n\
                Plain /Volumes/scratch/evidence/x.png, and /Volumes/scratch/pr/.\n\
                Not /home/u/tmp/y or a/tmp/z or /tmp/../etc.\nUnterminated `/tmp/cut here\nnext line";
    let found: Vec<PathBuf> = evidence_holds::extract(text, &roots())
        .into_iter()
        .collect();
    let expected: Vec<PathBuf> = [
        "/Volumes/scratch/evidence/x.png",
        "/Volumes/scratch/pr",
        "/Volumes/scratch/runs/a b/log.txt",
        "/private/tmp/cut here",
        "/private/tmp/review evidence/video.mp4",
    ]
    .iter()
    .map(PathBuf::from)
    .collect();
    assert_eq!(found, expected);
}

#[test]
fn merge_keeps_manual_holds_and_replaces_automatic_ones() {
    let mut existing = Holds::new();
    existing.insert("/m".into(), "manual note".into());
    existing.insert("/old".into(), format!("{AUTO}https://pr/1"));
    let mut fresh = BTreeMap::new();
    fresh.insert(PathBuf::from("/new"), "https://pr/2".to_owned());
    fresh.insert(PathBuf::from("/m"), "https://pr/3".to_owned());
    existing.insert("/elsewhere/kept".into(), format!("{AUTO}https://pr/4"));
    let roots = vec![
        ("/m".to_owned(), "/m".to_owned()),
        ("/old".to_owned(), "/old".to_owned()),
        ("/new".to_owned(), "/new".to_owned()),
    ];
    let merged = evidence_holds::merge(&existing, &fresh, &roots);
    assert!(merged.contains_key(Path::new("/elsewhere/kept")));
    assert_eq!(merged.get(Path::new("/m")).unwrap(), "manual note");
    assert_eq!(
        merged.get(Path::new("/new")).unwrap(),
        &format!("{AUTO}https://pr/2")
    );
    assert!(!merged.contains_key(Path::new("/old")));
}

fn one_request(_: &str) -> io::Result<Fetched> {
    Ok(Fetched {
        requests: vec![PullRequest {
            url: "https://pr/9".into(),
            texts: vec!["evidence at /tmp/held/file.txt".into()],
        }],
        partitions: Vec::new(),
    })
}

fn failing(_: &str) -> io::Result<Fetched> {
    Err(io::Error::other("network down"))
}

#[test]
fn refresh_writes_holds_and_a_failure_keeps_them() {
    let root = temp("refresh");
    let state = root.0.join("state");
    fs::create_dir_all(&state).unwrap();
    let (_, code) = evidence_holds::refresh(Some(&state), "q", &roots(), one_request).unwrap();
    assert_eq!(code, 0);
    let path = state.join("evidence-holds.json");
    let written = fs::read_to_string(&path).unwrap();
    assert!(written.contains("/private/tmp/held/file.txt"), "{written}");
    let (_, code) = evidence_holds::refresh(Some(&state), "q", &roots(), failing).unwrap();
    assert_eq!(code, 75);
    assert_eq!(fs::read_to_string(&path).unwrap(), written);
    fs::write(&path, "not json").unwrap();
    let (_, code) = evidence_holds::refresh(Some(&state), "q", &roots(), one_request).unwrap();
    assert_eq!(code, 75);
    assert_eq!(fs::read_to_string(&path).unwrap(), "not json");
}

#[test]
fn refuses_an_in_progress_operation_without_writing() {
    let (_root, repo, state) = repo_and_state("operation");
    let git_dir = PathBuf::from(git(&repo, &["rev-parse", "--absolute-git-dir"]).trim());
    for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
        fs::write(git_dir.join(marker), head(&repo) + "\n").unwrap();
        assert_held_unchanged(&repo, &state, "main", "operation_in_progress");
        fs::remove_file(git_dir.join(marker)).unwrap();
    }
    for marker in ["rebase-merge", "rebase-apply"] {
        fs::create_dir(git_dir.join(marker)).unwrap();
        assert_held_unchanged(&repo, &state, "main", "operation_in_progress");
        fs::remove_dir(git_dir.join(marker)).unwrap();
    }
}

#[test]
fn refuses_an_oversized_or_non_regular_source() {
    let (_root, repo, state) = repo_and_state("oversize");
    let source = state.join("snapshots/disk_snapshot.json");
    fs::write(&source, vec![b'x'; 10 * 1024 * 1024 + 1]).unwrap();
    assert_held_unchanged(&repo, &state, "main", "source_unreadable");
    fs::remove_file(&source).unwrap();
    fs::create_dir(&source).unwrap();
    assert_held_unchanged(&repo, &state, "main", "source_unreadable");
}

#[test]
fn keeps_automatic_holds_under_an_unscanned_root() {
    let mut existing = Holds::new();
    existing.insert(
        "/Volumes/scratch/runs/x".into(),
        format!("{AUTO}https://pr/1"),
    );
    existing.insert("/private/tmp/old".into(), format!("{AUTO}https://pr/2"));
    // Only the temp root was available for this refresh.
    let roots = vec![("/tmp".to_owned(), "/private/tmp".to_owned())];
    let merged = evidence_holds::merge(&existing, &BTreeMap::new(), &roots);
    assert!(merged.contains_key(Path::new("/Volumes/scratch/runs/x")));
    assert!(!merged.contains_key(Path::new("/private/tmp/old")));
}

#[test]
fn a_planted_temporary_link_is_never_followed() {
    let (root, repo, state) = repo_and_state("templink");
    let victim = root.0.join("victim.txt");
    fs::write(&victim, "keep me\n").unwrap();
    fs::create_dir_all(repo.join("snapshots")).unwrap();
    std::os::unix::fs::symlink(&victim, repo.join("snapshots/disk_snapshot.diskm-tmp")).unwrap();
    let committed = state_commit::commit(&repo, &state, "main")
        .unwrap()
        .unwrap();
    assert!(committed.is_some());
    assert_eq!(fs::read_to_string(&victim).unwrap(), "keep me\n");
}

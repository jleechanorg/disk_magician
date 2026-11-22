use super::*;
use std::fs;

/// Stands in for gitleaks where a test covers size, prefix or lease logic.
fn clean(_: &Path, _: &str) -> io::Result<Result<(), &'static str>> {
    Ok(Ok(()))
}

struct Fixture {
    root: PathBuf,
    work: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn sh(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@localhost",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?} failed");
}

/// A bare remote plus a clone whose main is published once.
fn fixture(name: &str) -> Fixture {
    let root =
        std::env::temp_dir().join(format!("diskm-state-publish-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    let remote = root.join("remote.git");
    let work = root.join("work");
    sh(
        &root,
        &[
            "init",
            "-q",
            "--bare",
            "-b",
            "main",
            remote.to_str().unwrap(),
        ],
    );
    sh(
        &root,
        &[
            "clone",
            "-q",
            remote.to_str().unwrap(),
            work.to_str().unwrap(),
        ],
    );
    sh(&work, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    add(&work, "base.txt", b"base\n");
    sh(&work, &["push", "-q", "origin", "main"]);
    Fixture { root, work }
}

fn add(work: &Path, name: &str, bytes: &[u8]) -> String {
    fs::write(work.join(name), bytes).unwrap();
    sh(work, &["add", name]);
    sh(work, &["commit", "-q", "-m", name]);
    commit(work, "HEAD").unwrap()
}

fn remote_tip(work: &Path) -> String {
    git(work, &["ls-remote", "origin", "refs/heads/main"])
        .unwrap()
        .split('\t')
        .next()
        .unwrap()
        .to_owned()
}

#[test]
fn publishes_only_the_bounded_prefix() {
    let f = fixture("prefix");
    let commits: Vec<String> = (0..25)
        .map(|i| add(&f.work, &format!("f{i}.txt"), b"small\n"))
        .collect();
    let Plan::Publish {
        upstream,
        candidate,
        count,
        remaining,
        ..
    } = observe(&f.work, "origin", "main", 20, 1024, clean).unwrap()
    else {
        panic!("expected publish")
    };
    assert_eq!((count, remaining, &candidate), (20, 5, &commits[19]));
    assert!(push_prefix(&f.work, "origin", "main", &upstream, &candidate).unwrap());
    assert_eq!(remote_tip(&f.work), commits[19]);
}

#[test]
fn stops_before_an_oversized_blob() {
    let f = fixture("oversize");
    let small: Vec<String> = (0..3)
        .map(|i| add(&f.work, &format!("s{i}.txt"), b"small\n"))
        .collect();
    add(&f.work, "big.bin", &[7u8; 2048]);
    let Plan::Publish {
        candidate,
        count,
        stop,
        ..
    } = observe(&f.work, "origin", "main", 20, 1024, clean).unwrap()
    else {
        panic!("expected publish")
    };
    assert_eq!((count, &candidate), (3, &small[2]));
    assert_eq!(stop["reason"], "oversize");
    assert_eq!(stop["path"], "big.bin");
}

#[test]
fn holds_when_the_first_pending_commit_is_oversized() {
    let f = fixture("oversize-first");
    let before = remote_tip(&f.work);
    add(&f.work, "big.bin", &[7u8; 2048]);
    let plan = observe(&f.work, "origin", "main", 20, 1024, clean).unwrap();
    assert!(
        matches!(&plan, Plan::Hold { reason, .. } if reason == "oversize_first_pending"),
        "{plan:?}"
    );
    assert_eq!(remote_tip(&f.work), before);
}

#[test]
fn holds_on_a_secret_scan_finding() {
    let f = fixture("secret");
    let before = remote_tip(&f.work);
    // Assembled at runtime so this source file itself carries no token.
    let token = format!("ghp_{}{}", "Zq8mN2vX4bL7tR1yK9wE", "3hJ6pC5sD0fG8aU2");
    add(
        &f.work,
        "config.env",
        format!("GITHUB_TOKEN={token}\n").as_bytes(),
    );
    let plan = observe(&f.work, "origin", "main", 20, 1024, secret_scan).unwrap();
    // Without gitleaks the scan fails closed instead of reporting the finding.
    let scanner = Command::new("gitleaks")
        .arg("version")
        .output()
        .is_ok_and(|output| output.status.success());
    let expected = if scanner {
        "secret_scan_finding"
    } else {
        "secret_scan_unavailable"
    };
    assert!(
        matches!(&plan, Plan::Hold { reason, .. } if reason == expected),
        "{plan:?}"
    );
    assert_eq!(remote_tip(&f.work), before);
}

#[test]
fn refuses_when_the_remote_moved_after_observation() {
    let f = fixture("lease");
    add(&f.work, "mine.txt", b"mine\n");
    let Plan::Publish {
        upstream,
        candidate,
        ..
    } = observe(&f.work, "origin", "main", 20, 1024, clean).unwrap()
    else {
        panic!("expected publish")
    };
    let other = f.root.join("other");
    sh(
        &f.root,
        &[
            "clone",
            "-q",
            f.root.join("remote.git").to_str().unwrap(),
            other.to_str().unwrap(),
        ],
    );
    let theirs = add(&other, "theirs.txt", b"theirs\n");
    sh(&other, &["push", "-q", "origin", "main"]);
    assert!(!push_prefix(&f.work, "origin", "main", &upstream, &candidate).unwrap());
    assert_eq!(remote_tip(&f.work), theirs);
}

#[test]
fn reports_up_to_date_without_pushing() {
    let f = fixture("current");
    let before = remote_tip(&f.work);
    assert!(matches!(
        observe(&f.work, "origin", "main", 20, 1024, clean).unwrap(),
        Plan::UpToDate { .. }
    ));
    assert_eq!(remote_tip(&f.work), before);
}

#[test]
fn replacement_objects_cannot_hide_an_oversized_commit() {
    let f = fixture("replace");
    let before = remote_tip(&f.work);
    let big = add(&f.work, "big.bin", &[7u8; 2048]);
    // A replacement commit with only a small file, standing in for `big`.
    sh(&f.work, &["reset", "-q", "--hard", "HEAD~1"]);
    let small = add(&f.work, "small.txt", b"small\n");
    sh(&f.work, &["reset", "-q", "--hard", &big]);
    sh(&f.work, &["replace", &big, &small]);
    let plan = observe(&f.work, "origin", "main", 20, 1024, clean).unwrap();
    assert!(
        matches!(&plan, Plan::Hold { reason, .. } if reason == "oversize_first_pending"),
        "{plan:?}"
    );
    assert_eq!(remote_tip(&f.work), before);
}

#[test]
fn holds_on_a_shallow_repository() {
    let f = fixture("shallow");
    add(&f.work, "one.txt", b"one\n");
    sh(&f.work, &["push", "-q", "origin", "main"]);
    let shallow = f.root.join("shallow");
    let url = format!("file://{}", f.root.join("remote.git").display());
    sh(
        &f.root,
        &[
            "clone",
            "-q",
            "--depth",
            "1",
            &url,
            shallow.to_str().unwrap(),
        ],
    );
    add(&shallow, "two.txt", b"two\n");
    let plan = observe(&shallow, "origin", "main", 20, 1024, clean).unwrap();
    assert!(
        matches!(&plan, Plan::Hold { reason, .. } if reason == "substituted_history"),
        "{plan:?}"
    );
}

//! Hourly expired Scratch sweep. Fixtures use the real clock: files are made,
//! two seconds pass, and the cutoff is one second ago, so every fixture is
//! stale by both mtime and ctime until a test touches it.
use diskm_shadow::scratch_expired::observe;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
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

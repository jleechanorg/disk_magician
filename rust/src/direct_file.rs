//! Bounded direct unlink for one pre-qualified regular file.
//!
//! Callers must hold the cleanup writer lock and the lease mutation scope
//! throughout qualification and this operation. The identity check and
//! `unlinkat` are separate POSIX calls, so this primitive does not eliminate
//! the race with a process able to replace the directory entry between them.
//! It never follows links, traverses directories, or retries a mismatch.

use std::ffi::{CString, OsStr};
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
    pub mode: u32,
    pub size: u64,
    pub mtime_seconds: i64,
    pub mtime_nanoseconds: i64,
    pub ctime_seconds: i64,
    pub ctime_nanoseconds: i64,
}

impl FileIdentity {
    pub fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            mode: metadata.mode(),
            size: metadata.size(),
            mtime_seconds: metadata.mtime(),
            mtime_nanoseconds: metadata.mtime_nsec(),
            ctime_seconds: metadata.ctime(),
            ctime_nanoseconds: metadata.ctime_nsec(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnlinkOutcome {
    Removed,
    AlreadyMissing,
    IdentityMismatch,
    /// The name was unlinked, but syncing the parent failed. Carries errno.
    RemovedNotSynced(i32),
}

fn component_name(name: &OsStr) -> io::Result<CString> {
    let bytes = name.as_bytes();
    if bytes.is_empty()
        || bytes == b"."
        || bytes == b".."
        || bytes.contains(&b'/')
        || bytes.contains(&0)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unlink target must be exactly one filename component",
        ));
    }
    CString::new(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "filename contains NUL"))
}

// libc exposes POSIX stat field widths per target, so these casts can be
// redundant on Linux and required on Apple platforms.
#[allow(clippy::unnecessary_cast)]
fn stat_mtime_nanoseconds(metadata: &libc::stat) -> i64 {
    metadata.st_mtime_nsec as i64
}

#[allow(clippy::unnecessary_cast)]
fn stat_ctime_nanoseconds(metadata: &libc::stat) -> i64 {
    metadata.st_ctime_nsec as i64
}

#[allow(clippy::unnecessary_cast)]
fn file_identity(metadata: &libc::stat) -> FileIdentity {
    FileIdentity {
        device: metadata.st_dev as u64,
        inode: metadata.st_ino as u64,
        mode: metadata.st_mode as u32,
        size: metadata.st_size as u64,
        mtime_seconds: metadata.st_mtime,
        mtime_nanoseconds: stat_mtime_nanoseconds(metadata),
        ctime_seconds: metadata.st_ctime,
        ctime_nanoseconds: stat_ctime_nanoseconds(metadata),
    }
}

fn stat_at(parent: &OwnedFd, name: &CString) -> io::Result<libc::stat> {
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: name is NUL-terminated, parent is a live owned descriptor, and
    // metadata points to writable storage for libc::stat.
    let result = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstatat returned success and initialized the output structure.
    Ok(unsafe { metadata.assume_init() })
}

/// Unlink one inventoried, single-link regular file relative to a pinned
/// parent directory. The parent directory remains open for this call.
// libc's device field has target-dependent POSIX integer widths.
#[allow(clippy::unnecessary_cast)]
pub fn unlink_regular_file(
    parent: &OwnedFd,
    name: &OsStr,
    expected: &FileIdentity,
) -> io::Result<UnlinkOutcome> {
    let name = component_name(name)?;
    let mut parent_stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: parent is a live owned descriptor and parent_stat is writable.
    let result = unsafe { libc::fstat(parent.as_raw_fd(), parent_stat.as_mut_ptr()) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstat returned success and initialized the output structure.
    let parent_stat = unsafe { parent_stat.assume_init() };
    if parent_stat.st_mode & libc::S_IFMT != libc::S_IFDIR {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "pinned parent descriptor is not a directory",
        ));
    }

    let observed = match stat_at(parent, &name) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(UnlinkOutcome::AlreadyMissing)
        }
        Err(error) => return Err(error),
    };
    let parent_device = parent_stat.st_dev as u64;
    if observed.st_mode & libc::S_IFMT != libc::S_IFREG
        || observed.st_dev as u64 != parent_device
        || observed.st_nlink != 1
        || file_identity(&observed) != *expected
        || expected.device != parent_device
    {
        return Ok(UnlinkOutcome::IdentityMismatch);
    }

    // SAFETY: name is a validated single component. Flags are zero, so unlinkat
    // cannot remove a directory and cannot traverse the final component.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } != 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::NotFound {
            return Ok(UnlinkOutcome::AlreadyMissing);
        }
        return Err(error);
    }

    // Removal has happened, but durability is not confirmed unless the
    // containing directory also syncs successfully.
    // SAFETY: parent remains an open directory descriptor.
    if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
        let error = io::Error::last_os_error();
        return Ok(UnlinkOutcome::RemovedNotSynced(
            error.raw_os_error().unwrap_or(libc::EIO),
        ));
    }
    Ok(UnlinkOutcome::Removed)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    use std::ffi::OsString;
    use std::fs;
    use std::os::fd::FromRawFd;
    #[cfg(target_os = "linux")]
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(
                std::env::var_os("DISKM_SCRATCH_TEST_DIR")
                    .expect("set DISKM_SCRATCH_TEST_DIR to registered Scratch tmp"),
            )
            .join(format!(
                "direct-file-unlink-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
        }

        fn parent(&self) -> OwnedFd {
            let path = CString::new(self.0.as_os_str().as_bytes()).unwrap();
            // SAFETY: path is NUL-terminated, flags request a directory fd, and
            // successful open returns ownership to OwnedFd.
            let raw = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
            assert!(raw >= 0, "{}", io::Error::last_os_error());
            // SAFETY: raw was returned by open and is not wrapped elsewhere.
            unsafe { OwnedFd::from_raw_fd(raw) }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn unlink(
        fixture: &Fixture,
        name: &OsStr,
        identity: &FileIdentity,
    ) -> io::Result<UnlinkOutcome> {
        unlink_regular_file(&fixture.parent(), name, identity)
    }

    #[test]
    fn unlinks_matching_regular_file_and_reports_already_missing() {
        let fixture = Fixture::new();
        let path = fixture.0.join("ordinary");
        fs::write(&path, b"direct file fixture").unwrap();
        let identity = FileIdentity::from_metadata(&fs::symlink_metadata(&path).unwrap());

        assert_eq!(
            unlink(&fixture, OsStr::new("ordinary"), &identity).unwrap(),
            UnlinkOutcome::Removed
        );
        assert!(!path.exists());
        assert_eq!(
            unlink(&fixture, OsStr::new("ordinary"), &identity).unwrap(),
            UnlinkOutcome::AlreadyMissing
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn accepts_a_non_utf8_single_component() {
        let fixture = Fixture::new();
        let raw = OsString::from_vec(b"raw-\xff".to_vec());
        let path = fixture.0.join(&raw);
        fs::write(&path, b"direct file fixture").unwrap();
        let identity = FileIdentity::from_metadata(&fs::symlink_metadata(&path).unwrap());
        assert_eq!(
            unlink(&fixture, &raw, &identity).unwrap(),
            UnlinkOutcome::Removed
        );
        assert!(!path.exists());
    }

    #[test]
    fn replacement_size_or_mode_is_rejected() {
        let fixture = Fixture::new();
        let path = fixture.0.join("changed");
        fs::write(&path, b"direct file fixture").unwrap();
        let identity = FileIdentity::from_metadata(&fs::symlink_metadata(&path).unwrap());
        fs::write(&path, b"replacement is longer than the original").unwrap();
        let changed = FileIdentity::from_metadata(&fs::symlink_metadata(&path).unwrap());
        assert_eq!(changed.inode, identity.inode);
        assert_ne!(changed.size, identity.size);
        assert_eq!(
            unlink(&fixture, OsStr::new("changed"), &identity).unwrap(),
            UnlinkOutcome::IdentityMismatch
        );
        assert!(path.exists());
        let mut wrong_mode = changed;
        wrong_mode.mode |= 0o100;
        assert_eq!(
            unlink(&fixture, OsStr::new("changed"), &wrong_mode).unwrap(),
            UnlinkOutcome::IdentityMismatch
        );
        assert!(path.exists());
    }

    #[test]
    fn symlink_directory_hardlink_and_bad_components_are_rejected() {
        let fixture = Fixture::new();
        let target = fixture.0.join("target");
        fs::write(&target, b"target").unwrap();
        let symlink_path = fixture.0.join("link");
        symlink(&target, &symlink_path).unwrap();
        let target_identity = FileIdentity::from_metadata(&fs::symlink_metadata(&target).unwrap());
        assert_eq!(
            unlink(&fixture, OsStr::new("link"), &target_identity).unwrap(),
            UnlinkOutcome::IdentityMismatch
        );
        let dir = fixture.0.join("dir");
        fs::create_dir(&dir).unwrap();
        let dir_identity = FileIdentity::from_metadata(&fs::symlink_metadata(&dir).unwrap());
        assert_eq!(
            unlink(&fixture, OsStr::new("dir"), &dir_identity).unwrap(),
            UnlinkOutcome::IdentityMismatch
        );
        let linked = fixture.0.join("linked");
        fs::hard_link(&target, &linked).unwrap();
        let target_identity = FileIdentity::from_metadata(&fs::symlink_metadata(&target).unwrap());
        assert_eq!(
            unlink(&fixture, OsStr::new("target"), &target_identity).unwrap(),
            UnlinkOutcome::IdentityMismatch
        );
        assert!(target.exists());
        for bad in [
            OsStr::new(""),
            OsStr::new("."),
            OsStr::new(".."),
            OsStr::new("a/b"),
        ] {
            assert_eq!(
                unlink(&fixture, bad, &target_identity).unwrap_err().kind(),
                io::ErrorKind::InvalidInput
            );
        }
    }
}

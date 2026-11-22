//! Identity-bound transaction for removing one selected Scratch file.
//! The caller persists the unique stage name in its intent before invoking us.

use serde::Serialize;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct FileIdentity {
    pub device: u64,
    pub inode: u64,
    pub size: u64,
    pub modified_seconds: i64,
    pub modified_nanoseconds: i64,
    pub changed_seconds: i64,
    pub changed_nanoseconds: i64,
    pub link_count: u64,
}

impl FileIdentity {
    fn read(meta: &fs::Metadata) -> Self {
        Self {
            device: meta.dev(),
            inode: meta.ino(),
            size: meta.size(),
            modified_seconds: meta.mtime(),
            modified_nanoseconds: meta.mtime_nsec(),
            changed_seconds: meta.ctime(),
            changed_nanoseconds: meta.ctime_nsec(),
            link_count: meta.nlink(),
        }
    }

    fn matches(self, current: Self) -> bool {
        self.device == current.device
            && self.inode == current.inode
            && self.size == current.size
            && self.modified_seconds == current.modified_seconds
            && self.modified_nanoseconds == current.modified_nanoseconds
            && self.changed_seconds == current.changed_seconds
            && self.changed_nanoseconds == current.changed_nanoseconds
            && self.link_count == current.link_count
    }

    fn matches_after_rename(self, current: Self) -> bool {
        self.device == current.device
            && self.inode == current.inode
            && self.size == current.size
            && self.modified_seconds == current.modified_seconds
            && self.modified_nanoseconds == current.modified_nanoseconds
            && self.link_count == current.link_count
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum Outcome {
    Removed { bytes: u64, parent_synced: bool },
    AlreadyAbsent,
    Changed,
    RestoredMismatch,
    DeferredOpen { open_pids: Vec<u32> },
    DeferredCheck { reason: String },
    RecoveryRequired { stage_created: bool, reason: String },
    Unsupported { reason: String },
}

/// Remove one nominated single-link regular file from the captured Scratch root.
/// This helper neither qualifies age nor establishes lease or evidence policy.
pub fn remove_exact(
    root: &Path,
    root_device: u64,
    root_inode: u64,
    relative: &Path,
    expected: FileIdentity,
    stage_name: &OsStr,
) -> io::Result<Outcome> {
    validate_basename(stage_name)?;
    if relative.as_os_str().is_empty()
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "selected path must be a normalized relative path",
        ));
    }
    if expected.device != root_device || expected.link_count != 1 {
        return Ok(Outcome::Unsupported {
            reason: "only nominated single-link files on the Scratch device are supported".into(),
        });
    }
    let (parent, source) = match open_parent(root, root_device, root_inode, relative) {
        Ok(result) => result,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Outcome::AlreadyAbsent),
        Err(error) => return Err(error),
    };
    let stage = CString::new(stage_name.as_bytes())?;
    remove_from_parent(
        &parent, &source, &stage, root, relative, expected, stage_name,
    )
}

fn remove_from_parent(
    parent: &File,
    source_name: &CString,
    stage: &CString,
    root: &Path,
    relative: &Path,
    expected: FileIdentity,
    stage_os: &OsStr,
) -> io::Result<Outcome> {
    let fd = parent.as_raw_fd();
    let source = match open_regular(fd, source_name) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Outcome::AlreadyAbsent),
        Err(error) => return Err(error),
    };
    if !expected.matches(FileIdentity::read(&source.metadata()?)) {
        return Ok(Outcome::Changed);
    }
    if stage.as_bytes() == source_name.as_bytes() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "transaction stage must differ from the selected filename",
        ));
    }
    verify_parent(root, relative, parent)?;
    if let Err(error) = rename_exclusive(fd, source_name, stage) {
        if error.kind() == io::ErrorKind::NotFound {
            return Ok(Outcome::AlreadyAbsent);
        }
        if error.kind() == io::ErrorKind::AlreadyExists {
            return Ok(Outcome::RecoveryRequired {
                stage_created: false,
                reason: "pre-recorded stage name is occupied".into(),
            });
        }
        return Err(error);
    }
    if let Err(error) = parent.sync_all() {
        return Ok(recovery(
            stage_os,
            true,
            &format!("cannot sync staged rename: {error}"),
        ));
    }
    // Rename changes ctime, so compare inode, link count, size, and mtime only.
    if !expected.matches_after_rename(FileIdentity::read(&source.metadata()?)) {
        return restore_or_recover(parent, stage, source_name, stage_os, &source);
    }
    if let Err(error) = verify_parent(root, relative, parent) {
        return Ok(recovery(
            stage_os,
            true,
            &format!("source parent changed: {error}"),
        ));
    }
    let absolute_stage = root
        .join(relative.parent().unwrap_or_else(|| Path::new("")))
        .join(stage_os);
    let open_pids = match open_file_processes(&absolute_stage) {
        Ok(pids) => pids,
        Err(error) => {
            return match restore_original(parent, stage, source_name, &source) {
                Ok(()) => Ok(Outcome::DeferredCheck {
                    reason: format!("open-file check unavailable: {error}"),
                }),
                Err(restore) => Ok(recovery(
                    stage_os,
                    true,
                    &format!("open-file check unavailable: {error}; restore failed: {restore}"),
                )),
            };
        }
    };
    let current = std::process::id();
    let other_pids: Vec<_> = open_pids
        .into_iter()
        .filter(|pid| *pid != current)
        .collect();
    if !other_pids.is_empty() {
        return match restore_original(parent, stage, source_name, &source) {
            Ok(()) => Ok(Outcome::DeferredOpen {
                open_pids: other_pids,
            }),
            Err(error) => Ok(recovery(
                stage_os,
                true,
                &format!("file open and restore failed: {error}"),
            )),
        };
    }
    let staged = match open_regular(fd, stage) {
        Ok(file) => file,
        Err(error) => {
            return Ok(recovery(
                stage_os,
                true,
                &format!("cannot verify staged identity: {error}"),
            ))
        }
    };
    if !expected.matches_after_rename(FileIdentity::read(&staged.metadata()?)) {
        drop(staged);
        return restore_or_recover(parent, stage, source_name, stage_os, &source);
    }
    if let Err(error) = verify_parent(root, relative, parent) {
        drop(staged);
        return Ok(recovery(
            stage_os,
            true,
            &format!("staged parent changed: {error}"),
        ));
    }
    let named_staged = match open_regular(fd, stage) {
        Ok(file) => file,
        Err(error) => {
            return Ok(recovery(
                stage_os,
                true,
                &format!("cannot revalidate staged name: {error}"),
            ))
        }
    };
    if !expected.matches_after_rename(FileIdentity::read(&named_staged.metadata()?)) {
        return Ok(recovery(
            stage_os,
            true,
            "staged name now identifies another entry",
        ));
    }
    drop(named_staged);
    drop(staged);
    drop(source);
    if unsafe { libc::unlinkat(fd, stage.as_ptr(), 0) } != 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::NotFound {
            return Ok(Outcome::AlreadyAbsent);
        }
        return Ok(recovery(
            stage_os,
            true,
            &format!("staged unlink failed: {error}"),
        ));
    }
    Ok(Outcome::Removed {
        bytes: expected.size,
        parent_synced: parent.sync_all().is_ok(),
    })
}

/// Restore a captured stage entry to its original basename without replacement.
pub fn restore_exact(
    root: &Path,
    root_device: u64,
    root_inode: u64,
    relative: &Path,
    expected: FileIdentity,
    stage_name: &OsStr,
) -> io::Result<bool> {
    validate_basename(stage_name)?;
    if relative.as_os_str().is_empty()
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "selected path must be a normalized relative path",
        ));
    }
    let (parent, original) = match open_parent(root, root_device, root_inode, relative) {
        Ok(result) => result,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    let stage = CString::new(stage_name.as_bytes())?;
    verify_parent(root, relative, &parent)?;
    let staged = match open_regular(parent.as_raw_fd(), &stage) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if !expected.matches_after_rename(FileIdentity::read(&staged.metadata()?)) {
        return Err(io::Error::other(
            "staged file identity differs from the durable transaction",
        ));
    }
    drop(staged);
    rename_exclusive(parent.as_raw_fd(), &stage, &original)?;
    parent.sync_all()?;
    Ok(true)
}

fn open_parent(
    root: &Path,
    root_device: u64,
    root_inode: u64,
    relative: &Path,
) -> io::Result<(File, CString)> {
    let root_fd = open_directory(root).map_err(|error| {
        io::Error::other(format!("registered Scratch root unavailable: {error}"))
    })?;
    let metadata = root_fd.metadata()?;
    if !metadata.is_dir() || metadata.dev() != root_device || metadata.ino() != root_inode {
        return Err(io::Error::other("registered Scratch root identity changed"));
    }
    let mut parent = root_fd;
    let mut components = relative.components().peekable();
    while let Some(Component::Normal(name)) = components.next() {
        if components.peek().is_none() {
            return Ok((parent, CString::new(name.as_bytes())?));
        }
        parent = open_child(parent.as_raw_fd(), name)?;
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        "selected path has no filename",
    ))
}

fn restore_original(
    parent: &File,
    stage: &CString,
    original: &CString,
    opened: &File,
) -> io::Result<()> {
    let wanted = FileIdentity::read(&opened.metadata()?);
    let staged = open_regular(parent.as_raw_fd(), stage)?;
    if !wanted.matches_after_rename(FileIdentity::read(&staged.metadata()?)) {
        return Err(io::Error::other(
            "staged pathname was replaced before restore",
        ));
    }
    drop(staged);
    rename_exclusive(parent.as_raw_fd(), stage, original)?;
    parent.sync_all()
}

fn verify_parent(root: &Path, relative: &Path, descriptor: &File) -> io::Result<()> {
    let parent = root.join(relative.parent().unwrap_or_else(|| Path::new("")));
    let path_metadata = fs::symlink_metadata(parent)?;
    let descriptor_metadata = descriptor.metadata()?;
    if !path_metadata.is_dir()
        || path_metadata.file_type().is_symlink()
        || (path_metadata.dev(), path_metadata.ino())
            != (descriptor_metadata.dev(), descriptor_metadata.ino())
    {
        return Err(io::Error::other("source parent identity changed"));
    }
    Ok(())
}

fn restore_or_recover(
    parent: &File,
    stage: &CString,
    source: &CString,
    stage_os: &OsStr,
    opened: &File,
) -> io::Result<Outcome> {
    match restore_original(parent, stage, source, opened) {
        Ok(()) => Ok(Outcome::RestoredMismatch),
        Err(error) => Ok(recovery(
            stage_os,
            true,
            &format!("identity mismatch and restore failed: {error}"),
        )),
    }
}

fn recovery(_stage: &OsStr, stage_created: bool, reason: &str) -> Outcome {
    Outcome::RecoveryRequired {
        stage_created,
        reason: reason.to_owned(),
    }
}

fn open_directory(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

fn open_child(parent_fd: libc::c_int, name: &OsStr) -> io::Result<File> {
    let name = CString::new(name.as_bytes())?;
    let fd = unsafe {
        libc::openat(
            parent_fd,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn open_regular(parent_fd: libc::c_int, name: &CString) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            parent_fd,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "selected path is not a regular file",
        ));
    }
    Ok(file)
}

fn validate_basename(value: &OsStr) -> io::Result<()> {
    let mut parts = Path::new(value).components();
    if !matches!(parts.next(), Some(Component::Normal(_))) || parts.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "transaction stage must be a basename",
        ));
    }
    Ok(())
}

fn rename_exclusive(parent: libc::c_int, old: &CString, new: &CString) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            parent,
            old.as_ptr(),
            parent,
            new.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            parent,
            old.as_ptr(),
            parent,
            new.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    return Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "exclusive rename unsupported",
    ));
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn open_file_processes(path: &Path) -> io::Result<Vec<u32>> {
    #[cfg(target_os = "linux")]
    let lsof = "/usr/bin/lsof";
    #[cfg(target_os = "macos")]
    let lsof = "/usr/sbin/lsof";
    let mut child = Command::new(lsof)
        .args(["-nP", "-t", "--"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let mut stdout = String::new();
            let mut stderr = String::new();
            std::io::Read::read_to_string(
                &mut std::io::BufReader::new(
                    child
                        .stdout
                        .take()
                        .ok_or_else(|| io::Error::other("lsof stdout unavailable"))?,
                ),
                &mut stdout,
            )?;
            std::io::Read::read_to_string(
                &mut std::io::BufReader::new(
                    child
                        .stderr
                        .take()
                        .ok_or_else(|| io::Error::other("lsof stderr unavailable"))?,
                ),
                &mut stderr,
            )?;
            if status.success() && stderr.is_empty() {
                let pids: Vec<u32> = stdout
                    .lines()
                    .map(|line| line.parse::<u32>().map_err(io::Error::other))
                    .collect::<io::Result<_>>()?;
                if pids.is_empty() {
                    return Err(io::Error::other(
                        "lsof exited successfully without a process list",
                    ));
                }
                return Ok(pids);
            }
            if status.code() == Some(1) && stdout.is_empty() && stderr.is_empty() {
                return Ok(Vec::new());
            }
            return Err(io::Error::other(format!("lsof failed: {}", stderr.trim())));
        }
        if started.elapsed() > Duration::from_secs(3) {
            child.kill()?;
            child.wait()?;
            return Err(io::Error::new(io::ErrorKind::TimedOut, "lsof timeout"));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

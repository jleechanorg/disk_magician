//! Identity-bound transaction for removing one selected Scratch file.
//! The caller persists the unique stage name in its intent before invoking us.

use serde::Serialize;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path};
use std::process::{Command, ExitStatus, Stdio};
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
    pub(crate) fn read(meta: &fs::Metadata) -> Self {
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

    pub(crate) fn matches_after_rename(self, current: Self) -> bool {
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
    Removed {
        allocated_bytes: u64,
        parent_synced: bool,
    },
    AlreadyAbsent,
    Changed,
    RestoredMismatch,
    DeferredOpen {
        open_pids: Vec<u32>,
    },
    DeferredCheck {
        reason: String,
    },
    RecoveryRequired {
        stage_created: bool,
        reason: String,
    },
    Unsupported {
        reason: String,
    },
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
    bind_stage: impl FnOnce((u64, u64)) -> io::Result<()>,
) -> io::Result<Outcome> {
    validate_basename(stage_name)?;
    if expected.device != root_device || expected.link_count != 1 {
        return Ok(Outcome::Unsupported {
            reason: "only nominated single-link files on the Scratch device are supported".into(),
        });
    }
    let (anchor, parent, source) = match open_parent(root, root_device, root_inode, relative) {
        Ok(result) => result,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Outcome::AlreadyAbsent),
        Err(error) => return Err(error),
    };
    if !protected_anchor(&anchor)? {
        return Ok(Outcome::Unsupported {
            reason: "unsafe-staging-root".into(),
        });
    }
    remove_from_parent(
        (&anchor, &parent),
        &source,
        root,
        relative,
        expected,
        stage_name,
        bind_stage,
    )
}

fn remove_from_parent(
    directories: (&File, &File),
    original: &CString,
    root: &Path,
    relative: &Path,
    expected: FileIdentity,
    stage_name: &OsStr,
    bind_stage: impl FnOnce((u64, u64)) -> io::Result<()>,
) -> io::Result<Outcome> {
    let (anchor, parent) = directories;
    let parent_fd = parent.as_raw_fd();
    let source = match open_regular(parent_fd, original) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Outcome::AlreadyAbsent),
        Err(error) => return Err(error),
    };
    if !expected.matches(FileIdentity::read(&source.metadata()?)) {
        return Ok(Outcome::Changed);
    }
    let stage = CString::new(stage_name.as_bytes())?;
    verify_parent(root, relative, parent)?;
    if unsafe { libc::mkdirat(anchor.as_raw_fd(), stage.as_ptr(), 0o700) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let private = open_private(anchor.as_raw_fd(), stage_name)?;
    let private_fd = private.as_raw_fd();
    anchor.sync_all()?;
    let metadata = private.metadata()?;
    bind_stage((metadata.dev(), metadata.ino()))?;
    if let Err(error) = rename_exclusive(parent_fd, original, private_fd, c"item") {
        remove_stage_dir(anchor, &stage)?;
        return if error.kind() == io::ErrorKind::NotFound {
            Ok(Outcome::AlreadyAbsent)
        } else {
            Err(error)
        };
    }
    parent.sync_all()?;
    private.sync_all()?;
    let restore = |outcome| match restore_private(anchor, parent, &private, &stage, original) {
        Ok(()) => Ok(outcome),
        Err(error) => Ok(recovery(&format!("cannot restore captured entry: {error}"))),
    };
    let captured = match open_regular(private_fd, c"item") {
        Ok(file) => file,
        Err(_) => return restore(Outcome::RestoredMismatch),
    };
    if !expected.matches_after_rename(FileIdentity::read(&captured.metadata()?)) {
        return restore(Outcome::RestoredMismatch);
    }
    let stage_path = root.join(stage_name);
    verify_parent(root, relative, parent)?;
    verify_parent(root, &Path::new(stage_name).join("item"), &private)?;
    let pids = match open_file_processes(&stage_path.join("item")) {
        Ok(pids) => pids
            .into_iter()
            .filter(|pid| *pid != std::process::id())
            .collect::<Vec<_>>(),
        Err(error) => {
            return restore(Outcome::DeferredCheck {
                reason: error.to_string(),
            })
        }
    };
    if !pids.is_empty() {
        return restore(Outcome::DeferredOpen { open_pids: pids });
    }
    verify_parent(root, relative, parent)?;
    verify_parent(root, &Path::new(stage_name).join("item"), &private)?;
    let staged = open_regular(private_fd, c"item")?;
    if !expected.matches_after_rename(FileIdentity::read(&staged.metadata()?)) {
        return restore(Outcome::RestoredMismatch);
    }
    let allocated_bytes = staged.metadata()?.blocks().saturating_mul(512);
    if unsafe { libc::unlinkat(private_fd, c"item".as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(Outcome::Removed {
        allocated_bytes,
        parent_synced: private
            .sync_all()
            .and_then(|()| remove_stage_dir(anchor, &stage))
            .is_ok(),
    })
}

fn remove_stage_dir(parent: &File, stage: &CString) -> io::Result<()> {
    if unsafe { libc::unlinkat(parent.as_raw_fd(), stage.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(io::Error::last_os_error());
    }
    parent.sync_all()
}

fn restore_private(
    anchor: &File,
    parent: &File,
    private: &File,
    stage: &CString,
    original: &CString,
) -> io::Result<()> {
    rename_exclusive(private.as_raw_fd(), c"item", parent.as_raw_fd(), original)?;
    private.sync_all()?;
    parent.sync_all()?;
    remove_stage_dir(anchor, stage)
}

fn open_private(parent: libc::c_int, name: &OsStr) -> io::Result<File> {
    let directory = open_child(parent, name)?;
    let metadata = directory.metadata()?;
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "staging directory ownership or mode changed",
        ));
    }
    Ok(directory)
}

/// Restore a captured stage entry to its original basename without replacement.
pub fn restore_exact(
    root: &Path,
    root_device: u64,
    root_inode: u64,
    relative: &Path,
    expected: FileIdentity,
    stage_name: &OsStr,
    stage_identity: Option<(u64, u64)>,
) -> io::Result<Option<FileIdentity>> {
    validate_basename(stage_name)?;
    let (root_fd, parent, original) = match open_parent(root, root_device, root_inode, relative) {
        Ok(result) => result,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let stage = CString::new(stage_name.as_bytes())?;
    verify_parent(root, relative, &parent)?;
    let anchored = root_stage(stage_name);
    let anchor = if anchored { &root_fd } else { &parent };
    if anchored && !protected_anchor(anchor)? {
        return Err(io::Error::other("staging root is no longer protected"));
    }
    if let Ok(private) = open_private(anchor.as_raw_fd(), stage_name) {
        let metadata = private.metadata()?;
        if stage_identity != Some((metadata.dev(), metadata.ino())) {
            return Err(io::Error::other(
                "staging directory identity differs from intent",
            ));
        }
        let staged = match open_regular(private.as_raw_fd(), c"item") {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                remove_stage_dir(anchor, &stage)?;
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        let captured = FileIdentity::read(&staged.metadata()?);
        restore_private(anchor, &parent, &private, &stage, &original)?;
        return Ok(Some(captured));
    }
    if anchored || stage_identity.is_some() {
        return Ok(None);
    }
    let staged = match open_regular(parent.as_raw_fd(), &stage) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !expected.matches_after_rename(FileIdentity::read(&staged.metadata()?)) {
        return Err(io::Error::other(
            "staged file identity differs from the durable transaction",
        ));
    }
    drop(staged);
    rename_exclusive(parent.as_raw_fd(), &stage, parent.as_raw_fd(), &original)?;
    parent.sync_all()?;
    Ok(Some(expected))
}

fn open_parent(
    root: &Path,
    root_device: u64,
    root_inode: u64,
    relative: &Path,
) -> io::Result<(File, File, CString)> {
    let root_fd = open_directory(root).map_err(|error| {
        io::Error::other(format!("registered Scratch root unavailable: {error}"))
    })?;
    let metadata = root_fd.metadata()?;
    if !metadata.is_dir() || metadata.dev() != root_device || metadata.ino() != root_inode {
        return Err(io::Error::other("registered Scratch root identity changed"));
    }
    let mut parent = root_fd.try_clone()?;
    let mut components = relative.components().peekable();
    while let Some(Component::Normal(name)) = components.next() {
        if components.peek().is_none() {
            return Ok((root_fd, parent, CString::new(name.as_bytes())?));
        }
        parent = open_child(parent.as_raw_fd(), name)?;
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        "selected path has no filename",
    ))
}

pub(crate) fn root_stage(name: &OsStr) -> bool {
    name.to_str()
        .and_then(|name| name.strip_prefix(".diskm-remove-"))
        .and_then(|name| name.split_once('-'))
        .is_some_and(|(_, rest)| rest.starts_with("root-"))
}

fn protected_anchor(root: &File) -> io::Result<bool> {
    let metadata = root.metadata()?;
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn acl_get_fd_np(fd: libc::c_int, kind: libc::c_int) -> *mut libc::c_void;
            fn acl_free(value: *mut libc::c_void) -> libc::c_int;
        }
        // The SDK defines ACL_TYPE_EXTENDED as 0x100. APFS reports ENOENT for no ACL.
        let acl = unsafe { acl_get_fd_np(root.as_raw_fd(), 0x100) };
        if !acl.is_null() {
            unsafe { acl_free(acl) };
            return Ok(false);
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT) {
            return Ok(false);
        }
    }
    Ok(
        (metadata.uid() == 0 || metadata.uid() == unsafe { libc::geteuid() })
            && (metadata.mode() & 0o022 == 0 || metadata.mode() & 0o1000 != 0),
    )
}

pub(crate) fn staging_root_protected(root: &Path) -> io::Result<bool> {
    protected_anchor(&open_directory(root)?)
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

fn recovery(reason: &str) -> Outcome {
    Outcome::RecoveryRequired {
        stage_created: true,
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

fn open_regular(parent_fd: libc::c_int, name: &std::ffi::CStr) -> io::Result<File> {
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

fn rename_exclusive(
    from: libc::c_int,
    old: &std::ffi::CStr,
    to: libc::c_int,
    new: &std::ffi::CStr,
) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            from,
            old.as_ptr(),
            to,
            new.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result =
        unsafe { libc::renameatx_np(from, old.as_ptr(), to, new.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub(crate) fn open_file_processes(path: &Path) -> io::Result<Vec<u32>> {
    let Some(stdout) = run_lsof(default_lsof(), &["-nP", "-w", "-t", "--"], Some(path))? else {
        return Ok(Vec::new());
    };
    let pids: Vec<u32> = stdout
        .lines()
        .map(|line| line.parse::<u32>().map_err(io::Error::other))
        .collect::<io::Result<_>>()?;
    if pids.is_empty() {
        return Err(io::Error::other(
            "lsof exited successfully without a process list",
        ));
    }
    Ok(pids)
}

/// Whether any process has a file or working directory at or under `path`,
/// from one listing of every open file. A failed or timed-out probe is an error.
pub fn open_paths(path: &Path) -> io::Result<bool> {
    open_paths_with(path, default_lsof())
}

fn default_lsof() -> &'static Path {
    Path::new(if cfg!(target_os = "linux") {
        "/usr/bin/lsof"
    } else {
        "/usr/sbin/lsof"
    })
}

/// As `open_paths`, with the `lsof` executable named. The listing must parse:
/// every line is a `p` (process) or `n` (name) field.
pub fn open_paths_with(path: &Path, lsof: &Path) -> io::Result<bool> {
    let prefix = path.as_os_str().as_encoded_bytes();
    let Some(listing) = run_lsof(lsof, &["-nP", "-w", "-F", "n"], None)? else {
        return Ok(false);
    };
    let mut found = false;
    for line in listing.lines() {
        match line.as_bytes().first() {
            Some(b'p') => {}
            Some(b'n') => {
                let name = &line.as_bytes()[1..];
                found |= name.starts_with(prefix)
                    && matches!(name.get(prefix.len()), None | Some(b'/' | b' '));
            }
            _ => return Err(io::Error::other("unparsable lsof listing")),
        }
    }
    Ok(found)
}

/// Run a command to completion within `limit`, draining stdout and stderr
/// concurrently so a large listing cannot fill a pipe and stall the child.
/// The whole collection is bounded by `limit`: a descendant that keeps a pipe
/// open after the command exits is killed with its process group, never waited
/// on.
pub fn run_capture(
    command: &mut Command,
    input: Option<String>,
    limit: Duration,
) -> io::Result<(ExitStatus, Vec<u8>, Vec<u8>)> {
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = command.spawn()?;
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        std::thread::spawn(move || stdin.write_all(text.as_bytes()));
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    let drain = |stream: Option<Box<dyn Read + Send>>, is_stdout: bool| {
        let sender = sender.clone();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.read_to_end(&mut bytes);
            }
            let _ = sender.send((is_stdout, bytes));
        });
    };
    drain(child.stdout.take().map(|s| Box::new(s) as _), true);
    drain(child.stderr.take().map(|s| Box::new(s) as _), false);
    drop(sender);
    let group = child.id() as libc::pid_t;
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() > limit {
            unsafe { libc::killpg(group, libc::SIGKILL) };
            child.wait()?;
            return Err(io::Error::new(io::ErrorKind::TimedOut, "probe timeout"));
        }
        std::thread::sleep(crate::time_windows::PROBE_POLL);
    };
    let (mut out, mut err) = (None, None);
    while out.is_none() || err.is_none() {
        match receiver.recv_timeout(limit.saturating_sub(started.elapsed())) {
            Ok((true, bytes)) => out = Some(bytes),
            Ok((false, bytes)) => err = Some(bytes),
            Err(_) => {
                unsafe { libc::killpg(group, libc::SIGKILL) };
                return Err(io::Error::new(io::ErrorKind::TimedOut, "probe timeout"));
            }
        }
    }
    Ok((status, out.unwrap_or_default(), err.unwrap_or_default()))
}

/// Standard output of `lsof`, or `None` when it found nothing. Exit status 1
/// with a listing means some entries could not be read, which `lsof` reports
/// beside a usable listing; any other failure is an error.
fn run_lsof(lsof: &Path, args: &[&str], path: Option<&Path>) -> io::Result<Option<String>> {
    let (status, stdout, stderr) = run_capture(
        Command::new(lsof).args(args).args(path),
        None,
        crate::time_windows::OPEN_FILE_PROBE_TIMEOUT,
    )?;
    let stdout = String::from_utf8_lossy(&stdout).into_owned();
    if !stdout.is_empty() && matches!(status.code(), Some(0 | 1)) {
        return Ok(Some(stdout));
    }
    if status.code() == Some(1) && stderr.is_empty() {
        return Ok(None);
    }
    Err(io::Error::other(format!(
        "lsof failed: {}",
        String::from_utf8_lossy(&stderr).trim()
    )))
}

/// Rename without replacing anything at `to`; fails if `to` exists.
pub fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    let (old, new) = (
        CString::new(from.as_os_str().as_bytes()).map_err(io::Error::other)?,
        CString::new(to.as_os_str().as_bytes()).map_err(io::Error::other)?,
    );
    rename_exclusive(libc::AT_FDCWD, &old, libc::AT_FDCWD, &new)
}

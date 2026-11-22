//! Scratch directory resolution and contained allocation.

use std::ffi::{CString, OsStr};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

const DIRECTORY_FLAGS: i32 = libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;

fn scratch_root() -> io::Result<PathBuf> {
    Ok(crate::verified_scratch_volume(None, false)?.unwrap_or_else(|| "/tmp".into()))
}

// Resolve existing inward symlinks without allowing a nonexistent suffix to
// bypass the containment check. Directory creation below uses anchored dirfds.
fn physical_target(path: &Path) -> io::Result<PathBuf> {
    let mut suffix = Vec::new();
    let mut probe = path;
    loop {
        match fs::canonicalize(probe) {
            Ok(mut resolved) => {
                resolved.extend(suffix.into_iter().rev());
                return Ok(resolved);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if fs::symlink_metadata(probe).is_ok() {
                    return Err(error);
                }
                suffix.push(probe.file_name().ok_or(error)?);
                probe = probe
                    .parent()
                    .ok_or_else(|| io::Error::other("invalid Scratch path"))?;
            }
            Err(error) => return Err(error),
        }
    }
}

fn open_child(fd: RawFd, name: &CString) -> io::Result<OwnedFd> {
    // O_DIRECTORY|O_NOFOLLOW keeps each descent on the checked physical path.
    let child = unsafe { libc::openat(fd, name.as_ptr(), DIRECTORY_FLAGS) };
    if child < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(child) })
}

fn create_contained(root: &Path, target: &Path) -> io::Result<()> {
    let root = fs::canonicalize(root)?;
    let target = physical_target(target)?;
    let relative = target
        .strip_prefix(&root)
        .map_err(|_| io::Error::other("subpath escapes Scratch root"))?;
    let mut directory = OwnedFd::from(
        OpenOptions::new()
            .read(true)
            .custom_flags(DIRECTORY_FLAGS)
            .open(&root)?,
    );
    for part in relative.components() {
        let Component::Normal(name) = part else {
            return Err(io::Error::other("subpath escapes Scratch root"));
        };
        let name = CString::new(name.as_bytes())?;
        let parent = directory.as_raw_fd();
        directory = match open_child(parent, &name) {
            Ok(child) => child,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if unsafe { libc::mkdirat(parent, name.as_ptr(), 0o777) } != 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::AlreadyExists {
                        return Err(error);
                    }
                }
                open_child(parent, &name)?
            }
            Err(error) => return Err(error),
        };
    }
    if !fs::canonicalize(&target)?.starts_with(&root) {
        return Err(io::Error::other("subpath escapes Scratch root"));
    }
    Ok(())
}

pub fn resolve(subpath: Option<&OsStr>, mut out: impl Write) -> io::Result<()> {
    let subpath = subpath
        .map(|value| {
            let bytes = value.as_bytes();
            let stripped = bytes.strip_prefix(b"/").unwrap_or(bytes);
            if stripped.is_empty() || stripped.windows(2).any(|pair| pair == b"..") {
                let detail = if bytes.is_empty() {
                    "(empty)".into()
                } else {
                    value.to_string_lossy()
                };
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("invalid subpath: {detail}"),
                ));
            }
            Ok(Path::new(OsStr::from_bytes(stripped)))
        })
        .transpose()?;
    let root = scratch_root()?;
    let result = if let Some(subpath) = subpath {
        if subpath.is_absolute() {
            return Err(io::Error::other("subpath escapes Scratch root"));
        }
        let target = root.join(subpath);
        create_contained(&root, &target)?;
        if !fs::canonicalize(&target)?.starts_with(fs::canonicalize(&root)?) {
            return Err(io::Error::other("subpath escapes Scratch root"));
        }
        target
    } else {
        root
    };
    out.write_all(result.as_os_str().as_bytes())?;
    out.write_all(b"\n")
}

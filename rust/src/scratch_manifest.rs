use crate::direct_file::{capture_parent, DirectoryIdentity, FileIdentity};
use crate::preview::{possible_dated_run, registered_scratch};
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs::{self, Metadata, OpenOptions};
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::Command;

const NANOS_PER_SECOND: i64 = 1_000_000_000;

#[derive(Serialize)]
pub struct Manifest {
    version: u8,
    root: RootIdentity,
    before_epoch_seconds: i64,
    entries: Vec<Entry>,
}

#[derive(Serialize)]
struct RootIdentity {
    path: PathBuf,
    dev: u64,
    ino: u64,
}

#[derive(Serialize)]
struct Entry {
    path: PathBuf,
    kind: &'static str,
    dev: u64,
    ino: u64,
    size: u64,
    mtime_ns: i64,
    ctime_ns: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    direct: Option<DirectIdentity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    inventory_sha256: Option<String>,
}

#[derive(Serialize)]
struct DirectIdentity {
    parent_dev: u64,
    parent_ino: u64,
    mode: u32,
}

fn timestamp_ns(seconds: i64, nanos: i64) -> io::Result<i64> {
    seconds
        .checked_mul(NANOS_PER_SECOND)
        .and_then(|n| n.checked_add(nanos))
        .ok_or_else(|| io::Error::other("filesystem timestamp is out of range"))
}

// Reuse the same canonical inventory writer as quarantine, so the digest
// covers the file content and inventory metadata that apply will validate.
fn fingerprint_run(path: &Path, cutoff: i64) -> io::Result<String> {
    let output = Command::new(crate::legacy_cli()?)
        .args(["quarantine", "scratch-apply", "--fingerprint-run"])
        .arg(path)
        .arg(cutoff.to_string())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "cannot bind managed run {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim(),
        )));
    }
    let digest = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let digest = digest.trim();
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(io::Error::other(
            "invalid managed-run inventory fingerprint",
        ));
    }
    Ok(digest.to_owned())
}

// An exact path list is a nomination, never a cleanup verdict. The apply side
// independently checks this identity, the exclusive cutoff, and all C14 holds.
pub fn create(paths: &[PathBuf], before_epoch_seconds: i64) -> io::Result<Manifest> {
    if paths.is_empty() {
        return Err(io::Error::other("scratch-manifest needs at least one path"));
    }
    let cutoff_ns = timestamp_ns(before_epoch_seconds, 0)?;
    let (root, dev) = registered_scratch()?;
    let root_meta = fs::symlink_metadata(&root)?;
    if !root_meta.is_dir() || root_meta.dev() != dev {
        return Err(io::Error::other("Scratch root changed during resolution"));
    }
    let root_file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&root)?;
    let root_identity = DirectoryIdentity {
        device: dev,
        inode: root_meta.ino(),
    };
    let mut seen = BTreeSet::new();
    let mut entries = Vec::with_capacity(paths.len());
    for path in paths {
        let relative = path.strip_prefix(&root).map_err(|_| {
            io::Error::other(format!("outside registered Scratch: {}", path.display()))
        })?;
        let metadata = entry_metadata(&root, relative, dev)?;
        let mtime_ns = timestamp_ns(metadata.mtime(), metadata.mtime_nsec())?;
        let (kind, inventory_sha256, direct) = if metadata.is_file() {
            if mtime_ns >= cutoff_ns {
                return Err(io::Error::other(format!(
                    "file is at or after the cutoff: {}",
                    path.display()
                )));
            }
            let parent = capture_parent(
                &root_file,
                root_identity,
                relative,
                FileIdentity::from_metadata(&metadata),
            )?;
            (
                "regular_file",
                None,
                Some(DirectIdentity {
                    parent_dev: parent.device,
                    parent_ino: parent.inode,
                    mode: metadata.mode(),
                }),
            )
        } else if possible_dated_run(&root.join("runs"), path).is_some() {
            (
                "managed_run",
                Some(fingerprint_run(path, before_epoch_seconds)?),
                None,
            )
        } else {
            return Err(io::Error::other(format!(
                "manifest requires a regular file or exact managed run: {}",
                path.display()
            )));
        };
        if !seen.insert(relative) {
            return Err(io::Error::other(format!(
                "duplicate file path: {}",
                path.display()
            )));
        }
        entries.push(Entry {
            path: relative.into(),
            kind,
            dev,
            ino: metadata.ino(),
            size: metadata.len(),
            mtime_ns,
            ctime_ns: timestamp_ns(metadata.ctime(), metadata.ctime_nsec())?,
            direct,
            inventory_sha256,
        });
    }
    let current = fs::symlink_metadata(&root)?;
    if !current.is_dir() || current.dev() != dev || current.ino() != root_meta.ino() {
        return Err(io::Error::other(
            "Scratch root changed while building manifest",
        ));
    }
    Ok(Manifest {
        version: 1,
        root: RootIdentity {
            path: root,
            dev,
            ino: root_meta.ino(),
        },
        before_epoch_seconds,
        entries,
    })
}

fn entry_metadata(root: &Path, relative: &Path, device: u64) -> io::Result<Metadata> {
    let mut current = root.to_path_buf();
    let mut parts = relative.components().peekable();
    if parts.peek().is_none() || relative.to_str().is_none() {
        return Err(io::Error::other(
            "manifest requires a descendant UTF-8 path",
        ));
    }
    while let Some(Component::Normal(name)) = parts.next() {
        current.push(name);
        let metadata = fs::symlink_metadata(&current)?;
        if metadata.dev() != device {
            return Err(io::Error::other(
                "manifest path crosses a filesystem boundary",
            ));
        }
        if parts.peek().is_none() && (metadata.is_file() || metadata.is_dir()) {
            return Ok(metadata);
        }
        if !metadata.is_dir() {
            break;
        }
    }
    Err(io::Error::other(format!(
        "manifest requires a regular file or managed run through real directories: {}",
        relative.display()
    )))
}

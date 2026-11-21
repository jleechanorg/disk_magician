//! Read-only projection of the canonical quarantine index for one manifest entry.

use serde::{Deserialize, Serialize};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

// An index record is a path pointer, not the potentially large sidecar inventory.
const MAX_INDEX_RECORD_BYTES: u64 = 64 * 1024;

#[derive(Serialize)]
pub struct RecoveryHint {
    pub path: String,
    pub recorded_id: Option<String>,
    pub index_status: &'static str,
    pub entry: Option<IndexEntry>,
}

#[derive(Deserialize, Serialize)]
pub struct IndexEntry {
    id: String,
    #[serde(rename(deserialize = "phase", serialize = "index_phase"))]
    phase: String,
    terminal: Option<String>,
}

#[derive(Deserialize)]
struct IndexRecord {
    schema: u8,
    original: PathBuf,
    root_dev: u64,
    root_ino: u64,
    #[serde(flatten)]
    entry: IndexEntry,
}

pub(crate) fn is_quarantine_id(id: &str) -> bool {
    id.len() == 16
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(crate) fn hint(
    root: &Path,
    relative: &str,
    identity: Option<(u64, u64)>,
    recorded_id: Option<&str>,
    writer_available: bool,
) -> RecoveryHint {
    let mut hint = RecoveryHint {
        path: relative.to_owned(),
        recorded_id: recorded_id
            .filter(|id| is_quarantine_id(id))
            .map(str::to_owned),
        index_status: "unavailable",
        entry: None,
    };
    let path = Path::new(relative);
    if !writer_available
        || path.as_os_str().is_empty()
        || !path
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return hint;
    }
    if let Some(identity) = identity {
        if let Ok((status, entry)) =
            find_entry(&root.join(path), identity, hint.recorded_id.as_deref())
        {
            hint.index_status = status;
            hint.entry = entry;
        }
    }
    hint
}

fn index_dir() -> io::Result<PathBuf> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("HOME unavailable for quarantine index"))?;
    let root = match env::var_os("DISK_MAGICIAN_STATE_DIR") {
        Some(value) if value == "~" => home,
        Some(value) => {
            let value = PathBuf::from(value);
            if let Ok(relative) = value.strip_prefix("~") {
                home.join(relative)
            } else {
                value
            }
        }
        None => home.join(".disk_magician_state"),
    };
    Ok(root.join("quarantine-index"))
}

fn find_entry(
    original: &Path,
    identity: (u64, u64),
    recorded_id: Option<&str>,
) -> io::Result<(&'static str, Option<IndexEntry>)> {
    let directory = index_dir()?;
    let before = match fs::symlink_metadata(&directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(("no_match", None)),
        Err(error) => return Err(error),
    };
    let uid = unsafe { libc::geteuid() };
    if !before.is_dir() || before.uid() != uid || before.mode() & 0o077 != 0 {
        return Err(io::Error::other("unsafe quarantine index directory"));
    }
    let mut matched = None;
    for row in fs::read_dir(&directory)? {
        let row = row?;
        let name = row.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_suffix(".json"))
            .filter(|id| is_quarantine_id(id))
        else {
            continue;
        };
        if recorded_id.is_some_and(|expected| expected != id) {
            continue;
        }
        let record = read_index_record(&row.path(), id, uid)?;
        if record.original != original || (record.root_dev, record.root_ino) != identity {
            continue;
        }
        if matched.is_some() {
            return Ok(("ambiguous", None));
        }
        matched = Some(record.entry);
    }
    let after = fs::symlink_metadata(directory)?;
    if (before.dev(), before.ino(), before.mode(), before.uid())
        != (after.dev(), after.ino(), after.mode(), after.uid())
    {
        return Err(io::Error::other("quarantine index changed during lookup"));
    }
    Ok((
        if matched.is_some() {
            "matched"
        } else {
            "no_match"
        },
        matched,
    ))
}

fn read_index_record(path: &Path, id: &str, uid: u32) -> io::Result<IndexRecord> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return Err(io::Error::other("unsafe quarantine index record"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_INDEX_RECORD_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INDEX_RECORD_BYTES {
        return Err(io::Error::other("oversized quarantine index record"));
    }
    let record: IndexRecord = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if record.schema != 1 || record.entry.id != id {
        return Err(io::Error::other("invalid quarantine index identity"));
    }
    Ok(record)
}

//! Append-only native terminal receipts. Each run owns one immutable file.

use serde_json::{json, Value};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn read_bounded(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(io::Error::other(
            "JSON input must be a bounded regular file",
        ));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::other("JSON input exceeds the size limit"));
    }
    Ok(bytes)
}

pub fn read_json_if_exists<T: serde::de::DeserializeOwned>(
    path: &Path,
    limit: u64,
) -> io::Result<Option<T>> {
    let bytes = match read_bounded(path, limit) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(io::Error::other)
}

pub fn state_dir(override_path: Option<&Path>) -> io::Result<PathBuf> {
    let root = override_path
        .map(Path::to_path_buf)
        .or_else(|| {
            std::env::var_os("DISK_MAGICIAN_STATE_DIR")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".disk_magician_state"))
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is unavailable"))?;
    if !root.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "state directory must be absolute",
        ));
    }
    Ok(root)
}

pub fn timestamp(value: SystemTime) -> io::Result<String> {
    let seconds = value
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_secs();
    let seconds = libc::time_t::try_from(seconds).map_err(io::Error::other)?;
    let mut utc = std::mem::MaybeUninit::<libc::tm>::uninit();
    if unsafe { libc::gmtime_r(&seconds, utc.as_mut_ptr()) }.is_null() {
        return Err(io::Error::other("cannot represent receipt timestamp"));
    }
    let utc = unsafe { utc.assume_init() };
    Ok(format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        utc.tm_year + 1900,
        utc.tm_mon + 1,
        utc.tm_mday,
        utc.tm_hour,
        utc.tm_min,
        utc.tm_sec
    ))
}

pub enum Completion<'a> {
    Success,
    Partial(&'a str),
    Error(&'a str),
}

/// Publish a terminal receipt through create-once publication and directory
/// fsync. Concurrent runs never rewrite one another's records or take an
/// application lock. Unknown byte counts stay JSON null.
pub fn publish_terminal(
    state: &Path,
    job: &str,
    started: SystemTime,
    completion: Completion<'_>,
    precondition: Value,
    postcondition: Value,
    publication: Value,
) -> io::Result<Value> {
    if !job
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid job name",
        ));
    }
    let (outcome, reason) = match completion {
        Completion::Success => ("success", None),
        Completion::Partial(reason) => ("partial", Some(reason)),
        Completion::Error(reason) => ("error", Some(reason)),
    };
    let ended = SystemTime::now();
    let run_id = format!(
        "{:x}-{}-{:x}",
        started
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos(),
        std::process::id(),
        ended
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos()
    );
    let started_at = timestamp(started)?;
    let ended_at = timestamp(ended)?;
    let document = json!({
        "schema_version": 1,
        "id": run_id,
        "run_id": run_id,
        "job": job,
        "trigger": std::env::var("DISK_MAGICIAN_TRIGGER").unwrap_or_else(|_| "native".into()),
        "identity": {
            "kind": "native_rust",
            "source_sha": std::env::var("DISKM_SOURCE_SHA").ok(),
            "revision": std::env::var("DISKM_SOURCE_SHA").ok()
        },
        "outcome": outcome,
        "reason": reason,
        "times": {
            "started_at": started_at,
            "ended_at": ended_at,
            "duration_seconds": ended.duration_since(started).map_err(io::Error::other)?.as_secs_f64()
        },
        "safety": {"status":"not_applicable","reason":null,"delegated":false},
        "candidates": {"count":null,"bytes":null},
        "precondition": precondition,
        "postcondition": postcondition,
        "publication": publication,
        "lock": {"held":false,"acquired":false}
    });
    let directory = state.join("receipts").join(job);
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory)?;
    if !fs::symlink_metadata(&directory)?.is_dir() {
        return Err(io::Error::other(
            "receipt directory is not a real directory",
        ));
    }
    let path = directory.join(format!("{run_id}.json"));
    let mut bytes = serde_json::to_vec(&document).map_err(io::Error::other)?;
    bytes.push(b'\n');
    create_once(&path, &bytes)?;
    Ok(document)
}

pub(crate) fn create_once(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let temp = path.with_extension(format!("tmp-{}-{}", std::process::id(), nonce));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = file
        .write_all(bytes)
        .and_then(|()| file.sync_all())
        .and_then(|()| fs::hard_link(&temp, path));
    if let Err(error) = result {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    fs::remove_file(temp)?;
    File::open(
        path.parent()
            .ok_or_else(|| io::Error::other("record has no parent"))?,
    )?
    .sync_all()
}

//! Append-only native terminal receipts. Each run owns one immutable file.

use serde_json::{json, Value};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn state_dir(override_path: Option<&Path>) -> io::Result<PathBuf> {
    let root =
        match override_path {
            Some(path) => path.to_path_buf(),
            None => match std::env::var_os("DISK_MAGICIAN_STATE_DIR") {
                Some(path) => PathBuf::from(path),
                None => PathBuf::from(std::env::var_os("HOME").ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "HOME is unavailable")
                })?)
                .join(".disk_magician_state"),
            },
        };
    if !root.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "state directory must be absolute",
        ));
    }
    Ok(root)
}

pub(crate) fn timestamp(value: SystemTime) -> io::Result<String> {
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
    let temp = directory.join(format!(".{run_id}.tmp"));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    let result = (|| {
        serde_json::to_writer(&mut file, &document).map_err(io::Error::other)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::hard_link(&temp, &path)?;
        fs::remove_file(&temp)?;
        File::open(&directory)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result?;
    Ok(document)
}

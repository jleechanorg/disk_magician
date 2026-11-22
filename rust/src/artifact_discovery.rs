//! Native producer and frame validator for generic Scratch artifact discovery.
//! The caller retains the legacy C14 lease, protection, and actuator checks.

use crate::history::parse_utc;
use crate::preview::possible_dated_run;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

const MARKER: &[u8] = b"diskm-artifact-children-v1";

#[derive(Debug)]
pub enum DiscoveryError {
    MalformedInput,
    LegacyRequired,
    Deadline,
    Io(io::Error),
}

impl DiscoveryError {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::MalformedInput => "malformed-input",
            Self::LegacyRequired => "legacy-required",
            Self::Deadline => "deadline",
            Self::Io(_) => "unmeasurable",
        }
    }
}

impl From<io::Error> for DiscoveryError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

fn expired(deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|deadline| Instant::now() >= deadline)
}

fn parse_roots(mut input: impl Read) -> Result<Vec<PathBuf>, DiscoveryError> {
    let mut bytes = Vec::new();
    input.read_to_end(&mut bytes)?;
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    if bytes.last() != Some(&0) {
        return Err(DiscoveryError::MalformedInput);
    }
    bytes.pop();
    if bytes.is_empty() || bytes.split(|byte| *byte == 0).any(|part| part.is_empty()) {
        return Err(DiscoveryError::MalformedInput);
    }
    Ok(bytes
        .split(|byte| *byte == 0)
        .map(|value| PathBuf::from(std::ffi::OsString::from_vec(value.to_vec())))
        .collect())
}

fn exists_nofollow(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn has_git_marker(path: &Path) -> io::Result<bool> {
    if exists_nofollow(&path.join(".git"))? {
        return Ok(true);
    }
    // A bare repository has all three root markers. Metadata is never traversed.
    for marker in ["HEAD", "objects", "refs"] {
        if !exists_nofollow(&path.join(marker))? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn unicode_managed_run_shape(root: &Path, path: &Path) -> bool {
    // The run name repeats the day. All candidates without Unicode in their
    // name use the fast allocator grammar above.
    if path.file_name().is_none_or(|id| id.as_bytes().is_ascii()) {
        return false;
    }
    let Ok(relative) = path.strip_prefix(root) else {
        return false;
    };
    let mut parts: Vec<_> = relative.components().map(|part| part.as_os_str()).collect();
    if parts.first().is_some_and(|part| *part == "runs") {
        parts.remove(0);
    }
    if parts.len() != 3 {
        return false;
    }
    let (Some(day), Some(id)) = (parts[0].to_str(), parts[2].to_str()) else {
        return false;
    };
    let repo = parts[1].as_bytes();
    if repo.is_empty() || repo.starts_with(b".") {
        return false;
    }
    // The Python parser decides which Unicode scalars are decimal digits.
    let digit_slot = |c: char| c.is_ascii_digit() || !c.is_ascii();
    if day.chars().count() != 8 || !day.chars().all(digit_slot) {
        return false;
    }
    let mut fields = id.rsplitn(4, '-');
    let (Some(nonce), Some(pid), Some(stamp), Some(purpose)) =
        (fields.next(), fields.next(), fields.next(), fields.next())
    else {
        return false;
    };
    let Some(time) = stamp
        .strip_prefix(day)
        .and_then(|rest| rest.strip_prefix('T'))
        .and_then(|rest| rest.strip_suffix('Z'))
    else {
        return false;
    };
    (1..=40).contains(&purpose.len())
        && purpose
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && time.chars().count() == 6
        && time.chars().all(digit_slot)
        && [pid, nonce]
            .iter()
            .all(|value| !value.is_empty() && value.chars().all(digit_slot))
}

fn secure_quarantine_marker(path: &Path) -> bool {
    let run = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => return false,
    };
    let marker_path = path.parent().unwrap_or(path).join(".dm-quarantine");
    let marker = match fs::symlink_metadata(marker_path) {
        Ok(metadata) => metadata,
        Err(_) => return false,
    };
    run.is_dir()
        && !run.file_type().is_symlink()
        && marker.is_dir()
        && !marker.file_type().is_symlink()
        && marker.uid() == unsafe { libc::geteuid() }
        && marker.mode() & 0o7777 == 0o700
}

fn is_managed_run(root: &Path, path: &Path) -> Result<bool, DiscoveryError> {
    let run_roots = [root.to_path_buf(), root.join("runs")];
    if run_roots
        .iter()
        .any(|runs| possible_dated_run(runs, path).is_some())
    {
        let relative = path
            .strip_prefix(root)
            .map_err(|_| io::Error::other("managed run escaped discovery root"))?;
        let mut components: Vec<_> = relative
            .components()
            .map(|component| component.as_os_str().as_bytes())
            .collect();
        if components
            .first()
            .is_some_and(|component| *component == b"runs")
        {
            components.remove(0);
        }
        if components.len() != 3 {
            return Ok(false);
        }
        let day = std::str::from_utf8(components[0])
            .map_err(|_| io::Error::other("invalid managed run date encoding"))?;
        if day.len() != 8 || !day.bytes().all(|byte| byte.is_ascii_digit()) {
            return Ok(false);
        }
        let iso_day = format!("{}-{}-{}", &day[0..4], &day[4..6], &day[6..8]);
        if parse_utc(&format!("{iso_day}T00:00:00Z")).is_none() {
            return Ok(false);
        }
        return Ok(secure_quarantine_marker(path));
    }
    if unicode_managed_run_shape(root, path) && secure_quarantine_marker(path) {
        return Err(DiscoveryError::LegacyRequired);
    }
    Ok(false)
}

// Python str(os.fsdecode(path)) compares Unicode scalar values and maps each
// undecodable byte to U+DC00..U+DCFF. Reproduce that order for traversal.
fn python_path_sort_key(path: &Path) -> Vec<u32> {
    let mut remaining = path.as_os_str().as_bytes();
    let mut key = Vec::new();
    while !remaining.is_empty() {
        match std::str::from_utf8(remaining) {
            Ok(text) => {
                key.extend(text.chars().map(u32::from));
                break;
            }
            Err(error) => {
                let valid = error.valid_up_to();
                if valid > 0 {
                    key.extend(
                        std::str::from_utf8(&remaining[..valid])
                            .unwrap()
                            .chars()
                            .map(u32::from),
                    );
                }
                let count = error.error_len().unwrap_or(remaining.len() - valid);
                for byte in &remaining[valid..valid + count] {
                    key.push(0xdc00 + u32::from(*byte));
                }
                remaining = &remaining[valid + count..];
            }
        }
    }
    key
}

fn discover_root(root: &Path, deadline: Option<Instant>) -> Result<Vec<PathBuf>, DiscoveryError> {
    let root_info = fs::symlink_metadata(root)?;
    if !root_info.is_dir() || root_info.file_type().is_symlink() {
        return Err(io::Error::other("submitted root is not a real directory").into());
    }
    if has_git_marker(root)? {
        return Ok(Vec::new());
    }

    let mut results = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(parent) = pending.pop() {
        if expired(deadline) {
            return Err(DiscoveryError::Deadline);
        }
        if has_git_marker(&parent)? {
            continue;
        }

        let entries = fs::read_dir(&parent)?;
        let mut child_directories = Vec::new();
        for entry in entries {
            if expired(deadline) {
                return Err(DiscoveryError::Deadline);
            }
            let entry = entry?;
            let name = entry.file_name();
            if name.as_bytes().starts_with(b".") {
                continue;
            }

            let child = entry.path();
            let metadata = fs::symlink_metadata(&child)?;
            if !metadata.is_dir()
                || metadata.file_type().is_symlink()
                || metadata.dev() != root_info.dev()
            {
                continue;
            }
            results.push(child.clone());
            if !has_git_marker(&child)? && !is_managed_run(root, &child)? {
                child_directories.push(child);
            }
        }
        child_directories.sort_by_key(|child| python_path_sort_key(child));
        pending.extend(child_directories.into_iter().rev());
    }
    Ok(results)
}

/// Consume the submitted roots and write blocked roots as a NUL list.
/// Candidate output is returned only after every root was fully processed.
pub fn discover_batch(
    input: impl Read,
    blocked_out: &Path,
    deadline: Option<Instant>,
) -> Result<Vec<u8>, DiscoveryError> {
    let roots = parse_roots(input)?;
    let mut blocked = Vec::new();
    let mut pairs = Vec::new();
    for root in roots {
        if expired(deadline) {
            return Err(DiscoveryError::Deadline);
        }
        let root_bytes = root.as_os_str().as_bytes().to_vec();
        match discover_root(&root, deadline) {
            Ok(children) => pairs.extend(
                children
                    .into_iter()
                    .map(|child| (root_bytes.clone(), child.as_os_str().as_bytes().to_vec())),
            ),
            Err(DiscoveryError::Deadline) => return Err(DiscoveryError::Deadline),
            Err(DiscoveryError::MalformedInput) => return Err(DiscoveryError::MalformedInput),
            Err(DiscoveryError::LegacyRequired) => return Err(DiscoveryError::LegacyRequired),
            Err(DiscoveryError::Io(_)) => blocked.push(root_bytes),
        }
    }

    let mut frame = Vec::new();
    frame.extend_from_slice(MARKER);
    frame.push(0);
    frame.extend_from_slice(pairs.len().to_string().as_bytes());
    frame.push(0);
    for (parent, child) in pairs {
        frame.extend_from_slice(&parent);
        frame.push(0);
        frame.extend_from_slice(&child);
        frame.push(0);
    }
    let mut blocked_file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(blocked_out)?;
    for root in blocked {
        blocked_file.write_all(&root)?;
        blocked_file.write_all(&[0])?;
    }
    blocked_file.flush()?;
    Ok(frame)
}

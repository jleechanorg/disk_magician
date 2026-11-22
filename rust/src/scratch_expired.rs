//! Hourly removal of Scratch folders whose newest content is past the floor.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// What one complete walk of a unit saw.
#[derive(Default)]
pub struct Observation {
    /// Newest mtime or ctime in nanoseconds, over everything strictly under
    /// the unit plus the unit root's own mtime, excluding `.git` entries.
    pub newest: i64,
    pub complete: bool,
    pub gaps: Vec<String>,
    /// Git directories (`.git` directories or files, bare repositories).
    pub repos: Vec<PathBuf>,
    /// Directories named `evidence`.
    pub evidence: Vec<PathBuf>,
    /// `(alternates file, borrowed object directory)` pairs.
    pub alternates: Vec<(PathBuf, PathBuf)>,
}

fn nanos(seconds: i64, fraction: i64) -> i64 {
    seconds * 1_000_000_000 + fraction
}

fn mtime(info: &fs::Metadata) -> i64 {
    nanos(info.mtime(), info.mtime_nsec())
}

fn alternates_of(git_dir: &Path, found: &mut Observation) {
    let file = git_dir.join("objects/info/alternates");
    if let Ok(text) = fs::read_to_string(&file) {
        for line in text.lines().filter(|line| !line.is_empty()) {
            let target = git_dir.join("objects").join(line);
            found
                .alternates
                .push((file.clone(), fs::canonicalize(&target).unwrap_or(target)));
        }
    }
}

/// Walk `unit` completely. Any gap makes the result incomplete.
pub fn observe(unit: &Path, device: u64, deadline: Instant) -> Observation {
    let mut found = Observation {
        complete: true,
        ..Observation::default()
    };
    match fs::symlink_metadata(unit) {
        Ok(info) => {
            found.newest = mtime(&info);
            if info.is_dir() {
                walk(unit, device, deadline, &mut found);
            }
        }
        Err(error) => found.gaps.push(format!("{}: {error}", unit.display())),
    }
    found.complete = found.gaps.is_empty();
    found
}

fn walk(dir: &Path, device: u64, deadline: Instant, found: &mut Observation) {
    if Instant::now() >= deadline {
        found.gaps.push(format!("{}: deadline", dir.display()));
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) => {
            found.gaps.push(format!("{}: {error}", dir.display()));
            return;
        }
    };
    let mut bare = [false; 3];
    for entry in entries {
        let Ok(entry) = entry else {
            found
                .gaps
                .push(format!("{}: unreadable entry", dir.display()));
            continue;
        };
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            found
                .gaps
                .push(format!("{}: non-UTF-8 name", path.display()));
            continue;
        };
        let info = match fs::symlink_metadata(&path) {
            Ok(info) if info.dev() == device => info,
            Ok(_) => {
                found.gaps.push(format!("{}: other device", path.display()));
                continue;
            }
            Err(error) => {
                found.gaps.push(format!("{}: {error}", path.display()));
                continue;
            }
        };
        match name {
            ".git" => {
                found.repos.push(path.clone());
                alternates_of(&path, found);
                continue;
            }
            "HEAD" if info.is_file() => bare[0] = true,
            "objects" if info.is_dir() => bare[1] = true,
            "refs" if info.is_dir() => bare[2] = true,
            "evidence" if info.is_dir() => found.evidence.push(path.clone()),
            _ => {}
        }
        found.newest = found
            .newest
            .max(mtime(&info))
            .max(nanos(info.ctime(), info.ctime_nsec()));
        if info.is_dir() {
            walk(&path, device, deadline, found);
        }
    }
    if bare == [true; 3] {
        found.repos.push(dir.to_path_buf());
        alternates_of(dir, found);
    }
}

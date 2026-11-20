use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const LEDGER: &str = "reclaim/directory-ledger.json";
const MAX_LEDGER_BYTES: u64 = 32 * 1024 * 1024;
const CHECK_WINDOW_SECONDS: u64 = 20;
pub const MAX_CANDIDATES: usize = 100;

#[derive(Deserialize)]
struct Ledger {
    rows: Vec<HistoryRow>,
}

#[derive(Deserialize)]
struct HistoryRow {
    row_type: String,
    canonical_path: Option<PathBuf>,
}

#[derive(Serialize)]
pub struct Report {
    scratch_root: PathBuf,
    min_hours: u32,
    pub complete: bool,
    recorded_paths: usize,
    candidates: Vec<Candidate>,
}

#[derive(Serialize)]
struct Candidate {
    path: PathBuf,
    source: String,
    verdict: String,
    eligible: bool,
}

fn checker_deadline() -> io::Result<String> {
    // C14 compares its deadline to Python time.monotonic(), not Unix time.
    let output = Command::new("python3")
        .args([
            "-c",
            "import sys,time; print(time.monotonic()+int(sys.argv[1]))",
        ])
        .arg(CHECK_WINDOW_SECONDS.to_string())
        .output()?;
    let value = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let deadline = value.trim();
    if !output.status.success() || !deadline.parse::<f64>().is_ok_and(f64::is_finite) {
        return Err(io::Error::other("cannot obtain C14 monotonic deadline"));
    }
    Ok(deadline.to_owned())
}

fn ledger_paths(state_dir: &Path, root: &Path) -> io::Result<Vec<(PathBuf, String)>> {
    let mut bytes = Vec::new();
    let path = state_dir.join(LEDGER);
    if !fs::symlink_metadata(&path)?.is_file() {
        return Err(io::Error::other(
            "the reclaim ledger must be a regular file",
        ));
    }
    let file = File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::other(
            "the reclaim ledger must be a regular file",
        ));
    }
    file.take(MAX_LEDGER_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_LEDGER_BYTES {
        return Err(io::Error::other(
            "the reclaim ledger exceeds the preview size limit",
        ));
    }
    let ledger: Ledger = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    let mut seen = HashSet::new();
    let mut paths = Vec::new();
    for source in ["cleanup_event", "cleanup_root"] {
        for row in ledger.rows.iter().filter(|row| row.row_type == source) {
            let Some(path) = &row.canonical_path else {
                continue;
            };
            let Ok(relative) = path.strip_prefix(root) else {
                continue;
            };
            if relative.as_os_str().is_empty()
                || !relative
                    .components()
                    .all(|part| matches!(part, Component::Normal(_)))
                || !seen.insert(path.clone())
            {
                continue;
            }
            paths.push((path.clone(), source.to_owned()));
        }
    }
    Ok(paths)
}

fn registered_scratch() -> io::Result<(PathBuf, u64)> {
    let output = Command::new("diskm")
        .args(["volume", "path", "scratch"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("registered Scratch volume is unavailable"));
    }
    let path = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let root = PathBuf::from(path.trim_end_matches(['\n', '\r']));
    if !root.is_absolute() || root == Path::new("/") || fs::canonicalize(&root)? != root {
        return Err(io::Error::other("invalid registered Scratch root"));
    }
    let info = fs::symlink_metadata(&root)?;
    if !info.is_dir() {
        return Err(io::Error::other(
            "registered Scratch root is not a directory",
        ));
    }
    Ok((root, info.dev()))
}

fn check_path(root: &Path, path: &Path, device: u64) -> Option<&'static str> {
    let mut current = root.to_path_buf();
    for part in path
        .strip_prefix(root)
        .expect("ledger paths are in scope")
        .components()
    {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(info) if info.is_symlink() => return Some("kept:symlink"),
            Ok(info) if info.dev() != device => return Some("kept:filesystem-boundary"),
            Ok(info) if !info.is_file() && !info.is_dir() => return Some("kept:unsupported-path"),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Some("missing"),
            Err(_) => return Some("deferred:metadata"),
        }
    }
    None
}

fn current_verdict(path: &Path, deadline: &str, min_hours: u32) -> String {
    let mut command = Command::new("diskm");
    command
        .args(["quarantine", "verdict"])
        .arg(path)
        .args(["--kind", "ephemeral", "--deadline-at", deadline])
        .env_remove("DISK_MAGICIAN_AGE_FLOOR_MINUTES")
        .env_remove("DISK_MAGICIAN_OPERATOR_TARGETS");
    if min_hours == 6 {
        command.env("DISK_MAGICIAN_AGE_FLOOR_MINUTES", "360");
    }
    match command.output() {
        Ok(output) if output.status.success() => {
            let verdict = String::from_utf8_lossy(&output.stdout);
            let verdict = verdict.trim();
            if !verdict.contains(['\r', '\n'])
                && (verdict == "remove"
                    || verdict.starts_with("kept:")
                    || verdict.starts_with("deferred:"))
            {
                return verdict.to_owned();
            }
            "deferred:unexpected-verdict".into()
        }
        _ => "deferred:verdict-unavailable".into(),
    }
}

pub fn preview(state_dir: &Path, min_hours: u32, limit: usize) -> io::Result<Report> {
    let started = Instant::now();
    let deadline = checker_deadline()?;
    let (root, device) = registered_scratch()?;
    let paths = ledger_paths(state_dir, &root)?;
    let recorded_paths = paths.len();
    let mut complete = recorded_paths <= limit;
    let mut candidates = Vec::new();
    for (path, source) in paths.into_iter().take(limit) {
        if started.elapsed() >= Duration::from_secs(CHECK_WINDOW_SECONDS) {
            complete = false;
            break;
        }
        let verdict = check_path(&root, &path, device).map_or_else(
            || current_verdict(&path, &deadline, min_hours),
            str::to_owned,
        );
        complete &= !verdict.starts_with("deferred:");
        let eligible = verdict == "remove";
        candidates.push(Candidate {
            path,
            source,
            verdict,
            eligible,
        });
    }
    Ok(Report {
        scratch_root: root,
        min_hours,
        complete,
        recorded_paths,
        candidates,
    })
}

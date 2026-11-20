use crate::scan::{scan, FileKind, ScanGap, ScanOptions};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const LEDGER: &str = "reclaim/directory-ledger.json";
const MAX_LEDGER_BYTES: u64 = 32 * 1024 * 1024;
const CHECK_WINDOW_SECONDS: u64 = 12;

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
    missing_paths: usize,
    candidates: Vec<Candidate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    discovery: Option<Discovery>,
}

#[derive(Serialize)]
struct Candidate {
    path: PathBuf,
    source: String,
    verdict: String,
    eligible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    apparent_bytes: Option<u64>,
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

fn current_verdict(path: &Path, min_hours: u32) -> String {
    // Use the checker's Python monotonic timebase and stop only the subprocess group
    // created for this read-only verdict. A stalled candidate cannot block siblings.
    let mut command = Command::new("python3");
    command
        .args([
            "-c",
            r#"
import os, signal, subprocess, sys, time
window = int(sys.argv[1])
argv = ["diskm", "quarantine", "verdict", sys.argv[2], "--kind", "ephemeral",
        "--deadline-at", str(time.monotonic() + window)]
child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
try:
    stdout, _ = child.communicate(timeout=window)
except subprocess.TimeoutExpired:
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    print("deferred:deadline")
else:
    sys.stdout.buffer.write(stdout)
    sys.exit(child.returncode)
"#,
        ])
        .arg(CHECK_WINDOW_SECONDS.to_string())
        .arg(path)
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

fn checked_verdict(root: &Path, path: &Path, device: u64, min_hours: u32) -> String {
    if let Some(reason) = check_path(root, path, device) {
        return reason.into();
    }
    let verdict = current_verdict(path, min_hours);
    check_path(root, path, device).map_or(verdict, str::to_owned)
}

pub fn preview(state_dir: &Path, min_hours: u32, limit: usize) -> io::Result<Report> {
    let (root, device) = registered_scratch()?;
    let paths = match ledger_paths(state_dir, &root) {
        Err(error) if min_hours == 6 && error.kind() == io::ErrorKind::NotFound => Vec::new(),
        result => result?,
    };
    if min_hours == 6 {
        return live_preview(root, device, paths, limit);
    }
    let recorded_paths = paths.len();
    let mut complete = true;
    let mut missing_paths = 0;
    let mut missing = Vec::new();
    let mut candidates = Vec::new();
    for (path, source) in paths {
        let checked = check_path(&root, &path, device);
        if checked == Some("missing") {
            missing_paths += 1;
            if missing.len() < limit {
                missing.push(Candidate {
                    path,
                    source,
                    verdict: "missing".into(),
                    eligible: false,
                    apparent_bytes: None,
                });
            }
            continue;
        }
        if candidates.len() == limit {
            complete = false;
            break;
        }
        let verdict = checked.map_or_else(
            || checked_verdict(&root, &path, device, min_hours),
            str::to_owned,
        );
        complete &= !verdict.starts_with("deferred:");
        let eligible = verdict == "remove";
        candidates.push(Candidate {
            path,
            source,
            verdict,
            eligible,
            apparent_bytes: None,
        });
    }
    candidates.extend(missing.into_iter().take(limit - candidates.len()));
    Ok(Report {
        scratch_root: root,
        min_hours,
        complete,
        recorded_paths,
        missing_paths,
        candidates,
        discovery: None,
    })
}

#[derive(Serialize)]
struct Discovery {
    complete: bool,
    files_measured: usize,
    directories_measured: usize,
    measured_apparent_bytes: u64,
    gaps: Vec<ScanGap>,
}

fn protected_scope(root: &Path, path: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return true;
    };
    let mut parts = relative.components();
    let Some(first) = parts.next() else {
        return true;
    };
    first.as_os_str().as_encoded_bytes().starts_with(b".")
        || relative
            .components()
            .any(|part| part.as_os_str() == "evidence")
}

fn live_preview(
    root: PathBuf,
    device: u64,
    history: Vec<(PathBuf, String)>,
    limit: usize,
) -> io::Result<Report> {
    let measured = scan(
        &root,
        ScanOptions {
            deadline: Duration::MAX,
            max_entries: usize::MAX,
        },
    )?;
    let cutoff = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_secs(),
    )
    .map_err(io::Error::other)?
        - 6 * 3600;
    let recorded_paths = history.len();
    let history: HashMap<_, _> = history.into_iter().collect();
    let missing_paths = history
        .keys()
        .filter(|path| check_path(&root, path, device) == Some("missing"))
        .count();
    let repos: HashSet<_> = measured
        .files
        .iter()
        .map(|file| file.path.as_str())
        .chain(measured.directories.iter().map(|dir| dir.path.as_str()))
        .map(Path::new)
        .filter(|path| path.file_name().is_some_and(|name| name == ".git"))
        .filter_map(Path::parent)
        .collect();

    let evidence_containers: HashSet<_> = measured
        .directories
        .iter()
        .map(|dir| Path::new(&dir.path))
        .filter(|path| path.file_name().is_some_and(|name| name == "evidence"))
        .flat_map(|path| path.ancestors())
        .collect();
    let mut proposals = Vec::new();
    let mut selected = HashSet::new();
    let mut protected = Vec::new();
    let inside_repo = |path: &Path| path.ancestors().any(|parent| repos.contains(parent));
    // Directories are lexically sorted by the scanner, so each parent precedes its children.
    for dir in &measured.directories {
        let path = Path::new(&dir.path);
        if dir.path_bytes_hex.is_some()
            || path == root
            || dir.must_itemize != Some(false)
            || protected_scope(&root, path)
            || evidence_containers.contains(path)
            || dir
                .newest_content_epoch_seconds
                .is_none_or(|epoch| epoch > cutoff)
        {
            continue;
        }
        if dir.contains_git || inside_repo(path) {
            if history.contains_key(path) {
                protected.push((
                    path,
                    dir.apparent_bytes,
                    "kept:repository-use-worktree-route",
                ));
            }
            continue;
        }
        if path
            .ancestors()
            .skip(1)
            .any(|parent| selected.contains(parent))
        {
            continue;
        }
        selected.insert(path);
        proposals.push((path, dir.apparent_bytes));
    }
    for file in &measured.files {
        let path = Path::new(&file.path);
        if file.kind == FileKind::File
            && file.path_bytes_hex.is_none()
            && !protected_scope(&root, path)
            && file
                .modified_epoch_seconds
                .is_some_and(|epoch| epoch <= cutoff)
            && !inside_repo(path)
            && !path
                .ancestors()
                .skip(1)
                .any(|parent| selected.contains(parent))
        {
            proposals.push((path, file.apparent_bytes));
        }
    }
    proposals
        .sort_unstable_by(|(a, a_bytes), (b, b_bytes)| b_bytes.cmp(a_bytes).then_with(|| a.cmp(b)));
    let mut complete = measured.complete;
    let candidate = |path: &Path, bytes: u64, verdict: String| Candidate {
        path: path.to_path_buf(),
        source: history
            .get(path)
            .cloned()
            .unwrap_or_else(|| "live_scan".into()),
        eligible: verdict == "remove",
        verdict,
        apparent_bytes: Some(bytes),
    };
    let mut candidates: Vec<_> = proposals
        .into_iter()
        .enumerate()
        .map(|(index, (path, bytes))| {
            let verdict = if index >= limit {
                "deferred:verification-limit".into()
            } else {
                checked_verdict(&root, path, device, 6)
            };
            complete &= !verdict.starts_with("deferred:");
            candidate(path, bytes, verdict)
        })
        .collect();
    candidates.extend(
        protected
            .into_iter()
            .map(|(path, bytes, reason)| candidate(path, bytes, reason.into())),
    );
    Ok(Report {
        scratch_root: root,
        min_hours: 6,
        complete,
        recorded_paths,
        missing_paths,
        candidates,
        discovery: Some(Discovery {
            complete: measured.complete,
            files_measured: measured.files.len(),
            directories_measured: measured.directories.len(),
            measured_apparent_bytes: measured.apparent_bytes,
            gaps: measured.gaps,
        }),
    })
}

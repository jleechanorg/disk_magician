use crate::scan::{scan, FileKind, ScanGap, ScanOptions};
use crate::{preview_scopes, preview_worktrees};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CHECK_WINDOW_SECONDS: u64 = 12;

#[derive(Serialize)]
pub struct Report {
    root: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    scratch_root: Option<PathBuf>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    allocated_bytes: Option<u64>,
}

fn ledger_paths(state_dir: &Path, root: &Path) -> io::Result<Vec<(PathBuf, String)>> {
    let ledger = preview_scopes::read_ledger(state_dir)?;
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

pub(crate) fn registered_scratch() -> io::Result<(PathBuf, u64)> {
    let output = Command::new(crate::LEGACY_CLI)
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
argv = [sys.argv[3], "quarantine", "verdict", sys.argv[2], "--kind", "ephemeral",
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
        .arg(crate::LEGACY_CLI)
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

pub fn preview(
    state_dir: &Path,
    min_hours: u32,
    limit: usize,
    scan_deadline: Duration,
) -> io::Result<Report> {
    let (root, device) = registered_scratch()?;
    let paths = match ledger_paths(state_dir, &root) {
        Err(error) if min_hours == 6 && error.kind() == io::ErrorKind::NotFound => Vec::new(),
        result => result?,
    };
    if min_hours == 6 {
        return live_preview(root, device, paths, min_hours, limit, true, scan_deadline);
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
                    allocated_bytes: None,
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
            allocated_bytes: None,
        });
    }
    candidates.extend(missing.into_iter().take(limit - candidates.len()));
    Ok(Report {
        scratch_root: Some(root.clone()),
        root,
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
    repository_roots: usize,
    measured_apparent_bytes: u64,
    allocated_bytes_semantics: &'static str,
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
    min_hours: u32,
    limit: usize,
    scratch_verdicts: bool,
    scan_deadline: Duration,
) -> io::Result<Report> {
    let measured = scan(
        &root,
        ScanOptions {
            deadline: scan_deadline,
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
        - i64::from(min_hours) * 3600;
    let recorded_paths = history.len();
    let history: HashMap<_, _> = history.into_iter().collect();
    let missing_paths = history
        .keys()
        .filter(|path| check_path(&root, path, device) == Some("missing"))
        .count();
    let mut repos: HashSet<_> = measured
        .files
        .iter()
        .map(|file| file.path.as_str())
        .chain(measured.directories.iter().map(|dir| dir.path.as_str()))
        .map(Path::new)
        .filter(|path| path.file_name().is_some_and(|name| name == ".git"))
        .filter_map(Path::parent)
        .collect();

    // A bare repository has HEAD and objects at its root, with no .git marker.
    // Protect it as a unit because C14 sees an individual pack as just a file.
    let heads: HashSet<_> = measured
        .files
        .iter()
        .map(|file| Path::new(&file.path))
        .filter(|path| path.file_name().is_some_and(|name| name == "HEAD"))
        .filter_map(Path::parent)
        .collect();
    repos.extend(
        measured
            .directories
            .iter()
            .map(|dir| Path::new(&dir.path))
            .filter(|path| path.file_name().is_some_and(|name| name == "objects"))
            .filter_map(Path::parent)
            .filter(|parent| heads.contains(parent)),
    );
    let repo_containers: HashSet<_> = repos.iter().flat_map(|path| path.ancestors()).collect();
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
        if dir.contains_git || inside_repo(path) || repo_containers.contains(path) {
            if history.contains_key(path) {
                protected.push((
                    path,
                    dir.apparent_bytes,
                    dir.path_allocated_bytes,
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
        proposals.push((path, dir.apparent_bytes, dir.path_allocated_bytes));
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
            proposals.push((path, file.apparent_bytes, file.allocated_bytes));
        }
    }
    proposals.sort_unstable_by(|(a, _, a_allocated), (b, _, b_allocated)| {
        b_allocated.cmp(a_allocated).then_with(|| a.cmp(b))
    });
    let mut complete = measured.complete;
    let candidate =
        |path: &Path, apparent_bytes: u64, allocated_bytes: u64, verdict: String| Candidate {
            path: path.to_path_buf(),
            source: history
                .get(path)
                .cloned()
                .unwrap_or_else(|| "live_scan".into()),
            eligible: verdict == "remove",
            verdict,
            apparent_bytes: Some(apparent_bytes),
            allocated_bytes: Some(allocated_bytes),
        };
    let mut candidates: Vec<_> = proposals
        .into_iter()
        .enumerate()
        .map(|(index, (path, apparent_bytes, allocated_bytes))| {
            let verdict = if !scratch_verdicts {
                "deferred:temp-policy".into()
            } else if index >= limit {
                "deferred:verification-limit".into()
            } else {
                checked_verdict(&root, path, device, min_hours)
            };
            complete &= !verdict.starts_with("deferred:");
            candidate(path, apparent_bytes, allocated_bytes, verdict)
        })
        .collect();
    candidates.extend(protected.into_iter().map(
        |(path, apparent_bytes, allocated_bytes, reason)| {
            candidate(path, apparent_bytes, allocated_bytes, reason.into())
        },
    ));
    Ok(Report {
        scratch_root: scratch_verdicts.then(|| root.clone()),
        root,
        min_hours,
        complete,
        recorded_paths,
        missing_paths,
        candidates,
        discovery: Some(Discovery {
            complete: measured.complete,
            files_measured: measured.files.len(),
            directories_measured: measured.directories.len(),
            repository_roots: repos.len(),
            measured_apparent_bytes: measured.apparent_bytes,
            allocated_bytes_semantics: "File values are inode-block allocations for the path. Directory values sum allocations per pathname, so hardlinks/shared blocks may be counted more than once and sibling values are not additive. These estimates prioritize checks but do not predict physical reclaim.",
            gaps: measured.gaps,
        }),
    })
}

pub fn scope_report(
    scope: &str,
    state_dir: Option<&Path>,
    min_hours: u32,
    limit: usize,
    scan_deadline: Duration,
) -> io::Result<Value> {
    let required_state =
        || state_dir.ok_or_else(|| io::Error::other("this scope requires --state-dir"));
    match scope {
        "scratch" => {
            serde_json::to_value(preview(required_state()?, min_hours, limit, scan_deadline)?)
                .map_err(io::Error::other)
        }
        "tmp" => {
            let scopes = preview_scopes::resolve_host_temp_scopes()?;
            let mut reports = Vec::new();
            for temp in scopes.roots {
                let result = (|| {
                    let device = fs::symlink_metadata(&temp.path)?.dev();
                    let history = state_dir
                        .and_then(|state| ledger_paths(state, &temp.path).ok())
                        .unwrap_or_default();
                    live_preview(
                        temp.path.clone(),
                        device,
                        history,
                        min_hours,
                        limit,
                        false,
                        Duration::MAX,
                    )
                })();
                reports.push(match result {
                    Ok(inventory) => json!({"source": temp.source, "inventory": inventory}),
                    Err(error) => json!({"root": temp.path, "source": temp.source, "error": error.to_string()}),
                });
            }
            let policy = match preview_scopes::temp_policy_preview() {
                Ok(report) => serde_json::to_value(report).map_err(io::Error::other)?,
                Err(error) => json!({"error": error.to_string()}),
            };
            Ok(json!({
                "scope": "tmp",
                "roots": reports,
                "scratch_scope_availability": scopes.scratch_scope_availability,
                "policy_preview": policy
            }))
        }
        "worktrees" => {
            serde_json::to_value(preview_worktrees::preview_worktrees()?).map_err(io::Error::other)
        }
        "ledger" => serde_json::to_value(preview_scopes::read_ledger(required_state()?)?)
            .map_err(io::Error::other),
        "all" => {
            let mut reports = serde_json::Map::new();
            for name in ["scratch", "tmp", "worktrees", "ledger"] {
                let report = scope_report(name, state_dir, min_hours, limit, scan_deadline)
                    .unwrap_or_else(|error| json!({"error": error.to_string()}));
                reports.insert(name.into(), report);
            }
            Ok(Value::Object(reports))
        }
        _ => Err(io::Error::other("unknown preview scope")),
    }
}

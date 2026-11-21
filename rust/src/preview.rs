use crate::scan::{
    self, scan, DirectoryMeasurement, FileKind, FileMeasurement, ScanGap, ScanGapKind, ScanOptions,
    ScanReport, ITEMIZATION_THRESHOLD_BYTES,
};
use crate::{preview_scopes, preview_worktrees};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const CHECK_WINDOW_SECONDS: u64 = 12;
const CHECKPOINT_VERSION: u32 = 1;
const CHECKPOINT_MAX_BYTES: u64 = 64 * 1024 * 1024;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    resumable: Option<ResumeSummary>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PendingScan {
    path: String,
    path_bytes_hex: Option<String>,
    kind: String,
    reason: String,
    retries: u32,
    retryable: bool,
}

#[derive(Clone, Debug, Serialize)]
struct ResumeSummary {
    checkpoint: PathBuf,
    scan_passes: u32,
    unfinished_scan_paths: Vec<PendingScan>,
    pending_verdict_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ResumeCheckpoint {
    version: u32,
    root: PathBuf,
    root_device: u64,
    root_inode: u64,
    min_hours: u32,
    cutoff_epoch: i64,
    scan_passes: u32,
    recorded_paths: usize,
    missing_paths: usize,
    candidates: Vec<Candidate>,
    unfinished_scan_paths: Vec<PendingScan>,
    discovery: Option<Discovery>,
    complete: bool,
}

struct LivePreviewContext {
    root: PathBuf,
    device: u64,
    history: Vec<(PathBuf, String)>,
    min_hours: u32,
    limit: usize,
    scratch_verdicts: bool,
    cutoff: i64,
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
    let Ok(relative) = path.strip_prefix(root) else {
        return Some("kept:outside-scratch");
    };
    if !relative
        .components()
        .all(|part| matches!(part, Component::Normal(_)))
    {
        return Some("kept:invalid-path");
    }
    let mut current = root.to_path_buf();
    for part in relative.components() {
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
            break;
        }
        let verdict = checked.map_or_else(
            || checked_verdict(&root, &path, device, min_hours),
            str::to_owned,
        );
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
        discovery: Some(Discovery {
            complete: false,
            files_measured: 0,
            directories_measured: 0,
            repository_roots: 0,
            measured_apparent_bytes: 0,
            allocated_bytes_semantics:
                "The ledger-only preview did not measure filesystem allocation.".into(),
            gaps: vec![ScanGap {
                path: root.to_string_lossy().into_owned(),
                path_bytes_hex: None,
                kind: ScanGapKind::NotScanned,
                message: "Ledger-only preview did not scan the Scratch filesystem.".into(),
            }],
        }),
        root,
        min_hours,
        complete: false,
        recorded_paths,
        missing_paths,
        candidates,
        resumable: None,
    })
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Discovery {
    complete: bool,
    files_measured: usize,
    directories_measured: usize,
    repository_roots: usize,
    measured_apparent_bytes: u64,
    allocated_bytes_semantics: String,
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

fn live_candidate_verdict(root: &Path, path: &Path, device: u64, min_hours: u32) -> String {
    if protected_scope(root, path) {
        return "kept:protected-scratch-scope".into();
    }
    if let Some(reason) = check_path(root, path, device) {
        return reason.into();
    }
    for ancestor in path.ancestors().skip(1).take_while(|p| p.starts_with(root)) {
        match fs::symlink_metadata(ancestor.join(".git")) {
            Ok(_) => return "kept:repository-use-worktree-route".into(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return "deferred:metadata".into(),
        }
        if ancestor.join("HEAD").is_file() && ancestor.join("objects").is_dir() {
            return "kept:repository-use-worktree-route".into();
        }
    }
    checked_verdict(root, path, device, min_hours)
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
    let cutoff = current_cutoff(min_hours)?;
    live_preview_from_measurement(
        LivePreviewContext {
            root,
            device,
            history,
            min_hours,
            limit,
            scratch_verdicts,
            cutoff,
        },
        measured,
    )
}

fn current_cutoff(min_hours: u32) -> io::Result<i64> {
    let now = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_secs(),
    )
    .map_err(io::Error::other)?;
    Ok(now - i64::from(min_hours) * 3600)
}

fn live_preview_from_measurement(
    context: LivePreviewContext,
    measured: ScanReport,
) -> io::Result<Report> {
    let LivePreviewContext {
        root,
        device,
        history: history_rows,
        min_hours,
        limit,
        scratch_verdicts,
        cutoff,
    } = context;
    let recorded_paths = history_rows.len();
    let history: HashMap<_, _> = history_rows.into_iter().collect();
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
                live_candidate_verdict(&root, path, device, min_hours)
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
            allocated_bytes_semantics: "File values are inode-block allocations for the path. Directory values sum allocations per pathname, so hardlinks/shared blocks may be counted more than once and sibling values are not additive. These estimates prioritize checks but do not predict physical reclaim.".to_owned(),
            gaps: measured.gaps,
        }),
        resumable: None,
    })
}

fn scan_frontiers(
    root: &Path,
    device: u64,
    targets: &[PathBuf],
    budget: Duration,
) -> io::Result<(ScanReport, Vec<PathBuf>)> {
    let started = Instant::now();
    let mut files: HashMap<(String, Option<String>), FileMeasurement> = HashMap::new();
    let mut directories: HashMap<(String, Option<String>), DirectoryMeasurement> = HashMap::new();
    let mut gaps: Vec<ScanGap> = Vec::new();
    let mut scanned_targets = Vec::new();
    let mut complete = true;

    for target in targets {
        if let Some(reason) = check_path(root, target, device) {
            if reason == "missing" {
                scanned_targets.push(target.clone());
                continue;
            }
            let boundary = matches!(
                reason,
                "kept:outside-scratch"
                    | "kept:invalid-path"
                    | "kept:filesystem-boundary"
                    | "kept:symlink"
                    | "kept:unsupported-path"
            );
            complete = false;
            let (path, path_bytes_hex) = scan::path_parts_for_report(target);
            gaps.push(ScanGap {
                path,
                path_bytes_hex,
                kind: if boundary {
                    ScanGapKind::CrossDevice
                } else {
                    ScanGapKind::Metadata
                },
                message: reason.to_owned(),
            });
            continue;
        }
        let remaining = budget.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            complete = false;
            let (path, path_bytes_hex) = scan::path_parts_for_report(target);
            gaps.push(ScanGap {
                path,
                path_bytes_hex,
                kind: ScanGapKind::Deadline,
                message: "deadline before frontier scan started".to_owned(),
            });
            continue;
        }
        scanned_targets.push(target.clone());
        match scan(
            target,
            ScanOptions {
                deadline: remaining,
                max_entries: usize::MAX,
            },
        ) {
            Ok(report) => {
                complete &= report.complete;
                for file in report.files {
                    files.insert((file.path.clone(), file.path_bytes_hex.clone()), file);
                }
                for directory in report.directories {
                    directories.insert(
                        (directory.path.clone(), directory.path_bytes_hex.clone()),
                        directory,
                    );
                }
                for gap in report.gaps {
                    if !gaps
                        .iter()
                        .any(|old| old.path == gap.path && old.kind == gap.kind)
                    {
                        gaps.push(gap);
                    }
                }
            }
            Err(error) => {
                complete = false;
                let (path, path_bytes_hex) = scan::path_parts_for_report(target);
                gaps.push(ScanGap {
                    path,
                    path_bytes_hex,
                    kind: ScanGapKind::Metadata,
                    message: error.to_string(),
                });
            }
        }
    }

    let mut files: Vec<_> = files.into_values().collect();
    files.sort_by(|left, right| left.path.cmp(&right.path));
    let mut directories: Vec<_> = directories.into_values().collect();
    directories.sort_by(|left, right| left.path.cmp(&right.path));
    gaps.sort_by(|left, right| (&left.path, left.kind).cmp(&(&right.path, right.kind)));
    let apparent_bytes = files.iter().map(|file| file.apparent_bytes).sum();
    let allocated_bytes = files.iter().map(|file| file.allocated_bytes).sum();
    Ok((
        ScanReport {
            root: root.to_string_lossy().into_owned(),
            root_bytes_hex: None,
            threshold_bytes: ITEMIZATION_THRESHOLD_BYTES,
            complete: complete && gaps.is_empty(),
            apparent_bytes,
            allocated_bytes,
            files,
            directories,
            gaps,
        },
        scanned_targets,
    ))
}

fn merge_frontier(
    previous: &[PendingScan],
    scanned_targets: &[PathBuf],
    gaps: &[ScanGap],
) -> Vec<PendingScan> {
    let scanned: HashSet<PathBuf> = scanned_targets.iter().cloned().collect();
    let mut frontier: HashMap<(String, Option<String>, String), PendingScan> = HashMap::new();
    for old in previous {
        let path = PathBuf::from(&old.path);
        if !old.retryable || !scanned.contains(&path) {
            frontier.insert(
                (
                    old.path.clone(),
                    old.path_bytes_hex.clone(),
                    old.kind.clone(),
                ),
                old.clone(),
            );
        }
    }
    for gap in gaps {
        let kind = format!("{:?}", gap.kind);
        let key = (gap.path.clone(), gap.path_bytes_hex.clone(), kind.clone());
        let retries = previous
            .iter()
            .find(|old| {
                old.path == gap.path && old.path_bytes_hex == gap.path_bytes_hex && old.kind == kind
            })
            .map_or(0, |old| old.retries.saturating_add(1));
        let retryable = gap.path_bytes_hex.is_none() && gap.kind != ScanGapKind::CrossDevice;
        frontier.insert(
            key,
            PendingScan {
                path: gap.path.clone(),
                path_bytes_hex: gap.path_bytes_hex.clone(),
                kind,
                reason: gap.message.clone(),
                retries,
                retryable,
            },
        );
    }
    let mut frontier: Vec<_> = frontier.into_values().collect();
    frontier.sort_by(|left, right| {
        Path::new(&right.path)
            .components()
            .count()
            .cmp(&Path::new(&left.path).components().count())
            .then_with(|| left.path.cmp(&right.path))
    });
    frontier
}

pub fn scope_report_resumable(
    scope: &str,
    state_dir: Option<&Path>,
    min_hours: u32,
    limit: usize,
    scan_deadline: Duration,
    checkpoint_path: &Path,
) -> io::Result<Value> {
    if scope != "scratch" || !matches!(min_hours, 6 | 48) {
        return Err(io::Error::other(
            "resumable preview requires Scratch with a 6- or 48-hour floor",
        ));
    }
    if !checkpoint_path.is_absolute() {
        return Err(io::Error::other("resume checkpoint path must be absolute"));
    }
    let state_dir = state_dir.ok_or_else(|| io::Error::other("this scope requires --state-dir"))?;
    let (root, device) = registered_scratch()?;
    let root_metadata = fs::metadata(&root)?;
    let history = match ledger_paths(state_dir, &root) {
        Ok(paths) => paths,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    let mut saved = load_checkpoint(checkpoint_path)?;
    let cutoff = if let Some(checkpoint) = saved.as_ref() {
        if checkpoint.version != CHECKPOINT_VERSION
            || checkpoint.root != root
            || checkpoint.root_device != device
            || checkpoint.root_inode != root_metadata.ino()
            || checkpoint.min_hours != min_hours
        {
            return Err(io::Error::other(
                "resume checkpoint does not match the current Scratch identity and policy",
            ));
        }
        checkpoint.cutoff_epoch
    } else {
        current_cutoff(min_hours)?
    };
    if let Some(checkpoint) = saved.as_ref().filter(|checkpoint| checkpoint.complete) {
        return serde_json::to_value(report_from_checkpoint(checkpoint_path, checkpoint.clone()))
            .map_err(io::Error::other);
    }

    let mut scan_targets: Vec<PathBuf> = saved
        .as_ref()
        .map(|checkpoint| {
            checkpoint
                .unfinished_scan_paths
                .iter()
                .filter(|pending| pending.retryable && pending.path_bytes_hex.is_none())
                .map(|pending| PathBuf::from(&pending.path))
                .collect()
        })
        .unwrap_or_else(|| vec![root.clone()]);
    scan_targets.sort_by(|left, right| {
        right
            .components()
            .count()
            .cmp(&left.components().count())
            .then_with(|| left.cmp(right))
    });
    scan_targets.dedup();

    let (measured, scanned_targets) = scan_frontiers(&root, device, &scan_targets, scan_deadline)?;
    let old_frontier = saved
        .as_ref()
        .map(|checkpoint| checkpoint.unfinished_scan_paths.as_slice())
        .unwrap_or_default();
    let unfinished_scan_paths = merge_frontier(old_frontier, &scanned_targets, &measured.gaps);
    let mut remaining_limit = limit;
    let mut prior_candidates = saved
        .as_mut()
        .map(|checkpoint| std::mem::take(&mut checkpoint.candidates))
        .unwrap_or_default();

    // Retain the checkpoint observation without presenting a prior verdict as current.
    mark_prior_verdicts(&mut prior_candidates);
    // Previously unchecked exact paths receive the next available verdict slots.
    for candidate in prior_candidates.iter_mut().filter(|candidate| {
        candidate.verdict.starts_with("deferred:verification-limit")
            || candidate.verdict.starts_with("deferred:deadline")
            || candidate
                .verdict
                .starts_with("deferred:verdict-unavailable")
    }) {
        if remaining_limit == 0 {
            break;
        }
        candidate.verdict = live_candidate_verdict(&root, &candidate.path, device, min_hours);
        candidate.eligible = candidate.verdict == "remove";
        remaining_limit -= 1;
    }

    let current = live_preview_from_measurement(
        LivePreviewContext {
            root: root.clone(),
            device,
            history,
            min_hours,
            limit: remaining_limit,
            scratch_verdicts: true,
            cutoff,
        },
        measured,
    )?;
    let current_missing = current.missing_paths;
    let current_recorded = current.recorded_paths;
    let mut discovery = if scan_targets.is_empty() {
        saved
            .as_ref()
            .and_then(|checkpoint| checkpoint.discovery.clone())
            .or(current.discovery)
    } else {
        current.discovery
    };

    let mut candidates_by_path: HashMap<PathBuf, Candidate> = prior_candidates
        .into_iter()
        .map(|candidate| (candidate.path.clone(), candidate))
        .collect();
    for candidate in current.candidates {
        let replace = candidates_by_path
            .get(&candidate.path)
            .is_none_or(|existing| {
                !candidate.verdict.starts_with("deferred:verification-limit")
                    || existing.verdict.starts_with("deferred:")
            });
        if replace {
            candidates_by_path.insert(candidate.path.clone(), candidate);
        }
    }
    let mut candidates: Vec<Candidate> = candidates_by_path.into_values().collect();
    candidates.sort_unstable_by(|left, right| {
        right
            .allocated_bytes
            .cmp(&left.allocated_bytes)
            .then_with(|| left.path.cmp(&right.path))
    });
    // A checkpoint inside Scratch is part of the scan tree. Keep its exact path
    // out of the candidate report and outside the pending-verdict selection.
    let checkpoint_target = checkpoint_path
        .parent()
        .and_then(|parent| fs::canonicalize(parent).ok())
        .zip(checkpoint_path.file_name())
        .map(|(parent, name)| parent.join(name));
    if let Some(target) = checkpoint_target.as_ref() {
        candidates.retain(|candidate| &candidate.path != target);
    }
    let pending_verdict_paths: Vec<PathBuf> = candidates
        .iter()
        .filter(|candidate| candidate.verdict.starts_with("deferred:"))
        .map(|candidate| candidate.path.clone())
        .collect();
    let scan_passes = saved
        .as_ref()
        .map_or(1, |checkpoint| checkpoint.scan_passes.saturating_add(1));
    let complete = discovery.as_ref().is_some_and(|value| value.complete)
        && unfinished_scan_paths.is_empty()
        && pending_verdict_paths.is_empty();
    if let Some(discovery) = discovery.as_mut() {
        // Counts describe this pass. They are never summed across overlapping rescans.
        discovery.complete = discovery.complete && unfinished_scan_paths.is_empty();
        discovery.gaps = unfinished_scan_paths
            .iter()
            .map(|pending| {
                let kind = match pending.kind.as_str() {
                    "Deadline" => ScanGapKind::Deadline,
                    "EntryLimit" => ScanGapKind::EntryLimit,
                    "ReadDirectory" => ScanGapKind::ReadDirectory,
                    "CrossDevice" => ScanGapKind::CrossDevice,
                    _ => ScanGapKind::Metadata,
                };
                ScanGap {
                    path: pending.path.clone(),
                    path_bytes_hex: pending.path_bytes_hex.clone(),
                    kind,
                    message: pending.reason.clone(),
                }
            })
            .collect();
    }
    let report = Report {
        root: root.clone(),
        scratch_root: Some(root.clone()),
        min_hours,
        complete,
        recorded_paths: current_recorded,
        missing_paths: current_missing,
        candidates: candidates.clone(),
        discovery: discovery.clone(),
        resumable: Some(ResumeSummary {
            checkpoint: checkpoint_path.to_path_buf(),
            scan_passes,
            unfinished_scan_paths: unfinished_scan_paths.clone(),
            pending_verdict_paths,
        }),
    };
    let checkpoint = ResumeCheckpoint {
        version: CHECKPOINT_VERSION,
        root,
        root_device: device,
        root_inode: root_metadata.ino(),
        min_hours,
        cutoff_epoch: cutoff,
        scan_passes,
        recorded_paths: current_recorded,
        candidates,
        unfinished_scan_paths,
        missing_paths: current_missing,
        discovery,
        complete,
    };
    write_checkpoint(checkpoint_path, &checkpoint)?;
    serde_json::to_value(report).map_err(io::Error::other)
}

fn mark_prior_verdicts(candidates: &mut [Candidate]) {
    for candidate in candidates {
        if candidate.verdict == "remove" {
            candidate.verdict = "historical:remove".into();
            candidate.eligible = false;
        }
    }
}

fn report_from_checkpoint(path: &Path, mut saved: ResumeCheckpoint) -> Report {
    mark_prior_verdicts(&mut saved.candidates);
    let pending_verdict_paths = saved
        .candidates
        .iter()
        .filter(|candidate| candidate.verdict.starts_with("deferred:"))
        .map(|candidate| candidate.path.clone())
        .collect();
    Report {
        root: saved.root.clone(),
        scratch_root: Some(saved.root),
        min_hours: saved.min_hours,
        complete: saved.complete,
        recorded_paths: saved.recorded_paths,
        missing_paths: saved.missing_paths,
        candidates: saved.candidates,
        discovery: saved.discovery,
        resumable: Some(ResumeSummary {
            checkpoint: path.to_path_buf(),
            scan_passes: saved.scan_passes,
            unfinished_scan_paths: saved.unfinished_scan_paths,
            pending_verdict_paths,
        }),
    }
}

fn load_checkpoint(path: &Path) -> io::Result<Option<ResumeCheckpoint>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_file() {
        return Err(io::Error::other("resume checkpoint must be a regular file"));
    }
    if metadata.len() > CHECKPOINT_MAX_BYTES {
        return Err(io::Error::other("resume checkpoint exceeds the read limit"));
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take(CHECKPOINT_MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > CHECKPOINT_MAX_BYTES {
        return Err(io::Error::other("resume checkpoint exceeds the read limit"));
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(io::Error::other)
}

fn write_checkpoint(path: &Path, checkpoint: &ResumeCheckpoint) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::other("resume checkpoint path must be absolute"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("resume checkpoint requires an existing parent"))?;
    let parent = fs::canonicalize(parent)?;
    if !parent.is_dir() {
        return Err(io::Error::other(
            "resume checkpoint parent is not a directory",
        ));
    }
    let target = parent.join(
        path.file_name()
            .ok_or_else(|| io::Error::other("resume checkpoint filename is missing"))?,
    );
    if fs::symlink_metadata(&target).is_ok_and(|metadata| !metadata.file_type().is_file()) {
        return Err(io::Error::other(
            "resume checkpoint target is not a regular file",
        ));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let temp = parent.join(format!(
        ".{}.tmp-{}-{nonce}",
        target.file_name().unwrap().to_string_lossy(),
        std::process::id()
    ));
    let bytes = serde_json::to_vec(checkpoint).map_err(io::Error::other)?;
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temp, &target)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
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

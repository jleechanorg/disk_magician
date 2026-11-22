use diskm_shadow::{
    artifact_batch, artifact_discovery, evidence_holds, history, preview, reclaim_report, scan,
    scratch_dir, scratch_manifest, scratch_sweep, scratch_target, snapshot, state_commit,
    state_publish, status, time_windows,
};
use serde::Serialize;
use std::env;
use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod scratch_index_cli;

const USAGE: &str = "diskm — Disk Magician migration candidate; inventory output is JSON

  diskm status [PATH] [--state-dir DIR] [--json]
  diskm scan PATH [--deadline-ms N] [--max-entries N] [--json]
  diskm reclaim-ledger --read-existing [--state-dir DIR]
  diskm history --state-dir DIR [--days 7|30] [--json]
  diskm scratch-dir [SUBPATH]
  diskm scratch-new REPO PURPOSE [--kind build|evidence|scratch]
  diskm scratch-temp-file REPO PURPOSE
  diskm scratch-lease PATH
  diskm scratch-finish PATH [completed|abandoned]
  diskm scratch-index refresh [--root scratch|system-tmp]
  diskm scratch-search --older-than Nh [--root scratch|system-tmp] [--limit N|--all]
  diskm snapshot [--path PATH] [--output FILE] [--state-dir DIR]
  diskm state-publish --repo DIR [--remote NAME] [--branch NAME] [--max-commits N] [--state-dir DIR]
  diskm state-commit --repo DIR [--state-dir DIR] [--publish] [--max-commits N]
  diskm evidence-holds refresh [--state-dir DIR] [--query Q]
  diskm scratch-sweep [--root scratch|system-tmp] [--clean] [--min-hours N] [--deadline-ms N] [--max-candidates N] [--path PATH ...]
  diskm scratch-manifest (--before-epoch SECONDS | --older-than Nh) (--path PATH | --paths-from FILE) [--root scratch|system-tmp]
  diskm scratch-qualify (--before-epoch SECONDS | --older-than Nh) (--path PATH | --paths-from FILE) [--root scratch|system-tmp] [--jobs N] [--deadline-ms N] [--max-entries N]
  diskm scratch-target-apply --manifest FILE --manifest-sha256 SHA --resume-state FILE --target-used-bytes N [--path REL ... | --all | --ack-restored REL | --restore-staged REL]
  diskm preview [--scope scratch|tmp|worktrees|ledger|all] [--state-dir DIR] [--min-hours N] [--max-candidates N] [--deadline-ms N] [--resume-state FILE] [--recheck PATH ...] [--dry-run]

Preview --deadline-ms bounds Scratch discovery at any age. With --resume-state,
preview can resume incomplete discovery. Verdict checks run after discovery.

Status defaults to the current directory. Scan defaults to 30 seconds and
100,000 visited paths. An incomplete scan emits a report and exits 75.
Preview defaults to the Scratch scope. Use --scope all for all supported locations.";

const TEMPORARY_FAILURE: u8 = 75;
const USAGE_ERROR: u8 = 2;

enum Operation {
    Help,
    Snapshot {
        root: PathBuf,
        output: Option<PathBuf>,
        state_dir: Option<PathBuf>,
    },
    Status {
        root: PathBuf,
        state_dir: Option<PathBuf>,
    },
    Scan {
        root: PathBuf,
        options: scan::ScanOptions,
    },
    History {
        state_dir: PathBuf,
        days: u32,
    },
    ScratchManifest {
        cutoff: i64,
        paths: Vec<PathBuf>,
        host_temp: bool,
    },
    ScratchSweep(scratch_sweep::Options),
    StatePublish(state_publish::Options),
    StateCommit(state_commit::Options),
    EvidenceHoldsRefresh {
        state_dir: Option<PathBuf>,
        query: String,
    },
    ScratchQualify {
        cutoff: i64,
        paths: Vec<PathBuf>,
        options: scan::ScanOptions,
        jobs: usize,
        host_temp: bool,
    },
    ScratchTargetApply {
        manifest: PathBuf,
        digest: String,
        resume_state: PathBuf,
        target_used_bytes: u64,
        paths: Vec<String>,
        all_entries: bool,
        recovery: Option<scratch_target::RecoveryAction>,
    },
    Preview {
        scope: &'static str,
        state_dir: Option<PathBuf>,
        min_hours: u32,
        max_candidates: usize,
        scan_deadline: Option<Duration>,
        resume_state: Option<PathBuf>,
        recheck_paths: Vec<PathBuf>,
    },
}

fn required_value(
    args: &mut impl Iterator<Item = OsString>,
    option: &str,
) -> Result<OsString, String> {
    args.next()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{option} requires a value"))
}

fn positive<T: std::str::FromStr + Default + PartialOrd>(
    args: &mut impl Iterator<Item = OsString>,
    option: &str,
) -> Result<T, String> {
    required_value(args, option)?
        .to_str()
        .and_then(|value| value.parse::<T>().ok())
        .filter(|value| *value > T::default())
        .ok_or_else(|| format!("{option} requires a positive integer"))
}

fn parse(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let Some(command) = args.next() else {
        return Ok(Operation::Help);
    };
    let command = command
        .to_str()
        .ok_or_else(|| "invalid command".to_owned())?;
    match command {
        "-h" | "--help" | "help" => return Ok(Operation::Help),
        "snapshot" => return parse_snapshot(args),
        "state-publish" => return parse_state_publish(args),
        "state-commit" => return parse_state_commit(args),
        "evidence-holds" => return parse_evidence_holds(args),
        "scratch-manifest" => return parse_scratch_nomination(args, false),
        "scratch-sweep" => return parse_scratch_sweep(args),
        "scratch-qualify" => return parse_scratch_nomination(args, true),
        "scratch-target-apply" => return parse_scratch_target_apply(args),
        "status" | "scan" | "history" | "preview" => {}
        _ => return Err(format!("unknown command {command:?}")),
    }

    let mut root = None;
    let mut state_dir = None;
    let mut deadline_ms = time_windows::SCAN_DEADLINE.as_millis() as u64;
    let mut max_entries = 100_000;
    let mut days = time_windows::HISTORY_DAYS;
    let mut preview_scope = "scratch";
    let mut min_hours = time_windows::CONTENT_FLOOR_HOURS;
    let mut max_candidates = None;
    let mut preview_deadline_ms = None;
    let mut preview_resume_state = None;
    let mut recheck_paths = Vec::new();
    let mut positional_only = false;

    while let Some(arg) = args.next() {
        let option = if positional_only { None } else { arg.to_str() };
        match option {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--") => positional_only = true,
            Some("--json") => {}
            Some("--dry-run") if command == "preview" => {}
            Some("--scope") if command == "preview" => {
                preview_scope = match required_value(&mut args, "--scope")?.to_str() {
                    Some("scratch") => "scratch",
                    Some("tmp") => "tmp",
                    Some("worktrees") => "worktrees",
                    Some("ledger") => "ledger",
                    Some("all") => "all",
                    _ => {
                        return Err("--scope must be scratch, tmp, worktrees, ledger, or all".into())
                    }
                };
            }
            Some("--min-hours") if command == "preview" => {
                min_hours = positive(&mut args, "--min-hours")?;
            }
            Some("--max-candidates") if command == "preview" => {
                max_candidates = Some(positive(&mut args, "--max-candidates")?);
            }
            Some("--deadline-ms") if command == "preview" => {
                preview_deadline_ms = Some(positive(&mut args, "--deadline-ms")?);
            }
            Some("--resume-state") if command == "preview" && preview_resume_state.is_none() => {
                preview_resume_state =
                    Some(PathBuf::from(required_value(&mut args, "--resume-state")?));
            }
            Some("--recheck") if command == "preview" => {
                recheck_paths.push(PathBuf::from(required_value(&mut args, "--recheck")?));
            }
            Some("--state-dir") if command != "scan" && state_dir.is_none() => {
                state_dir = Some(PathBuf::from(required_value(&mut args, "--state-dir")?));
            }
            Some("--deadline-ms") if command == "scan" => {
                deadline_ms = positive(&mut args, "--deadline-ms")?;
            }
            Some("--max-entries") if command == "scan" => {
                max_entries = positive(&mut args, "--max-entries")?;
            }
            Some("--days") if command == "history" => {
                days = match required_value(&mut args, "--days")?.to_str() {
                    Some("7") => 7,
                    Some("30") => 30,
                    _ => return Err("--days must be 7 or 30".to_owned()),
                };
            }
            Some(flag) if flag.starts_with('-') => return Err(format!("unexpected option {flag}")),
            _ if matches!(command, "scan" | "status") && root.is_none() => {
                root = Some(PathBuf::from(arg))
            }
            _ => return Err("unexpected extra path".to_owned()),
        }
    }

    match command {
        "status" => Ok(Operation::Status {
            root: root
                .map(Ok)
                .unwrap_or_else(env::current_dir)
                .map_err(|error| format!("cannot resolve current directory: {error}"))?,
            state_dir,
        }),
        "scan" => Ok(Operation::Scan {
            root: root.ok_or("scan requires a path")?,
            options: scan::ScanOptions {
                deadline: Duration::from_millis(deadline_ms),
                max_entries,
            },
        }),
        "history" => Ok(Operation::History {
            state_dir: state_dir.ok_or("history requires --state-dir")?,
            days,
        }),
        "preview" => {
            if preview_resume_state.is_some() && preview_scope != "scratch" {
                return Err("preview --resume-state requires --scope scratch".into());
            }
            if preview_deadline_ms.is_some() && preview_scope != "scratch" {
                return Err("preview --deadline-ms requires --scope scratch".into());
            }
            if !recheck_paths.is_empty() {
                if preview_resume_state.is_none() || preview_scope != "scratch" {
                    return Err("preview --recheck requires Scratch and --resume-state".into());
                }
                if preview_deadline_ms.is_some() {
                    return Err(
                        "preview --deadline-ms bounds scans; --recheck checks exact files".into(),
                    );
                }
            }
            if recheck_paths.is_empty()
                && state_dir.is_none()
                && matches!(preview_scope, "scratch" | "ledger")
            {
                return Err("this preview scope requires --state-dir".into());
            }
            Ok(Operation::Preview {
                scope: preview_scope,
                state_dir,
                min_hours,
                max_candidates: max_candidates.unwrap_or(20),
                scan_deadline: preview_deadline_ms.map(Duration::from_millis),
                resume_state: preview_resume_state,
                recheck_paths,
            })
        }
        _ => unreachable!("command already validated"),
    }
}

fn parse_scratch_sweep(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let mut options = scratch_sweep::Options::default();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--clean") => options.clean = true,
            Some("--root") => options.system_tmp = parse_temp_root(&mut args)?,
            Some("--min-hours") => options.min_hours = positive(&mut args, "--min-hours")?,
            Some("--max-candidates") => options.limit = positive(&mut args, "--max-candidates")?,
            Some("--deadline-ms") => {
                options.deadline = Duration::from_millis(positive(&mut args, "--deadline-ms")?)
            }
            Some("--path") => options
                .paths
                .push(required_value(&mut args, "--path")?.into()),
            _ => return Err(format!("unexpected scratch-sweep argument {arg:?}")),
        }
    }
    Ok(Operation::ScratchSweep(options))
}

fn parse_state_publish(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let mut repo = None;
    let mut remote = None;
    let mut branch = None;
    let mut max_commits = None;
    let mut state_dir = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--repo") if repo.is_none() => {
                repo = Some(required_value(&mut args, "--repo")?.into())
            }
            Some("--remote") if remote.is_none() => {
                remote = Some(utf8(required_value(&mut args, "--remote")?)?)
            }
            Some("--branch") if branch.is_none() => {
                branch = Some(utf8(required_value(&mut args, "--branch")?)?)
            }
            Some("--max-commits") if max_commits.is_none() => {
                max_commits = Some(positive(&mut args, "--max-commits")?)
            }
            Some("--state-dir") if state_dir.is_none() => {
                state_dir = Some(required_value(&mut args, "--state-dir")?.into())
            }
            _ => return Err("state-publish accepts --repo DIR, --remote NAME, --branch NAME, --max-commits N and --state-dir DIR".into()),
        }
    }
    Ok(Operation::StatePublish(state_publish::Options {
        repo: repo.ok_or("state-publish requires --repo DIR")?,
        remote: remote.unwrap_or_else(|| "origin".into()),
        branch: branch.unwrap_or_else(|| "main".into()),
        max_commits: max_commits.unwrap_or(20),
        state_dir,
    }))
}

fn parse_state_commit(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let mut repo: Option<PathBuf> = None;
    let mut state_dir: Option<PathBuf> = None;
    let mut publish = false;
    let mut max_commits = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--repo") if repo.is_none() => {
                repo = Some(required_value(&mut args, "--repo")?.into())
            }
            Some("--state-dir") if state_dir.is_none() => {
                state_dir = Some(required_value(&mut args, "--state-dir")?.into())
            }
            Some("--publish") if !publish => publish = true,
            Some("--max-commits") if max_commits.is_none() => {
                max_commits = Some(positive(&mut args, "--max-commits")?)
            }
            _ => return Err(
                "state-commit accepts --repo DIR, --state-dir DIR, --publish and --max-commits N"
                    .into(),
            ),
        }
    }
    if max_commits.is_some() && !publish {
        return Err("--max-commits requires --publish".into());
    }
    let repo = repo.ok_or("state-commit requires --repo DIR")?;
    let publish = publish.then(|| state_publish::Options {
        repo: repo.clone(),
        remote: "origin".into(),
        branch: "main".into(),
        max_commits: max_commits.unwrap_or(20),
        state_dir: state_dir.clone(),
    });
    Ok(Operation::StateCommit(state_commit::Options {
        repo,
        state_dir,
        publish,
    }))
}

fn parse_evidence_holds(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    if args.next().as_deref().and_then(|value| value.to_str()) != Some("refresh") {
        return Err("evidence-holds supports only: refresh".into());
    }
    let mut state_dir: Option<PathBuf> = None;
    let mut query = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--state-dir") if state_dir.is_none() => {
                state_dir = Some(required_value(&mut args, "--state-dir")?.into())
            }
            Some("--query") if query.is_none() => {
                query = Some(
                    required_value(&mut args, "--query")?
                        .into_string()
                        .map_err(|_| "--query must be UTF-8".to_owned())?,
                )
            }
            _ => return Err("evidence-holds refresh accepts --state-dir DIR and --query Q".into()),
        }
    }
    Ok(Operation::EvidenceHoldsRefresh {
        state_dir,
        query: query.unwrap_or_else(|| evidence_holds::DEFAULT_QUERY.into()),
    })
}

fn utf8(value: OsString) -> Result<String, String> {
    value
        .into_string()
        .ok()
        .filter(|name| {
            !name.starts_with('-') && !name.contains(':') && !name.chars().any(char::is_whitespace)
        })
        .ok_or_else(|| "Git remote and branch names must be plain UTF-8 names".to_owned())
}

fn parse_snapshot(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let mut root = None;
    let mut output = None;
    let mut state_dir = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--path") if root.is_none() => {
                root = Some(required_value(&mut args, "--path")?.into())
            }
            Some("--output") if output.is_none() => {
                output = Some(required_value(&mut args, "--output")?.into())
            }
            Some("--state-dir") if state_dir.is_none() => {
                state_dir = Some(required_value(&mut args, "--state-dir")?.into())
            }
            _ => {
                return Err(
                    "snapshot accepts --path PATH, --output FILE and --state-dir DIR".into(),
                )
            }
        }
    }
    Ok(Operation::Snapshot {
        root: root.unwrap_or_else(|| "/".into()),
        output,
        state_dir,
    })
}

fn relative_age_cutoff(value: OsString) -> Result<i64, String> {
    let hours = value
        .to_str()
        .and_then(|value| value.strip_suffix("h"))
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .ok_or("--older-than expects a positive number of hours such as 6h")?;
    let seconds = hours.checked_mul(3600).ok_or("age is out of range")?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?;
    i64::try_from(now.as_secs())
        .ok()
        .and_then(|now| now.checked_sub(seconds))
        .filter(|cutoff| *cutoff > 0)
        .ok_or_else(|| "age cutoff must be after the Unix epoch".to_owned())
}

fn parse_temp_root(args: &mut impl Iterator<Item = OsString>) -> Result<bool, String> {
    match required_value(args, "--root")?.to_str() {
        Some("scratch") => Ok(false),
        Some("system-tmp") => Ok(true),
        _ => Err("--root must be scratch or system-tmp".into()),
    }
}

fn parse_scratch_nomination(
    mut args: impl Iterator<Item = OsString>,
    qualify: bool,
) -> Result<Operation, String> {
    let mut cutoff = None;
    let mut paths = Vec::new();
    let mut jobs = 1;
    let mut host_temp = false;
    let mut deadline_ms = time_windows::SCAN_DEADLINE.as_millis() as u64;
    let mut max_entries = 100_000;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--before-epoch") if cutoff.is_none() => {
                cutoff = Some(positive(&mut args, "--before-epoch")?);
            }
            Some("--older-than") if cutoff.is_none() => {
                cutoff = Some(relative_age_cutoff(required_value(&mut args, "--older-than")?)?);
            }
            Some("--path") => paths.push(PathBuf::from(required_value(&mut args, "--path")?)),
            Some("--jobs") if qualify => jobs = positive(&mut args, "--jobs")?,
            Some("--root") => host_temp = parse_temp_root(&mut args)?,
            Some("--deadline-ms") if qualify => deadline_ms = positive(&mut args, "--deadline-ms")?,
            Some("--max-entries") if qualify => max_entries = positive(&mut args, "--max-entries")?,
            Some("--paths-from") => {
                let list = PathBuf::from(required_value(&mut args, "--paths-from")?);
                let bytes = std::fs::read(&list)
                    .map_err(|error| format!("cannot read {}: {error}", list.display()))?;
                let paths_bytes = bytes.strip_suffix(&[0]).ok_or("--paths-from requires a NUL-terminated path list")?;
                for item in paths_bytes.split(|byte| *byte == 0) {
                    let path = std::str::from_utf8(item).map_err(|_| "--paths-from contains a non-UTF-8 path")?;
                    if path.is_empty() {
                        return Err("--paths-from contains an empty path".into());
                    }
                    paths.push(PathBuf::from(path));
                }
            }
            Some("--help" | "-h") => return Ok(Operation::Help),
            _ => {
                return Err(
                    "scratch-manifest accepts --before-epoch or --older-than, and --path or --paths-from".into(),
                )
            }
        }
    }
    if paths.is_empty() {
        return Err("Scratch nomination requires --path or --paths-from".into());
    }
    let cutoff = cutoff.ok_or("Scratch nomination requires --before-epoch or --older-than")?;
    if qualify {
        return Ok(Operation::ScratchQualify {
            cutoff,
            paths,
            jobs,
            host_temp,
            options: scan::ScanOptions {
                deadline: Duration::from_millis(deadline_ms),
                max_entries,
            },
        });
    }
    Ok(Operation::ScratchManifest {
        cutoff,
        paths,
        host_temp,
    })
}

fn parse_scratch_target_apply(
    mut args: impl Iterator<Item = OsString>,
) -> Result<Operation, String> {
    let mut manifest = None;
    let mut digest = None;
    let mut resume_state = None;
    let mut target_used_bytes = None;
    let mut paths = Vec::new();
    let mut all_entries = false;
    let mut recovery = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--manifest") if manifest.is_none() => {
                manifest = Some(PathBuf::from(required_value(&mut args, "--manifest")?));
            }
            Some("--manifest-sha256") if digest.is_none() => {
                let value = required_value(&mut args, "--manifest-sha256")?;
                let value = value.to_str().ok_or("manifest digest must be UTF-8")?;
                if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return Err("manifest digest must be 64 hexadecimal characters".into());
                }
                digest = Some(value.to_ascii_lowercase());
            }
            Some("--resume-state") if resume_state.is_none() => {
                resume_state = Some(PathBuf::from(required_value(&mut args, "--resume-state")?));
            }
            Some("--target-used-bytes") if target_used_bytes.is_none() => {
                target_used_bytes = Some(positive(&mut args, "--target-used-bytes")?);
            }
            Some("--path") if !all_entries && recovery.is_none() => {
                paths.push(
                    required_value(&mut args, "--path")?
                        .into_string()
                        .map_err(|_| "manifest paths must be UTF-8")?,
                );
            }
            Some("--all") if !all_entries && paths.is_empty() && recovery.is_none() => {
                all_entries = true
            }
            Some(option @ ("--ack-restored" | "--restore-staged"))
                if !all_entries && paths.is_empty() && recovery.is_none() =>
            {
                let path = required_value(&mut args, option)?
                    .into_string()
                    .map_err(|_| "recovery path must be UTF-8")?;
                recovery = Some(if option == "--restore-staged" {
                    scratch_target::RecoveryAction::Restore(path)
                } else {
                    scratch_target::RecoveryAction::Acknowledge(path)
                });
            }
            _ => return Err("invalid scratch-target-apply options".into()),
        }
    }
    Ok(Operation::ScratchTargetApply {
        manifest: manifest.ok_or("--manifest is required")?,
        digest: digest.ok_or("--manifest-sha256 is required")?,
        resume_state: resume_state.ok_or("--resume-state is required")?,
        target_used_bytes: target_used_bytes.ok_or("--target-used-bytes is required")?,
        paths,
        all_entries,
        recovery,
    })
}

fn print_json(report: &impl Serialize) -> io::Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer_pretty(&mut output, report).map_err(io::Error::other)?;
    output.write_all(b"\n")
}

fn run(operation: Operation) -> io::Result<u8> {
    match operation {
        Operation::Snapshot {
            root,
            output,
            state_dir,
        } => {
            if let Some(state_dir) = state_dir.as_deref() {
                print_json(&snapshot::run(&root, Some(state_dir), output.as_deref())?)?;
            } else {
                let value = snapshot::collect(&root)?;
                if let Some(destination) = output {
                    snapshot::publish(&destination, &value)?;
                } else {
                    print_json(&value)?;
                }
            }
        }
        Operation::Help => {
            writeln!(io::stdout().lock(), "{USAGE}")?;
        }
        Operation::Status { root, state_dir } => {
            print_json(&status::status(&root, state_dir.as_deref())?)?;
        }
        Operation::Scan { root, options } => {
            let report = scan::scan(&root, options)?;
            print_json(&report)?;
            if !report.complete {
                return Ok(TEMPORARY_FAILURE);
            }
        }
        Operation::ScratchQualify {
            cutoff,
            paths,
            options,
            jobs,
            host_temp,
        } => {
            if host_temp {
                print_json(&scratch_manifest::qualify_host_temp(
                    &paths, cutoff, options, jobs,
                )?)?;
            } else {
                print_json(&scratch_manifest::qualify_exact(
                    &paths, cutoff, options, jobs,
                )?)?;
            }
        }
        Operation::StateCommit(options) => {
            let (report, code) = state_commit::run(&options)?;
            print_json(&report)?;
            if code != 0 {
                return Ok(code);
            }
        }
        Operation::EvidenceHoldsRefresh { state_dir, query } => {
            let roots = evidence_holds::default_roots();
            let (report, code) = evidence_holds::refresh(
                state_dir.as_deref(),
                &query,
                &roots,
                evidence_holds::fetch_github,
            )?;
            print_json(&report)?;
            if code != 0 {
                return Ok(code);
            }
        }
        Operation::StatePublish(options) => {
            let (report, code) = state_publish::run(&options)?;
            print_json(&report)?;
            if code != 0 {
                return Ok(code);
            }
        }
        Operation::ScratchSweep(options) => {
            let (report, complete) = scratch_sweep::run(&options)?;
            print_json(&report)?;
            if !complete {
                return Ok(TEMPORARY_FAILURE);
            }
        }
        Operation::ScratchManifest {
            cutoff,
            paths,
            host_temp,
        } => {
            print_json(&scratch_manifest::create_in(&paths, cutoff, host_temp)?)?;
        }
        Operation::ScratchTargetApply {
            manifest,
            digest,
            resume_state,
            target_used_bytes,
            paths,
            all_entries,
            recovery,
        } => {
            let report = scratch_target::apply(
                &manifest,
                &digest,
                &resume_state,
                target_used_bytes,
                &paths,
                all_entries,
                recovery.as_ref(),
            )?;
            let reached = report.target_reached;
            let acknowledged = recovery.is_some()
                && report.recovery.is_none()
                && report.native_recovery_stage.is_none();
            print_json(&report)?;
            if !reached && !acknowledged {
                return Ok(TEMPORARY_FAILURE);
            }
        }
        Operation::History { state_dir, days } => {
            print_json(&history::history(&state_dir, days)?)?;
        }
        Operation::Preview {
            scope,
            state_dir,
            min_hours,
            max_candidates,
            scan_deadline,
            resume_state,
            recheck_paths,
        } => {
            if !recheck_paths.is_empty() {
                let checkpoint = resume_state
                    .as_deref()
                    .expect("recheck requires a checkpoint");
                let report = preview::recheck_checkpoint_files(
                    checkpoint,
                    min_hours,
                    max_candidates,
                    &recheck_paths,
                )?;
                print_json(&report)?;
                return Ok(0);
            }
            let report = if let Some(checkpoint) = resume_state.as_deref() {
                preview::scope_report_resumable(
                    scope,
                    state_dir.as_deref(),
                    min_hours,
                    max_candidates,
                    scan_deadline.unwrap_or(Duration::MAX),
                    checkpoint,
                )?
            } else {
                preview::scope_report(
                    scope,
                    state_dir.as_deref(),
                    min_hours,
                    max_candidates,
                    scan_deadline.unwrap_or(Duration::MAX),
                )?
            };
            print_json(&report)?;
        }
    }
    Ok(0)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn native_volume(args: &[OsString]) -> Option<ExitCode> {
    if args.first()?.as_os_str() != "volume" {
        return None;
    }
    let parameters = &args[1..];
    let (expected, for_reclaim) = match parameters {
        [verb, class] if verb == "path" && class == "scratch" => (None, false),
        [verb, class, mode] if verb == "path" && class == "scratch" && mode == "--for-reclaim" => {
            (None, true)
        }
        [verb, path] if verb == "verify-mount" => (Some(std::path::Path::new(path)), false),
        _ => return None,
    };
    Some(
        match diskm_shadow::verified_scratch_volume(expected, for_reclaim) {
            Ok(Some(root)) => {
                if expected.is_none() {
                    println!("{}", root.display());
                }
                ExitCode::SUCCESS
            }
            Ok(None) if expected.is_none() => ExitCode::from(3),
            Ok(None) => ExitCode::from(TEMPORARY_FAILURE),
            Err(error) => {
                eprintln!("diskm: {error}");
                ExitCode::from(TEMPORARY_FAILURE)
            }
        },
    )
}

fn main() -> ExitCode {
    let args: Vec<OsString> = env::args_os().skip(1).collect();
    if let Some(status) = scratch_index_cli::dispatch(&args) {
        return status;
    }
    if let Some(status) = diskm_shadow::scratch_lease::dispatch(&args) {
        return status;
    }
    if args
        .first()
        .is_some_and(|arg| arg == "scratch-artifact-validate")
    {
        return match args.as_slice() {
            [_, batch] => artifact_batch::validate(
                std::path::Path::new(batch),
                io::stdin().lock(),
                io::stdout().lock(),
                io::stderr().lock(),
            ),
            _ => {
                let mut stderr = io::stderr().lock();
                let _ = writeln!(stderr, "malformed-header");
                ExitCode::from(75)
            }
        };
    }
    if args
        .first()
        .is_some_and(|arg| arg == "scratch-artifact-discover")
    {
        return match args.as_slice() {
            [_, blocked] => match artifact_discovery::discover_batch(
                io::stdin().lock(),
                std::path::Path::new(blocked),
                None,
            ) {
                Ok(frame) => {
                    if io::stdout().lock().write_all(&frame).is_ok() {
                        ExitCode::SUCCESS
                    } else {
                        ExitCode::FAILURE
                    }
                }
                Err(error) => {
                    eprintln!("{}", error.reason());
                    ExitCode::from(match error {
                        artifact_discovery::DiscoveryError::Deadline => 124,
                        artifact_discovery::DiscoveryError::LegacyRequired => 76,
                        artifact_discovery::DiscoveryError::MalformedInput
                        | artifact_discovery::DiscoveryError::Io(_) => 1,
                    })
                }
            },
            _ => ExitCode::from(2),
        };
    }
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    if let Some(status) = native_volume(&args) {
        return status;
    }

    if matches!(
        args.first().and_then(|arg| arg.to_str()),
        Some("scratch-dir" | "scratch_dir")
    ) {
        return match scratch_dir::resolve(args.get(1).map(OsString::as_os_str), io::stdout().lock())
        {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("scratch-dir: {error}");
                if error.kind() == io::ErrorKind::InvalidInput {
                    ExitCode::from(USAGE_ERROR)
                } else {
                    ExitCode::from(TEMPORARY_FAILURE)
                }
            }
        };
    }
    if let Some(request) = reclaim_report::read_request(&args) {
        return match reclaim_report::print_existing(request, io::stdout().lock()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("diskm: {error}");
                ExitCode::FAILURE
            }
        };
    }
    let operation = match parse(args.into_iter()) {
        Ok(operation) => operation,
        Err(message) => {
            eprintln!("diskm: {message}\n{USAGE}");
            return ExitCode::from(USAGE_ERROR);
        }
    };
    match run(operation) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("diskm: {error}");
            ExitCode::FAILURE
        }
    }
}

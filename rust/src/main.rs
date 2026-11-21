use diskm_shadow::{
    history, preview, reclaim_report, scan, scratch_manifest, scratch_target, status,
};
use serde::Serialize;
use std::env;
use std::ffi::OsString;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::time::Duration;

const USAGE: &str = "diskm — Disk Magician migration candidate; inventory output is JSON

  diskm status [PATH] [--state-dir DIR] [--json]
  diskm scan PATH [--deadline-ms N] [--max-entries N] [--json]
  diskm reclaim-ledger --read-existing [--state-dir DIR]
  diskm history --state-dir DIR [--days 7|30] [--json]
  diskm scratch-manifest --before-epoch SECONDS --path ABSOLUTE_FILE [--path ...] | --paths-from FILE
  diskm scratch-target-apply --manifest FILE --manifest-sha256 SHA --resume-state FILE --target-used-bytes N [--path REL ... | --all]
  diskm preview [--scope scratch|tmp|worktrees|ledger|all] [--state-dir DIR] [--min-hours 6|48] [--max-candidates N] [--deadline-ms N] [--resume-state FILE] [--dry-run]

Preview --deadline-ms bounds Scratch discovery. With --resume-state, it supports
48-hour and six-hour live inventory. Verdict
checks run afterward, up to 12 seconds per candidate, and the default scan is unlimited.

Status defaults to the current directory. Scan defaults to 30 seconds and
100,000 visited paths. An incomplete scan emits a report and exits 75.
Preview defaults to the Scratch scope. Use --scope all for all supported locations.";

const TEMPORARY_FAILURE: u8 = 75;
const USAGE_ERROR: u8 = 2;
const LEGACY_COMPAT_CLI: &str = diskm_shadow::LEGACY_COMPAT_CLI;
const LEGACY_COMPAT_ACTIVE: &str = "DISKM_LEGACY_COMPAT_ACTIVE";

enum Operation {
    Help,
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
    },
    ScratchTargetApply {
        manifest: PathBuf,
        digest: String,
        resume_state: PathBuf,
        target_used_bytes: u64,
        paths: Vec<String>,
        all_entries: bool,
    },
    Preview {
        scope: &'static str,
        state_dir: Option<PathBuf>,
        min_hours: u32,
        max_candidates: usize,
        scan_deadline: Option<Duration>,
        resume_state: Option<PathBuf>,
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
        "scratch-manifest" => return parse_scratch_manifest(args),
        "scratch-target-apply" => return parse_scratch_target_apply(args),
        "status" | "scan" | "history" | "preview" => {}
        _ => return Err(format!("unknown command {command:?}")),
    }

    let mut root = None;
    let mut state_dir = None;
    let mut deadline_ms = 30_000;
    let mut max_entries = 100_000;
    let mut days = 7;
    let mut preview_scope = "scratch";
    let mut min_hours = 48;
    let mut max_candidates = None;
    let mut preview_deadline_ms = None;
    let mut preview_resume_state = None;
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
                min_hours = match required_value(&mut args, "--min-hours")?.to_str() {
                    Some("6") => 6,
                    Some("48") => 48,
                    _ => return Err("--min-hours must be 6 or 48".to_owned()),
                };
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
            if preview_deadline_ms.is_some()
                && (preview_scope != "scratch"
                    || (min_hours != 6 && preview_resume_state.is_none()))
            {
                return Err(
                    "preview --deadline-ms requires Scratch with --min-hours 6 or --resume-state"
                        .into(),
                );
            }
            if state_dir.is_none() && matches!(preview_scope, "scratch" | "ledger") {
                return Err("this preview scope requires --state-dir".into());
            }
            Ok(Operation::Preview {
                scope: preview_scope,
                state_dir,
                min_hours,
                max_candidates: max_candidates.unwrap_or(20),
                scan_deadline: preview_deadline_ms.map(Duration::from_millis),
                resume_state: preview_resume_state,
            })
        }
        _ => unreachable!("command already validated"),
    }
}

fn parse_scratch_manifest(mut args: impl Iterator<Item = OsString>) -> Result<Operation, String> {
    let mut cutoff = None;
    let mut paths = Vec::new();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--before-epoch") if cutoff.is_none() => {
                cutoff = Some(positive(&mut args, "--before-epoch")?);
            }
            Some("--path") => paths.push(PathBuf::from(required_value(&mut args, "--path")?)),
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
                    "scratch-manifest accepts --before-epoch SECONDS, --path FILE, and --paths-from FILE".into(),
                )
            }
        }
    }
    if paths.is_empty() {
        return Err("scratch-manifest requires --path or --paths-from".into());
    }
    Ok(Operation::ScratchManifest {
        cutoff: cutoff.ok_or("scratch-manifest requires --before-epoch")?,
        paths,
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
            Some("--path") if !all_entries => {
                paths.push(
                    required_value(&mut args, "--path")?
                        .into_string()
                        .map_err(|_| "manifest paths must be UTF-8")?,
                );
            }
            Some("--all") if !all_entries && paths.is_empty() => all_entries = true,
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
    })
}

fn print_json(report: &impl Serialize) -> io::Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer_pretty(&mut output, report).map_err(io::Error::other)?;
    output.write_all(b"\n")
}

fn run(operation: Operation) -> io::Result<u8> {
    match operation {
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
        Operation::ScratchManifest { cutoff, paths } => {
            print_json(&scratch_manifest::create(&paths, cutoff)?)?;
        }
        Operation::ScratchTargetApply {
            manifest,
            digest,
            resume_state,
            target_used_bytes,
            paths,
            all_entries,
        } => {
            let report = scratch_target::apply(
                &manifest,
                &digest,
                &resume_state,
                target_used_bytes,
                &paths,
                all_entries,
            )?;
            let reached = report.target_reached;
            print_json(&report)?;
            if !reached {
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
        } => {
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

fn dispatch_legacy(args: &[OsString]) -> Option<ExitCode> {
    env::var_os(LEGACY_COMPAT_CLI)?;
    if matches!(
        args.first().and_then(|arg| arg.to_str()),
        Some("preview" | "scan" | "scratch-manifest" | "scratch-target-apply")
    ) {
        return None;
    }
    // The legacy command may legitimately invoke diskm with different arguments.
    // Store a fingerprint of each forwarded argv to catch repeated dispatch.
    let mut hasher = DefaultHasher::new();
    args.hash(&mut hasher);
    let fingerprint = format!("{:016x}", hasher.finish());
    let mut chain = env::var(LEGACY_COMPAT_ACTIVE).unwrap_or_default();
    if chain.split(',').any(|previous| previous == fingerprint) {
        eprintln!("diskm: refusing recursive legacy compatibility dispatch");
        return Some(ExitCode::from(USAGE_ERROR));
    }
    if !chain.is_empty() {
        chain.push(',');
    }
    chain.push_str(&fingerprint);
    let legacy = match diskm_shadow::legacy_cli() {
        Ok(path) => path,
        Err(error) if error.kind() == io::ErrorKind::InvalidInput => {
            eprintln!("diskm: legacy compatibility backend refused: {error}");
            return Some(ExitCode::from(USAGE_ERROR));
        }
        Err(error) => {
            eprintln!("diskm: legacy compatibility backend unavailable: {error}");
            return Some(ExitCode::from(127));
        }
    };
    let error = Command::new(legacy)
        .arg0("diskm")
        .args(args)
        .env(LEGACY_COMPAT_ACTIVE, chain)
        .exec();
    eprintln!("diskm: cannot exec legacy compatibility backend: {error}");
    Some(ExitCode::from(127))
}

fn main() -> ExitCode {
    let args: Vec<OsString> = env::args_os().skip(1).collect();
    if let Some(request) = reclaim_report::read_request(&args) {
        return match reclaim_report::print_existing(request, io::stdout().lock()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("diskm: {error}");
                ExitCode::FAILURE
            }
        };
    }
    if let Some(status) = dispatch_legacy(&args) {
        return status;
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

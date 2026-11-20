use diskm_shadow::{history, preview, scan, status};
use serde::Serialize;
use std::env;
use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

const USAGE: &str = "diskm-rust — read-only Disk Magician candidate; output is JSON

  diskm-rust status [PATH] [--state-dir DIR] [--json]
  diskm-rust scan PATH [--deadline-ms N] [--max-entries N] [--json]
  diskm-rust history --state-dir DIR [--days 7|30] [--json]
  diskm-rust preview --state-dir DIR [--min-hours 6|48] [--max-candidates N] [--dry-run]

Status defaults to the current directory. Scan defaults to 30 seconds and
100,000 visited paths. An incomplete scan emits a report and exits 75.";

const TEMPORARY_FAILURE: u8 = 75;
const USAGE_ERROR: u8 = 2;

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
    Preview {
        state_dir: PathBuf,
        min_hours: u32,
        max_candidates: usize,
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
        "status" | "scan" | "history" | "preview" => {}
        _ => return Err(format!("unknown command {command:?}")),
    }

    let mut root = None;
    let mut state_dir = None;
    let mut deadline_ms = 30_000;
    let mut max_entries = 100_000;
    let mut days = 7;
    let mut min_hours = 48;
    let mut max_candidates = 20;
    let mut positional_only = false;

    while let Some(arg) = args.next() {
        let option = if positional_only { None } else { arg.to_str() };
        match option {
            Some("--help" | "-h") => return Ok(Operation::Help),
            Some("--") => positional_only = true,
            Some("--json") => {}
            Some("--dry-run") if command == "preview" => {}
            Some("--min-hours") if command == "preview" => {
                min_hours = match required_value(&mut args, "--min-hours")?.to_str() {
                    Some("6") => 6,
                    Some("48") => 48,
                    _ => return Err("--min-hours must be 6 or 48".to_owned()),
                };
            }
            Some("--max-candidates") if command == "preview" => {
                max_candidates = positive(&mut args, "--max-candidates")?;
                if max_candidates > preview::MAX_CANDIDATES {
                    return Err(format!(
                        "--max-candidates must be <= {}",
                        preview::MAX_CANDIDATES
                    ));
                }
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
        "preview" => Ok(Operation::Preview {
            state_dir: state_dir.ok_or("preview requires --state-dir")?,
            min_hours,
            max_candidates,
        }),
        _ => unreachable!("command already validated"),
    }
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
        Operation::History { state_dir, days } => {
            print_json(&history::history(&state_dir, days)?)?;
        }
        Operation::Preview {
            state_dir,
            min_hours,
            max_candidates,
        } => {
            print_json(&preview::preview(&state_dir, min_hours, max_candidates)?)?;
        }
    }
    Ok(0)
}

fn main() -> ExitCode {
    let operation = match parse(env::args_os().skip(1)) {
        Ok(operation) => operation,
        Err(message) => {
            eprintln!("diskm-rust: {message}\n{USAGE}");
            return ExitCode::from(USAGE_ERROR);
        }
    };
    match run(operation) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("diskm-rust: {error}");
            ExitCode::FAILURE
        }
    }
}

//! Read the published reclaim report without regenerating it.

use crate::history::{parse_utc, unix_now};
use crate::volume_config::{configuration, json_file};
use serde_json::Value;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

const FOOTER: &str = "<!-- diskm reclaim-ledger complete -->";
const CONTINUE: &str = "not evidence of no growth. Deeper diagnosis may continue.";

pub struct ReadRequest(Option<PathBuf>);

/// Other ledger modes still use the compatibility backend.
pub fn read_request(args: &[OsString]) -> Option<ReadRequest> {
    if !matches!(
        args.first()?.to_str(),
        Some("reclaim-ledger" | "reclaim_ledger")
    ) {
        return None;
    }
    let mut args = args[1..].iter();
    let mut read_existing = false;
    let mut state_dir = None;
    while let Some(arg) = args.next() {
        match arg.to_str()? {
            "--read-existing" => read_existing = true,
            "--state-dir" => {
                let value = args.next()?;
                if value.as_encoded_bytes().starts_with(b"-") {
                    return None;
                }
                state_dir = Some(PathBuf::from(value));
            }
            option if option.starts_with("--state-dir=") => {
                state_dir = Some(PathBuf::from(&option["--state-dir=".len()..]));
            }
            _ => return None,
        }
    }
    read_existing.then_some(ReadRequest(state_dir))
}

fn configured_state(config: &Value, home: &Path) -> Option<PathBuf> {
    let value = config
        .get("state_repo_path")?
        .as_str()
        .filter(|path| !path.is_empty())?;
    Some(match value {
        "~" => home.to_path_buf(),
        value if value.starts_with("~/") => home.join(&value[2..]),
        value => home.join(value),
    })
}

fn default_state() -> PathBuf {
    if let Some(path) = env::var_os("DISK_MAGICIAN_STATE_REPO").filter(|path| !path.is_empty()) {
        return path.into();
    }
    let home = env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    if env::var_os("DISK_MAGICIAN_CONFIG").is_none_or(|path| path.is_empty()) {
        let xdg = env::var_os("XDG_CONFIG_HOME")
            .map_or_else(|| home.join(".config"), PathBuf::from)
            .join("disk-magician/config.json");
        // An XDG snapshot overlay can select the state root independently of
        // the state configuration it locates.
        if let Some(root) = json_file(&xdg)
            .ok()
            .and_then(|config| configured_state(&config, &home))
        {
            return root;
        }
    }
    configuration(&home)
        .ok()
        .and_then(|config| configured_state(&config, &home))
        .unwrap_or_else(|| {
            env::var_os("XDG_STATE_HOME")
                .map_or_else(|| home.join(".local/state"), PathBuf::from)
                .join("disk-magician")
        })
}

fn section_label(line: &str) -> Option<&str> {
    let (label, title) = line.strip_prefix("### ")?.split_once(". ")?;
    let mut bytes = label.bytes();
    if title.is_empty() || !bytes.next()?.is_ascii_uppercase() || !bytes.all(|b| b.is_ascii_digit())
    {
        return None;
    }
    Some(label)
}

fn complete(text: &str) -> bool {
    let title = text.lines().any(|line| {
        line.strip_prefix("# Known reclaim directories: ")
            .is_some_and(|name| name.starts_with(|ch: char| !ch.is_whitespace()))
    });
    let mut labels = Vec::new();
    let mut populated = Vec::new();
    for line in text.split_inclusive('\n') {
        if let Some(label) = line.strip_suffix('\n').and_then(section_label) {
            labels.push(label);
            populated.push(None);
        } else if let Some(body @ None) = populated.last_mut() {
            let part = line.replace(FOOTER, "");
            let part = part.trim_start();
            if !part.is_empty() {
                *body = Some(!part.starts_with('#'));
            }
        }
    }
    title
        && labels == ["C", "D", "B1", "B2", "A"]
        && populated.iter().all(|part| *part == Some(true))
        && text.trim_end().ends_with(FOOTER)
}

fn generation_time(text: &str) -> Option<(i64, String)> {
    text.lines().find_map(|line| {
        let (stamp, _) = line
            .strip_prefix("Generated ")?
            .split_once(" by `diskm reclaim-ledger`")?;
        let clock = stamp.strip_suffix(" UTC")?;
        let (date, time) = clock.split_once(' ')?;
        let iso = format!("{date}T{time}:00");
        Some((parse_utc(&format!("{iso}Z"))?, format!("{iso}+00:00")))
    })
}

pub fn print_existing(request: ReadRequest, mut out: impl Write) -> io::Result<()> {
    let path = request
        .0
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(default_state)
        .join("reclaim/known-reclaim-dirs.md");
    writeln!(
        out,
        "=== Existing per-host reclaim ledger: {} ===",
        path.display()
    )?;
    let text = match fs::read_to_string(path) {
        Ok(text) => text.replace("\r\n", "\n").replace('\r', "\n"),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return writeln!(out, "MISSING reclaim ledger; {CONTINUE}");
        }
        Err(error) => {
            let kind = match error.kind() {
                io::ErrorKind::InvalidData => "UnicodeDecodeError",
                io::ErrorKind::PermissionDenied => "PermissionError",
                io::ErrorKind::IsADirectory => "IsADirectoryError",
                _ => "OSError",
            };
            return writeln!(out, "UNREADABLE reclaim ledger ({kind}); {CONTINUE}");
        }
    };
    if !text.trim().is_empty() && !complete(&text) {
        writeln!(out, "INVALID RECLAIM REPORT: incomplete producer sections, title or final completion footer; {CONTINUE}")?;
    }
    let now = unix_now();
    let stale_hours = env::var("DISK_MAGICIAN_LEDGER_STALE_HOURS")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .filter(|value| value.is_finite() && *value > 0.0)
        .unwrap_or(48.0);
    match generation_time(&text) {
        None => writeln!(out, "UNKNOWN RECLAIM REPORT AGE; not evidence of no growth.")?,
        Some((generated, _)) if generated > now => writeln!(out, "FUTURE RECLAIM REPORT: generation time is ahead of current UTC; not evidence of no growth.")?,
        Some((generated, iso)) if (now - generated) as f64 > stale_hours * 3600.0 => {
            writeln!(out, "STALE RECLAIM REPORT: generated {iso}, older than {stale_hours}h; not evidence of no growth.")?;
        }
        _ => {}
    }
    write!(out, "{text}")?;
    if !text.ends_with('\n') {
        writeln!(out)?;
    }
    if text.trim().is_empty() {
        writeln!(out, "EMPTY reclaim ledger; not evidence of no growth.")?;
    }
    Ok(())
}

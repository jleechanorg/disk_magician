use serde::Serialize;
use std::io;
use std::process::Command;
use std::time::Duration;

const TIMEOUT_SECONDS: u64 = 45;
const PREVIEW_RUNNER: &str = r#"
import os, signal, subprocess, sys
env = os.environ.copy()
for name in ("WORKTREE_APPROVED", "MANUAL_DISCARD", "MANUAL_INCLUDE_LIVE",
             "DISK_MAGICIAN_WORKTREE_FLOOR_HOURS", "DISK_MAGICIAN_AGE_FLOOR_MINUTES",
             "DISK_MAGICIAN_OPERATOR_TARGETS"):
    env.pop(name, None)
cmd = ["diskm", "cleanup-worktrees", "--dry-run"]
child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env, start_new_session=True)
try:
    stdout, stderr = child.communicate(timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired as timeout:
    # communicate(timeout) retains bytes already collected. Do not communicate
    # again because a descendant can keep a pipe open after the group is killed.
    stdout = timeout.output or b""
    stderr = timeout.stderr or b""
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    sys.stderr.write("\nworktree preview timed out\n")
    sys.exit(124)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
sys.exit(child.returncode)
"#;

#[derive(Clone, Debug, Serialize)]
pub struct WorktreeCandidate {
    pub path: String,
    pub disposition: String,
    pub reason: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct WorktreePreviewReport {
    /// All ELIGIBLE entries from this command are preliminary only.
    pub verdict_scope: &'static str,
    /// The canonical cleaner process finished successfully and its ledger rows parsed.
    pub command_complete: bool,
    pub coverage_scope: &'static str,
    pub timed_out: bool,
    pub exit_code: Option<i32>,
    pub candidates: Vec<WorktreeCandidate>,
    pub unparsed_ledger_rows: Vec<String>,
    pub stderr: String,
}

fn canonical_suffix(value: &str) -> bool {
    let fields: Vec<_> = value.split_whitespace().collect();
    if fields.len() < 4 || !fields[0].starts_with("age=") {
        return false;
    }
    let mut index = 1;
    if fields.get(index) == Some(&"days") {
        index += 1;
    }
    if fields
        .get(index)
        .is_none_or(|field| !field.starts_with("size="))
    {
        return false;
    }
    index += 1;
    let Some(head) = fields
        .get(index)
        .and_then(|field| field.strip_prefix("head="))
    else {
        return false;
    };
    if head.len() != 8 || !head.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return false;
    }
    index += 1;
    if fields
        .get(index)
        .is_none_or(|field| !field.starts_with("branch="))
    {
        return false;
    }
    index += 1;
    if fields
        .get(index)
        .is_some_and(|field| field.starts_with("recency=hours:"))
    {
        index += 1;
    }
    if fields
        .get(index)
        .is_some_and(|field| field.starts_with("reason="))
    {
        index += 1;
    }
    index == fields.len()
}

fn parse_ledger_line(line: &str) -> Option<WorktreeCandidate> {
    let body = line.trim_start().strip_prefix("LEDGER ")?;
    let (scope, remainder) = body.split_once(char::is_whitespace)?;
    if scope != "repo-local" {
        return None;
    }
    let remainder = remainder.trim_start();
    let (disposition, payload) = remainder.split_once(char::is_whitespace)?;
    if disposition != "ELIGIBLE" && disposition != "PRESERVE" {
        return None;
    }

    // Parse the canonical metadata suffix from the right so delimiters in paths survive.
    let suffix_start = payload.rfind(" | age=")?;
    let suffix = &payload[suffix_start + 3..];
    if !canonical_suffix(suffix) {
        return Some(WorktreeCandidate {
            path: payload.to_owned(),
            disposition: "unparsed".to_owned(),
            reason: Some("worktree ledger metadata suffix is not canonical".to_owned()),
        });
    }

    let prefix = &payload[..suffix_start];
    let (path, reason) = if disposition == "PRESERVE" {
        match prefix.rsplit_once(" | ") {
            Some((path, reason)) => (path, Some(reason)),
            None => {
                return Some(WorktreeCandidate {
                    path: prefix.to_owned(),
                    disposition: "unparsed".to_owned(),
                    reason: Some("preserve row has no reason field".to_owned()),
                })
            }
        }
    } else {
        (prefix, None)
    };
    if !std::path::Path::new(path).is_absolute() {
        return Some(WorktreeCandidate {
            path: path.to_owned(),
            disposition: "unparsed".to_owned(),
            reason: Some("worktree path is not absolute".to_owned()),
        });
    }

    Some(WorktreeCandidate {
        path: path.to_owned(),
        disposition: if disposition == "ELIGIBLE" {
            "preliminary".to_owned()
        } else {
            "preserve".to_owned()
        },
        reason: reason.map(str::to_owned),
    })
}

pub fn preview_worktrees() -> io::Result<WorktreePreviewReport> {
    let output = Command::new("python3")
        .args(["-c", PREVIEW_RUNNER, &TIMEOUT_SECONDS.to_string()])
        .env_remove("WORKTREE_APPROVED")
        .env_remove("MANUAL_DISCARD")
        .env_remove("MANUAL_INCLUDE_LIVE")
        .env_remove("DISK_MAGICIAN_WORKTREE_FLOOR_HOURS")
        .env_remove("DISK_MAGICIAN_AGE_FLOOR_MINUTES")
        .env_remove("DISK_MAGICIAN_OPERATOR_TARGETS")
        .output()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    let timed_out =
        output.status.code() == Some(124) || stderr.contains("worktree preview timed out");
    let mut candidates = Vec::new();
    let mut unparsed_ledger_rows = Vec::new();
    for line in stdout
        .lines()
        .filter(|line| line.trim_start().starts_with("LEDGER "))
    {
        match parse_ledger_line(line) {
            Some(candidate) if candidate.disposition != "unparsed" => candidates.push(candidate),
            _ => unparsed_ledger_rows.push(line.to_owned()),
        }
    }
    let complete = output.status.success() && !timed_out && unparsed_ledger_rows.is_empty();

    Ok(WorktreePreviewReport {
        verdict_scope: "preliminary; eligible rows still require fresh removal checks",
        command_complete: complete,
        coverage_scope:
            "canonical cleanup-worktrees discovery; not a complete filesystem inventory",
        timed_out,
        exit_code: output.status.code(),
        candidates,
        unparsed_ledger_rows,
        stderr,
    })
}

//! Bounded Git state publication: scan and fast-forward only the oldest
//! pending prefix from a freshly fetched upstream.

use crate::job_receipt::{self, Completion};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::SystemTime;

/// GitHub rejects any pushed file above 100 MB.
pub const MAX_BLOB_BYTES: u64 = 104_857_600;

/// Replacement objects would let the size, ancestry and secret checks inspect
/// different objects from the ones a push transfers, so every subprocess
/// reads the original history.
const NO_REPLACE: &str = "GIT_NO_REPLACE_OBJECTS";

pub struct Options {
    pub repo: PathBuf,
    pub remote: String,
    pub branch: String,
    pub max_commits: usize,
    pub state_dir: Option<PathBuf>,
}

/// Result of observing the pending range without publishing.
#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    UpToDate {
        upstream: String,
    },
    Hold {
        upstream: String,
        reason: String,
        detail: Value,
    },
    Publish {
        upstream: String,
        candidate: String,
        count: usize,
        remaining: usize,
        stop: Value,
    },
}

pub fn git(repo: &Path, args: &[&str]) -> io::Result<String> {
    let output = Command::new("git")
        .env(NO_REPLACE, "1")
        .arg("-C")
        .arg(repo)
        .args(args)
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "git {} failed: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    String::from_utf8(output.stdout).map_err(io::Error::other)
}

pub fn git_ok(repo: &Path, args: &[&str]) -> io::Result<bool> {
    Ok(Command::new("git")
        .env(NO_REPLACE, "1")
        .arg("-C")
        .arg(repo)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?
        .success())
}

fn commit(repo: &Path, reference: &str) -> io::Result<String> {
    Ok(git(
        repo,
        &["rev-parse", "--verify", &format!("{reference}^{{commit}}")],
    )?
    .trim()
    .to_owned())
}

/// Added or modified blobs in one commit as (object id, path, size).
fn commit_blobs(repo: &Path, commit: &str) -> io::Result<Vec<(String, String, u64)>> {
    let listing = git(
        repo,
        &[
            "diff-tree",
            "-r",
            "--no-commit-id",
            "--no-renames",
            "-z",
            "--diff-filter=AMT",
            "--root",
            commit,
        ],
    )?;
    let mut fields = listing.split('\0').filter(|field| !field.is_empty());
    let mut blobs = Vec::new();
    while let (Some(meta), Some(path)) = (fields.next(), fields.next()) {
        // ":old_mode new_mode old_sha new_sha status"
        let new_sha = meta
            .split(' ')
            .nth(3)
            .ok_or_else(|| io::Error::other("malformed diff-tree row"))?;
        let new_mode = meta.split(' ').nth(1).unwrap_or("");
        if new_mode != "160000" {
            blobs.push((new_sha.to_owned(), path.to_owned()));
        }
    }
    if blobs.is_empty() {
        return Ok(Vec::new());
    }
    let mut child = Command::new("git")
        .env(NO_REPLACE, "1")
        .arg("-C")
        .arg(repo)
        .args(["cat-file", "--batch-check=%(objectsize)"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("cat-file stdin"))?;
        for (sha, _) in &blobs {
            writeln!(stdin, "{sha}")?;
        }
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(io::Error::other("git cat-file failed"));
    }
    let sizes = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let sizes: Vec<&str> = sizes.lines().collect();
    if sizes.len() != blobs.len() {
        return Err(io::Error::other(
            "git cat-file returned the wrong row count",
        ));
    }
    blobs
        .into_iter()
        .zip(sizes)
        .map(|((sha, path), line)| {
            let size = line
                .trim()
                .parse()
                .map_err(|_| io::Error::other(format!("unsized object for {path}")))?;
            Ok((sha, path, size))
        })
        .collect()
}

/// Scans blob contents; `Err(reason)` holds publication.
pub type Scanner = fn(&Path, &[String]) -> io::Result<Result<(), &'static str>>;

/// Feeds each blob's raw bytes to `gitleaks stdin`, so no diff configuration,
/// attribute or text conversion can narrow what is scanned. Exit 0 is clean and
/// 1 is a finding; anything else, including a missing binary, holds.
fn secret_scan(repo: &Path, blobs: &[String]) -> io::Result<Result<(), &'static str>> {
    for blob in blobs {
        let content = Command::new("git")
            .env(NO_REPLACE, "1")
            .arg("-C")
            .arg(repo)
            .args(["cat-file", "blob", blob])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()?;
        if !content.status.success() {
            return Err(io::Error::other("git cat-file blob failed"));
        }
        let Ok(mut child) = Command::new("gitleaks")
            .args(["stdin", "--no-banner", "--redact", "--exit-code", "1"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return Ok(Err("secret_scan_unavailable"));
        };
        child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("gitleaks stdin"))?
            .write_all(&content.stdout)?;
        match child.wait()?.code() {
            Some(0) => {}
            Some(1) => return Ok(Err("secret_scan_finding")),
            _ => return Ok(Err("secret_scan_unavailable")),
        }
    }
    Ok(Ok(()))
}

/// Steps 1-5: fresh fetch, ancestry, bounded size walk and secret scan.
pub fn observe(
    repo: &Path,
    remote: &str,
    branch: &str,
    max_commits: usize,
    max_blob: u64,
    scan: Scanner,
) -> io::Result<Plan> {
    let top = PathBuf::from(git(repo, &["rev-parse", "--show-toplevel"])?.trim());
    let repo = top.as_path();
    let tracking = format!("refs/remotes/{remote}/{branch}");
    git(
        repo,
        &[
            "fetch",
            "--no-tags",
            "--quiet",
            remote,
            &format!("+refs/heads/{branch}:{tracking}"),
        ],
    )?;
    let upstream = commit(repo, &tracking)?;
    let local = commit(repo, &format!("refs/heads/{branch}"))?;
    let hold = |reason: &str, detail: Value| Plan::Hold {
        upstream: upstream.clone(),
        reason: reason.to_owned(),
        detail,
    };
    // Shallow boundaries and grafts also substitute history that a push does
    // not, so the checks above cannot vouch for what would be sent.
    let grafts = git(repo, &["rev-parse", "--git-path", "info/grafts"])?;
    if git(repo, &["rev-parse", "--is-shallow-repository"])?.trim() != "false"
        || repo.join(grafts.trim()).exists()
    {
        return Ok(hold("substituted_history", json!({"local": local})));
    }
    if local == upstream {
        return Ok(Plan::UpToDate { upstream });
    }
    if !git_ok(repo, &["merge-base", "--is-ancestor", &upstream, &local])? {
        return Ok(hold("diverged", json!({"local": local})));
    }
    let range = format!("{upstream}..{local}");
    if !git(repo, &["rev-list", "--merges", &range])?
        .trim()
        .is_empty()
    {
        return Ok(hold("merge_in_range", json!({"local": local})));
    }
    let pending: Vec<String> = git(repo, &["rev-list", "--reverse", &range])?
        .lines()
        .map(str::to_owned)
        .collect();
    let mut accepted = 0;
    let mut stop = json!({"reason": "max_commits"});
    let mut scanned = Vec::new();
    for commit in pending.iter().take(max_commits) {
        let blobs = commit_blobs(repo, commit)?;
        if let Some((_, path, size)) = blobs
            .iter()
            .filter(|(_, _, size)| *size > max_blob)
            .max_by_key(|(_, _, size)| *size)
        {
            stop = json!({"reason": "oversize", "commit": commit, "path": path, "bytes": size});
            break;
        }
        scanned.extend(blobs.into_iter().map(|(sha, _, _)| sha));
        accepted += 1;
    }
    scanned.sort_unstable();
    scanned.dedup();
    if accepted == pending.len() {
        stop = json!({"reason": "all_pending"});
    }
    if accepted == 0 {
        return Ok(hold("oversize_first_pending", stop));
    }
    let candidate = pending[accepted - 1].clone();
    if let Err(reason) = scan(repo, &scanned)? {
        return Ok(hold(reason, json!({"candidate": candidate})));
    }
    Ok(Plan::Publish {
        upstream,
        candidate,
        count: accepted,
        remaining: pending.len() - accepted,
        stop,
    })
}

/// Steps 6-7: lease-guarded fast-forward and remote readback.
/// Returns false when the remote no longer equals the observed upstream.
pub fn push_prefix(
    repo: &Path,
    remote: &str,
    branch: &str,
    upstream: &str,
    candidate: &str,
) -> io::Result<bool> {
    let target = format!("refs/heads/{branch}");
    let pushed = git_ok(
        repo,
        &[
            "push",
            "--porcelain",
            "--quiet",
            remote,
            &format!("{candidate}:{target}"),
            &format!("--force-with-lease={target}:{upstream}"),
        ],
    )?;
    if !pushed {
        return Ok(false);
    }
    let remote_tip = git(repo, &["ls-remote", remote, &target])?;
    if remote_tip.split('\t').next() != Some(candidate) {
        return Err(io::Error::other(
            "remote readback does not match the published commit",
        ));
    }
    Ok(true)
}

pub fn run(options: &Options) -> io::Result<(Value, u8)> {
    let started = SystemTime::now();
    let state = job_receipt::state_dir(options.state_dir.as_deref())?;
    let precondition = json!({"repo": options.repo, "remote": options.remote, "branch": options.branch, "max_commits": options.max_commits});
    let outcome = observe(&options.repo, &options.remote, &options.branch, options.max_commits, MAX_BLOB_BYTES, secret_scan)
        .and_then(|plan| match plan {
            Plan::UpToDate { upstream } => Ok((json!({"status": "up_to_date", "upstream": upstream, "published": 0}), 0)),
            Plan::Hold { upstream, reason, detail } => Ok((json!({"status": "held", "reason": reason, "upstream": upstream, "detail": detail, "published": 0}), 75)),
            Plan::Publish { upstream, candidate, count, remaining, stop } => {
                if push_prefix(&options.repo, &options.remote, &options.branch, &upstream, &candidate)? {
                    Ok((json!({"status": "published", "upstream": upstream, "published_tip": candidate, "published": count, "remaining": remaining, "stop": stop}), 0))
                } else {
                    Ok((json!({"status": "held", "reason": "upstream_moved", "upstream": upstream, "candidate": candidate, "published": 0}), 75))
                }
            }
        });
    let (result, code) = match outcome {
        Ok(value) => value,
        Err(error) => {
            let message = error.to_string();
            job_receipt::publish_terminal(
                &state,
                "state-publish",
                started,
                Completion::Error(&message),
                precondition,
                json!({}),
                json!({}),
            )?;
            return Err(error);
        }
    };
    let completion = match result["status"].as_str() {
        Some("held") => Completion::Partial(result["reason"].as_str().unwrap_or("held")),
        _ => Completion::Success,
    };
    let receipt = job_receipt::publish_terminal(
        &state,
        "state-publish",
        started,
        completion,
        precondition,
        result.clone(),
        json!({}),
    )?;
    Ok((json!({"result": result, "receipt": receipt}), code))
}

#[cfg(test)]
#[path = "state_publish_test.rs"]
mod tests;

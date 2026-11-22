//! Commit native state into the backup repository for bounded publication.

use crate::job_receipt::{self, Completion};
use crate::state_publish;
use serde_json::{json, Value};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};
use std::time::SystemTime;

/// State files copied into the backup repository, relative to both roots.
pub const ALLOWLIST: &[&str] = &["snapshots/disk_snapshot.json"];
const MAX_FILE_BYTES: u64 = 10 * 1024 * 1024;

pub struct Options {
    pub repo: PathBuf,
    pub state_dir: Option<PathBuf>,
    pub publish: Option<state_publish::Options>,
}

/// Copies the allowlist and commits it. `Ok(Err(reason))` is a hold; a
/// committed run returns the new commit, an unchanged run returns `None`.
pub fn commit(
    repo: &Path,
    state: &Path,
    branch: &str,
) -> io::Result<Result<Option<String>, String>> {
    let hold = |reason: &str| Ok(Err(reason.to_owned()));
    match state_publish::git(repo, &["symbolic-ref", "--quiet", "--short", "HEAD"]) {
        Ok(head) if head.trim() == branch => {}
        Ok(_) => return hold("wrong_branch"),
        Err(_) => return hold("detached_head"),
    }
    let git_dir =
        PathBuf::from(state_publish::git(repo, &["rev-parse", "--absolute-git-dir"])?.trim());
    if [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    ]
    .iter()
    .any(|name| git_dir.join(name).exists())
    {
        return hold("operation_in_progress");
    }
    let staged = state_publish::git(repo, &["diff", "--cached", "--name-only", "-z"])?;
    if staged
        .split('\0')
        .any(|path| !path.is_empty() && !ALLOWLIST.contains(&path))
    {
        return hold("unrelated_staged_changes");
    }
    // Every check above and below runs before the first write.
    let mut copies = Vec::new();
    for relative in ALLOWLIST {
        if !inside_without_links(repo, Path::new(relative))? {
            return hold("target_path_unsafe");
        }
        let Ok(bytes) = job_receipt::read_bounded(&state.join(relative), MAX_FILE_BYTES) else {
            return hold("source_unreadable");
        };
        copies.push((repo.join(relative), bytes));
    }
    for (target, bytes) in copies {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        // A fresh, exclusively created name: an existing file or link at the
        // temporary path is never followed or overwritten.
        let nonce = SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos();
        let temporary = target.with_extension(format!("diskm-tmp-{}-{nonce}", std::process::id()));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &target)?;
    }
    let mut add = vec!["add", "--"];
    add.extend(ALLOWLIST);
    state_publish::git(repo, &add)?;
    let mut unchanged = vec!["diff", "--cached", "--quiet", "--"];
    unchanged.extend(ALLOWLIST);
    if state_publish::git_ok(repo, &unchanged)? {
        return Ok(Ok(None));
    }
    let message = format!(
        "disk-magician snapshot {}",
        job_receipt::timestamp(SystemTime::now())?
    );
    let mut commit = vec![
        "-c",
        "user.name=disk-magician",
        "-c",
        "user.email=disk-magician@localhost",
        "commit",
        "--quiet",
        "-m",
        &message,
        "--",
    ];
    commit.extend(ALLOWLIST);
    state_publish::git(repo, &commit)?;
    Ok(Ok(Some(
        state_publish::git(repo, &["rev-parse", "HEAD"])?
            .trim()
            .to_owned(),
    )))
}

/// Every existing directory between the repository and the target must be a
/// real directory, so a link cannot redirect the copy outside the work tree.
fn inside_without_links(repo: &Path, relative: &Path) -> io::Result<bool> {
    let mut current = repo.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Ok(false);
        };
        current.push(name);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => return Ok(false),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(true),
            Err(error) => return Err(error),
        }
    }
    Ok(true)
}

pub fn run(options: &Options) -> io::Result<(Value, u8)> {
    let started = SystemTime::now();
    let state = job_receipt::state_dir(options.state_dir.as_deref())?;
    let branch = options
        .publish
        .as_ref()
        .map_or("main", |publish| publish.branch.as_str());
    let precondition = json!({"repo": options.repo, "allowlist": ALLOWLIST});
    let (result, mut code) = match commit(&options.repo, &state, branch) {
        Err(error) => {
            let message = error.to_string();
            job_receipt::publish_terminal(
                &state,
                "state-commit",
                started,
                Completion::Error(&message),
                precondition,
                json!({}),
                json!({}),
            )?;
            return Err(error);
        }
        Ok(Err(reason)) => (json!({"status": "held", "reason": reason}), 75),
        Ok(Ok(None)) => (json!({"status": "unchanged"}), 0),
        Ok(Ok(Some(commit))) => (json!({"status": "committed", "commit": commit}), 0),
    };
    let completion = match result["reason"].as_str() {
        Some(reason) => Completion::Partial(reason),
        None => Completion::Success,
    };
    let receipt = job_receipt::publish_terminal(
        &state,
        "state-commit",
        started,
        completion,
        precondition,
        result.clone(),
        json!({}),
    )?;
    let mut report = json!({"result": result, "receipt": receipt});
    if code == 0 {
        if let Some(publish) = &options.publish {
            let (published, publish_code) = state_publish::run(publish)?;
            report["publish"] = published;
            code = publish_code;
        }
    }
    Ok((report, code))
}

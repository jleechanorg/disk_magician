//! Hourly removal of Scratch folders whose newest content is past the floor.

use crate::scratch_lease::{self, BundleKind, LegacyLease, OwnerProcessState};
use crate::time_windows::{GIT_REMOTE_PROBE_TIMEOUT, PROBE_POLL};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::IpAddr;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// What one complete walk of a unit saw.
#[derive(Default)]
pub struct Observation {
    /// Newest mtime or ctime in nanoseconds, over everything strictly under
    /// the unit plus the unit root's own mtime, excluding `.git` entries.
    pub newest: i64,
    pub complete: bool,
    pub gaps: Vec<String>,
    /// Git directories (`.git` directories or files, bare repositories).
    pub repos: Vec<PathBuf>,
    /// Directories named `evidence`.
    pub evidence: Vec<PathBuf>,
    /// `(alternates file, borrowed object directory)` pairs.
    pub alternates: Vec<(PathBuf, PathBuf)>,
}

fn nanos(seconds: i64, fraction: i64) -> i64 {
    seconds * 1_000_000_000 + fraction
}

fn mtime(info: &fs::Metadata) -> i64 {
    nanos(info.mtime(), info.mtime_nsec())
}

fn alternates_of(git_dir: &Path, found: &mut Observation) {
    let file = git_dir.join("objects/info/alternates");
    if let Ok(text) = fs::read_to_string(&file) {
        for line in text.lines().filter(|line| !line.is_empty()) {
            let target = git_dir.join("objects").join(line);
            found
                .alternates
                .push((file.clone(), fs::canonicalize(&target).unwrap_or(target)));
        }
    }
}

/// Walk `unit` completely. Any gap makes the result incomplete.
pub fn observe(unit: &Path, device: u64, deadline: Instant) -> Observation {
    let mut found = Observation {
        complete: true,
        ..Observation::default()
    };
    match fs::symlink_metadata(unit) {
        Ok(info) => {
            found.newest = mtime(&info);
            if info.is_dir() {
                walk(unit, device, deadline, &mut found);
            }
        }
        Err(error) => found.gaps.push(format!("{}: {error}", unit.display())),
    }
    found.complete = found.gaps.is_empty();
    found
}

fn walk(dir: &Path, device: u64, deadline: Instant, found: &mut Observation) {
    if Instant::now() >= deadline {
        found.gaps.push(format!("{}: deadline", dir.display()));
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) => {
            found.gaps.push(format!("{}: {error}", dir.display()));
            return;
        }
    };
    let mut bare = [false; 3];
    for entry in entries {
        let Ok(entry) = entry else {
            found
                .gaps
                .push(format!("{}: unreadable entry", dir.display()));
            continue;
        };
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            found
                .gaps
                .push(format!("{}: non-UTF-8 name", path.display()));
            continue;
        };
        let info = match fs::symlink_metadata(&path) {
            Ok(info) if info.dev() == device => info,
            Ok(_) => {
                found.gaps.push(format!("{}: other device", path.display()));
                continue;
            }
            Err(error) => {
                found.gaps.push(format!("{}: {error}", path.display()));
                continue;
            }
        };
        match name {
            ".git" => {
                found.repos.push(path.clone());
                alternates_of(&path, found);
                continue;
            }
            "HEAD" if info.is_file() => bare[0] = true,
            "objects" if info.is_dir() => bare[1] = true,
            "refs" if info.is_dir() => bare[2] = true,
            "evidence" if info.is_dir() => found.evidence.push(path.clone()),
            _ => {}
        }
        found.newest = found
            .newest
            .max(mtime(&info))
            .max(nanos(info.ctime(), info.ctime_nsec()));
        if info.is_dir() {
            walk(&path, device, deadline, found);
        }
    }
    if bare == [true; 3] {
        found.repos.push(dir.to_path_buf());
        alternates_of(dir, found);
    }
}

// ---- Git protection: a repository holds unless recovery is proven ----

fn bounded(command: &mut Command, input: Option<String>, limit: Duration) -> io::Result<String> {
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("GIT_TERMINAL_PROMPT", "0");
    let mut child = command.spawn()?;
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        std::thread::spawn(move || stdin.write_all(text.as_bytes()));
    }
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("no stdout"))?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        stdout.read_to_string(&mut text).map(|_| text)
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let text = reader.join().map_err(|_| io::Error::other("reader"))??;
            return if status.success() {
                Ok(text)
            } else {
                Err(io::Error::other(format!("exited with {status}")))
            };
        }
        if started.elapsed() > limit {
            child.kill()?;
            child.wait()?;
            return Err(io::Error::new(io::ErrorKind::TimedOut, "probe timeout"));
        }
        std::thread::sleep(PROBE_POLL);
    }
}

fn git(git_dir: &Path, args: &[&str], input: Option<String>) -> io::Result<String> {
    let mut command = Command::new("git");
    command.arg("--git-dir").arg(git_dir).args(args);
    bounded(&mut command, input, GIT_REMOTE_PROBE_TIMEOUT)
}

/// Whether a remote URL names a hosted network destination that cannot be
/// this machine. `resolve(user, port, host)` is the `ssh -G` hostname.
pub fn independent(url: &str, resolve: &dyn Fn(&str, &str, &str) -> Option<String>) -> bool {
    let scp;
    let (scheme, rest) = match url.split_once("://") {
        Some(parts) => parts,
        None if !url.starts_with(['/', '.'])
            && url.split('/').next().is_some_and(|head| head.contains(':')) =>
        {
            scp = url.replacen(':', "/", 1);
            ("ssh", scp.as_str())
        }
        None => return false,
    };
    let authority = rest.split('/').next().unwrap_or("");
    let (user, hostport) = authority.rsplit_once('@').unwrap_or(("", authority));
    let (host, port) = match hostport.strip_prefix('[') {
        Some(inner) => inner.split_once(']').map_or((inner, ""), |(host, tail)| {
            (host, tail.trim_start_matches(':'))
        }),
        None => hostport
            .rsplit_once(':')
            .filter(|(_, port)| port.bytes().all(|b| b.is_ascii_digit()))
            .unwrap_or((hostport, "")),
    };
    let host = match scheme {
        "https" | "http" | "git" => host.to_owned(),
        "ssh" | "git+ssh" | "ssh+git" => match resolve(user, port, host) {
            Some(host) => host,
            None => return false,
        },
        _ => return false,
    };
    let host = host.trim_matches(['[', ']']).to_ascii_lowercase();
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            let [a, b, ..] = ip.octets();
            !(ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_broadcast()
                || (a == 100 && (64..128).contains(&b)))
        }
        Ok(IpAddr::V6(ip)) => {
            let first = ip.segments()[0];
            !(ip.is_loopback()
                || ip.is_unspecified()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80
                || ip.to_ipv4_mapped().is_some())
        }
        Err(_) => {
            host.contains('.')
                && ![
                    "localhost",
                    ".local",
                    ".lan",
                    ".internal",
                    ".home.arpa",
                    ".localdomain",
                ]
                .iter()
                .any(|local| host.ends_with(local))
        }
    }
}

fn ssh_hostname(user: &str, port: &str, host: &str) -> Option<String> {
    let mut command = Command::new("ssh");
    command.arg("-G");
    if !user.is_empty() {
        command.args(["-l", user]);
    }
    if !port.is_empty() {
        command.args(["-p", port]);
    }
    let text = bounded(command.arg(host), None, GIT_REMOTE_PROBE_TIMEOUT).ok()?;
    text.lines()
        .find_map(|line| line.strip_prefix("hostname ").map(str::to_owned))
}

fn independent_remote(git_dir: &Path, name: &str) -> bool {
    git(git_dir, &["ls-remote", "--get-url", name], None)
        .is_ok_and(|url| independent(url.trim(), &ssh_hostname))
}

fn remote_tips(git_dir: &Path, name: &str) -> io::Result<Vec<String>> {
    let listing = git(git_dir, &["ls-remote", "--heads", "--tags", name], None)?;
    Ok(listing
        .lines()
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect())
}

fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// A repository holds its folder unless every commit is recoverable from a
/// live, independent remote. `within` are the path prefixes that count as the
/// candidate (its original and, while staged, its staged location).
fn git_protected(
    git_dir: &Path,
    within: &[&Path],
    alts: &[(PathBuf, PathBuf)],
    hooks: &Hooks,
) -> Option<&'static str> {
    let inside = |path: &Path| within.iter().any(|prefix| path.starts_with(prefix));
    let failed = Some("deferred:git-probe-failed");
    if git_dir.is_file() {
        let text = fs::read_to_string(git_dir).ok()?;
        let target = text.trim().strip_prefix("gitdir:")?.trim();
        let target = lexical(&git_dir.parent()?.join(target));
        return if inside(&target) {
            None
        } else {
            Some("kept:git-linked-worktree")
        };
    }
    let objects = git_dir.join("objects");
    if alts
        .iter()
        .any(|(file, target)| target.starts_with(&objects) && !inside(file))
    {
        return Some("kept:git-alternates-dependent");
    }
    let Ok(config) = git(git_dir, &["config", "--local", "--list"], None) else {
        return failed;
    };
    let mut remotes = Vec::new();
    for line in config.lines() {
        let (key, value) = line.split_once('=').unwrap_or((line, ""));
        // A non-bare git directory not named `.git` belongs to a working
        // tree elsewhere (`--separate-git-dir`), which deleting would orphan.
        let detached =
            key == "core.bare" && value == "false" && git_dir.file_name() != Some(".git".as_ref());
        if detached || (key == "core.worktree" && !inside(&lexical(&git_dir.join(value)))) {
            return Some("kept:git-external-worktree");
        }
        if let Some(name) = key
            .strip_prefix("remote.")
            .and_then(|key| key.strip_suffix(".url"))
        {
            remotes.push(name.to_owned());
        }
    }
    if let Ok(linked) = fs::read_dir(git_dir.join("worktrees")) {
        for entry in linked {
            let Ok(text) = entry.and_then(|entry| fs::read_to_string(entry.path().join("gitdir")))
            else {
                return failed;
            };
            if !inside(&lexical(Path::new(text.trim()))) {
                return Some("kept:git-external-worktree");
            }
        }
    }
    let mut tips = Vec::new();
    for name in remotes
        .iter()
        .filter(|name| (hooks.independent)(git_dir, name))
    {
        match (hooks.tips)(git_dir, name) {
            Ok(found) => tips.extend(found),
            Err(_) => return failed,
        }
    }
    let known = if tips.is_empty() {
        String::new()
    } else {
        match git(
            git_dir,
            &["cat-file", "--batch-check"],
            Some(tips.join("\n") + "\n"),
        ) {
            Ok(text) => text,
            Err(_) => return failed,
        }
    };
    let live: Vec<&str> = known
        .lines()
        .filter(|line| !line.ends_with("missing"))
        .filter_map(|line| line.split(' ').next())
        .collect();
    let mut args = vec!["rev-list", "--all", "--reflog", "--count"];
    if !live.is_empty() {
        args.push("--not");
        args.extend(live);
    }
    match git(git_dir, &args, None).map(|text| text.trim().parse::<u64>()) {
        Ok(Ok(0)) => None,
        Ok(Ok(_)) => Some("kept:git-unrecovered-commits"),
        _ => failed,
    }
}

// ---- Leases, holds and the plan ----

/// A run is protected when its recorded owner may still be running or its
/// lease is evidence, whatever kind or completion state it records.
pub fn lease_protects(kind: &BundleKind, owner: &OwnerProcessState) -> Option<&'static str> {
    match (kind, owner) {
        (BundleKind::Evidence, _) => Some("kept:evidence-run"),
        (_, OwnerProcessState::Live | OwnerProcessState::Unavailable) => {
            Some("kept:live-or-unknown-owner")
        }
        _ => None,
    }
}

fn run_lease(root: &Path, run: &Path) -> Option<&'static str> {
    match scratch_lease::lookup_bundle_under_root(run, root) {
        Ok(found) => lease_protects(&found.lease.kind, &found.owner_process_state),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            match scratch_lease::legacy_lease(run) {
                Ok(None | Some(LegacyLease::Build { owner_live: false })) => None,
                Ok(Some(_)) => Some("kept:live-or-unknown-owner"),
                Err(_) => Some("deferred:lease-unavailable"),
            }
        }
        Err(_) => Some("deferred:lease-unavailable"),
    }
}

/// Injection points: the remote classifier, the remote tip probe and the lease
/// verdict, so tests need no network and no registered Scratch volume.
pub struct Hooks {
    pub independent: Box<dyn Fn(&Path, &str) -> bool>,
    pub tips: Box<dyn Fn(&Path, &str) -> io::Result<Vec<String>>>,
    pub lease: Box<dyn Fn(&Path, &Path) -> Option<&'static str>>,
}

impl Default for Hooks {
    fn default() -> Self {
        Self {
            independent: Box::new(independent_remote),
            tips: Box::new(remote_tips),
            lease: Box::new(run_lease),
        }
    }
}

pub struct Run {
    pub root: PathBuf,
    pub device: u64,
    /// Content newer than this (nanoseconds since the epoch) is fresh.
    pub cutoff: i64,
    pub clean: bool,
    pub deadline: Instant,
    pub log: PathBuf,
    pub holds: PathBuf,
    pub hooks: Hooks,
}

impl Run {
    pub fn new(root: &Path, device: u64, cutoff: i64) -> Self {
        Self {
            root: root.to_path_buf(),
            device,
            cutoff,
            clean: false,
            deadline: Instant::now() + crate::time_windows::EXPIRED_SWEEP_DEADLINE,
            log: PathBuf::new(),
            holds: PathBuf::new(),
            hooks: Hooks::default(),
        }
    }
}

#[derive(Default)]
pub struct Plan {
    pub removals: Vec<PathBuf>,
    pub kept: Vec<(PathBuf, String)>,
    pub alts: Vec<(PathBuf, PathBuf)>,
    pub timed_out: bool,
}

const DESCENT_DEPTH: u32 = 4;

fn read_holds(path: &Path) -> io::Result<Vec<PathBuf>> {
    match fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice::<BTreeMap<PathBuf, String>>(&bytes)
            .map_err(io::Error::other)?
            .into_keys()
            .collect()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error),
    }
}

fn sorted_children(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut children = fs::read_dir(dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<io::Result<Vec<_>>>()?;
    children.sort();
    Ok(children)
}

fn candidates(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut found = Vec::new();
    for path in sorted_children(root)? {
        let hidden = path
            .file_name()
            .is_none_or(|name| name.as_encoded_bytes().starts_with(b"."));
        if hidden || path.file_name().is_none_or(|name| name.to_str().is_none()) {
            continue;
        }
        if path.file_name().is_some_and(|name| name == "runs")
            && fs::symlink_metadata(&path)?.is_dir()
        {
            runs(&path, 0, &mut found)?;
        } else {
            found.push(path);
        }
    }
    Ok(found)
}

/// `runs/<date>/<repo>/<run>`: each run is a candidate; the levels above stay.
fn runs(dir: &Path, level: u32, found: &mut Vec<PathBuf>) -> io::Result<()> {
    for path in sorted_children(dir)? {
        if level < 2 && fs::symlink_metadata(&path)?.is_dir() {
            runs(&path, level + 1, found)?;
        } else {
            found.push(path);
        }
    }
    Ok(())
}

struct Ctx<'a> {
    run: &'a Run,
    holds: Vec<PathBuf>,
    alts: Vec<(PathBuf, PathBuf)>,
    blind: bool,
    removals: Vec<PathBuf>,
    kept: Vec<(PathBuf, String)>,
}

fn repo_root(git_dir: &Path) -> &Path {
    match git_dir.file_name() {
        Some(name) if name == ".git" => git_dir.parent().unwrap_or(git_dir),
        _ => git_dir,
    }
}

/// Why `path` cannot be removed whole: `(reason, own)` where `own` means the
/// path itself is an indivisible protected subtree, not just a descendant.
/// `full` adds the checks that matter only when removal is on the table.
fn protection(
    run: &Run,
    holds: &[PathBuf],
    alts: &[(PathBuf, PathBuf)],
    blind: bool,
    path: &Path,
    obs: &Observation,
    within: &[&Path],
    full: bool,
) -> io::Result<Option<(String, bool)>> {
    let mut below = None;
    if path.file_name().is_some_and(|name| name == "evidence") {
        return Ok(Some(("evidence".into(), true)));
    }
    for held in holds {
        if path.starts_with(held) {
            return Ok(Some(("pr-evidence".into(), true)));
        }
        if full && held.starts_with(path) {
            below = Some(("pr-evidence".to_owned(), false));
        }
    }
    if full && !obs.evidence.is_empty() {
        below = Some(("evidence".to_owned(), false));
    }
    if let Ok(relative) = path.strip_prefix(&run.root) {
        let parts: Vec<_> = relative.components().collect();
        if parts.len() == 4
            && parts[0].as_os_str() == "runs"
            && fs::symlink_metadata(path)?.is_dir()
        {
            if let Some(reason) = (run.hooks.lease)(&run.root, path) {
                return Ok(Some((reason.into(), true)));
            }
        }
    }
    for git_dir in &obs.repos {
        let own = repo_root(git_dir) == path;
        if !(own || full) {
            continue;
        }
        let reason = if blind {
            Some("deferred:incomplete-alternates-scan")
        } else {
            git_protected(git_dir, within, alts, &run.hooks)
        };
        if let Some(reason) = reason {
            let reason = reason
                .split_once(':')
                .map_or(reason, |(_, rest)| rest)
                .to_owned();
            if own {
                return Ok(Some((reason, true)));
            }
            below = Some((reason, false));
        }
    }
    Ok(below)
}

fn judge(c: &mut Ctx, path: PathBuf, obs: Observation, depth: u32) -> io::Result<()> {
    let stale = obs.complete && obs.newest < c.run.cutoff;
    let held = protection(
        c.run,
        &c.holds,
        &c.alts,
        c.blind,
        &path,
        &obs,
        &[&path],
        stale,
    )?;
    if let Some((reason, true)) = &held {
        c.kept
            .push((path, format!("kept:protected-subtree:{reason}")));
        return Ok(());
    }
    if stale && held.is_none() {
        c.removals.push(path);
        return Ok(());
    }
    let reason = match &held {
        Some((reason, _)) => format!("kept:protected-descendant:{reason}"),
        None if !obs.complete => "deferred:incomplete".into(),
        None => "kept:fresh".into(),
    };
    let is_dir = fs::symlink_metadata(&path)?.is_dir();
    let descend = is_dir && depth < DESCENT_DEPTH;
    let reason = if is_dir && !descend {
        "kept:depth-limit".into()
    } else {
        reason
    };
    c.kept.push((path.clone(), reason));
    if descend {
        for child in sorted_children(&path)? {
            let seen = observe(&child, c.run.device, c.run.deadline);
            judge(c, child, seen, depth + 1)?;
        }
    }
    Ok(())
}

/// Judge every candidate under the Scratch root. Nothing is changed.
pub fn plan(run: &Run) -> io::Result<Plan> {
    let mut units = Vec::new();
    let mut alts = Vec::new();
    for path in candidates(&run.root)? {
        let seen = observe(&path, run.device, run.deadline);
        alts.extend(seen.alternates.iter().cloned());
        units.push((path, seen));
    }
    let blind = units.iter().any(|(_, seen)| !seen.complete);
    let mut ctx = Ctx {
        run,
        holds: read_holds(&run.holds)?,
        alts,
        blind,
        removals: Vec::new(),
        kept: Vec::new(),
    };
    for (path, seen) in units {
        judge(&mut ctx, path, seen, 1)?;
    }
    Ok(Plan {
        removals: ctx.removals,
        kept: ctx.kept,
        alts: ctx.alts,
        timed_out: Instant::now() >= run.deadline,
    })
}

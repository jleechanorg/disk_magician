//! Hourly removal of Scratch folders whose newest content is past the floor.

use crate::scratch_file_transaction::rename_noreplace;
pub use crate::scratch_file_transaction::{open_paths, run_capture};
use crate::scratch_lease::{self, BundleKind, LegacyLease, OwnerProcessState};
use crate::time_windows::GIT_REMOTE_PROBE_TIMEOUT;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::net::{IpAddr, ToSocketAddrs};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// What one complete walk of a unit saw.
#[derive(Default)]
pub struct Observation {
    /// Newest mtime or ctime in nanoseconds, over everything strictly under
    /// the unit plus the unit root's own mtime, excluding `.git` entries.
    pub newest: i64,
    /// The same, over files and links only: removing entries from a staged
    /// tree changes directory times but never a surviving file's.
    pub newest_file: i64,
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

/// Objects borrowed through `objects/info/alternates`; a file that exists but
/// cannot be read is an error, never "no alternates".
fn read_alternates(git_dir: &Path) -> io::Result<Vec<(PathBuf, PathBuf)>> {
    let file = git_dir.join("objects/info/alternates");
    let text = match fs::read_to_string(&file) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    Ok(text
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let target = git_dir.join("objects").join(line);
            (file.clone(), fs::canonicalize(&target).unwrap_or(target))
        })
        .collect())
}

fn alternates_of(git_dir: &Path, found: &mut Observation) {
    if !git_dir.is_dir() {
        return;
    }
    match read_alternates(git_dir) {
        Ok(pairs) => found.alternates.extend(pairs),
        Err(error) => found
            .gaps
            .push(format!("{}: alternates: {error}", git_dir.display())),
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
            } else {
                found.newest_file = found.newest.max(nanos(info.ctime(), info.ctime_nsec()));
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
        let changed = mtime(&info).max(nanos(info.ctime(), info.ctime_nsec()));
        found.newest = found.newest.max(changed);
        if !info.is_dir() {
            found.newest_file = found.newest_file.max(changed);
        }
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
    let (status, stdout, _) = run_capture(command.env("GIT_TERMINAL_PROMPT", "0"), input, limit)?;
    if !status.success() {
        return Err(io::Error::other(format!("exited with {status}")));
    }
    String::from_utf8(stdout).map_err(io::Error::other)
}

fn git(git_dir: &Path, args: &[&str], input: Option<String>) -> io::Result<String> {
    let mut command = Command::new("git");
    command.arg("--git-dir").arg(git_dir).args(args);
    bounded(&mut command, input, GIT_REMOTE_PROBE_TIMEOUT)
}

/// Whether a remote URL names a hosted network destination that cannot be
/// this machine. `resolve(user, port, host)` is the `ssh -G` hostname and
/// `dns(host)` the addresses a name resolves to; a name that cannot be
/// resolved, or resolves to any non-public address, is not independent.
pub fn independent(
    url: &str,
    resolve: &dyn Fn(&str, &str, &str) -> Option<String>,
    dns: &dyn Fn(&str) -> Option<Vec<IpAddr>>,
) -> bool {
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
        Ok(ip) => public(ip),
        Err(_) => {
            dns(&host).is_some_and(|found| !found.is_empty() && found.into_iter().all(public))
        }
    }
}

fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, ..] = ip.octets();
            !(ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_broadcast()
                || (a == 100 && (64..128).contains(&b)))
        }
        IpAddr::V6(ip) => {
            let first = ip.segments()[0];
            !(ip.is_loopback()
                || ip.is_unspecified()
                || first & 0xfe00 == 0xfc00
                || first & 0xffc0 == 0xfe80
                || ip.to_ipv4_mapped().is_some())
        }
    }
}

fn resolve_dns(host: &str) -> Option<Vec<IpAddr>> {
    Some(
        (host, 0)
            .to_socket_addrs()
            .ok()?
            .map(|addr| addr.ip())
            .collect(),
    )
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
        .is_ok_and(|url| independent(url.trim(), &ssh_hostname, &resolve_dns))
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
    tree_inside: bool,
) -> Option<&'static str> {
    let inside = |path: &Path| within.iter().any(|prefix| path.starts_with(prefix));
    let failed = Some("deferred:git-probe-failed");
    if git_dir.is_file() {
        // A gitfile: unparsable or unreadable fails closed; a target outside
        // the candidate is someone else's repository; an internal target is
        // judged as the repository it belongs to (superproject modules, the
        // common directory of a linked worktree).
        let Some(target) = fs::read_to_string(git_dir).ok().and_then(|text| {
            let relative = text.trim().strip_prefix("gitdir:")?.trim().to_owned();
            Some(lexical(&git_dir.parent()?.join(relative)))
        }) else {
            return failed;
        };
        if !inside(&target) {
            return Some("kept:git-linked-worktree");
        }
        let home = match fs::read_to_string(target.join("commondir")) {
            Ok(text) => lexical(&target.join(text.trim())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => target,
            Err(_) => return failed,
        };
        return if home.is_dir() {
            git_protected(&home, within, alts, hooks, true)
        } else {
            failed
        };
    }
    // Alternates name the original location; map each prefix onto this repo.
    let relative = within
        .iter()
        .find_map(|prefix| git_dir.strip_prefix(prefix).ok());
    let lent = |target: &Path| {
        within.iter().any(|prefix| {
            relative.is_some_and(|rel| target.starts_with(prefix.join(rel).join("objects")))
        })
    };
    if alts
        .iter()
        .any(|(file, target)| lent(target) && !inside(file))
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
        let detached = !tree_inside
            && key == "core.bare"
            && value == "false"
            && git_dir.file_name() != Some(".git".as_ref());
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
    match git(git_dir, &["for-each-ref", "refs/stash"], None) {
        Ok(text) if text.trim().is_empty() => {}
        Ok(_) => return Some("kept:git-stash"),
        Err(_) => return failed,
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

/// The lease verdict for the run recorded at `run` whose directory is now at
/// `actual` (the same path unless it is staged).
fn run_lease(root: &Path, run: &Path, actual: &Path) -> Option<&'static str> {
    match scratch_lease::lookup_bundle_at(run, root, (run != actual).then_some(actual)) {
        Ok(found) => lease_protects(&found.lease.kind, &found.owner_process_state),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            match scratch_lease::legacy_lease(run, (run != actual).then_some(actual)) {
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
#[allow(clippy::type_complexity)]
pub struct Hooks {
    pub independent: Box<dyn Fn(&Path, &str) -> bool>,
    pub tips: Box<dyn Fn(&Path, &str) -> io::Result<Vec<String>>>,
    /// `(root, recorded path, current path)`.
    pub lease: Box<dyn Fn(&Path, &Path, &Path) -> Option<&'static str>>,
    /// Whether any process has a file or working directory under the path.
    pub open: Box<dyn Fn(&Path) -> io::Result<bool>>,
    /// Called with the original and staged path right after the rename.
    pub after_stage: Box<dyn Fn(&Path, &Path)>,
    /// Returning true at a named point simulates a crash there.
    pub crash: Box<dyn Fn(&str) -> bool>,
}

impl Default for Hooks {
    fn default() -> Self {
        Self {
            independent: Box::new(independent_remote),
            tips: Box::new(remote_tips),
            lease: Box::new(run_lease),
            open: Box::new(open_paths),
            after_stage: Box::new(|_, _| {}),
            crash: Box::new(|_| false),
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
    /// Every Git directory seen under the root, to re-read alternates at
    /// removal time.
    pub repos: Vec<PathBuf>,
    pub blind: bool,
    pub timed_out: bool,
}

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

/// `(candidates, scan-only)`: hidden entries are never candidates but are
/// still scanned for repositories that may borrow objects. Stages of this job
/// are neither.
fn candidates(root: &Path) -> io::Result<(Vec<PathBuf>, Vec<PathBuf>)> {
    let (mut found, mut hidden) = (Vec::new(), Vec::new());
    for path in sorted_children(root)? {
        let name = path.file_name().unwrap_or_default();
        if name == STAGES {
            continue;
        }
        if name.as_encoded_bytes().starts_with(b".") {
            hidden.push(path);
        } else if name == "runs" && fs::symlink_metadata(&path)?.is_dir() {
            runs(&path, 0, &mut found, &mut hidden)?;
        } else if name.to_str().is_some() {
            found.push(path);
        }
    }
    Ok((found, hidden))
}

/// `runs/<date>/<repo>/<run>`: each run is a candidate; the levels above stay.
fn runs(
    dir: &Path,
    level: u32,
    found: &mut Vec<PathBuf>,
    hidden: &mut Vec<PathBuf>,
) -> io::Result<()> {
    for path in sorted_children(dir)? {
        if path
            .file_name()
            .is_some_and(|name| name.as_encoded_bytes().starts_with(b"."))
        {
            hidden.push(path);
        } else if level < 2 && fs::symlink_metadata(&path)?.is_dir() {
            runs(&path, level + 1, found, hidden)?;
        } else {
            found.push(path);
        }
    }
    Ok(())
}

/// What the whole run knows: evidence holds, the alternates scan, and whether
/// any unit was only partly observed (which blinds that scan).
struct Known {
    holds: Vec<PathBuf>,
    alts: Vec<(PathBuf, PathBuf)>,
    blind: bool,
}

struct Ctx<'a> {
    run: &'a Run,
    known: Known,
    removals: Vec<PathBuf>,
    kept: Vec<(PathBuf, String)>,
}

fn repo_root(git_dir: &Path) -> &Path {
    match git_dir.file_name() {
        Some(name) if name == ".git" => git_dir.parent().unwrap_or(git_dir),
        _ => git_dir,
    }
}

/// The lease verdict for a run directory (`runs/<date>/<repo>/<run>`) recorded
/// at `original` and currently at `actual`; other paths have no lease.
fn lease_of(run: &Run, original: &Path, actual: &Path) -> Option<&'static str> {
    let relative = original.strip_prefix(&run.root).ok()?;
    let is_run = relative.components().count() == 4
        && relative.starts_with("runs")
        && fs::symlink_metadata(actual).is_ok_and(|info| info.is_dir());
    if is_run {
        (run.hooks.lease)(&run.root, original, actual)
    } else {
        None
    }
}

/// Why `path` cannot be removed whole: `(reason, own)` where `own` means the
/// path itself is an indivisible protected subtree, not just a descendant.
/// `full` adds the checks that matter only when removal is on the table.
fn protection(
    run: &Run,
    known: &Known,
    path: &Path,
    obs: &Observation,
    within: &[&Path],
    full: bool,
) -> io::Result<Option<(String, bool)>> {
    let mut below = None;
    if path.file_name().is_some_and(|name| name == "evidence") {
        return Ok(Some(("evidence".into(), true)));
    }
    for held in &known.holds {
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
    if let Some(reason) = lease_of(run, path, path) {
        return Ok(Some((reason.into(), true)));
    }
    for git_dir in &obs.repos {
        let own = repo_root(git_dir) == path;
        // One protected descendant already blocks removal; no more probes.
        if !(own || full) || (!own && below.is_some()) {
            continue;
        }
        let reason = if known.blind {
            Some("deferred:incomplete-alternates-scan")
        } else {
            git_protected(git_dir, within, &known.alts, &run.hooks, false)
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

/// Judge one candidate whole: removed when stale, complete and free of
/// protected content; otherwise kept whole. Active workspaces are never
/// descended into.
fn judge(c: &mut Ctx, path: PathBuf, obs: Observation) -> io::Result<()> {
    let stale = obs.complete && obs.newest < c.run.cutoff;
    let held = protection(c.run, &c.known, &path, &obs, &[&path], stale)?;
    let reason = match held {
        Some((reason, true)) => format!("kept:protected-subtree:{reason}"),
        Some((reason, false)) => format!("kept:protected-descendant:{reason}"),
        None if !obs.complete => "deferred:incomplete".into(),
        None if !stale => "kept:fresh".into(),
        None => {
            c.removals.push(path);
            return Ok(());
        }
    };
    c.kept.push((path, reason));
    Ok(())
}

/// Judge every candidate under the Scratch root. Nothing is changed.
pub fn plan(run: &Run) -> io::Result<Plan> {
    let (mut units, mut alts, mut repos, mut blind) = (Vec::new(), Vec::new(), Vec::new(), false);
    let (found, hidden) = candidates(&run.root)?;
    for (path, judged) in found
        .into_iter()
        .map(|path| (path, true))
        .chain(hidden.into_iter().map(|path| (path, false)))
    {
        let seen = observe(&path, run.device, run.deadline);
        alts.extend(seen.alternates.iter().cloned());
        repos.extend(seen.repos.iter().filter(|dir| dir.is_dir()).cloned());
        blind |= !seen.complete;
        if judged {
            units.push((path, seen));
        }
    }
    let known = Known {
        holds: read_holds(&run.holds)?,
        alts,
        blind,
    };
    let mut ctx = Ctx {
        run,
        known,
        removals: Vec::new(),
        kept: Vec::new(),
    };
    for (path, seen) in units {
        judge(&mut ctx, path, seen)?;
    }
    Ok(Plan {
        removals: ctx.removals,
        kept: ctx.kept,
        alts: ctx.known.alts,
        repos,
        blind: ctx.known.blind,
        timed_out: Instant::now() >= run.deadline,
    })
}

// ---- Removal transaction, recovery and report ----

const STAGES: &str = ".diskm-expired";

/// What a stage records so an interrupted run can be finished or undone.
#[derive(Serialize, Deserialize)]
pub struct Intent {
    /// `staged` (renamed, not yet verified) or `deleting`.
    pub state: String,
    /// Original path relative to the Scratch root.
    pub original: PathBuf,
    pub device: u64,
    pub inode: u64,
    pub newest: i64,
    pub bytes: u64,
    /// The exact deletion-log row, so replay appends it at most once.
    pub row: String,
}

#[derive(Default)]
pub struct Report {
    pub removed: Vec<(PathBuf, u64)>,
    pub would_remove: Vec<PathBuf>,
    pub deferred: Vec<(PathBuf, String)>,
    /// Kept units counted by reason; paths are not listed.
    pub kept: BTreeMap<String, usize>,
    pub interrupted: Vec<String>,
    pub timed_out: bool,
}

/// Longest list the report prints; the rest is counted under `truncated`.
const LIST_CAP: usize = 500;

impl Report {
    /// The printable report: full (capped) lists of what was or would be
    /// removed or deferred, and only counts for everything kept.
    pub fn summary(&self) -> Value {
        let mut truncated = serde_json::Map::new();
        let mut capped = |name: &str, list: Vec<Value>| {
            if list.len() > LIST_CAP {
                truncated.insert(name.into(), json!(list.len() - LIST_CAP));
            }
            list.into_iter().take(LIST_CAP).collect::<Vec<_>>()
        };
        let removed = capped(
            "removed",
            self.removed.iter().map(|row| json!(row)).collect(),
        );
        let would_remove = capped(
            "would_remove",
            self.would_remove.iter().map(|row| json!(row)).collect(),
        );
        let deferred = capped(
            "deferred",
            self.deferred.iter().map(|row| json!(row)).collect(),
        );
        let interrupted = capped(
            "interrupted",
            self.interrupted.iter().map(|row| json!(row)).collect(),
        );
        json!({"removed":removed,"would_remove":would_remove,"deferred":deferred,"interrupted":interrupted,
            "kept":self.kept,"truncated":truncated,"timed_out":self.timed_out})
    }

    pub fn complete(&self) -> bool {
        !self.timed_out
    }
}

fn write_intent(path: &Path, intent: &Intent) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut file = fs::File::create(&temporary)?;
    file.write_all(&serde_json::to_vec(intent).map_err(io::Error::other)?)?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    fs::File::open(path.parent().unwrap_or(path))?.sync_all()
}

fn alive(pid: i32) -> bool {
    (unsafe { libc::kill(pid, 0) } == 0)
        || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn allocated(path: &Path) -> u64 {
    let Ok(info) = fs::symlink_metadata(path) else {
        return 0;
    };
    let children = if info.is_dir() {
        sorted_children(path).unwrap_or_default()
    } else {
        Vec::new()
    };
    info.blocks() * 512 + children.iter().map(|child| allocated(child)).sum::<u64>()
}

fn make_writable(path: &Path) -> io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        for child in sorted_children(path)? {
            make_writable(&child)?;
        }
    }
    Ok(())
}

/// The staged-tree check: identity, completeness, no newer content, no hold,
/// no new evidence directory, the Git proof again, and no open file or
/// working directory. While finishing a half-removed tree only surviving
/// files and links count toward freshness, because our own removals changed
/// directory times.
fn staged_ok(
    run: &Run,
    item: &Path,
    intent: &Intent,
    alts: &[(PathBuf, PathBuf)],
) -> io::Result<bool> {
    let original = run.root.join(&intent.original);
    let info = fs::symlink_metadata(item)?;
    let seen = observe(item, run.device, run.deadline);
    let newer = if intent.state == "staged" {
        seen.newest
    } else {
        seen.newest_file
    } > intent.newest;
    if (info.dev(), info.ino()) != (intent.device, intent.inode)
        || !seen.complete
        || newer
        || !seen.evidence.is_empty()
    {
        return Ok(false);
    }
    if read_holds(&run.holds)?
        .iter()
        .any(|held| original.starts_with(held) || held.starts_with(&original))
        || lease_of(run, &original, item).is_some()
    {
        return Ok(false);
    }
    if seen.repos.iter().any(|git_dir| {
        git_protected(git_dir, &[item, &original], alts, &run.hooks, false).is_some()
    }) {
        return Ok(false);
    }
    Ok(matches!((run.hooks.open)(item), Ok(false)))
}

fn crashed(run: &Run, point: &str) -> io::Result<()> {
    if (run.hooks.crash)(point) {
        return Err(io::Error::other(format!("simulated crash at {point}")));
    }
    Ok(())
}

/// Delete the staged item, then make the receipt durable, then drop the
/// intent. Replaying skips a row already in the log.
fn finish(
    run: &Run,
    stage: &Path,
    intent_path: &Path,
    intent: &mut Intent,
    report: &mut Report,
) -> io::Result<()> {
    let item = stage.join("item");
    if let Ok(info) = fs::symlink_metadata(&item) {
        if intent.state != "deleting" {
            intent.bytes = allocated(&item);
            let timestamp = crate::job_receipt::timestamp(std::time::SystemTime::now())?;
            let path = run
                .root
                .join(&intent.original)
                .to_string_lossy()
                .replace('\t', "\\t")
                .replace('\r', "\\r")
                .replace('\n', "\\n");
            let nonce = stage.file_name().unwrap_or_default().to_string_lossy();
            intent.row = format!(
                "{timestamp}\tdiskm-expired\tremove\t{}\t{path}\t{nonce}\n",
                intent.bytes.div_ceil(1024)
            );
            intent.state = "deleting".into();
            write_intent(intent_path, intent)?;
        }
        if info.is_dir() {
            make_writable(&item)?;
            fs::remove_dir_all(&item)?;
        } else {
            fs::remove_file(&item)?;
        }
    }
    crashed(run, "removed")?;
    crate::scratch_target::flush_audit(&mut Some((run.log.clone(), intent.row.clone())), true)?;
    fs::remove_file(intent_path)?;
    let _ = fs::remove_dir(stage);
    report
        .removed
        .push((run.root.join(&intent.original), intent.bytes));
    Ok(())
}

/// Put the staged item back; if its name is taken keep stage and intent.
fn restore(
    run: &Run,
    stage: &Path,
    intent_path: &Path,
    intent: &Intent,
    report: &mut Report,
) -> io::Result<()> {
    let original = run.root.join(&intent.original);
    crashed(run, "restore")?;
    let verdict = if rename_noreplace(&stage.join("item"), &original).is_ok() {
        fs::remove_file(intent_path)?;
        let _ = fs::remove_dir(stage);
        "deferred:restored"
    } else {
        "deferred:restore-blocked"
    };
    report.deferred.push((original, verdict.into()));
    Ok(())
}

fn remove_unit(run: &Run, plan: &Plan, path: &Path, report: &mut Report) -> io::Result<()> {
    let seen = observe(path, run.device, run.deadline);
    // Borrowers can appear after planning: re-read every known alternates file.
    let alts = plan
        .repos
        .iter()
        .filter(|dir| dir.is_dir())
        .map(|dir| read_alternates(dir))
        .collect::<io::Result<Vec<_>>>();
    let known = Known {
        holds: read_holds(&run.holds)?,
        alts: alts.iter().flatten().flatten().cloned().collect(),
        blind: plan.blind || alts.is_err(),
    };
    let stale = seen.complete && seen.newest < run.cutoff;
    if !stale || protection(run, &known, path, &seen, &[path], true)?.is_some() {
        report
            .deferred
            .push((path.to_path_buf(), "deferred:changed".into()));
        return Ok(());
    }
    let info = fs::symlink_metadata(path)?;
    let name = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos())
    );
    let dir = run.root.join(STAGES);
    let (stage, intent_path) = (dir.join(&name), dir.join(format!("{name}.intent")));
    fs::create_dir_all(&stage)?;
    let mut intent = Intent {
        state: "staged".into(),
        original: path
            .strip_prefix(&run.root)
            .map_err(io::Error::other)?
            .to_path_buf(),
        device: info.dev(),
        inode: info.ino(),
        newest: seen.newest,
        bytes: 0,
        row: String::new(),
    };
    write_intent(&intent_path, &intent)?;
    let item = stage.join("item");
    fs::rename(path, &item)?;
    (run.hooks.after_stage)(path, &item);
    crashed(run, "staged")?;
    if staged_ok(run, &item, &intent, &known.alts).unwrap_or(false) {
        finish(run, &stage, &intent_path, &mut intent, report)
    } else {
        restore(run, &stage, &intent_path, &intent, report)
    }
}

/// Finish or undo the stages of dead processes; a live process's stage is
/// never touched, and a dry run only lists them.
fn recover(run: &Run, plan: &Plan, report: &mut Report) -> io::Result<()> {
    let dir = run.root.join(STAGES);
    let Ok(_) = fs::symlink_metadata(&dir) else {
        return Ok(());
    };
    for intent_path in sorted_children(&dir)? {
        let Some(name) = intent_path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_suffix(".intent"))
        else {
            continue;
        };
        if name
            .split('-')
            .next()
            .and_then(|pid| pid.parse::<i32>().ok())
            .is_none_or(alive)
        {
            continue;
        }
        if !run.clean {
            report.interrupted.push(name.to_owned());
            continue;
        }
        let stage = dir.join(name);
        let item = stage.join("item");
        let mut intent: Intent =
            serde_json::from_slice(&fs::read(&intent_path)?).map_err(io::Error::other)?;
        let present = fs::symlink_metadata(&item).is_ok();
        if intent.state == "deleting" && (!present || staged_ok(run, &item, &intent, &plan.alts)?) {
            finish(run, &stage, &intent_path, &mut intent, report)?;
        } else if present {
            restore(run, &stage, &intent_path, &intent, report)?;
        } else {
            fs::remove_file(&intent_path)?;
            let _ = fs::remove_dir(&stage);
        }
    }
    Ok(())
}

/// Apply a plan: recover interrupted stages, then remove each planned unit
/// through the revalidate, stage, check, delete transaction.
pub fn apply(run: &Run, plan: &Plan) -> io::Result<Report> {
    let mut report = Report {
        timed_out: plan.timed_out,
        ..Report::default()
    };
    for (_, reason) in &plan.kept {
        *report.kept.entry(reason.clone()).or_default() += 1;
    }
    recover(run, plan, &mut report)?;
    if !run.clean {
        report.would_remove = plan.removals.clone();
        return Ok(report);
    }
    for path in &plan.removals {
        if Instant::now() >= run.deadline {
            report.timed_out = true;
            break;
        }
        remove_unit(run, plan, path, &mut report)?;
    }
    Ok(report)
}

pub fn sweep(run: &Run) -> io::Result<Report> {
    apply(run, &plan(run)?)
}

/// `diskm scratch-sweep --expired`: sweep the registered Scratch root.
pub fn run(
    state: &Path,
    options: &crate::scratch_sweep::Options,
    precondition: &mut Value,
) -> io::Result<(Value, bool)> {
    let (root, device) = crate::preview::registered_scratch()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    *precondition = json!({"root":root,"min_hours":options.min_hours,"expired":true});
    let cutoff = crate::preview::current_cutoff(options.min_hours)? * 1_000_000_000;
    let mut run = Run::new(&root, device, cutoff);
    run.clean = options.clean;
    run.deadline = Instant::now() + options.deadline;
    run.log = crate::scratch_target::deletion_log_path()?;
    run.holds = state.join("evidence-holds.json");
    let report = sweep(&run)?;
    let status = if report.complete() {
        "expired_sweep"
    } else {
        "deadline"
    };
    Ok((
        json!({"status":status,"clean":options.clean,"report":report.summary()}),
        report.complete(),
    ))
}

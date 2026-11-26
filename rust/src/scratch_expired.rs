//! Hourly removal of Scratch folders whose newest content is past the floor.

use crate::scratch_file_transaction::rename_noreplace;
pub use crate::scratch_file_transaction::{
    open_paths, open_paths_any, open_paths_any_with, open_paths_with, open_pids_in_proc,
    run_capture,
};
use crate::scratch_lease::{self, BundleKind, LegacyLease, OwnerProcessState};
use crate::time_windows::GIT_REMOTE_PROBE_TIMEOUT;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::net::{IpAddr, ToSocketAddrs};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};
use std::{collections::BTreeMap, fs, process::Command};

/// What one complete walk of a unit saw.
#[derive(Default)]
pub struct Observation {
    pub newest: i64,
    pub newest_file: i64,
    pub complete: bool,
    pub gaps: Vec<String>,
    pub repos: Vec<PathBuf>,
    pub evidence: Vec<PathBuf>,
    pub alternates: Vec<(PathBuf, PathBuf)>,
    pub stores: Vec<PathBuf>,
}

fn nanos(seconds: i64, fraction: i64) -> i64 {
    seconds * 1_000_000_000 + fraction
}

fn mtime(info: &fs::Metadata) -> i64 {
    nanos(info.mtime(), info.mtime_nsec())
}

/// `path` with every symlink resolved. When the tail no longer exists (a
/// lender that has been staged) `..` after a symlink cannot be evaluated, so
/// the lexical form is trusted only if the part that does exist has no symlink
/// in it; otherwise the answer is `None` (unknown), which callers hold.
fn resolve(path: &Path) -> Option<PathBuf> {
    if let Ok(real) = fs::canonicalize(path) {
        return Some(real);
    }
    let mut head = path.to_path_buf();
    while let Err(e) = fs::symlink_metadata(&head) {
        if e.kind() != io::ErrorKind::NotFound {
            return None;
        }
        head = head.parent()?.to_path_buf();
    }
    (fs::canonicalize(&head).ok()? == lexical(&head)).then(|| lexical(path))
}

/// Objects borrowed through `objects/info/alternates`; a file that exists but
/// cannot be read is an error, never "no alternates".
fn unquote_alt(line: &str) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    let b = line.strip_prefix('"')?.strip_suffix('"')?.as_bytes();
    let (mut out, mut i) = (Vec::with_capacity(b.len()), 0);
    while i < b.len() {
        if b[i] != b'\\' {
            out.push(b[i]);
            i += 1;
            continue;
        }
        let e = *b.get(i + 1)?;
        i += 2;
        if let Some(p) = b"abtnvfr".iter().position(|&x| x == e) {
            out.push(p as u8 + 7);
        } else if e == b'\\' || e == b'"' {
            out.push(e);
        } else if (b'0'..=b'3').contains(&e)
            && b.get(i..i + 2)
                .is_some_and(|s| s.iter().all(|c| (b'0'..=b'7').contains(c)))
        {
            out.push(u8::from_str_radix(std::str::from_utf8(&b[i - 1..i + 2]).ok()?, 8).ok()?);
            i += 2;
        } else {
            return None;
        }
    }
    Some(PathBuf::from(std::ffi::OsString::from_vec(out)))
}

fn read_alternates(git_dir: &Path) -> io::Result<Vec<(PathBuf, PathBuf)>> {
    let file = git_dir.join("objects/info/alternates");
    if existing(&file)?.is_none() {
        return Ok(Vec::new());
    }
    fs::read_to_string(&file)?
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let p = if l.starts_with('"') {
                unquote_alt(l)
            } else {
                Some(PathBuf::from(l))
            };
            p.and_then(|p| resolve(&git_dir.join("objects").join(p)))
                .map(|target| (file.clone(), target))
                .ok_or_else(|| io::Error::other("unresolvable alternates path"))
        })
        .collect()
}

/// Every object store behind a `.git` entry or bare repository: the git
/// directory, submodule module directories, and for a gitfile its target. A
/// linked worktree's store is its common repository's, found on its own.
fn git_stores(entry: &Path) -> io::Result<Vec<PathBuf>> {
    fn modules(dir: &Path, out: &mut Vec<PathBuf>) -> io::Result<()> {
        let children = match sorted_children(dir) {
            Ok(children) => children,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        for child in children {
            if !fs::symlink_metadata(&child)?.is_dir() {
                continue;
            }
            match existing(&child.join("HEAD"))? {
                Some(head) if !head.is_dir() => {
                    out.push(child.clone());
                    modules(&child.join("modules"), out)?;
                }
                _ => modules(&child, out)?,
            }
        }
        Ok(())
    }
    let mut stores = Vec::new();
    let home = if fs::symlink_metadata(entry)?.is_file() {
        let target = gitfile_target(entry).ok_or_else(|| io::Error::other("unparsable gitfile"))?;
        if existing(&target.join("commondir"))?.is_some() {
            return Ok(stores);
        }
        target
    } else {
        entry.to_path_buf()
    };
    modules(&home.join("modules"), &mut stores)?;
    stores.push(home);
    Ok(stores)
}

fn gitfile_target(file: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(file).ok()?;
    resolve(
        &file
            .parent()?
            .join(text.trim().strip_prefix("gitdir:")?.trim()),
    )
}

fn collect_stores(entry: &Path, found: &mut Observation) {
    let stores = match git_stores(entry) {
        Ok(s) => s,
        Err(e) => {
            found
                .gaps
                .push(format!("{}: git entry: {e}", entry.display()));
            return;
        }
    };
    for store in stores {
        if store.starts_with(entry.join("modules")) {
            found.repos.push(store.clone());
        }
        if let Err(e) = read_alternates(&store).map(|p| found.alternates.extend(p)) {
            found
                .gaps
                .push(format!("{}: alternates: {e}", store.display()));
        }
        found.stores.push(store);
    }
}

/// Walk `unit` completely. Any gap makes the result incomplete.
pub fn observe(unit: &Path, device: u64, deadline: Instant) -> Observation {
    let mut found = Observation {
        complete: true,
        ..Observation::default()
    };
    if unit.to_str().is_none() {
        found
            .gaps
            .push(format!("{}: non-UTF-8 name", unit.display()));
    }
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
        if Instant::now() >= deadline {
            found.gaps.push(format!("{}: deadline", dir.display()));
            return;
        }
        let g = &mut found.gaps;
        let Ok(entry) = entry else {
            g.push(format!("{}: unreadable entry", dir.display()));
            continue;
        };
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            g.push(format!("{}: non-UTF-8 name", path.display()));
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
                collect_stores(&path, found);
                continue;
            }
            "HEAD" if !info.is_dir() => bare[0] = true,
            "objects" if info.is_dir() || info.is_symlink() => bare[1] = true,
            "refs" if info.is_dir() || info.is_symlink() => bare[2] = true,
            "evidence" if info.is_dir() => found.evidence.push(path.clone()),
            _ => {}
        }
        let changed = mtime(&info).max(nanos(info.ctime(), info.ctime_nsec()));
        found.newest = found.newest.max(changed);
        if info.is_dir() {
            let b = info
                .created()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
            found.newest_file = found.newest_file.max(b.map_or(0, |d| d.as_nanos() as i64));
            walk(&path, device, deadline, found);
        } else {
            found.newest_file = found.newest_file.max(changed);
        }
    }
    if bare == [true; 3] {
        found.repos.push(dir.to_path_buf());
        collect_stores(dir, found);
    }
}

fn bounded(command: &mut Command, input: Option<String>, limit: Duration) -> io::Result<String> {
    let (status, stdout, stderr) =
        run_capture(command.env("GIT_TERMINAL_PROMPT", "0"), input, limit)?;
    if !status.success() {
        return Err(io::Error::other(format!("exited with {status}")));
    }
    if !stderr.is_empty() {
        let first = String::from_utf8_lossy(&stderr);
        let first = first.lines().next().unwrap_or_default();
        return Err(io::Error::other(format!("git-stderr:{first}")));
    }
    String::from_utf8(stdout).map_err(io::Error::other)
}

fn git(d: &Path, args: &[&str], inp: Option<String>, dl: Instant) -> io::Result<String> {
    let rem = dl.saturating_duration_since(Instant::now());
    if rem.is_zero() {
        return Err(io::Error::new(io::ErrorKind::TimedOut, "deadline"));
    }
    let mut cmd = Command::new("git");
    cmd.arg("--no-replace-objects")
        .arg("--git-dir")
        .arg(d)
        .args(args)
        .current_dir(repo_root(d));
    bounded(&mut cmd, inp, GIT_REMOTE_PROBE_TIMEOUT.min(rem))
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
        Err(_) => dns(&host).is_some_and(|f| !f.is_empty() && f.into_iter().all(public)),
    }
}

fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, ..] = ip.octets();
            let bad = ip.is_loopback() || ip.is_private() || ip.is_link_local();
            !(bad
                || ip.is_unspecified()
                || ip.is_broadcast()
                || (a == 100 && (64..128).contains(&b)))
        }
        IpAddr::V6(ip) => {
            let first = ip.segments()[0];
            let bad = ip.is_loopback() || ip.is_unspecified() || first & 0xfe00 == 0xfc00;
            !(bad || first & 0xffc0 == 0xfe80 || ip.to_ipv4_mapped().is_some())
        }
    }
}

fn resolve_dns(host: &str) -> Option<Vec<IpAddr>> {
    Some((host, 0).to_socket_addrs().ok()?.map(|a| a.ip()).collect())
}

fn ssh_hostname(user: &str, port: &str, host: &str) -> Option<String> {
    let mut cmd = Command::new("ssh");
    cmd.args(["-G", "-T"]);
    let _ = [("-l", user), ("-p", port)].map(|(f, v)| {
        if !v.is_empty() {
            cmd.args([f, v]);
        }
    });
    let text = bounded(cmd.arg(host), None, GIT_REMOTE_PROBE_TIMEOUT).ok()?;
    text.lines()
        .find_map(|l| l.strip_prefix("hostname ").map(str::to_owned))
}

fn independent_remote(git_dir: &Path, name: &str) -> bool {
    let dl = Instant::now() + GIT_REMOTE_PROBE_TIMEOUT;
    git(git_dir, &["ls-remote", "--get-url", name], None, dl)
        .is_ok_and(|url| independent(url.trim(), &ssh_hostname, &resolve_dns))
}

fn remote_tips(git_dir: &Path, name: &str) -> io::Result<Vec<String>> {
    let dl = Instant::now() + GIT_REMOTE_PROBE_TIMEOUT;
    let l = git(git_dir, &["ls-remote", "--heads", "--tags", name], None, dl)?;
    Ok(l.lines()
        .filter_map(|s| s.split_whitespace().next().map(str::to_owned))
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

/// Precondition for Git recovery proof: gitdir is listable, symlink-free, and
/// regular files are openable (`objects/` fanout dirs only checked listable).
fn readable(dir: &Path, depth: u8) -> io::Result<()> {
    for child in sorted_children(dir)? {
        let info = fs::symlink_metadata(&child)?;
        let name = child.file_name().and_then(|n| n.to_str());
        if info.is_symlink() {
            return Err(io::Error::other("symlink"));
        } else if info.is_dir() && depth == 1 && !matches!(name, Some("info" | "pack")) {
            fs::read_dir(&child)?;
        } else if info.is_dir() {
            readable(&child, u8::from(depth != 0 || name != Some("objects")) + 1)?;
        } else if info.is_file() {
            fs::File::open(&child)?;
        }
    }
    Ok(())
}

/// A repository holds its folder unless every commit is recoverable from a
/// live, independent remote. `within` are the path prefixes that count as the
/// candidate (its original and, while staged, its staged location).
fn git_protected(
    git_dir: &Path,
    within: &[&Path],
    alts: &[(PathBuf, PathBuf)],
    hooks: &Hooks,
    ti: bool,
    deadline: Instant,
) -> Option<&'static str> {
    let tree_inside = ti
        || git_dir
            .ancestors()
            .skip(1)
            .any(|u| u.file_name() == Some(".git".as_ref()));
    let physical: Vec<PathBuf> = within.iter().filter_map(|p| resolve(p)).collect();
    let inside = |p: &Path| resolve(p).is_some_and(|p| physical.iter().any(|x| p.starts_with(x)));
    let failed = Some("deferred:git-probe-failed");
    let Ok(git_entry) = fs::symlink_metadata(git_dir) else {
        return failed;
    };
    if git_entry.is_symlink() {
        return failed;
    }
    if git_entry.is_file() {
        // A gitfile: unparsable or unreadable fails closed; a target outside
        // the candidate is someone else's repository.
        let Some(target) = gitfile_target(git_dir) else {
            return failed;
        };
        if !inside(&target) {
            return Some("kept:git-linked-worktree");
        }
        // A linked worktree (its gitdir has a `commondir`) is held without
        // exception: its owner cannot be established from Scratch. Anything
        // else inside the candidate is a submodule or separate git directory,
        // judged as the repository it is.
        return match existing(&target.join("commondir")) {
            Ok(Some(_)) => Some("kept:git-linked-worktree"),
            Ok(None) if fs::symlink_metadata(&target).is_ok_and(|i| i.is_dir()) => {
                git_protected(&target, within, alts, hooks, true, deadline)
            }
            _ => failed,
        };
    }
    // Alternates name the original location; map each prefix onto this repo.
    let Some(relative) = within.iter().find_map(|p| git_dir.strip_prefix(p).ok()) else {
        return failed;
    };
    let lent = |t: &Path| {
        within
            .iter()
            .any(|p| t.starts_with(p.join(relative).join("objects")))
    };
    if alts
        .iter()
        .any(|(file, target)| lent(target) && !inside(file))
    {
        return Some("kept:git-alternates-dependent");
    }
    if readable(git_dir, 0).is_err() {
        return failed;
    }
    let Ok(config) = git(git_dir, &["config", "--local", "--list"], None, deadline) else {
        return failed;
    };
    let has_wt = config.lines().any(|l| l.starts_with("core.worktree="));
    let remotes: Vec<_> = config
        .lines()
        .filter_map(|l| {
            let k = l.split_once('=').map_or(l, |(k, _)| k);
            k.strip_prefix("remote.")
                .and_then(|k| k.strip_suffix(".url"))
                .map(str::to_owned)
        })
        .collect();
    // Never gate on a config key: Git itself says whether there is a working
    // tree (`config.worktree` and other sources included) and where it is.
    match git(
        git_dir,
        &["rev-parse", "--is-bare-repository"],
        None,
        deadline,
    ) {
        Ok(text) if text.trim() == "true" => {}
        Ok(_) => {
            // A non-bare git directory not named `.git` belongs to a working
            // tree elsewhere (`--separate-git-dir`), which deleting would orphan.
            if !tree_inside && !has_wt && git_dir.file_name() != Some(".git".as_ref()) {
                return Some("kept:git-external-worktree");
            }
            let Ok(top) = git(git_dir, &["rev-parse", "--show-toplevel"], None, deadline) else {
                return failed;
            };
            let top = top.trim();
            if top.is_empty() {
                return failed;
            }
            if !inside(Path::new(top)) {
                return Some("kept:git-external-worktree");
            }
        }
        Err(_) => return failed,
    }
    match fs::read_dir(git_dir.join("worktrees")) {
        Ok(linked) => {
            for entry in linked {
                let Ok(text) =
                    entry.and_then(|entry| fs::read_to_string(entry.path().join("gitdir")))
                else {
                    return failed;
                };
                if !inside(Path::new(text.trim())) {
                    return Some("kept:git-external-worktree");
                }
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(_) => return failed,
    }
    match git(git_dir, &["for-each-ref", "refs/stash"], None, deadline) {
        Ok(text) if text.trim().is_empty() => {}
        Ok(_) => return Some("kept:git-stash"),
        Err(_) => return failed,
    }
    let mut tips = Vec::new();
    for name in remotes.iter().filter(|n| (hooks.independent)(git_dir, n)) {
        if Instant::now() >= deadline {
            return failed;
        }
        match (hooks.tips)(git_dir, name) {
            Ok(found) => tips.extend(found),
            Err(_) => return failed,
        }
    }
    let inp = (!tips.is_empty()).then(|| tips.join("\n") + "\n");
    let res = inp.map_or(Ok(String::new()), |s| {
        git(git_dir, &["cat-file", "--batch-check"], Some(s), deadline)
    });
    let Ok(known) = res else {
        return failed;
    };
    let live: Vec<&str> = known
        .lines()
        .filter(|l| !l.ends_with("missing"))
        .filter_map(|l| l.split(' ').next())
        .collect();
    if !matches!(existing(&git_dir.join("info/grafts")), Ok(None)) {
        return Some("kept:git-unrecovered-commits");
    }
    let mut args = vec!["rev-list", "--all", "--reflog", "--count"];
    if !live.is_empty() {
        args.push("--not");
        args.extend(live);
    }
    match git(git_dir, &args, None, deadline).map(|text| text.trim().parse::<u64>()) {
        Ok(Ok(0)) => None,
        Ok(Ok(_)) => Some("kept:git-unrecovered-commits"),
        _ => failed,
    }
}

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
            match scratch_lease::legacy_lease(run, (run != actual).then_some(actual), true) {
                Ok(None | Some(LegacyLease::Build { owner_live: false })) => None,
                Ok(Some(_)) => Some("kept:live-or-unknown-owner"),
                Err(_) => Some("deferred:lease-unavailable"),
            }
        }
        Err(_) => Some("deferred:lease-unavailable"),
    }
}

/// Injection points for tests (remote classifier, tip probe, lease, open, hooks).
#[allow(clippy::type_complexity)]
pub struct Hooks {
    pub independent: Box<dyn Fn(&Path, &str) -> bool>,
    pub tips: Box<dyn Fn(&Path, &str) -> io::Result<Vec<String>>>,
    pub lease: Box<dyn Fn(&Path, &Path, &Path) -> Option<&'static str>>,
    pub open: Box<dyn Fn(&[&Path]) -> io::Result<bool>>,
    pub after_stage: Box<dyn Fn(&Path, &Path)>,
    pub crash: Box<dyn Fn(&str) -> bool>,
}

impl Default for Hooks {
    fn default() -> Self {
        Self {
            independent: Box::new(independent_remote),
            tips: Box::new(remote_tips),
            lease: Box::new(run_lease),
            open: Box::new(open_paths_any),
            after_stage: Box::new(|_, _| {}),
            crash: Box::new(|_| false),
        }
    }
}

pub struct Run {
    pub root: PathBuf,
    pub paths: Vec<PathBuf>,
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
            paths: Vec::new(),
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
    /// Every object store seen under the root, to re-read alternates cheaply.
    pub stores: Vec<PathBuf>,
    pub blind: bool,
    pub timed_out: bool,
}

fn read_holds(path: &Path) -> io::Result<Vec<PathBuf>> {
    if existing(path)?.is_none() {
        return Ok(Vec::new());
    }
    let bytes = fs::read(path)?;
    let m: BTreeMap<PathBuf, String> = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    Ok(m.into_keys().collect())
}

fn sorted_children(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut c: Vec<_> = fs::read_dir(dir)?
        .map(|e| e.map(|e| e.path()))
        .collect::<io::Result<_>>()?;
    c.sort();
    Ok(c)
}

/// `(candidates, scan-only)`: hidden entries are never candidates but are
/// still scanned for repositories that may borrow objects. Stages of this job
/// and unreadable macOS APFS volume metadata directories at the root are neither.
fn candidates(root: &Path) -> io::Result<(Vec<PathBuf>, Vec<PathBuf>)> {
    let (mut found, mut hidden) = (Vec::new(), Vec::new());
    for path in sorted_children(root)? {
        let name = path.file_name().unwrap_or_default();
        if name == STAGES || crate::scan::is_unreadable_macos_volume_metadata(&path, name) {
            continue;
        } else if name.as_encoded_bytes().starts_with(b".") {
            hidden.push(path);
        } else if name == "runs" && fs::symlink_metadata(&path)?.is_dir() {
            runs(&path, 0, &mut found, &mut hidden)?;
        } else {
            found.push(path);
        }
    }
    Ok((found, hidden))
}

/// `runs/<date>/<repo>/<run>`: each run is a candidate; the levels above stay.
fn runs(dir: &Path, lvl: u32, out: &mut Vec<PathBuf>, hid: &mut Vec<PathBuf>) -> io::Result<()> {
    for path in sorted_children(dir)? {
        let dot = path
            .file_name()
            .is_some_and(|n| n.as_encoded_bytes().starts_with(b"."));
        if dot {
            hid.push(path);
        } else if lvl < 2 && fs::symlink_metadata(&path)?.is_dir() {
            runs(&path, lvl + 1, out, hid)?;
        } else {
            out.push(path);
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
    if relative.components().count() != 4 || !relative.starts_with("runs") {
        return None;
    }
    let Ok(info) = fs::symlink_metadata(actual) else {
        return Some("deferred:lease-unavailable");
    };
    info.is_dir()
        .then(|| (run.hooks.lease)(&run.root, original, actual))
        .flatten()
}

fn has_gf(repos: &[PathBuf], d: &Path) -> bool {
    repos
        .iter()
        .any(|r| gitfile_target(r).as_deref() == Some(d))
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
    let rel = path.strip_prefix(&run.root).unwrap_or(path);
    if rel.components().any(|c| c.as_os_str() == "evidence") {
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
        if !own && (!full || below.is_some()) {
            continue;
        }
        if Instant::now() >= run.deadline {
            return Ok(Some(("incomplete".into(), own)));
        }
        let (alts, hooks, dl, ti) = (
            &known.alts,
            &run.hooks,
            run.deadline,
            has_gf(&obs.repos, git_dir),
        );
        let reason = if known.blind {
            Some("deferred:incomplete-alternates-scan")
        } else {
            git_protected(git_dir, within, alts, hooks, ti, dl)
        };
        if let Some(reason) = reason {
            let reason = reason.split_once(':').map_or(reason, |(_, r)| r).to_owned();
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
    let stale = obs.complete && obs.newest.max(obs.newest_file) < c.run.cutoff;
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
    let (mut units, mut alts, mut stores, mut blind) = (Vec::new(), Vec::new(), Vec::new(), false);
    let (mut found, mut hidden) = candidates(&run.root)?;
    if !run.paths.is_empty() {
        if run.paths.iter().any(|path| {
            !found.contains(path)
                || !path.is_dir()
                || crate::preview::check_path(&run.root, path, run.device).is_some()
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "not an exact expired Scratch candidate",
            ));
        }
        found.retain(|path| run.paths.contains(path));
        hidden.clear();
    }
    let items: Vec<(PathBuf, bool)> = found
        .into_iter()
        .map(|p| (p, true))
        .chain(hidden.into_iter().map(|p| (p, false)))
        .collect();
    let workers = std::thread::available_parallelism()
        .map_or(4, |n| n.get())
        .clamp(1, 8)
        .min(items.len().max(1));
    let (device, deadline) = (run.device, run.deadline);
    let next = std::sync::atomic::AtomicUsize::new(0);
    let mut observed: Vec<(usize, Observation)> = std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(workers);
        for _ in 0..workers {
            handles.push(scope.spawn(|| {
                let mut local = Vec::new();
                loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let Some((path, _)) = items.get(i) else { break };
                    local.push((i, observe(path, device, deadline)));
                }
                local
            }));
        }
        let mut all = Vec::with_capacity(items.len());
        for handle in handles {
            all.extend(
                handle
                    .join()
                    .expect("expired-sweep observer thread panicked"),
            );
        }
        all
    });
    observed.sort_unstable_by_key(|(i, _)| *i);
    for ((path, judged), (_, seen)) in items.into_iter().zip(observed) {
        alts.extend(seen.alternates.iter().cloned());
        stores.extend(seen.stores.iter().cloned());
        blind |= !seen.complete;
        if judged {
            units.push((path, seen));
        }
    }
    let known = if !run.paths.is_empty() && units.iter().any(|(_, seen)| !seen.repos.is_empty()) {
        fresh_known(run)?
    } else {
        Known {
            holds: read_holds(&run.holds)?,
            alts,
            blind,
        }
    };
    let mut ctx = Ctx {
        run,
        known,
        removals: Vec::new(),
        kept: Vec::new(),
    };
    for (path, seen) in units {
        if Instant::now() >= run.deadline {
            ctx.kept.push((path, "deferred:incomplete".into()));
        } else {
            judge(&mut ctx, path, seen)?;
        }
    }
    Ok(Plan {
        removals: ctx.removals,
        kept: ctx.kept,
        alts: ctx.known.alts,
        stores,
        blind: ctx.known.blind,
        timed_out: Instant::now() >= run.deadline,
    })
}

const STAGES: &str = ".diskm-expired";

/// What a stage records so an interrupted run can be finished or undone.
#[derive(Serialize, Deserialize)]
pub struct Intent {
    pub state: String,
    pub original: PathBuf,
    pub device: u64,
    pub inode: u64,
    pub newest: i64,
    pub bytes: u64,
    pub row: String,
}

#[derive(Default)]
pub struct Report {
    pub removed: Vec<(PathBuf, u64)>,
    pub would_remove: Vec<PathBuf>,
    pub deferred: Vec<(PathBuf, String)>,
    pub kept: BTreeMap<String, usize>,
    pub interrupted: Vec<String>,
    pub timed_out: bool,
}

const LIST_CAP: usize = 500;

impl Report {
    /// Printable report: capped lists for removed/would_remove/deferred, counts for kept.
    pub fn summary(&self) -> Value {
        let mut truncated = serde_json::Map::new();
        let mut cap = |n: &str, v: Vec<Value>| {
            if v.len() > LIST_CAP {
                truncated.insert(n.into(), json!(v.len() - LIST_CAP));
            }
            v.into_iter().take(LIST_CAP).collect::<Vec<_>>()
        };
        let t = |p: &Path| p.to_string_lossy().into_owned();
        let rem: Vec<_> = self.removed.iter().map(|(p, b)| json!([t(p), b])).collect();
        let wr: Vec<_> = self.would_remove.iter().map(|p| json!(t(p))).collect();
        let def: Vec<_> = self
            .deferred
            .iter()
            .map(|(p, w)| json!([t(p), w]))
            .collect();
        let int: Vec<_> = self.interrupted.iter().map(|r| json!(r)).collect();
        json!({"removed": cap("removed", rem), "would_remove": cap("would_remove", wr),
            "deferred": cap("deferred", def), "interrupted": cap("interrupted", int),
            "kept": self.kept, "truncated": truncated, "timed_out": self.timed_out})
    }

    pub fn complete(&self) -> bool {
        !self.timed_out
            && !self.kept.keys().any(|k| incomplete_reason(k))
            && !self.deferred.iter().any(|(_, r)| incomplete_reason(r))
    }
}

fn incomplete_reason(r: &str) -> bool {
    let a = ["incomplete", "probe-error:", "check-error:"];
    let b = ["git-probe-failed", "lease-unavailable", "restore-blocked"];
    a.iter().chain(&b).any(|s| r.contains(s))
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
    let e = || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    (unsafe { libc::kill(pid, 0) } == 0) || e()
}

fn allocated(path: &Path) -> u64 {
    let Ok(info) = fs::symlink_metadata(path) else {
        return 0;
    };
    let kids = if info.is_dir() {
        sorted_children(path).unwrap_or_default()
    } else {
        Vec::new()
    };
    info.blocks() * 512 + kids.iter().map(|c| allocated(c)).sum::<u64>()
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

/// The staged-tree verdict. Repositories need the borrower scan (`NeedsScan`).
enum Verdict {
    Pass,
    NeedsScan,
    Fail(String),
}

fn staged_ok(
    run: &Run,
    item: &Path,
    intent: &Intent,
    known: Option<&Known>,
) -> io::Result<Verdict> {
    use Verdict::Fail;
    let short = |r: &str| r.split_once(':').map_or(r, |(_, s)| s).to_owned();
    let original = run.root.join(&intent.original);
    let info = fs::symlink_metadata(item)?;
    let seen = observe(item, run.device, run.deadline);
    let newest = if intent.state == "staged" {
        seen.newest
    } else {
        seen.newest_file
    };
    if let Some(reason) = match () {
        _ if (info.dev(), info.ino()) != (intent.device, intent.inode) => Some("identity".into()),
        _ if !seen.complete => Some(format!(
            "incomplete:{}",
            seen.gaps.first().map_or("", String::as_str)
        )),
        _ if !seen.evidence.is_empty() => Some("evidence".into()),
        _ if newest > intent.newest => Some("fresh-content".into()),
        _ => None,
    } {
        return Ok(Fail(reason));
    }
    let holds = read_holds(&run.holds)?;
    if holds
        .iter()
        .any(|h| original.starts_with(h) || h.starts_with(&original))
    {
        return Ok(Fail("hold".into()));
    }
    if let Some(reason) = lease_of(run, &original, item) {
        return Ok(Fail(format!("lease-{}", short(reason))));
    }
    match (run.hooks.open)(&[item, &original]) {
        Ok(false) => {}
        Ok(true) => return Ok(Fail("open-file".into())),
        Err(error) => return Ok(Fail(format!("probe-error:{error}"))),
    }
    if seen.repos.is_empty() {
        return Ok(Verdict::Pass);
    }
    let Some(known) = known else {
        return Ok(Verdict::NeedsScan);
    };
    // The borrower scan was incomplete: no repository can be proven unborrowed.
    if known.blind {
        return Ok(Fail("alternates-scan-incomplete".into()));
    }
    let (alts, hooks, dl, pair) = (&known.alts, &run.hooks, run.deadline, [item, &original]);
    for git_dir in &seen.repos {
        let ti = has_gf(&seen.repos, git_dir);
        if let Some(reason) = git_protected(git_dir, &pair, alts, hooks, ti, dl) {
            return Ok(Fail(short(reason)));
        }
    }
    Ok(Verdict::Pass)
}

/// Metadata of `path`, or `None` only when it is truly absent.
fn existing(path: &Path) -> io::Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(info) => Ok(Some(info)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn crashed(run: &Run, point: &str) -> io::Result<()> {
    (!(run.hooks.crash)(point))
        .then_some(())
        .ok_or_else(|| io::Error::other(format!("simulated crash at {point}")))
}

/// Delete the staged item, then make the receipt durable, then drop the
/// intent. Replaying skips a row already in the log.
fn finish(run: &Run, s: &Path, ip: &Path, i: &mut Intent, r: &mut Report) -> io::Result<()> {
    let item = s.join("item");
    if let Some(info) = existing(&item)? {
        if i.state != "deleting" {
            i.bytes = allocated(&item);
            let timestamp = crate::job_receipt::timestamp(std::time::SystemTime::now())?;
            let p = run.root.join(&i.original).to_string_lossy().into_owned();
            let path = p
                .replace('\t', "\\t")
                .replace('\r', "\\r")
                .replace('\n', "\\n");
            let nonce = s.file_name().unwrap_or_default().to_string_lossy();
            i.row = format!(
                "{timestamp}\tdiskm-expired\tremove\t{}\t{path}\t{nonce}\n",
                i.bytes.div_ceil(1024)
            );
            i.state = "deleting".into();
            write_intent(ip, i)?;
        }
        if info.is_dir() {
            make_writable(&item)?;
            fs::remove_dir_all(&item)?;
        } else {
            fs::remove_file(&item)?;
        }
    }
    crashed(run, "removed")?;
    crate::scratch_target::flush_audit(&mut Some((run.log.clone(), i.row.clone())), true)?;
    fs::remove_file(ip)?;
    let _ = fs::remove_dir(s);
    r.removed.push((run.root.join(&i.original), i.bytes));
    Ok(())
}

/// Put the staged item back; if its name is taken keep stage and intent.
fn restore(run: &Run, s: &Path, ip: &Path, i: &Intent, c: &str, r: &mut Report) -> io::Result<()> {
    let original = run.root.join(&i.original);
    crashed(run, "restore")?;
    let verdict: String = if rename_noreplace(&s.join("item"), &original).is_ok() {
        fs::remove_file(ip)?;
        let _ = fs::remove_dir(s);
        format!("deferred:restored:{c}")
    } else {
        "deferred:restore-blocked".into()
    };
    r.deferred.push((original, verdict));
    Ok(())
}

/// One pass over the whole root, reading directory entries only, for every
/// object store; a directory it cannot read marks the scan incomplete.
fn scan_stores(
    dir: &Path,
    is_root: bool,
    deadline: Instant,
    out: &mut Vec<PathBuf>,
    complete: &mut bool,
) {
    let Ok(entries) = fs::read_dir(dir) else {
        *complete = false;
        return;
    };
    let (mut bare, mut subdirs) = ([false; 3], Vec::new());
    for entry in entries {
        if Instant::now() >= deadline {
            *complete = false;
            return;
        }
        let Ok((entry, kind)) = entry.and_then(|entry| entry.file_type().map(|kind| (entry, kind)))
        else {
            *complete = false;
            continue;
        };
        if is_root
            && crate::scan::is_unreadable_macos_volume_metadata(&entry.path(), &entry.file_name())
        {
            continue;
        }
        match entry.file_name().to_str() {
            Some(".git") => match git_stores(&entry.path()) {
                Ok(stores) => out.extend(stores),
                Err(_) => *complete = false,
            },
            Some("HEAD") if !kind.is_dir() => bare[0] = true,
            Some("objects") if kind.is_dir() || kind.is_symlink() => bare[1] = true,
            Some("refs") if kind.is_dir() || kind.is_symlink() => bare[2] = true,
            _ => {}
        }
        if kind.is_dir() && entry.file_name() != ".git" {
            subdirs.push(entry.path());
        }
    }
    if bare == [true; 3] {
        if git_stores(dir).map(|s| out.extend(s)).is_err() {
            *complete = false;
        }
        return;
    }
    for sub in subdirs {
        if Instant::now() >= deadline {
            *complete = false;
            return;
        }
        scan_stores(&sub, false, deadline, out, complete);
    }
}

/// Holds and borrower dependencies as they are now, found by a fresh pass.
fn fresh_known(run: &Run) -> io::Result<Known> {
    let (mut stores, mut complete) = (Vec::new(), true);
    scan_stores(&run.root, true, run.deadline, &mut stores, &mut complete);
    let mut alts = Vec::new();
    for store in &stores {
        match read_alternates(store) {
            Ok(pairs) => alts.extend(pairs),
            Err(_) => complete = false,
        }
    }
    Ok(Known {
        holds: read_holds(&run.holds)?,
        alts,
        blind: !complete,
    })
}

/// A unit renamed into its stage, awaiting the staged-tree check.
struct Staged {
    stage: PathBuf,
    intent_path: PathBuf,
    intent: Intent,
}

fn stage_unit(
    run: &Run,
    plan: &Plan,
    path: &Path,
    report: &mut Report,
) -> io::Result<Option<Staged>> {
    let seen = observe(path, run.device, run.deadline);
    let alts: io::Result<Vec<_>> = plan.stores.iter().map(|d| read_alternates(d)).collect();
    let blind = plan.blind
        || alts.is_err()
        || (!run.paths.is_empty() && seen.stores.iter().any(|store| !plan.stores.contains(store)));
    let alts = alts.iter().flatten().flatten().cloned().collect();
    let known = Known {
        holds: read_holds(&run.holds)?,
        alts,
        blind,
    };
    let stale = seen.complete && seen.newest.max(seen.newest_file) < run.cutoff;
    let prot = protection(run, &known, path, &seen, &[path], true)?;
    if let Some(why) = match prot.as_ref().map(|(r, _)| r.as_str()) {
        Some(r) if incomplete_reason(r) => Some(format!("deferred:{r}")),
        Some(_) => Some("deferred:changed".into()),
        None if !seen.complete => Some("deferred:incomplete".into()),
        None if !stale => Some("deferred:changed".into()),
        None => match (run.hooks.open)(&[path]) {
            Ok(true) => Some("deferred:open-file".into()),
            Err(e) => Some(format!("deferred:probe-error:{e}")),
            Ok(false) => None,
        },
    } {
        report.deferred.push((path.to_path_buf(), why));
        return Ok(None);
    }
    let info = fs::symlink_metadata(path)?;
    let epoch = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    let name = format!(
        "{}-{}",
        std::process::id(),
        epoch.map_or(0, |e| e.as_nanos())
    );
    let dir = run.root.join(STAGES);
    let _ = safe_stages(&dir, run.device)?;
    let (stage, intent_path) = (dir.join(&name), dir.join(format!("{name}.intent")));
    fs::create_dir_all(&stage)?;
    let original = path
        .strip_prefix(&run.root)
        .map_err(io::Error::other)?
        .to_path_buf();
    let intent = Intent {
        state: "staged".into(),
        original,
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
    Ok(Some(Staged {
        stage,
        intent_path,
        intent,
    }))
}

fn safe_stages(dir: &Path, device: u64) -> io::Result<bool> {
    let Some(m) = existing(dir)? else {
        return Ok(false);
    };
    if m.file_type().is_symlink() || !m.is_dir() || m.dev() != device {
        return Err(io::Error::other("unsafe staging root"));
    }
    Ok(true)
}

/// Recover stages of dead processes (dry run only lists them).
fn recover(run: &Run, report: &mut Report) -> io::Result<()> {
    let dir = run.root.join(STAGES);
    if !safe_stages(&dir, run.device)? {
        return Ok(());
    }
    for intent_path in sorted_children(&dir)? {
        let f = intent_path.file_name().and_then(|n| n.to_str());
        let Some(name) = f.and_then(|n| n.strip_suffix(".intent")) else {
            continue;
        };
        let pid = name.split('-').next().and_then(|p| p.parse::<i32>().ok());
        if pid.is_none_or(alive) {
            continue;
        }
        if !run.clean {
            report.interrupted.push(name.to_owned());
            continue;
        }
        let stage = dir.join(name);
        if fs::symlink_metadata(&stage)
            .is_ok_and(|m| m.file_type().is_symlink() || m.dev() != run.device)
        {
            return Err(io::Error::other("unsafe stage"));
        }
        let item = stage.join("item");
        let mut intent: Intent =
            serde_json::from_slice(&fs::read(&intent_path)?).map_err(io::Error::other)?;
        if intent.original.as_os_str().is_empty()
            || !intent
                .original
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_)))
        {
            return Err(io::Error::other("unsafe original path"));
        }
        let present = existing(&item)?.is_some();
        let cause = if present && intent.state == "deleting" {
            let v = match staged_ok(run, &item, &intent, None)? {
                Verdict::NeedsScan => staged_ok(run, &item, &intent, Some(&fresh_known(run)?))?,
                other => other,
            };
            match v {
                Verdict::Pass => None,
                Verdict::Fail(c) => Some(c),
                Verdict::NeedsScan => Some("scan-unavailable".into()),
            }
        } else {
            Some("interrupted-stage".into())
        };
        if intent.state == "deleting" && (!present || cause.is_none()) {
            finish(run, &stage, &intent_path, &mut intent, report)?;
        } else if present {
            let c = cause.unwrap_or_default();
            restore(run, &stage, &intent_path, &intent, &c, report)?;
        } else {
            fs::remove_file(&intent_path)?;
            let _ = fs::remove_dir(&stage);
        }
    }
    Ok(())
}

/// Recover interrupted stages, then apply `plan`.
pub fn apply(run: &Run, plan: &Plan) -> io::Result<Report> {
    let mut report = Report {
        timed_out: plan.timed_out,
        ..Report::default()
    };
    for (_, reason) in &plan.kept {
        *report.kept.entry(reason.clone()).or_default() += 1;
    }
    if run.paths.is_empty() {
        recover(run, &mut report)?;
    }
    if !run.clean {
        report.would_remove = plan.removals.clone();
        return Ok(report);
    }
    let step = |u: &mut Staged, k: Option<&Known>, rep: &mut Report| -> io::Result<bool> {
        let (s, p, item) = (&u.stage, &u.intent_path, u.stage.join("item"));
        let v = staged_ok(run, &item, &u.intent, k);
        match v.unwrap_or_else(|e| Verdict::Fail(format!("check-error:{e}"))) {
            Verdict::Pass if Instant::now() >= run.deadline => {
                rep.timed_out = true;
                restore(run, s, p, &u.intent, "deadline", rep).map(|_| false)
            }
            Verdict::Pass => finish(run, s, p, &mut u.intent, rep).map(|_| false),
            Verdict::Fail(c) => restore(run, s, p, &u.intent, &c, rep).map(|_| false),
            Verdict::NeedsScan if k.is_none() => Ok(true),
            Verdict::NeedsScan => {
                restore(run, s, p, &u.intent, "scan-unavailable", rep).map(|_| false)
            }
        }
    };
    let mut pending = Vec::new();
    for path in &plan.removals {
        if Instant::now() >= run.deadline {
            report.timed_out = true;
            break;
        }
        let Some(mut unit) = stage_unit(run, plan, path, &mut report)? else {
            continue;
        };
        if step(&mut unit, None, &mut report)? {
            pending.push(unit);
        }
    }
    if pending.is_empty() {
        return Ok(report);
    }
    let known = fresh_known(run)?;
    for mut unit in pending {
        step(&mut unit, Some(&known), &mut report)?;
    }
    Ok(report)
}

pub fn sweep(run: &Run) -> io::Result<Report> {
    let mut report = apply(run, &plan(run)?)?;
    report.timed_out |= Instant::now() >= run.deadline;
    Ok(report)
}

/// `diskm scratch-sweep --expired`: sweep the registered Scratch root.
pub fn run(
    state: &Path,
    options: &crate::scratch_sweep::Options,
    precondition: &mut Value,
) -> io::Result<(Value, bool)> {
    let deadline = Instant::now() + options.deadline;
    let (root, device) = crate::preview::registered_scratch()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    *precondition =
        json!({"root":root,"min_hours":options.min_hours,"expired":true,"paths":options.paths});
    let cutoff = crate::preview::current_cutoff(options.min_hours)? * 1_000_000_000;
    let run = Run {
        clean: options.clean,
        paths: options.paths.clone(),
        deadline,
        log: crate::scratch_target::deletion_log_path()?,
        holds: state.join("evidence-holds.json"),
        ..Run::new(&root, device, cutoff)
    };
    let u = crate::scratch_target::measure_usage;
    let before = options.clean.then(|| u(&root, device)).transpose()?;
    let report = sweep(&run)?;
    let after = options.clean.then(|| u(&root, device)).transpose()?;
    let freed = before
        .zip(after)
        .map(|(b, a)| i128::from(b) - i128::from(a));
    let ok = report.complete();
    let status = if ok {
        "expired_sweep"
    } else if report.timed_out {
        "deadline"
    } else {
        "partial"
    };
    let body = json!({"status": status, "clean": options.clean, "used_before_bytes": before,
        "used_after_bytes": after, "freed_bytes": freed, "report": report.summary()});
    Ok((body, ok))
}

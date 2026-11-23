//! Native worktree hygiene: sparse-checkout slimming and gated archive-push.

use crate::job_receipt::{self, Completion};
use crate::scratch_file_transaction::{open_paths, run_capture};
use crate::scratch_lease::{legacy_lease, live_cwd_in};
use crate::scratch_target::{deletion_log_path, flush_audit};
use crate::time_windows::{GIT_REMOTE_PROBE_TIMEOUT, WORKTREE_FLOOR_DAYS};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, ErrorKind};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, SystemTime};

pub fn dispatch(args: &[OsString]) -> Option<ExitCode> {
    let cmd = args.first()?.to_str()?;
    if !matches!(cmd, "worktree-slim" | "worktree-archive") {
        return None;
    }
    Some(match run(cmd, &args[1..]) {
        Ok(rep) => {
            println!("{}", serde_json::to_string_pretty(&rep).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("diskm {cmd}: {e}");
            ExitCode::from(if e.kind() == ErrorKind::InvalidInput {
                2
            } else {
                1
            })
        }
    })
}

fn bad(m: &str) -> io::Error {
    io::Error::new(ErrorKind::InvalidInput, m)
}

fn run(cmd: &str, args: &[OsString]) -> io::Result<Value> {
    let (mut roots, mut excl, mut clean, mut push) = (Vec::new(), Vec::new(), false, false);
    let (mut cfg, mut state_dir, mut sfx, mut days) = (None, None, None, WORKTREE_FLOOR_DAYS);
    let mut i = 0;
    while i < args.len() {
        let s = args[i].to_str().ok_or_else(|| bad("non-UTF-8 arg"))?;
        let val = |idx: &mut usize| -> io::Result<String> {
            *idx += 1;
            args.get(*idx)
                .and_then(|v| v.to_str())
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| bad(s))
        };
        match s {
            "--root" => roots.push(PathBuf::from(val(&mut i)?)),
            "--state-dir" => state_dir = Some(PathBuf::from(val(&mut i)?)),
            "--clean" => clean = true,
            "--config" if cmd == "worktree-slim" => cfg = Some(PathBuf::from(val(&mut i)?)),
            "--exclude" if cmd == "worktree-slim" => excl.push(norm_rel(&val(&mut i)?)?),
            "--push-only" if cmd == "worktree-archive" => push = true,
            "--min-days" if cmd == "worktree-archive" => {
                days = val(&mut i)?
                    .parse()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| bad("bad --min-days"))?
            }
            "--archive-suffix" if cmd == "worktree-archive" => {
                let v = val(&mut i)?;
                if v.starts_with('-')
                    || v.contains("..")
                    || v.contains(':')
                    || v.chars().any(|c| c.is_whitespace() || c == '/')
                {
                    return Err(bad("bad suffix"));
                }
                sfx = Some(v);
            }
            _ => return Err(bad(s)),
        }
        i += 1;
    }
    if push && clean {
        return Err(bad("--push-only conflicts with --clean"));
    }
    if let Some(d) = &state_dir {
        std::env::set_var("DISK_MAGICIAN_STATE_DIR", d);
    }
    let started = SystemTime::now();
    let state = job_receipt::state_dir(state_dir.as_deref())?;
    let wts = discover(&roots)?;
    let report = if cmd == "worktree-slim" {
        let map = if excl.is_empty() {
            load_cfg(cfg.as_deref())?
        } else {
            BTreeMap::new()
        };
        let rows: Vec<Value> = if wts.is_empty() {
            Vec::new()
        } else {
            std::thread::scope(|sc| {
                let hs: Vec<_> = wts.chunks(wts.len().div_ceil(4)).map(|ch| sc.spawn(|| {
                    ch.iter().map(|wt| slim_one(wt, &excl, &map, clean).unwrap_or_else(|r| json!({"path": wt, "status": "skipped", "reason": r, "excludes": [], "apparent_delta_bytes": 0}))).collect::<Vec<_>>()
                })).collect();
                hs.into_iter()
                    .flat_map(|h| h.join().unwrap_or_default())
                    .collect()
            })
        };
        json!({"clean": clean, "count": rows.len(), "worktrees": rows})
    } else {
        let app = std::env::var_os("WORKTREE_APPROVED").as_deref() == Some(OsStr::new("1"));
        let cut = SystemTime::now() - Duration::from_secs(u64::from(days) * 86_400);
        let holds = job_receipt::read_json_if_exists::<BTreeMap<PathBuf, String>>(
            &state.join("evidence-holds.json"),
            16 << 20,
        );
        let mode = if clean {
            2
        } else if push {
            1
        } else {
            0
        };
        let rows: Vec<Value> = wts
            .iter()
            .map(|wt| {
                archive_one(wt, cut, mode, app, sfx.as_deref(), &holds)
                    .unwrap_or_else(|r| json!({"path": wt, "status": "skipped", "reason": r}))
            })
            .collect();
        let m = ["dry_run", "push_only", "clean"][mode];
        json!({"mode": m, "min_days": days, "worktrees": rows})
    };
    job_receipt::publish_terminal(
        &state,
        cmd,
        started,
        Completion::Success,
        json!({}),
        report.clone(),
        json!({}),
    )?;
    Ok(report)
}

fn norm_rel(raw: &str) -> io::Result<String> {
    let c = raw.trim_end_matches('/');
    if raw.starts_with('/')
        || c.is_empty()
        || c.contains('\0')
        || c.split('/').any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(bad("invalid exclude"));
    }
    Ok(c.to_owned())
}

fn discover(roots: &[PathBuf]) -> io::Result<Vec<PathBuf>> {
    fn walk(d: &Path, out: &mut Vec<PathBuf>) -> io::Result<()> {
        match fs::symlink_metadata(d.join(".git")) {
            Ok(m) => {
                if m.is_file() {
                    out.push(d.to_path_buf());
                }
                return Ok(());
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let Ok(rd) = fs::read_dir(d) else {
            return Ok(());
        };
        for e in rd {
            let e = e?;
            let p = e.path();
            if e.file_name() != ".git"
                && fs::symlink_metadata(&p).is_ok_and(|m| !m.file_type().is_symlink() && m.is_dir())
            {
                walk(&p, out)?;
            }
        }
        Ok(())
    }
    let defs = if roots.is_empty() {
        vec![PathBuf::from(
            std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME unavailable"))?,
        )
        .join(".worktrees")]
    } else {
        roots.to_vec()
    };
    let mut out = Vec::new();
    for r in &defs {
        walk(r, &mut out)?;
    }
    out.sort();
    out.dedup();
    Ok(out)
}

fn git_out(d: &Path, a: &[&str]) -> Option<String> {
    let (st, out, _) = run_capture(
        Command::new("git").arg("-C").arg(d).args(a),
        None,
        GIT_REMOTE_PROBE_TIMEOUT,
    )
    .ok()?;
    st.success()
        .then(|| String::from_utf8_lossy(&out).into_owned())
}

fn bytes_at(p: &Path) -> u64 {
    let Ok(m) = fs::symlink_metadata(p) else {
        return 0;
    };
    if m.is_file() {
        m.len()
    } else if m.is_dir() {
        fs::read_dir(p)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| bytes_at(&e.path()))
            .sum()
    } else {
        0
    }
}

fn load_cfg(explicit: Option<&Path>) -> io::Result<BTreeMap<String, Vec<String>>> {
    let fb = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".config/disk-magician/config.json"));
    let Some(p) = explicit
        .map(Path::to_path_buf)
        .or_else(|| fb.filter(|x| x.exists()))
        .or_else(|| {
            Path::new("config.json.template")
                .exists()
                .then(|| PathBuf::from("config.json.template"))
        })
    else {
        return Ok(BTreeMap::new());
    };
    let val: Value = serde_json::from_slice(&fs::read(p)?).map_err(io::Error::other)?;
    let mut map = BTreeMap::new();
    for (k, v) in val
        .get("worktree_sparse_excludes")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
    {
        map.insert(
            k.clone(),
            v.as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(norm_rel)
                .collect::<io::Result<Vec<_>>>()?,
        );
    }
    Ok(map)
}

fn slim_one(
    wt: &Path,
    cli: &[String],
    cfg: &BTreeMap<String, Vec<String>>,
    clean: bool,
) -> Result<Value, &'static str> {
    if git_out(wt, &["config", "--bool", "extensions.worktreeConfig"])
        .as_deref()
        .map(str::trim)
        != Some("true")
    {
        return Err("missing_worktree_config");
    }
    if !git_out(wt, &["status", "--porcelain"]).is_some_and(|s| s.trim().is_empty()) {
        return Err("dirty");
    }
    let ex = if !cli.is_empty() {
        cli.to_vec()
    } else {
        let k1 = wt
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str());
        k1.and_then(|k| cfg.get(k))
            .cloned()
            .or_else(|| {
                let c = git_out(wt, &["rev-parse", "--git-common-dir"])?;
                let p = Path::new(c.trim());
                fs::canonicalize(if p.is_absolute() {
                    p.to_path_buf()
                } else {
                    wt.join(p)
                })
                .ok()?
                .parent()?
                .file_name()?
                .to_str()
                .and_then(|k| cfg.get(k))
                .cloned()
            })
            .unwrap_or_default()
    };
    if ex.is_empty() {
        return Err("no_excludes");
    }
    let before: u64 = ex.iter().map(|d| bytes_at(&wt.join(d))).sum();
    if !clean {
        return Ok(
            json!({"path": wt, "status": "candidate", "reason": null, "excludes": ex, "apparent_delta_bytes": before}),
        );
    }
    let mut args = vec![
        "sparse-checkout".into(),
        "set".into(),
        "--no-cone".into(),
        "/*".into(),
    ];
    args.extend(ex.iter().map(|d| format!("!/{d}/")));
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    git_out(wt, &refs).ok_or("sparse_checkout_failed")?;
    let after: u64 = ex.iter().map(|d| bytes_at(&wt.join(d))).sum();
    Ok(
        json!({"path": wt, "status": "slimmed", "reason": null, "excludes": ex, "apparent_delta_bytes": before.saturating_sub(after)}),
    )
}

fn archive_one(
    wt: &Path,
    cut: SystemTime,
    mode: usize,
    app: bool,
    sfx: Option<&str>,
    holds: &io::Result<Option<BTreeMap<PathBuf, String>>>,
) -> Result<Value, &'static str> {
    let (canon, s) = (
        fs::canonicalize(wt).unwrap_or_else(|_| wt.to_path_buf()),
        wt.to_string_lossy(),
    );
    if s.contains("/.ao/")
        || s.contains("/.ao-")
        || fs::symlink_metadata(wt.join(".ao-owner")).is_ok()
    {
        return Err("ao_owned");
    }
    if !matches!(live_cwd_in(&canon), Ok(false)) || !matches!(open_paths(&canon), Ok(false)) {
        return Err("open_files");
    }
    let held = holds.as_ref().map_or(true, |o| {
        o.as_ref().is_some_and(|m| {
            m.keys().any(|k| {
                let ck = fs::canonicalize(k).unwrap_or_else(|_| k.clone());
                wt.starts_with(k)
                    || canon.starts_with(k)
                    || canon.starts_with(&ck)
                    || k.starts_with(wt)
                    || ck.starts_with(&canon)
            })
        })
    });
    if held
        || !matches!(legacy_lease(wt, None, true), Ok(None))
        || !matches!(legacy_lease(&canon, None, true), Ok(None))
    {
        return Err("held");
    }
    let list = git_out(wt, &["worktree", "list", "--porcelain"]).ok_or("locked")?;
    let (mut main, mut cur, mut lock, mut found) = (None, false, false, false);
    for l in list.lines() {
        if let Some(p) = l.strip_prefix("worktree ") {
            main.get_or_insert_with(|| PathBuf::from(p));
            cur = fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p)) == canon;
            found |= cur;
        } else if cur && (l == "locked" || l.starts_with("locked ")) {
            lock = true;
        }
    }
    if !found || lock {
        return Err("locked");
    }
    if !git_out(wt, &["status", "--porcelain"]).is_some_and(|o| o.trim().is_empty()) {
        return Err("dirty");
    }
    scan_tree(wt, cut)?;
    if mode == 0 {
        return Ok(json!({"path": wt, "status": "candidate", "reason": null}));
    }
    if mode == 2 && !app {
        return Err("missing_approval");
    }
    let name = wt
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("invalid_name")?;
    let tgt = sfx.map_or_else(|| name.to_owned(), |x| format!("{name}-{x}"));
    let (rref, tref) = (
        format!("refs/heads/archive/{tgt}"),
        format!("refs/remotes/origin/archive/{tgt}"),
    );
    let ls = git_out(wt, &["ls-remote", "--heads", "origin", &rref]).ok_or("remote_error")?;
    let mut push = true;
    if !ls.trim().is_empty() {
        git_out(
            wt,
            &["fetch", "--no-tags", "origin", &format!("{rref}:{tref}")],
        )
        .ok_or("remote_error")?;
        if git_out(wt, &["merge-base", "--is-ancestor", "HEAD", &tref]).is_some() {
            push = false;
        } else if git_out(wt, &["merge-base", "--is-ancestor", &tref, "HEAD"]).is_none() {
            return Err("ref_collision");
        }
    }
    if push {
        git_out(wt, &["push", "origin", &format!("HEAD:{rref}")]).ok_or("push_failed")?;
    }
    if mode == 1 {
        return Ok(json!({"path": wt, "status": "pushed", "reason": null, "ref": rref}));
    }
    git_out(
        &main.ok_or("remove_failed")?,
        &["worktree", "remove", "--", &s],
    )
    .ok_or("remove_failed")?;
    if let (Ok(log), Ok(ts)) = (
        deletion_log_path(),
        job_receipt::timestamp(SystemTime::now()),
    ) {
        let mut row = Some((
            log,
            format!(
                "{ts}\tdiskm\tworktree_remove\t0\t{}\t{rref}\n",
                s.replace(['\t', '\r', '\n'], " ")
            ),
        ));
        let _ = flush_audit(&mut row, false);
    }
    Ok(json!({"path": wt, "status": "archived", "reason": null, "ref": rref}))
}

fn scan_tree(wt: &Path, cut: SystemTime) -> Result<(), &'static str> {
    let (mut st, mut seen, mut rec) = (vec![wt.to_path_buf()], false, false);
    while let Some(d) = st.pop() {
        for e in fs::read_dir(&d).map_err(|_| "too_recent")? {
            let e = e.map_err(|_| "too_recent")?;
            let nm = e.file_name();
            if d == wt && nm == ".git" {
                continue;
            }
            let n = nm.to_string_lossy();
            if n == ".env" || n.starts_with(".env.") {
                return Err("secret_env");
            }
            let p = e.path();
            let m = fs::symlink_metadata(&p).map_err(|_| "too_recent")?;
            if m.is_dir() && !m.file_type().is_symlink() {
                st.push(p);
            } else {
                seen = true;
                if m.modified().map_or(true, |t| t >= cut) {
                    rec = true;
                }
            }
        }
    }
    if rec
        || (!seen
            && fs::symlink_metadata(wt)
                .and_then(|m| m.modified())
                .map_or(true, |t| t >= cut))
    {
        return Err("too_recent");
    }
    Ok(())
}

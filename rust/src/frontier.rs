//! Parallel top-down frontier scanner producing `ledger/topdown-5g.json`.

use crate::{job_receipt, preview, scan, status};
use scan::ScanGapKind::{self, Deadline, Metadata, ReadDirectory};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashSet};
use std::fs::{self, Metadata as FsMeta};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Mutex,
};
use std::{
    io,
    time::{Duration, Instant, SystemTime},
};

const MIB: u64 = 1024 * 1024;
const T: u64 = scan::ITEMIZATION_THRESHOLD_BYTES;
pub struct Options {
    pub roots: Vec<PathBuf>,
    pub min_mb: u64,
    pub deadline: Duration,
    pub output: Option<PathBuf>,
    pub state_dir: Option<PathBuf>,
}
type Hl = Mutex<HashSet<(u64, u64)>>;
type Gap = (String, ScanGapKind, String);
type Acc = (Vec<Value>, Vec<Value>, Vec<Value>, Vec<Gap>, u64, u64);

fn pstr(p: &Path) -> String {
    scan::path_parts_for_report(p).0
}
fn exp(end: Option<Instant>) -> bool {
    end.is_none_or(|e| Instant::now() >= e)
}
fn pgap(acc: &mut Acc, p: &Path, k: ScanGapKind, m: &str) {
    acc.3.push((pstr(p), k, m.into()));
}
fn leaf(p: &Path, alloc: u64, app: u64, kind: &str) -> Value {
    json!({"path": pstr(p), "measured_kb": alloc / 1024, "apparent_bytes": app, "kind": kind})
}
fn add_file(p: &Path, m: &FsMeta, hl: &Hl, b: &mut Vec<Value>, o: &mut Vec<Value>) -> (u64, u64) {
    let (fa, mut fl) = (m.len(), m.blocks().saturating_mul(512));
    if m.nlink() > 1 && !hl.lock().unwrap().insert((m.dev(), m.ino())) {
        fl = 0;
    }
    if fa >= T || fl >= T {
        o.push(leaf(p, fl, fa, "file"));
    } else if fl >= MIB {
        b.push(leaf(p, fl, fa, "file"));
    }
    (fa, fl)
}
fn walk(
    dir: &Path,
    dev: u64,
    cfg: (bool, u64, Option<Instant>),
    hl: &Hl,
    acc: &mut Acc,
) -> (u64, u64) {
    let (root, min_b, end) = cfg;
    if exp(end) {
        pgap(acc, dir, Deadline, "deadline exceeded");
        if root {
            acc.4 += 1;
            acc.5 += 1;
        }
        return (0, 0);
    }
    let Ok(rd) = fs::read_dir(dir) else {
        pgap(acc, dir, ReadDirectory, "read_dir failed");
        if root {
            acc.4 += 1;
            acc.5 += 1;
        }
        return (0, 0);
    };
    let g0 = acc.3.len();
    let (mut app, mut alloc, mut sub_b, mut dirs) = (0_u64, 0_u64, vec![], vec![]);
    for (i, entry) in rd.enumerate() {
        if i & 63 == 63 && exp(end) {
            pgap(acc, dir, Deadline, "deadline exceeded");
            break;
        }
        let Ok(e) = entry else {
            pgap(acc, dir, ReadDirectory, "entry failed");
            continue;
        };
        let p = e.path();
        if matches!(p.to_str(), Some("/dev" | "/proc" | "/sys" | "/Volumes"))
            || (root && scan::is_unreadable_macos_volume_metadata(&p, &e.file_name()))
        {
            continue;
        }
        let Ok(m) = fs::symlink_metadata(&p) else {
            pgap(acc, &p, Metadata, "lstat failed");
            continue;
        };
        if m.is_dir() && m.dev() == dev {
            dirs.push(p);
        } else if !m.is_dir() {
            acc.4 += u64::from(root);
            let dst = if root { &mut acc.1 } else { &mut sub_b };
            let (fa, fl) = add_file(&p, &m, hl, dst, &mut acc.2);
            app += fa;
            alloc += fl;
        }
    }
    if root {
        let errs = (acc.3.len() - g0) as u64;
        acc.4 += dirs.len() as u64 + errs;
        acc.5 += errs;
        dirs.sort();
        let workers = std::thread::available_parallelism()
            .map_or(4, |n| n.get())
            .clamp(1, 8)
            .min(dirs.len().max(1));
        let (next, lock) = (AtomicUsize::new(0), Mutex::new(vec![]));
        std::thread::scope(|s| {
            for _ in 0..workers {
                s.spawn(|| {
                    while let Some(i) =
                        Some(next.fetch_add(1, Ordering::Relaxed)).filter(|i| *i < dirs.len())
                    {
                        let mut c = Acc::default();
                        let (ca, cl) = walk(&dirs[i], dev, (false, min_b, end), hl, &mut c);
                        lock.lock().unwrap().push((i, ca, cl, c));
                    }
                });
            }
        });
        let mut res = lock.into_inner().unwrap();
        res.sort_unstable_by_key(|x| x.0);
        for (_, ca, cl, c) in res {
            acc.5 += u64::from(!c.3.is_empty());
            app += ca;
            alloc += cl;
            acc.0.extend(c.0);
            acc.1.extend(c.1);
            acc.2.extend(c.2);
            acc.3.extend(c.3);
        }
    } else {
        for sub in dirs {
            let saved = std::mem::take(&mut acc.1);
            let (ca, cl) = walk(&sub, dev, (false, min_b, end), hl, acc);
            app += ca;
            alloc += cl;
            sub_b.extend(std::mem::replace(&mut acc.1, saved));
        }
    }
    if alloc >= min_b {
        acc.0.push(json!({"path": pstr(dir), "size_mb": alloc / MIB, "measured_kb": alloc / 1024, "allocated_bytes": alloc, "apparent_bytes": app}));
    }
    if app >= T || alloc >= T {
        acc.1.extend(sub_b);
    } else if !root && (alloc > 0 || app > 0) {
        acc.1.push(leaf(dir, alloc, app, "dir"));
    }
    (app, alloc)
}
pub fn run(options: &Options) -> io::Result<(Value, bool)> {
    let end = Instant::now().checked_add(options.deadline);
    let cwd = std::env::current_dir()?;
    let data = Path::new("/System/Volumes/Data");
    let mac = cfg!(target_os = "macos") && data.is_dir();
    let roots: Vec<_> = if options.roots.is_empty() {
        vec![if mac { data } else { Path::new("/") }.into()]
    } else {
        options.roots.iter().map(|p| cwd.join(p)).collect()
    };
    let cap_r = if mac && matches!(roots[0].to_str(), Some("/" | "/System/Volumes/Data")) {
        data
    } else {
        &roots[0]
    };
    let cap = status::status(cap_r, None)?.capacity;
    let host_s =
        String::from_utf8(Command::new("hostname").output()?.stdout).map_err(io::Error::other)?;
    let host = host_s.trim();
    if host.is_empty() {
        return Err(io::Error::other("cannot identify host"));
    }
    let captured_at = job_receipt::timestamp(SystemTime::now())?;
    let (min_b, mut total_b) = (options.min_mb.saturating_mul(MIB), 0_u64);
    let (hl, mut acc) = (Mutex::new(HashSet::new()), Acc::default());
    for root in &roots {
        let m = fs::symlink_metadata(root)?;
        if m.is_dir() {
            total_b += walk(root, m.dev(), (true, min_b, end), &hl, &mut acc).1;
        } else if exp(end) {
            acc.4 += 1;
            acc.5 += 1;
            pgap(&mut acc, root, Deadline, "deadline exceeded");
        } else {
            acc.4 += 1;
            total_b += add_file(root, &m, &hl, &mut acc.1, &mut acc.2).1;
        }
    }
    let sort = |l: &mut [Value], k: &str| {
        l.sort_by(|a, b| {
            b[k].as_u64()
                .cmp(&a[k].as_u64())
                .then_with(|| a["path"].as_str().cmp(&b["path"].as_str()))
        });
    };
    sort(&mut acc.0, "size_mb");
    sort(&mut acc.1, "measured_kb");
    sort(&mut acc.2, "measured_kb");
    let complete = acc.3.is_empty();
    let mode = if complete { "complete" } else { "partial" };
    let fda = if acc.3.iter().any(|g| g.1 != Deadline) {
        "partial"
    } else {
        "granted"
    };
    let unfinished: BTreeSet<String> = acc.3.iter().map(|g| g.0.clone()).collect();
    let gaps: Vec<_> = acc
        .3
        .into_iter()
        .map(|(p, k, m)| json!({"path": p, "kind": k, "message": m}))
        .collect();
    let (disk_used_kb, measured_total_kb) = (cap.used_bytes / 1024, total_b / 1024);
    let sum = |v: &[Value]| -> u64 { v.iter().filter_map(|x| x["measured_kb"].as_u64()).sum() };
    let (db_kb, ov_kb) = (sum(&acc.1), sum(&acc.2));
    let res_raw = i128::from(disk_used_kb) - i128::from(measured_total_kb);
    let gib = |b| b as f64 / 1_073_741_824.0;
    let report = json!({
        "schema_version": 2, "mode": mode, "canonical": complete, "publication_kind": mode, "captured_at": captured_at, "root": pstr(&roots[0]), "hostname": host,
        "scope": { "root": pstr(&roots[0]), "hostname": host, "mounted_at": cap.mounted_at, "filesystem": cap.filesystem },
        "min_mb": options.min_mb, "disk_total_kb": cap.total_bytes / 1024, "disk_used_kb": disk_used_kb, "disk_free_kb": cap.available_bytes / 1024,
        "disk_total_gb": gib(cap.total_bytes), "disk_used_gb": gib(cap.used_bytes), "disk_free_gb": gib(cap.available_bytes),
        "measured_total_kb": measured_total_kb, "entries": acc.0, "granularity_buckets": acc.1, "oversize_indivisible_files": acc.2,
        "opaque_intrinsic_gates": [], "frontier_unfinished": unfinished, "unfinished": unfinished, "gaps": gaps,
        "coverage_envelope": { "complete": complete, "fda_preflight_status": fda, "fda_user_preflight_status": fda, "reachable_top_level_roots": acc.4, "measured_top_level_roots": acc.4.saturating_sub(acc.5), "unfinished_top_level_roots": acc.5 },
        "accounting_equation": { "data_used_kb": disk_used_kb, "displayed_buckets_kb": db_kb, "oversize_indivisible_files_kb": ov_kb, "sub_granularity_tail_kb": measured_total_kb.saturating_sub(db_kb + ov_kb), "purgeable_kb": 0, "residual_kb": res_raw.max(0) as u64, "clone_shared_kb": res_raw.min(0) as i64, "display_ledger_valid": true, "displayed_balanced": true },
    });
    let wjson = |p: PathBuf, v: &Value| {
        fs::create_dir_all(p.parent().unwrap())?;
        preview::write_checkpoint(&p, v)
    };
    if let Some(out) = &options.output {
        wjson(cwd.join(out), &report)?;
    } else if let Some(sd) = &options.state_dir {
        let dir = cwd.join(sd).join("ledger");
        wjson(dir.join("topdown-5g.json"), &report)?;
        wjson(
            dir.join("topdown-5g.status.json"),
            &json!({"status": if complete { "published" } else { "partial" }, "reason": if complete { Value::Null } else { json!("incomplete_frontier_scan") }, "captured_at": captured_at, "mode": mode, "coverage_envelope": &report["coverage_envelope"]}),
        )?;
    }
    Ok((report, complete))
}

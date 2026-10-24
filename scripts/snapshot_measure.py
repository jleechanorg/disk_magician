#!/usr/bin/env python3
"""Bounded, load-aware parallel measurement of monitored_dirs.

Each key is measured by `disk_snapshot.sh --measure-one KEY PATH TIMEOUT OUTFILE`
(one worker process per key, disjoint output files). Results are printed to stdout
in config order as `key<TAB>kb-or-empty<TAB>path<TAB>timeout<TAB>retry_timeout`;
an empty kb means "not measured" (never zero). Phase 1 attempts every key,
shortest configured timeout first; phase 2 retries timed-out keys once with the
time left before the deadline.
Roots >= 20 GiB (or that timed out last run) are measured as parallel depth-1 shards and summed; a timed-out
shard's last-good value is reported as stale (never summed, dropped after
DISK_MAGICIAN_SHARD_CARRY_MAX_HOURS, default 48) and marks the parent partial/lower-bound. At the deadline every worker's whole descendant
tree is killed (GNU timeout escapes process groups, so groups are not enough).
"""
import argparse
import concurrent.futures
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import zlib

MAX_WORKERS = 6
GRACE = 2.0
MIN_RETRY_SECONDS = 5
MAX_DIAGNOSTIC_TEXT = 256


def inventory_metadata(state_dir, captured_at, previous=None):
    """Reference verified inventory bytes; watched refresh never traverses directories."""
    from directory_inventory import read_current, read_publication

    previous = previous if isinstance(previous, dict) else {}
    reference = {"manifest_sha256": None, "captured_at": None,
                 "status": "unavailable", "complete": False}
    manifest = None
    try:
        current = read_current(state_dir, verify=True)
        manifest = current["manifest"]
        reference.update(manifest_sha256=current["pointer"]["manifest_sha256"],
                         captured_at=manifest["published_at"],
                         complete=bool(manifest.get("complete")))
        now = datetime.datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
        observed = datetime.datetime.fromisoformat(reference["captured_at"].replace("Z", "+00:00"))
        age = (now - observed).total_seconds()
        reference["status"] = "fresh" if 0 <= age <= 24 * 3600 else "stale"
    except (OSError, ValueError, KeyError, TypeError):
        if previous.get("manifest_sha256"):
            reference.update(manifest_sha256=previous["manifest_sha256"],
                             captured_at=previous.get("captured_at"))
            try:
                manifest = read_publication(state_dir, previous["manifest_sha256"], verify=True)["manifest"]
                reference.update(status="stale", complete=bool(manifest.get("complete")))
            except FileNotFoundError:
                reference["status"] = "retention-expired"
            except (OSError, ValueError, KeyError, TypeError):
                reference["status"] = "invalid"
    metadata = (manifest or {}).get("scan_metadata", {})
    return {"directory_inventory": reference,
            "selected_filesystem_df_samples": metadata.get("df_samples", []),
            "selected_filesystem_df_aggregate": None,
            "selected_filesystem_selection_epoch": metadata.get("selection_epoch"),
            "selected_filesystem_set_sha256": metadata.get("selected_set_sha256")}


def worker_count(cores, load1, pressure, avail_gb, override=None):
    if override is not None:
        return max(1, min(MAX_WORKERS, int(override)))
    if pressure >= 4 or avail_gb < 4:
        return 1
    if cores > 0 and load1 / cores > 4:
        return 2
    return max(2, min(MAX_WORKERS, cores // 3))


def _sysctl(name):
    try:
        return subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def probe_system():
    cores = int(_sysctl("hw.ncpu") or os.cpu_count() or 1)
    try:
        load1 = float(_sysctl("vm.loadavg").strip("{} ").split()[0])
    except Exception:
        load1 = os.getloadavg()[0]
    pressure = int(_sysctl("kern.memorystatus_vm_pressure_level") or 1)
    avail_gb = 99.0
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        page = int(re.search(r"page size of (\d+)", out).group(1))
        pages = sum(int(n) for _, n in re.findall(r"Pages (free|inactive|purgeable|speculative):\s+(\d+)", out))
        avail_gb = pages * page / 1024 ** 3
    except Exception:
        pass
    return cores, load1, pressure, avail_gb


def _children_map():
    out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    kids = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            kids.setdefault(int(parts[1]), []).append(int(parts[0]))
    return kids


def descendants(pid):
    kids = _children_map()
    found, stack = [], [pid]
    while stack:
        for c in kids.get(stack.pop(), []):
            found.append(c)
            stack.append(c)
    return found


def kill_tree(pid):
    """SIGKILL pid and all of its descendants; the tree is collected first so
    re-parented orphans are not lost, then re-walked once to verify."""
    for _ in range(2):
        try:
            victims = descendants(pid) + [pid]
        except Exception:
            victims = [pid]
        for v in victims:
            try:
                os.kill(v, signal.SIGKILL)
            except OSError:
                pass
        try:
            if not descendants(pid):
                break
        except Exception:
            break


def load_entries(config_path):
    with open(config_path) as f:
        data = json.load(f)
    entries = []
    for item in data.get("monitored_dirs", []):
        entries.append({"key": item["key"], "path": item["path"], "timeout": int(item.get("timeout", 30)),
                        "retry_timeout": int(item.get("retry_timeout", 0) or 0)})
    return entries


SHARD_MIN_KB = 20 * 1024 * 1024
SHARD_DEFAULT_WORKERS = 4
SHARD_DEFAULT_TIMEOUT = 30
MAX_SHARDS = 64
SHARD_CARRY_MAX_HOURS = 48
_BENIGN_DU_ERR = re.compile(r"(Permission denied|No such file or directory|Operation not permitted)$")


def shard_worker_count(cores, load5, pressure, requested=None):
    """Shard pool size: default 4, never above half the cores, 1 under memory pressure or load > 4x cores."""
    if pressure >= 3 or (cores > 0 and load5 > 4 * cores):
        return 1
    want = SHARD_DEFAULT_WORKERS if requested is None else max(1, int(requested))
    return max(1, min(want, cores // 2))


def list_shards(root, max_shards=MAX_SHARDS):
    """Depth-1 children of root as [(shard_name, [paths])] plus the root's own block usage in KB.
    More than max_shards children are bucketed by a stable name hash. None if unreadable."""
    try:
        names = sorted(e.name for e in os.scandir(root))
        own_kb = os.stat(root).st_blocks * 512 // 1024
    except OSError:
        return None
    if len(names) <= max_shards:
        return [(n, [os.path.join(root, n)]) for n in names], own_kb
    buckets = {}
    for n in names:
        buckets.setdefault(zlib.crc32(n.encode("utf-8", "surrogateescape")) % max_shards, []).append(os.path.join(root, n))
    return [(f"bucket-{b:02d}", p) for b, p in sorted(buckets.items())], own_kb


def measure_shard(paths, timeout, deadline):
    """One bounded `du -sk` over a shard. Returns (kb, lower_bound); (None, False) on timeout/error
    (never zero). lower_bound is True when du exited 1 on permission/traversal errors only."""
    budget = min(timeout, deadline - time.time())
    if budget < 1:
        return None, False
    try:
        proc = subprocess.Popen(["du", "-sk", "--", *paths], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
    except OSError:
        return None, False
    try:
        out, err = proc.communicate(timeout=budget)
    except subprocess.TimeoutExpired:
        kill_tree(proc.pid)
        proc.communicate()
        return None, False
    if proc.returncode not in (0, 1):
        return None, False
    if proc.returncode == 1 and any(l.strip() and not _BENIGN_DU_ERR.search(l.strip()) for l in err.splitlines()):
        return None, False
    sizes = [int(l.split()[0]) for l in out.splitlines() if l.split() and l.split()[0].isdigit()]
    if not sizes or len(sizes) != len(paths):
        return None, False
    return sum(sizes), proc.returncode == 1


def shard_carry_max_seconds():
    return float(os.environ.get("DISK_MAGICIAN_SHARD_CARRY_MAX_HOURS") or SHARD_CARRY_MAX_HOURS) * 3600


def _prior_entry(v):
    """(kb, ts) from a carried shard; legacy bare ints have no timestamp (age unknown)."""
    if isinstance(v, dict):
        return v.get("kb"), v.get("ts")
    return v, None


def measure_sharded(root, workers, shard_timeout, deadline, prior, now=None, carry_max_s=None):
    """Measure root as independent depth-1 shards in parallel and sum. A timed-out shard may carry its
    last-good value only as *stale*: reported separately, never summed into kb (so it cannot count toward
    coverage), and dropped once older than carry_max_s (unknown age is expired). Any timed-out or
    lower-bound shard makes the parent partial and a lower bound."""
    now = time.time() if now is None else now
    carry_max_s = shard_carry_max_seconds() if carry_max_s is None else carry_max_s
    listed = list_shards(root)
    if listed is None:
        return None
    shards, own_kb = listed
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        got = list(pool.map(lambda s: measure_shard(s[1], shard_timeout, deadline), shards))
    fresh, lb_kb, stale, expired, timed_out, carry = {}, {}, {}, [], [], {}
    for (name, _), (kb, lb) in zip(shards, got):
        if kb is not None:
            if lb:  # partial du result: counted as a lower bound, never carried as a complete measurement
                lb_kb[name] = kb
            else:
                fresh[name] = kb
                carry[name] = {"kb": kb, "ts": now}
            continue
        timed_out.append(name)
        pkb, pts = _prior_entry(prior.get(name))
        if pkb is None:
            continue
        if pts is not None and 0 <= now - pts <= carry_max_s:
            stale[name] = pkb
            carry[name] = {"kb": pkb, "ts": pts}
        else:
            expired.append(name)
    if not fresh and not lb_kb:
        return None
    return {"kb": own_kb + sum(fresh.values()) + sum(lb_kb.values()), "partial": bool(timed_out or lb_kb),
            "timed_out_shards": timed_out, "stale_shards": stale, "expired_shards": expired,
            "lower_bound_shards": sorted(lb_kb), "fresh_shards": fresh, "carry": carry,
            "lower_bound": bool(timed_out or lb_kb)}


def _load_shard_state(path):
    try:
        with open(path) as f:
            return json.load(f).get("roots", {})
    except (OSError, ValueError, AttributeError):
        return {}


def _save_shard_state(path, roots):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            json.dump({"roots": roots}, f, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        pass


def _bounded_text(value):
    """Keep worker diagnostics useful without copying unbounded output."""
    if value is None:
        return ""
    return str(value).replace("\r", " ").replace("\n", " ")[:MAX_DIAGNOSTIC_TEXT]


def _attempt_diagnostic(key, path, attempt, reason, started, **details):
    result = {
        "key": key,
        "path": path,
        "attempt": attempt,
        "reason": _bounded_text(reason),
        "elapsed_s": round(max(0.0, time.monotonic() - started), 3),
    }
    for name in ("backend", "backend_exit", "stderr", "kb", "lower_bound"):
        if name in details and details[name] is not None:
            value = details[name]
            if name == "stderr":
                value = _bounded_text(value)
            result[name] = value
    return result


def measure(entry, budget, snapshot_script, tmpdir, deadline, attempt, env_extra):
    """Run one worker and retain a bounded, structured attempt diagnostic."""
    started = time.monotonic()
    now = time.time()
    if now >= deadline - 1:
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "orchestrator_deadline", started)
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", entry["key"])
    out = os.path.join(tmpdir, f"{safe}.{attempt}.json")
    env = dict(os.environ, DISK_MAGICIAN_WORKER_DEADLINE_EPOCH=str(int(deadline)), DUA_THREADS="1", **env_extra)
    try:
        proc = subprocess.Popen(["bash", snapshot_script, "--measure-one", entry["key"], entry["path"],
                                 str(budget), out], env=env, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "launch_failure", started,
                                          stderr=_bounded_text(exc))
    timed_out = False
    try:
        proc.wait(timeout=max(0.1, deadline - time.time() + GRACE))
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_tree(proc.pid)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    if timed_out:
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "orchestrator_deadline", started)
    try:
        with open(out) as f:
            worker = json.load(f)
    except FileNotFoundError:
        reason = "launch_failure" if proc.returncode == 127 else ("worker_exit_nonzero" if proc.returncode not in (0, None) else "missing_result")
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, reason, started,
                                          backend_exit=proc.returncode)
    except (OSError, ValueError, TypeError):
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "malformed_result", started,
                                          backend_exit=proc.returncode)
    if not isinstance(worker, dict):
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "malformed_result", started,
                                          backend_exit=proc.returncode)
    worker_elapsed = worker.get("elapsed_s")
    elapsed = worker_elapsed if isinstance(worker_elapsed, (int, float)) and not isinstance(worker_elapsed, bool) else None
    details = {name: worker.get(name) for name in ("backend", "backend_exit", "stderr", "lower_bound") if worker.get(name) is not None}
    if proc.returncode not in (0, None):
        details.pop("backend_exit", None)
        return None, _attempt_diagnostic(entry["key"], entry["path"], attempt, "worker_exit_nonzero", started,
                                          backend_exit=proc.returncode, **details)
    kb = worker.get("kb")
    if type(kb) is int and kb >= 0:
        result = _attempt_diagnostic(entry["key"], entry["path"], attempt, "success", started, kb=kb, **details)
        if elapsed is not None:
            result["elapsed_s"] = round(float(elapsed), 3)
        return kb, result
    reason = worker.get("reason")
    if not isinstance(reason, str) or not reason:
        reason = "backend_timeout" if worker.get("timed_out") else "malformed_result"
    result = _attempt_diagnostic(entry["key"], entry["path"], attempt, reason, started, **details)
    if elapsed is not None:
        result["elapsed_s"] = round(float(elapsed), 3)
    return None, result


def summarize_attempts(attempts):
    """Keep failed or recovered measurements in their original key order."""
    failures = []
    for key, key_attempts in attempts.items():
        if not key_attempts or all(a.get("reason") == "success" for a in key_attempts):
            continue
        status = "recovered" if key_attempts[-1].get("reason") == "success" else "failed"
        failures.append({"key": key, "path": key_attempts[0]["path"], "status": status, "attempts": key_attempts})
    return failures


def lower_bound_keys(attempts):
    """Keys whose final successful measurement was a du lower bound (EACCES/ENOENT only)."""
    return [k for k, a in attempts.items() if a and a[-1].get("reason") == "success" and a[-1].get("lower_bound")]


def orchestrate(entries, snapshot_script, workers, deadline, tmpdir, carry_sizes=None, env_extra=None, diagnostics_out=None,
                shard_state_path=None, shard_timeout=SHARD_DEFAULT_TIMEOUT, shard_workers=SHARD_DEFAULT_WORKERS):
    env_extra = env_extra or {}
    os.makedirs(tmpdir, exist_ok=True)
    results = {}
    attempts = {}
    lock = threading.Lock()

    def job(entry, budget, attempt):
        kb, diagnostic = measure(entry, budget, snapshot_script, tmpdir, deadline, attempt, env_extra)
        with lock:
            attempts.setdefault(entry["key"], []).append(diagnostic)
            if kb is not None:
                results[entry["key"]] = kb
            else:
                results.setdefault(entry["key"], None)
        return kb

    # Big roots (last-good >= 20 GiB, or that timed out last run) are measured as parallel depth-1
    # shards instead of one whole-root probe; everything else keeps the single-probe path.
    sizes = carry_sizes or {}
    shard_state = _load_shard_state(shard_state_path) if shard_state_path else {}
    sharded, partials = {}, []

    def run_sharded(entry):
        prior = (shard_state.get(entry["key"]) or {}).get("shards", {})
        r = measure_sharded(os.path.expanduser(entry["path"]), shard_workers, shard_timeout, deadline, prior)
        if r is None:
            return False
        sharded[entry["key"]] = r
        results[entry["key"]] = r["kb"]
        attempts.setdefault(entry["key"], []).append({"key": entry["key"], "path": entry["path"], "attempt": 1,
                                                       "reason": "success", "sharded": True})
        if r["partial"]:
            partials.append({"key": entry["key"], "path": entry["path"], "status": "partial",
                             "timed_out_shards": r["timed_out_shards"], "stale_shards": r["stale_shards"],
                             "expired_shards": r["expired_shards"], "lower_bound_shards": r["lower_bound_shards"]})
        return True

    def shardable(e):
        if os.environ.get("DISK_MAGICIAN_SHARDING") == "0":  # escape hatch: whole-root probes only
            return False
        p = os.path.expanduser(e["path"])
        return os.path.isdir(p) and not os.path.islink(p)

    def wants_shards(e):
        return shardable(e) and (sizes.get(e["key"], 0) >= SHARD_MIN_KB or (shard_state.get(e["key"]) or {}).get("timed_out"))

    # Phase 1: every other key once, shortest configured timeout first (stable); then the sharded roots.
    big = [e for e in entries if wants_shards(e)]
    order = sorted((e for e in entries if e not in big), key=lambda e: e["timeout"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(lambda e: job(e, e["timeout"], 1), order))
    for e in big:
        if not run_sharded(e):
            job(e, e["timeout"], 1)

    # Phase 2: one retry per timed-out key, largest estimated size first, only
    # with time left; budget is the key's retry_timeout (else its own timeout).
    failed = [e for e in entries if results.get(e["key"]) is None]
    failed.sort(key=lambda e: -sizes.get(e["key"], 0))
    jobs = [(e, e["retry_timeout"] or e["timeout"]) for e in failed]
    runnable, skipped = [], []
    for e, budget in jobs:
        (runnable if deadline - time.time() >= MIN_RETRY_SECONDS else skipped).append((e, budget))
    for e, _budget in skipped:
        with lock:
            attempts.setdefault(e["key"], []).append({
                "key": e["key"], "path": e["path"], "attempt": 2,
                "reason": "orchestrator_deadline", "elapsed_s": 0.0,
            })
    jobs = []
    for e, budget in runnable:  # a timed-out directory is retried as shards, not as one more whole-root probe
        timed_out_whole = attempts.get(e["key"], [{}])[-1].get("reason") == "backend_timeout"
        if e not in big and timed_out_whole and shardable(e) and run_sharded(e):
            continue
        jobs.append((e, budget))
    if jobs:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            list(pool.map(lambda eb: job(eb[0], eb[1], 2), jobs))
    if shard_state_path:
        roots = dict(shard_state)
        for e in entries:
            k = e["key"]
            if k in sharded:
                r = sharded[k]
                roots[k] = {"timed_out": r["partial"], "shards": r["carry"]}
            elif results.get(k) is None:
                roots[k] = {**roots.get(k, {}), "timed_out": True}
            elif k in roots and not roots[k].get("shards"):
                roots.pop(k)
        _save_shard_state(shard_state_path, roots)
    if diagnostics_out is not None:
        diagnostics_out["lower_bound_keys"] = sorted(set(lower_bound_keys(attempts)) | {
            k for k, r in sharded.items() if r["lower_bound"]})
        diagnostics_out["partial_keys"] = sorted(k for k, r in sharded.items() if r["partial"])
        diagnostics_out["measurement_failures"] = summarize_attempts(
            {entry["key"]: attempts.get(entry["key"], []) for entry in entries}
        ) + partials
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", required=True)
    ap.add_argument("--snapshot-script", required=True)
    ap.add_argument("--workers", default="", help="empty = auto from load/memory; capped at 6")
    ap.add_argument("--deadline-epoch", type=float, required=True)
    ap.add_argument("--tmpdir", required=True)
    ap.add_argument("--meta-out", default="")
    ap.add_argument("--carry-state", default="")
    args = ap.parse_args()

    entries = load_entries(args.config)
    override = int(args.workers) if args.workers.isdigit() and int(args.workers) > 0 else None
    cores, load1, pressure, avail = probe_system() if override is None else (1, 0, 1, 99)
    workers = worker_count(cores, load1, pressure, avail, override)

    sizes = {}
    if args.carry_state:
        try:
            with open(args.carry_state) as f:
                sizes = {k: v.get("kb", 0) for k, v in json.load(f).items() if isinstance(v, dict)}
        except (OSError, ValueError):
            pass

    cores_s, load5, pressure_s, _ = probe_system()
    try:
        load5 = os.getloadavg()[1]
    except OSError:
        pass
    env_workers = os.environ.get("DISK_MAGICIAN_MEASURE_WORKERS", "")
    shard_workers = shard_worker_count(cores_s, load5, pressure_s, int(env_workers) if env_workers.isdigit() and int(env_workers) > 0 else None)
    shard_timeout = int(os.environ.get("DISK_MAGICIAN_SHARD_TIMEOUT_SECONDS") or SHARD_DEFAULT_TIMEOUT)
    shard_state = os.path.join(os.path.dirname(os.path.abspath(args.carry_state)), "shard_last_good.json") if args.carry_state else None

    diagnostics = {}
    results = orchestrate(entries, args.snapshot_script, workers, args.deadline_epoch, args.tmpdir, sizes,
                          diagnostics_out=diagnostics, shard_state_path=shard_state,
                          shard_timeout=shard_timeout, shard_workers=shard_workers)
    for e in entries:  # config order, independent of completion order
        kb = results.get(e["key"])
        print(f"{e['key']}\t{'' if kb is None else kb}\t{e['path']}\t{e['timeout']}\t{e['retry_timeout']}")
    if args.meta_out:
        with open(args.meta_out, "w") as f:
            json.dump({"measure_mode": "parallel", "measure_workers": workers, "shard_workers": shard_workers, **diagnostics}, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())

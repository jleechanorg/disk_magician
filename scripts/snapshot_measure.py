#!/usr/bin/env python3
"""Bounded, load-aware parallel measurement of monitored_dirs.

Each key is measured by `disk_snapshot.sh --measure-one KEY PATH TIMEOUT OUTFILE`
(one worker process per key, disjoint output files). Results are printed to stdout
in config order as `key<TAB>kb-or-empty<TAB>path<TAB>timeout<TAB>retry_timeout`;
an empty kb means "not measured" (never zero). Phase 1 attempts every key,
shortest configured timeout first; phase 2 retries timed-out keys once with the
time left before the deadline. At the deadline every worker's whole descendant
tree is killed (GNU timeout escapes process groups, so groups are not enough).
"""
import argparse
import concurrent.futures
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

MAX_WORKERS = 6
GRACE = 2.0
MIN_RETRY_SECONDS = 5
MAX_DIAGNOSTIC_TEXT = 256


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
    for name in ("backend", "backend_exit", "stderr", "kb"):
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
    details = {name: worker.get(name) for name in ("backend", "backend_exit", "stderr") if worker.get(name) is not None}
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


def orchestrate(entries, snapshot_script, workers, deadline, tmpdir, carry_sizes=None, env_extra=None, diagnostics_out=None):
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

    # Phase 1: every key once, shortest configured timeout first (stable).
    order = sorted(entries, key=lambda e: e["timeout"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(lambda e: job(e, e["timeout"], 1), order))

    # Phase 2: one retry per timed-out key, largest estimated size first, only
    # with time left; budget is the key's retry_timeout (else its own timeout).
    sizes = carry_sizes or {}
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
    jobs = runnable
    if jobs:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            list(pool.map(lambda eb: job(eb[0], eb[1], 2), jobs))
    if diagnostics_out is not None:
        diagnostics_out["measurement_failures"] = summarize_attempts(
            {entry["key"]: attempts.get(entry["key"], []) for entry in entries}
        )
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

    diagnostics = {}
    results = orchestrate(entries, args.snapshot_script, workers, args.deadline_epoch, args.tmpdir, sizes,
                          diagnostics_out=diagnostics)
    for e in entries:  # config order, independent of completion order
        kb = results.get(e["key"])
        print(f"{e['key']}\t{'' if kb is None else kb}\t{e['path']}\t{e['timeout']}\t{e['retry_timeout']}")
    if args.meta_out:
        with open(args.meta_out, "w") as f:
            json.dump({"measure_mode": "parallel", "measure_workers": workers, **diagnostics}, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())

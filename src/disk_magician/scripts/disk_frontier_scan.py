#!/usr/bin/env python3
"""disk_frontier_scan.py — exhaustive top-down disk coverage via frontier-BFS.

Standalone scanner (not yet wired into disk_snapshot.sh — see
roadmap/2026-07-11-total-coverage-snapshot-v2.md, implementation-order step 3).

Design contract (roadmap doc, "post-critic" section):
  - Level-1 enumeration under --root is exhaustive and O(1) (single readdir),
    so nothing can be silently absent the way an allowlist can miss a tree.
  - Any subtree that doesn't finish `du` within its timeout tier is
    subdivided into its own children and re-queued — never silently
    null'd out.
  - Every byte of the residual (disk_used - measured) is attributable to a
    named unfinished frontier path, the purgeable/snapshot bucket, or a
    sibling APFS volume.
  - Symlinks are never followed (du -P, no recursion through symlink dirs)
    and a realpath dedup trie prevents double-counting when two different
    top-level paths resolve to the same real directory (e.g. /etc and
    /private/etc both existing as children of the volume root).
  - A single global, dynamically-throttled worker pool bounds concurrent
    `du` subprocesses across ALL BFS levels — subdivision enqueues more
    tasks, it never spins up more concurrent workers.
"""

import argparse
import concurrent.futures
import json
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_ROOT = "/System/Volumes/Data"
DEFAULT_OUTPUT_STATE_FILE = os.path.expanduser("~/.disk_magician_state/frontier_last.json")
DEFAULT_TIMEOUT_TIERS = [10, 30, 90, 180]
DEFAULT_WORKERS = 8
DEFAULT_MAX_DEPTH = 6
DEFAULT_MAX_NODES = 500
DEFAULT_WALL_CLOCK_CAP = 480
LOW_FREE_GB_THRESHOLD = 15
SCHEMA_VERSION = 1

HAVE_TASKPOLICY = shutil.which("taskpolicy") is not None
HAVE_NICE = shutil.which("nice") is not None


class AdjustableSemaphore:
    """Semaphore whose capacity can be lowered/raised while workers are live.

    Plain threading.Semaphore has a fixed initial value; subdivision must
    never multiply concurrent `du` processes, so every task (at every BFS
    depth) acquires from this ONE shared instance. Backpressure checks
    between levels call set_limit() to halve capacity under load/low-disk
    without disturbing threads that already hold a permit.
    """

    def __init__(self, limit):
        self._cond = threading.Condition()
        self._limit = max(1, limit)
        self._count = 0

    def acquire(self):
        with self._cond:
            while self._count >= self._limit:
                self._cond.wait()
            self._count += 1

    def release(self):
        with self._cond:
            self._count -= 1
            self._cond.notify()

    def set_limit(self, n):
        with self._cond:
            self._limit = max(1, n)
            self._cond.notify_all()

    def limit(self):
        with self._cond:
            return self._limit


class RealpathDedupTrie:
    """Tracks already-covered real paths; flags aliases (symlink chains,
    accidental re-enumeration) that would otherwise double-count bytes.
    Root-level /etc,/tmp,/var -> /private/* is the live-verified case."""

    def __init__(self):
        self._covered = []
        self._lock = threading.Lock()

    def covered_by(self, path):
        real = os.path.realpath(path)
        with self._lock:
            for existing in self._covered:
                if real == existing or real.startswith(existing.rstrip("/") + "/"):
                    return existing
        return None

    def add(self, path):
        real = os.path.realpath(path)
        with self._lock:
            self._covered.append(real)
        return real


class ConcurrencyTracker:
    """Debug instrumentation: high-water-mark of concurrent du subprocesses,
    used by tests/test_frontier_scan.sh to prove subdivision never
    multiplies the worker pool (critic BLOCKER)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._current = 0
        self._peak = 0

    def enter(self):
        with self._lock:
            self._current += 1
            self._peak = max(self._peak, self._current)

    def exit(self):
        with self._lock:
            self._current -= 1

    def peak(self):
        with self._lock:
            return self._peak


def run_du(path, timeout_s, tracker):
    cmd = []
    if HAVE_TASKPOLICY:
        cmd += ["taskpolicy", "-b"]
    if HAVE_NICE:
        cmd += ["nice", "-n", "10"]
    cmd += ["du", "-x", "-P", "-sk", path]
    tracker.enter()
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout_s
        )
    except subprocess.TimeoutExpired:
        return None
    except OSError:
        return None
    finally:
        tracker.exit()
    out = proc.stdout.strip()
    if not out:
        return None
    line = out.splitlines()[-1]
    parts = line.split()
    if not parts:
        return None
    try:
        return int(parts[0])
    except ValueError:
        return None


def list_children(path):
    """Cheap O(1)-per-level enumeration (single readdir). Never descends
    through symlinked directories — those are measured as leaves (du -P
    reports their own tiny size) so they can never contribute a walk cost
    or a double-count."""
    children = []
    try:
        with os.scandir(path) as it:
            for entry in it:
                try:
                    is_symlink = entry.is_symlink()
                except OSError:
                    continue
                children.append((entry.path, is_symlink))
    except (PermissionError, FileNotFoundError, NotADirectoryError, OSError):
        return None
    return children


def get_disk_stats(root):
    try:
        out = subprocess.check_output(["df", "-k", root], text=True)
    except (subprocess.CalledProcessError, OSError):
        return {"total_kb": 0, "used_kb": 0, "free_kb": 0}
    lines = out.strip().splitlines()
    if len(lines) < 2:
        return {"total_kb": 0, "used_kb": 0, "free_kb": 0}
    fields = lines[1].split()
    try:
        return {
            "total_kb": int(fields[1]),
            "used_kb": int(fields[2]),
            "free_kb": int(fields[3]),
        }
    except (IndexError, ValueError):
        return {"total_kb": 0, "used_kb": 0, "free_kb": 0}


def get_sibling_volumes(root, warnings):
    """Enumerate every APFS volume in the same container as `root`'s
    container, excluding the Data-role volume itself. These are
    structurally invisible to a Data-rooted walk (VM/Preboot/Update/...)."""
    try:
        raw = subprocess.check_output(
            ["diskutil", "apfs", "list", "-plist"], stderr=subprocess.DEVNULL
        )
        data = plistlib.loads(raw)
    except (subprocess.CalledProcessError, OSError, ValueError):
        warnings.append("sibling_volumes unavailable: diskutil apfs list failed")
        return {}

    try:
        root_info = subprocess.check_output(
            ["diskutil", "info", "-plist", root], stderr=subprocess.DEVNULL
        )
        root_plist = plistlib.loads(root_info)
        root_container_uuid = root_plist.get("APFSContainerUUID") or root_plist.get(
            "ContainerUUID"
        )
    except (subprocess.CalledProcessError, OSError, ValueError):
        root_container_uuid = None
        warnings.append("sibling_volumes: could not resolve root's container UUID")

    siblings = {}
    for container in data.get("Containers", []):
        if root_container_uuid and container.get("APFSContainerUUID") != root_container_uuid:
            continue
        for vol in container.get("Volumes", []):
            roles = vol.get("Roles", []) or []
            if "Data" in roles:
                continue
            name = vol.get("Name") or vol.get("APFSVolumeUUID") or "unknown"
            siblings[name] = {
                "roles": roles,
                "capacity_in_use_kb": int((vol.get("CapacityInUse") or 0) / 1024),
            }
        if root_container_uuid:
            break
    return siblings


def get_purgeable_info(root, warnings):
    """Best-effort. macOS 15.5's diskutil does not expose a distinct
    purgeable-bytes field via the CLI (verified empirically — diskutil
    info -plist has APFSContainerFree/CapacityInUse/FreeSpace but no
    purgeable key). We report tmutil's local snapshot list as the
    verifiable proxy signal and are explicit that purgeable_kb is an
    unavailable estimate rather than fabricating a number."""
    snapshots = []
    try:
        out = subprocess.check_output(
            ["tmutil", "listlocalsnapshots", root],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )
        for line in out.splitlines():
            line = line.strip()
            if line and not line.lower().startswith("snapshots for"):
                snapshots.append(line)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        warnings.append("local_snapshots unavailable: tmutil listlocalsnapshots failed")

    return {
        "purgeable_kb": 0,
        "purgeable_estimate_method": (
            "unavailable: diskutil does not expose a distinct purgeable field "
            "on this macOS version; local_snapshots is reported as a proxy "
            "signal, not netted into residual_kb"
        ),
        "local_snapshots": snapshots,
        "local_snapshots_count": len(snapshots),
    }


class FrontierScanner:
    def __init__(self, args):
        self.root = os.path.realpath(args.root) if args.resolve_root else args.root
        self.workers_cap = args.workers
        self.max_depth = args.max_depth
        self.max_nodes = args.max_nodes
        self.wall_clock_cap = args.wall_clock_cap
        self.timeout_tiers = args.timeout_tiers
        self.trie = RealpathDedupTrie()
        self.tracker = ConcurrencyTracker()
        self.sem = AdjustableSemaphore(args.workers)
        self.measured = {}
        self.deduped = []
        self.frontier_unfinished = []
        self.warnings = []
        self.nodes_processed = 0
        self.nodes_lock = threading.Lock()
        self.start_time = 0.0
        self.root_dev = None
        self.skip_sibling_volumes = args.no_sibling_volumes
        self.skip_purgeable = args.no_purgeable

    def elapsed(self):
        return time.time() - self.start_time

    def remaining_budget(self):
        return self.wall_clock_cap - self.elapsed()

    def try_take_node_slot(self):
        with self.nodes_lock:
            if self.nodes_processed >= self.max_nodes:
                return False
            self.nodes_processed += 1
            return True

    def maybe_throttle(self):
        """Backpressure: halve worker-pool capacity when 1-min loadavg
        exceeds core count or free disk drops below the safety floor.
        Never raises above the configured cap once lowered mid-run only
        raises back if pressure clears, avoiding thrash at the boundary."""
        try:
            load1, _, _ = os.getloadavg()
        except OSError:
            load1 = 0
        ncpu = os.cpu_count() or 1
        free_gb = shutil.disk_usage(self.root).free / (1024 ** 3)
        under_pressure = load1 > ncpu or free_gb < LOW_FREE_GB_THRESHOLD
        target = max(1, self.workers_cap // 2) if under_pressure else self.workers_cap
        if self.sem.limit() != target:
            self.sem.set_limit(target)
            if under_pressure:
                self.warnings.append(
                    f"backpressure: throttled worker pool to {target} "
                    f"(load1={load1:.1f} ncpu={ncpu} free_gb={free_gb:.1f})"
                )

    def measure_one(self, path):
        self.sem.acquire()
        try:
            attempted_tiers = []
            kb = None
            for tier in self.timeout_tiers:
                remaining = self.remaining_budget()
                if remaining <= 0:
                    break
                effective = min(tier, max(1, int(remaining)))
                attempted_tiers.append(effective)
                kb = run_du(path, effective, self.tracker)
                if kb is not None:
                    break
            if kb is None and self.timeout_tiers:
                # second attempt at top tier before giving up on this node
                remaining = self.remaining_budget()
                if remaining > 0:
                    top = self.timeout_tiers[-1]
                    effective = min(top, max(1, int(remaining)))
                    kb = run_du(path, effective, self.tracker)
        finally:
            self.sem.release()
        return kb

    def process_node(self, path, depth, is_symlink):
        if not self.try_take_node_slot():
            self.frontier_unfinished.append(
                {"path": path, "depth": depth, "reason": "node_budget_exhausted"}
            )
            return

        if self.remaining_budget() <= 0:
            self.frontier_unfinished.append(
                {"path": path, "depth": depth, "reason": "time_budget_exhausted"}
            )
            return

        try:
            st = os.lstat(path)
        except OSError:
            self.warnings.append(f"lstat failed, skipping: {path}")
            return

        if self.root_dev is not None and st.st_dev != self.root_dev and not is_symlink:
            self.frontier_unfinished.append(
                {"path": path, "depth": depth, "reason": "cross_device_boundary"}
            )
            return

        covering = self.trie.covered_by(path)
        if covering is not None:
            self.deduped.append({"path": path, "realpath_of": covering})
            return

        # Symlinks are always measured as leaves (du -P never follows them,
        # so this is O(1) and cannot double-count or recurse).
        if is_symlink:
            kb = self.measure_one(path)
            if kb is not None:
                self.measured[path] = kb
                self.trie.add(path)
            else:
                self.frontier_unfinished.append(
                    {"path": path, "depth": depth, "reason": "symlink_measure_failed"}
                )
            return

        kb = self.measure_one(path)
        if kb is not None:
            self.measured[path] = kb
            self.trie.add(path)
            return

        # Exhausted all timeout tiers (+ one extra attempt at top tier).
        # Subdivide into children rather than nulling out, unless we've
        # hit max depth or the tree has no further children to offer.
        if depth >= self.max_depth or self.remaining_budget() <= 0:
            self.frontier_unfinished.append(
                {
                    "path": path,
                    "depth": depth,
                    "reason": "max_depth_reached"
                    if depth >= self.max_depth
                    else "time_budget_exhausted",
                }
            )
            return

        children = list_children(path)
        if children is None:
            self.frontier_unfinished.append(
                {"path": path, "depth": depth, "reason": "unreadable_after_timeout"}
            )
            return
        if not children:
            self.frontier_unfinished.append(
                {"path": path, "depth": depth, "reason": "empty_dir_timeout_anomaly"}
            )
            return

        return [(child_path, depth + 1, child_symlink) for child_path, child_symlink in children]

    def run(self):
        self.start_time = time.time()
        try:
            self.root_dev = os.stat(self.root).st_dev
        except OSError as exc:
            return {"error": f"root not accessible: {self.root}: {exc}"}

        level1 = list_children(self.root)
        if level1 is None:
            return {"error": f"could not enumerate root: {self.root}"}

        frontier = [(p, 1, is_sym) for p, is_sym in level1]

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=max(self.workers_cap, 1)
        ) as pool:
            while frontier:
                if self.elapsed() > self.wall_clock_cap:
                    for path, depth, _ in frontier:
                        self.frontier_unfinished.append(
                            {"path": path, "depth": depth, "reason": "time_budget_exhausted"}
                        )
                    break

                self.maybe_throttle()

                futures = {
                    pool.submit(self.process_node, path, depth, is_sym): path
                    for path, depth, is_sym in frontier
                }
                next_frontier = []
                for fut in concurrent.futures.as_completed(futures):
                    try:
                        result = fut.result()
                    except Exception as exc:  # noqa: BLE001 - never crash the scan
                        self.warnings.append(f"worker exception for {futures[fut]}: {exc}")
                        continue
                    if result:
                        next_frontier.extend(result)
                frontier = next_frontier

        return None


def atomic_write_json(path, text):
    """Write `text` to `path` atomically: temp file in the same directory +
    os.replace (same-filesystem rename is atomic on APFS/HFS+), then chmod
    0644. A reader can never observe a partially-written or empty file —
    it's either the previous complete snapshot or the new complete one.
    Atomicity, not durability: no F_FULLFSYNC before the rename, so power
    loss can revert to the prior complete file — acceptable, since this
    state is fully regenerated by the next nightly scan."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    tmp_path = None
    try:
        tmp_fd, tmp_path = tempfile.mkstemp(
            prefix=".disk_frontier_scan.", suffix=".tmp", dir=directory
        )
        with os.fdopen(tmp_fd, "w") as f:
            f.write(text)
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
        tmp_path = None
    finally:
        if tmp_path is not None and os.path.exists(tmp_path):
            os.unlink(tmp_path)


def build_report(scanner, disk_stats, sibling_volumes, purgeable_info, elapsed_s, args):
    measured_total_kb = sum(scanner.measured.values())
    residual_raw_kb = disk_stats["used_kb"] - measured_total_kb - purgeable_info["purgeable_kb"]
    residual_negative_clamped = residual_raw_kb < 0
    residual_kb = max(0, residual_raw_kb)

    mode = "complete" if not scanner.frontier_unfinished else "partial"

    report = {
        "schema_version": SCHEMA_VERSION,
        "tool": "disk_frontier_scan",
        "mode": mode,
        "hostname": socket.gethostname(),
        "argv": sys.argv[1:],
        "root": scanner.root,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_s": round(elapsed_s, 1),
        "config": {
            "workers": args.workers,
            "max_depth": args.max_depth,
            "max_nodes": args.max_nodes,
            "wall_clock_cap_s": args.wall_clock_cap,
            "timeout_tiers_s": args.timeout_tiers,
        },
        "disk_total_kb": disk_stats["total_kb"],
        "disk_used_kb": disk_stats["used_kb"],
        "disk_free_kb": disk_stats["free_kb"],
        "measured": scanner.measured,
        "measured_total_kb": measured_total_kb,
        "deduped": scanner.deduped,
        "frontier_unfinished": scanner.frontier_unfinished,
        "sibling_volumes": sibling_volumes,
        "purgeable_kb": purgeable_info["purgeable_kb"],
        "purgeable_estimate_method": purgeable_info["purgeable_estimate_method"],
        "local_snapshots": purgeable_info["local_snapshots"],
        "local_snapshots_count": purgeable_info["local_snapshots_count"],
        "residual_kb": residual_kb,
        "residual_raw_kb": residual_raw_kb,
        "residual_negative_clamped": residual_negative_clamped,
        "clones_suspected": residual_negative_clamped,
        "nodes_processed": scanner.nodes_processed,
        "max_concurrent_du_observed": scanner.tracker.peak(),
        "warnings": scanner.warnings,
    }
    return report


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", default=DEFAULT_ROOT)
    p.add_argument("--resolve-root", action="store_true", default=False,
                    help="realpath() the --root before scanning (off by default: "
                         "the volume root itself is never a symlink in practice)")
    p.add_argument("--output", default=None,
                    help="also write JSON here (atomically); stdout is always emitted regardless")
    p.add_argument("--output-default", action="store_true", default=False,
                    help=f"also write JSON to {DEFAULT_OUTPUT_STATE_FILE} (atomically), "
                         "creating its parent dir if needed; ignored if --output is given")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    p.add_argument("--max-depth", type=int, default=DEFAULT_MAX_DEPTH)
    p.add_argument("--max-nodes", type=int, default=DEFAULT_MAX_NODES)
    p.add_argument("--wall-clock-cap", type=float, default=DEFAULT_WALL_CLOCK_CAP)
    p.add_argument(
        "--timeout-tiers",
        default=",".join(str(t) for t in DEFAULT_TIMEOUT_TIERS),
        help="comma-separated fixed timeout tiers in seconds, e.g. 10,30,90,180",
    )
    p.add_argument("--no-sibling-volumes", action="store_true", default=False)
    p.add_argument("--no-purgeable", action="store_true", default=False)
    p.add_argument("--debug-concurrency", action="store_true", default=False,
                    help="print MAX_CONCURRENT_DU=<n> to stderr at the end (test hook)")
    p.add_argument("--disk-used-kb-override", type=int, default=None,
                    help="test-only: force disk_used_kb to exercise residual clamping")
    args = p.parse_args(argv)
    args.timeout_tiers = [int(x) for x in args.timeout_tiers.split(",") if x.strip()]
    if not args.timeout_tiers:
        args.timeout_tiers = list(DEFAULT_TIMEOUT_TIERS)
    return args


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])

    scanner = FrontierScanner(args)
    err = scanner.run()
    elapsed_s = scanner.elapsed()

    if err:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "tool": "disk_frontier_scan", **err}))
        return 1

    disk_stats = get_disk_stats(args.root)
    if args.disk_used_kb_override is not None:
        disk_stats["used_kb"] = args.disk_used_kb_override

    sibling_volumes = {}
    if not args.no_sibling_volumes:
        sibling_volumes = get_sibling_volumes(args.root, scanner.warnings)

    purgeable_info = {
        "purgeable_kb": 0,
        "purgeable_estimate_method": "skipped (--no-purgeable)",
        "local_snapshots": [],
        "local_snapshots_count": 0,
    }
    if not args.no_purgeable:
        purgeable_info = get_purgeable_info(args.root, scanner.warnings)

    report = build_report(scanner, disk_stats, sibling_volumes, purgeable_info, elapsed_s, args)

    out_text = json.dumps(report, indent=2)

    # stdout is always emitted — --output/--output-default are additive
    # persistence for the nightly launchd job, not a replacement for it.
    print(out_text)

    state_path = args.output
    if state_path is None and args.output_default:
        state_path = DEFAULT_OUTPUT_STATE_FILE
    if state_path:
        atomic_write_json(state_path, out_text)

    if args.debug_concurrency:
        print(f"MAX_CONCURRENT_DU={scanner.tracker.peak()}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

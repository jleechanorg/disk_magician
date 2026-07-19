#!/usr/bin/env python3
"""disk_frontier_scan.py — exhaustive top-down disk coverage.

Standalone scanner (not yet wired into disk_snapshot.sh — see
roadmap/2026-07-11-total-coverage-snapshot-v2.md, implementation-order step 3).

Design contract (roadmap doc, "post-critic" section):
  - With GNU du installed and a nonzero granularity, all level-1 logical
    shards are scanned by ONE NUL-delimited postorder inventory process.
    This avoids repeated subtree walks and preserves process-global hardlink
    deduplication across shards.
  - Localized permission/TCC failures taint their ancestors; partial ancestor
    totals are rejected while clean siblings remain attributable. Unknown
    diagnostics fail closed to the legacy frontier scanner.
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
  - In the compatibility fallback, a single global, dynamically-throttled worker pool bounds concurrent
    `du` subprocesses across ALL BFS levels — subdivision enqueues more
    tasks, it never spins up more concurrent workers.
"""

import argparse
import collections
import concurrent.futures
import heapq
import json
import os
import plistlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_ROOT = "/System/Volumes/Data"
DEFAULT_OUTPUT_STATE_FILE = os.path.expanduser("~/.disk_magician_state/frontier_last.json")
DEFAULT_TIMEOUT_TIERS = [10, 30, 90, 180]
DUA_TIMEOUT_CAP_SECONDS = 1
DEFAULT_WORKERS = 8
DEFAULT_MAX_DEPTH = 6
DEFAULT_MAX_NODES = 100_000_000
DEFAULT_WALL_CLOCK_CAP = 480
SHALLOW_ENUMERATION_MAX_DEPTH = 2
LOW_FREE_GB_THRESHOLD = 15
SCHEMA_VERSION = 2

HAVE_TASKPOLICY = shutil.which("taskpolicy") is not None
HAVE_NICE = shutil.which("nice") is not None
DUA_CMD = shutil.which("dua")
_GDU_OVERRIDE = os.environ.get("DISK_MAGICIAN_GDU_CMD")
GDU_CMD = shutil.which("gdu") if _GDU_OVERRIDE is None else (_GDU_OVERRIDE or None)
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*m")
GDU_LOCALIZED_ERROR_RE = re.compile(
    r"^gdu: .*? '(.+)': (Permission denied|Operation not permitted|"
    r"No such file or directory|Input/output error|Interrupted system call)$"
)
GDU_FTS_ERROR_RE = re.compile(
    r"^gdu: fts_read failed: (.+): (No such file or directory|"
    r"Permission denied|Operation not permitted|Input/output error|Interrupted system call)$"
)


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


def run_du(path, timeout_s, tracker, is_symlink=False):
    prefix = []
    if HAVE_TASKPOLICY:
        prefix += ["taskpolicy", "-b"]
    if HAVE_NICE:
        prefix += ["nice", "-n", "10"]
    deadline = time.monotonic() + timeout_s
    tracker.enter()
    try:
        if GDU_CMD and not is_symlink:
            try:
                proc = subprocess.run(
                    [GDU_CMD, "-x", "-k", "-s", path],
                    capture_output=True,
                    text=True,
                    timeout=max(0.001, deadline - time.monotonic()),
                )
            except subprocess.TimeoutExpired:
                proc = None
            except OSError:
                proc = None
            if proc is not None and proc.returncode == 0:
                parts = proc.stdout.strip().split()
                if parts:
                    try:
                        return int(parts[0])
                    except ValueError:
                        pass
        if DUA_CMD and not is_symlink:
            try:
                proc = subprocess.run(
                    [DUA_CMD, "aggregate", "-x", "--format", "bytes", path],
                    capture_output=True,
                    text=True,
                    timeout=max(0.001, deadline - time.monotonic()),
                )
            except subprocess.TimeoutExpired:
                return None
            except OSError:
                proc = None
            if proc is not None and proc.returncode == 0:
                bytes_used = None
                for line in ANSI_ESCAPE_RE.sub("", proc.stdout).splitlines():
                    parts = line.split()
                    if parts and parts[0].isdigit():
                        bytes_used = int(parts[0])
                if bytes_used is not None:
                    return (bytes_used + 1023) // 1024

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            proc = subprocess.run(
                prefix + ["du", "-x", "-P", "-sk", path],
                capture_output=True,
                text=True,
                timeout=remaining,
            )
        except (subprocess.TimeoutExpired, OSError):
            return None
    finally:
        tracker.exit()
    # `du` can print a partial subtotal and still exit nonzero when TCC or
    # filesystem permissions block a descendant. Treating that stdout as a
    # complete measurement would silently hide the inaccessible subtree.
    if proc.returncode != 0:
        return None
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


def run_gdu_inventory(paths, timeout_s, tracker, max_records):
    """Walk a non-overlapping path manifest once with GNU du.

    One process is important: GNU du's hardlink deduplication is process-local,
    so totals from independently scanned shards cannot safely be summed.
    NUL records preserve whitespace and newlines in filesystem paths.
    """
    cmd = [GDU_CMD, "-x", "-k", "--null", "--", *paths]
    tracker.enter()
    try:
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=max(0.001, timeout_s),
                env={**os.environ, "LC_ALL": "C"},
            )
        except subprocess.TimeoutExpired as exc:
            return {
                "usable": False,
                "records": {},
                "error_paths": [],
                "unknown_errors": ["inventory_timeout"],
                "returncode": None,
                "timed_out": True,
                "stderr": exc.stderr or "",
            }
        except OSError as exc:
            return {
                "usable": False,
                "records": {},
                "error_paths": [],
                "unknown_errors": [f"inventory_exec_errno_{exc.errno}"],
                "returncode": None,
                "timed_out": False,
                "stderr": str(exc),
            }
    finally:
        tracker.exit()

    records = {}
    malformed = False
    record_ceiling_exceeded = False
    chunks = proc.stdout.split("\0")
    if chunks and chunks[-1]:
        malformed = True
    for raw in chunks[:-1] if chunks else []:
        if not raw:
            continue
        try:
            size_text, path = raw.split("\t", 1)
            kb = int(size_text)
        except (ValueError, TypeError):
            malformed = True
            break
        if kb < 0 or not path:
            malformed = True
            break
        records[os.path.normpath(path)] = kb
        if len(records) > max_records:
            record_ceiling_exceeded = True
            break

    error_paths = []
    unknown_errors = []
    reason_by_message = {
        "Permission denied": "inventory_permission_denied",
        "Operation not permitted": "inventory_permission_denied",
        "No such file or directory": "inventory_path_disappeared",
        "Input/output error": "inventory_io_error",
        "Interrupted system call": "inventory_interrupted_system_call",
    }
    for line in proc.stderr.splitlines():
        line = line.strip()
        if not line:
            continue
        match = GDU_LOCALIZED_ERROR_RE.match(line) or GDU_FTS_ERROR_RE.match(line)
        if match:
            error_paths.append(
                {
                    "path": os.path.normpath(match.group(1)),
                    "reason": reason_by_message[match.group(2)],
                }
            )
        else:
            unknown_errors.append(line)

    if malformed:
        unknown_errors.append("inventory_malformed_output")
    if record_ceiling_exceeded:
        unknown_errors.append("inventory_record_ceiling_exceeded")
    if proc.returncode != 0 and not error_paths and not unknown_errors:
        unknown_errors.append(f"inventory_exit_{proc.returncode}_without_diagnostic")
    return {
        "usable": not malformed and not unknown_errors,
        "records": records,
        "error_paths": error_paths,
        "unknown_errors": unknown_errors,
        "returncode": proc.returncode,
        "timed_out": False,
        "stderr": proc.stderr,
    }


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
    except PermissionError:
        return None, "permission_denied_or_tcc"
    except FileNotFoundError:
        return None, "path_disappeared"
    except NotADirectoryError:
        return None, "not_a_directory"
    except OSError as exc:
        return None, f"enumeration_errno_{exc.errno}"
    return children, None


DATA_ROOT_PRIORITY = {
    "Users": 0,
    "private": 1,
    ".Spotlight-V100": 2,
    "opt": 3,
    "Library": 4,
    "Applications": 5,
    "System": 6,
}

USER_ROOT_PRIORITY = {
    "projects": 0,
    "projects_other": 1,
    "Library": 2,
    ".colima": 3,
    ".codex": 4,
    ".worktrees": 5,
    ".hermes": 6,
    "Pictures": 7,
    "dk2d_evidence": 8,
    "project_worldaiclaw": 9,
    "projects_reference": 10,
    "repos": 11,
    ".ao": 12,
    ".local": 13,
    ".lima": 14,
}


def frontier_sort_key(root, item):
    """Deterministic traversal order: the Data-root priority class dominates
    depth, so the entire /Users subtree drains (breadth-first within the
    class) before any system-dir fan-out is measured. Under a tight
    wall-clock budget a whole-volume scan previously died running slow `du`s
    over depth-2 /Library and /System nodes before ever reaching depth-3
    /Users content (bead jleechan-ez97); class-first ordering spends the
    budget on the usage-relevant tree first while residual accounting keeps
    the unmeasured remainder honest."""
    path, depth, _ = item
    try:
        rel = os.path.relpath(path, root)
    except ValueError:
        rel = path
    parts = rel.split(os.sep)
    first = parts[0]
    user_priority = len(USER_ROOT_PRIORITY)
    hidden_descendant = 0
    if first == "Users" and len(parts) >= 3:
        if len(parts) == 3:
            user_priority = USER_ROOT_PRIORITY.get(parts[2], user_priority)
        hidden_descendant = int(any(part.startswith(".") for part in parts[3:]))
    return (
        DATA_ROOT_PRIORITY.get(first, len(DATA_ROOT_PRIORITY)),
        depth,
        user_priority,
        hidden_descendant,
        rel.casefold(),
        rel,
    )


def build_granularity_buckets(measured, root, granularity_kb):
    """Project one non-overlapping display partition from accepted leaves.

    A path is rolled up only when its accepted descendants total no more than
    the configured ceiling. Larger directories are recursively subdivided;
    an indivisible accepted leaf above the ceiling is reported separately by
    ``build_report`` and never masquerades as a bounded bucket.
    """
    if granularity_kb <= 0:
        return []

    tree = {"path": root, "measured_kb": 0, "children": {}}
    for path, kb in measured.items():
        try:
            rel = os.path.relpath(path, root)
        except ValueError:
            continue
        if rel == os.pardir or rel.startswith(os.pardir + os.sep):
            continue
        parts = [] if rel == os.curdir else rel.split(os.sep)
        node = tree
        node["measured_kb"] += kb
        current = root
        for part in parts:
            current = os.path.join(current, part)
            node = node["children"].setdefault(
                part, {"path": current, "measured_kb": 0, "children": {}}
            )
            node["measured_kb"] += kb

    def select(node):
        if 0 < node["measured_kb"] <= granularity_kb:
            return [{"path": node["path"], "measured_kb": node["measured_kb"]}]
        selected = []
        for child in node["children"].values():
            selected.extend(select(child))
        return selected

    buckets = []
    for child in tree["children"].values():
        buckets.extend(select(child))
    buckets.sort(key=lambda item: (-item["measured_kb"], item["path"]))
    return buckets


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


def get_sibling_volumes(root, warnings, apfs_accounting=None):
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
        root_container_reference = root_plist.get("APFSContainerReference")
    except (subprocess.CalledProcessError, OSError, ValueError):
        root_container_uuid = None
        root_container_reference = None
        warnings.append("sibling_volumes: could not resolve root's container identity")

    siblings = {}
    for container in data.get("Containers", []):
        if root_container_uuid and container.get("APFSContainerUUID") != root_container_uuid:
            continue
        if (
            not root_container_uuid
            and root_container_reference
            and container.get("ContainerReference") != root_container_reference
        ):
            continue
        if not root_container_uuid and not root_container_reference:
            continue
        all_volumes = []
        for vol in container.get("Volumes", []):
            roles = vol.get("Roles", []) or []
            all_volumes.append(
                {
                    "name": vol.get("Name") or vol.get("APFSVolumeUUID") or "unknown",
                    "roles": roles,
                    "capacity_in_use_kb": int((vol.get("CapacityInUse") or 0) / 1024),
                }
            )
            if "Data" in roles:
                continue
            name = vol.get("Name") or vol.get("APFSVolumeUUID") or "unknown"
            siblings[name] = {
                "roles": roles,
                "capacity_in_use_kb": int((vol.get("CapacityInUse") or 0) / 1024),
            }
        if apfs_accounting is not None:
            capacity_kb = int((container.get("CapacityCeiling") or 0) / 1024)
            free_kb = int((container.get("CapacityFree") or 0) / 1024)
            allocated_kb = sum(item["capacity_in_use_kb"] for item in all_volumes)
            shared_kb = max(0, capacity_kb - free_kb - allocated_kb)
            apfs_accounting.update(
                {
                    "container_uuid": container.get("APFSContainerUUID"),
                    "container_reference": container.get("ContainerReference"),
                    "physical_stores": [
                        {
                            "device": item.get("DeviceIdentifier"),
                            "size_kb": int((item.get("Size") or 0) / 1024),
                        }
                        for item in container.get("PhysicalStores", [])
                    ],
                    "container_capacity_kb": capacity_kb,
                    "container_free_kb": free_kb,
                    "volumes": all_volumes,
                    "volume_allocations_kb": allocated_kb,
                    "shared_allocation_kb": shared_kb,
                    "equation_balanced": allocated_kb + shared_kb + free_kb == capacity_kb,
                }
            )
        if root_container_uuid or root_container_reference:
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
        # Every successful du result, including parents later subdivided for
        # the granularity report. `measured` remains the non-overlapping byte
        # ledger; `observed` is only for selecting useful display buckets.
        self.observed = {}
        self.granularity_kb = int(args.granularity_gib * 1024 * 1024)
        self.shallow_enumeration_depth = getattr(
            args,
            "shallow_enumeration_depth",
            SHALLOW_ENUMERATION_MAX_DEPTH if args.root == DEFAULT_ROOT else 0,
        )
        self.oversize_files = []
        self.inventory_buckets = None
        self.inventory_backend = None
        self.deduped = []
        self.frontier_unfinished = []
        self.warnings = []
        self.nodes_processed = 0
        self.nodes_lock = threading.Lock()
        self.start_time = 0.0
        self.root_dev = None
        self.level1_paths = []
        self.skip_sibling_volumes = args.no_sibling_volumes
        self.skip_purgeable = args.no_purgeable

    def _apply_inventory_partition(self, records, error_items, manifest):
        """Build one safe byte ledger and one <=granularity display frontier."""
        children = collections.defaultdict(set)
        for path in records:
            current = path
            while current != self.root:
                parent = os.path.dirname(current)
                if parent == current:
                    break
                children[parent].add(current)
                if parent in records:
                    break
                current = parent
        children = {
            parent: sorted(paths, key=str.casefold) for parent, paths in children.items()
        }

        error_roots = [item["path"] for item in error_items]
        tainted_ancestors = set()
        root_prefix = self.root.rstrip(os.sep) + os.sep
        for error_path in error_roots:
            current = error_path
            while current == self.root or current.startswith(root_prefix):
                tainted_ancestors.add(current)
                if current == self.root:
                    break
                parent = os.path.dirname(current)
                if parent == current:
                    break
                current = parent

        def is_tainted(path):
            if path in tainted_ancestors:
                return True
            prefix = path.rstrip(os.sep) + os.sep
            return any(path == failed or path.startswith(failed.rstrip(os.sep) + os.sep)
                       or failed.startswith(prefix) for failed in error_roots)

        def accept_safe_ledger(path):
            if path not in records or is_tainted(path):
                for child in children.get(path, []):
                    accept_safe_ledger(child)
                return
            self.measured[path] = records[path]

        for path in manifest:
            accept_safe_ledger(path)

        buckets = []

        def emit_direct_allocation(path, direct_kb):
            """Explain directory-local allocation without emitting a >5 GiB row.

            Directory-only gdu output keeps the inventory small. Unique-link
            direct files above the ceiling can still be named exactly; the
            remaining direct files plus directory metadata are split into
            bounded, explicitly synthetic path-local segments.
            """
            remaining_kb = max(0, direct_kb)
            try:
                direct_files = []
                with os.scandir(path) as entries:
                    for entry in entries:
                        try:
                            if not entry.is_file(follow_symlinks=False):
                                continue
                            st = entry.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        file_kb = (st.st_blocks * 512 + 1023) // 1024
                        if st.st_nlink == 1 and file_kb > self.granularity_kb:
                            direct_files.append((entry.path, file_kb))
                for file_path, file_kb in sorted(direct_files):
                    if file_kb > remaining_kb:
                        continue
                    self.oversize_files.append(
                        {
                            "path": file_path,
                            "measured_kb": file_kb,
                            "reason": "indivisible_file",
                        }
                    )
                    remaining_kb -= file_kb
            except OSError:
                pass

            if remaining_kb <= 0:
                return
            parts = (remaining_kb + self.granularity_kb - 1) // self.granularity_kb
            for index in range(parts):
                segment_kb = min(self.granularity_kb, remaining_kb)
                suffix = "" if parts == 1 else f" {index + 1}/{parts}"
                buckets.append(
                    {
                        "path": f"{path} [direct files + directory metadata{suffix}]",
                        "source_path": path,
                        "kind": "direct_allocation_segment",
                        "measured_kb": segment_kb,
                    }
                )
                remaining_kb -= segment_kb

        def select_display(path):
            kb = records[path]
            if kb <= self.granularity_kb:
                if kb > 0:
                    buckets.append({"path": path, "measured_kb": kb})
                return
            try:
                is_directory = stat.S_ISDIR(os.lstat(path).st_mode)
            except OSError:
                is_directory = bool(children.get(path))
            if is_directory:
                child_paths = [
                    child for child in children.get(path, []) if not is_tainted(child)
                ]
                for child in child_paths:
                    select_display(child)
                child_total_kb = sum(records[child] for child in child_paths)
                emit_direct_allocation(path, max(0, kb - child_total_kb))
                return
            self.oversize_files.append(
                {"path": path, "measured_kb": kb, "reason": "indivisible_file"}
            )

        for path in self.measured:
            select_display(path)
        buckets.sort(key=lambda item: (-item["measured_kb"], item["path"]))
        self.inventory_buckets = buckets

    def run_one_pass_inventory(self, level1):
        """Use one GNU du process for all level-1 logical shards.

        Returns True when the authoritative inventory was usable. Unknown
        diagnostics fail closed and leave the existing frontier scanner as
        the compatibility fallback.
        """
        manifest_items = []
        pending_unfinished = []
        for path, is_symlink in sorted(
            level1, key=lambda item: frontier_sort_key(self.root, (item[0], 1, item[1]))
        ):
            try:
                st = os.lstat(path)
            except OSError as exc:
                pending_unfinished.append(
                    {"path": path, "depth": 1, "reason": "lstat_failed", "errno": exc.errno}
                )
                continue
            if not is_symlink and self.root_dev is not None and st.st_dev != self.root_dev:
                pending_unfinished.append(
                    {"path": path, "depth": 1, "reason": "cross_device_boundary"}
                )
                continue
            manifest_items.append(path)

        if not manifest_items:
            self.frontier_unfinished.extend(pending_unfinished)
            self.inventory_buckets = []
            self.inventory_backend = "gdu_one_pass"
            return True

        result = run_gdu_inventory(
            manifest_items,
            max(0.001, self.remaining_budget()),
            self.tracker,
            self.max_nodes,
        )
        if not result["usable"]:
            self.warnings.append(
                "one-pass gdu inventory rejected; falling back to frontier: "
                + "; ".join(result["unknown_errors"][:5])
            )
            return False

        self.nodes_processed = len(result["records"])
        self.frontier_unfinished.extend(pending_unfinished)
        for item in result["error_paths"]:
            try:
                rel = os.path.relpath(item["path"], self.root)
                depth = 0 if rel == os.curdir else len(rel.split(os.sep))
            except ValueError:
                depth = None
            self.frontier_unfinished.append({**item, "depth": depth})
        if result["returncode"] != 0:
            self.warnings.append(
                f"one-pass gdu returned {result['returncode']}; localized inaccessible paths "
                "were excluded from accepted ancestor totals"
            )
        self._apply_inventory_partition(
            result["records"], result["error_paths"], manifest_items
        )
        self.observed = result["records"]
        self.inventory_backend = "gdu_one_pass"
        return True

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

    def measure_one(self, path, is_symlink=False):
        self.sem.acquire()
        try:
            if (GDU_CMD or DUA_CMD) and not is_symlink and self.timeout_tiers:
                remaining = self.remaining_budget()
                if remaining <= 0:
                    return None
                effective = min(
                    self.timeout_tiers[-1], DUA_TIMEOUT_CAP_SECONDS,
                    max(1, int(remaining)),
                )
                return run_du(path, effective, self.tracker)

            kb = None
            for tier in self.timeout_tiers:
                remaining = self.remaining_budget()
                if remaining <= 0:
                    break
                effective = min(tier, max(1, int(remaining)))
                kb = run_du(path, effective, self.tracker, is_symlink=is_symlink)
                if kb is not None:
                    break
            if kb is None and self.timeout_tiers:
                # second attempt at top tier before giving up on this node
                remaining = self.remaining_budget()
                if remaining > 0:
                    top = self.timeout_tiers[-1]
                    effective = min(top, max(1, int(remaining)))
                    kb = run_du(path, effective, self.tracker, is_symlink=is_symlink)
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
        except OSError as exc:
            self.frontier_unfinished.append(
                {
                    "path": path,
                    "depth": depth,
                    "reason": "lstat_failed",
                    "errno": exc.errno,
                }
            )
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
            kb = self.measure_one(path, is_symlink=True)
            if kb is not None:
                self.observed[path] = kb
                self.measured[path] = kb
            else:
                self.frontier_unfinished.append(
                    {"path": path, "depth": depth, "reason": "symlink_measure_failed"}
                )
            return

        # ponytail: a fixed shallow depth avoids spending the per-node timeout
        # on known namespace containers; deeper paths still use measured
        # subdivision, and this ceiling can become configurable if another
        # filesystem layout needs it.
        if (
            stat.S_ISDIR(st.st_mode)
            and depth <= self.shallow_enumeration_depth
            and depth < self.max_depth
        ):
            children, enumeration_error = list_children(path)
            if children is None:
                self.frontier_unfinished.append(
                    {
                        "path": path,
                        "depth": depth,
                        "reason": enumeration_error or "shallow_enumeration_failed",
                    }
                )
                return
            if children:
                return [
                    (child_path, depth + 1, child_symlink)
                    for child_path, child_symlink in children
                ]

        # Regular files are O(1) leaves: st_blocks reports allocated 512-byte
        # blocks, matching this tool's allocated-space accounting without a
        # subprocess that can starve under background I/O policy.
        if stat.S_ISDIR(st.st_mode):
            kb = self.measure_one(path)
        else:
            kb = (st.st_blocks * 512 + 1023) // 1024
        if kb is not None:
            self.observed[path] = kb
            if self.granularity_kb > 0 and kb > self.granularity_kb:
                if not stat.S_ISDIR(st.st_mode):
                    self.oversize_files.append(
                        {"path": path, "measured_kb": kb, "reason": "indivisible_file"}
                    )
                    self.measured[path] = kb
                    self.trie.add(path)
                    return
                granularity_reason = None
                if depth >= self.max_depth:
                    granularity_reason = "granularity_max_depth_reached"
                elif self.remaining_budget() <= 0:
                    granularity_reason = "granularity_time_budget_exhausted"
                else:
                    children, enumeration_error = list_children(path)
                    if children:
                        return [
                            (child_path, depth + 1, child_symlink)
                            for child_path, child_symlink in children
                        ]
                    if children is None:
                        granularity_reason = (
                            "granularity_" + (enumeration_error or "enumeration_failed")
                        )
                    else:
                        granularity_reason = "granularity_no_children"
                if granularity_reason:
                    self.frontier_unfinished.append(
                        {
                            "path": path,
                            "depth": depth,
                            "reason": granularity_reason,
                            "observed_kb": kb,
                        }
                    )
                    return
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

        children, enumeration_error = list_children(path)
        if children is None:
            self.frontier_unfinished.append(
                {
                    "path": path,
                    "depth": depth,
                    "reason": enumeration_error or "unreadable_after_timeout",
                }
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

        level1, root_enumeration_error = list_children(self.root)
        if level1 is None:
            return {
                "error": f"could not enumerate root: {self.root}",
                "reason": root_enumeration_error,
            }
        self.level1_paths = [path for path, _ in level1]

        if GDU_CMD and self.granularity_kb > 0 and self.run_one_pass_inventory(level1):
            return None

        frontier = []
        sequence = 0

        def enqueue(item):
            nonlocal sequence
            sequence += 1
            heapq.heappush(
                frontier,
                (frontier_sort_key(self.root, item), sequence, item),
            )

        for path, is_sym in level1:
            enqueue((path, 1, is_sym))

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=max(self.workers_cap, 1)
        ) as pool:
            in_flight = {}
            stop_scheduling = False
            while frontier or in_flight:
                if self.elapsed() > self.wall_clock_cap and not stop_scheduling:
                    stop_scheduling = True
                    while frontier:
                        _, _, (path, depth, _) = heapq.heappop(frontier)
                        self.frontier_unfinished.append(
                            {"path": path, "depth": depth, "reason": "time_budget_exhausted"}
                        )

                if not stop_scheduling:
                    self.maybe_throttle()
                    while frontier and len(in_flight) < max(self.workers_cap, 1):
                        _, _, item = heapq.heappop(frontier)
                        path, depth, is_sym = item
                        in_flight[pool.submit(
                            self.process_node, path, depth, is_sym
                        )] = item

                if not in_flight:
                    break

                done, _ = concurrent.futures.wait(
                    in_flight,
                    return_when=concurrent.futures.FIRST_COMPLETED,
                )
                for fut in done:
                    path, _, _ = in_flight.pop(fut)
                    try:
                        result = fut.result()
                    except Exception as exc:  # noqa: BLE001 - never crash the scan
                        self.warnings.append(f"worker exception for {path}: {exc}")
                        self.frontier_unfinished.append(
                            {
                                "path": path,
                                "reason": "worker_exception",
                            }
                        )
                        continue
                    if result:
                        if stop_scheduling or self.elapsed() > self.wall_clock_cap:
                            stop_scheduling = True
                            for child_path, child_depth, _ in result:
                                self.frontier_unfinished.append(
                                    {
                                        "path": child_path,
                                        "depth": child_depth,
                                        "reason": "time_budget_exhausted",
                                    }
                                )
                        else:
                            for item in result:
                                enqueue(item)

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


def build_report(
    scanner, disk_stats, sibling_volumes, purgeable_info, elapsed_s, args,
    apfs_accounting=None, disk_stats_before=None,
):
    disk_stats_before = disk_stats_before or disk_stats
    measured_total_kb = sum(scanner.measured.values())
    residual_raw_kb = disk_stats["used_kb"] - measured_total_kb - purgeable_info["purgeable_kb"]
    residual_negative_clamped = residual_raw_kb < 0
    residual_kb = max(0, residual_raw_kb)
    used_before_kb = disk_stats_before["used_kb"]
    used_after_kb = disk_stats["used_kb"]
    residual_interval_kb = {
        "min": max(
            0,
            min(used_before_kb, used_after_kb)
            - measured_total_kb
            - purgeable_info["purgeable_kb"],
        ),
        "max": max(
            0,
            max(used_before_kb, used_after_kb)
            - measured_total_kb
            - purgeable_info["purgeable_kb"],
        ),
    }

    mode = "complete" if not scanner.frontier_unfinished else "partial"

    measured_by_top = collections.defaultdict(int)
    exact_measured = {}
    unfinished_by_top = collections.defaultdict(list)
    deduped_top = set()

    def top_child(path):
        try:
            rel = os.path.relpath(os.path.realpath(path), os.path.realpath(scanner.root))
        except (OSError, ValueError):
            return None, None
        if rel == os.pardir or rel.startswith(os.pardir + os.sep):
            return None, None
        first = rel.split(os.sep, 1)[0]
        return os.path.join(os.path.realpath(scanner.root), first), rel

    for path, kb in scanner.measured.items():
        top, rel = top_child(path)
        if top is None:
            continue
        measured_by_top[top] += kb
        if os.sep not in rel:
            exact_measured[top] = kb
    for item in scanner.frontier_unfinished:
        top, _ = top_child(item.get("path", ""))
        if top is not None:
            unfinished_by_top[top].append(item.get("reason") or "unfinished")
    for item in scanner.deduped:
        top, _ = top_child(item.get("path", ""))
        if top is not None:
            deduped_top.add(top)

    top_level_ledger = []
    for original_path in sorted(scanner.level1_paths):
        path = os.path.realpath(original_path)
        reasons = sorted(set(unfinished_by_top[path]))
        if path in exact_measured and not reasons:
            status, size_kb = "measured", exact_measured[path]
        elif measured_by_top[path]:
            status = "partial" if reasons else "measured_by_descendants"
            size_kb = measured_by_top[path]
        elif path in deduped_top and not reasons:
            status, size_kb = "deduped", None
        else:
            status, size_kb = "unfinished", None
            if not reasons:
                reasons = ["scanner_did_not_report"]
        top_level_ledger.append(
            {
                "path": path,
                "status": status,
                "measured_kb": size_kb,
                "unfinished_reasons": reasons,
            }
        )

    status_counts = collections.Counter(item["status"] for item in top_level_ledger)

    granularity_kb = int(args.granularity_gib * 1024 * 1024)
    inventory_buckets = getattr(scanner, "inventory_buckets", None)
    granularity_buckets = (
        inventory_buckets
        if inventory_buckets is not None
        else build_granularity_buckets(scanner.measured, scanner.root, granularity_kb)
    )
    granularity_bucket_total_kb = sum(
        item["measured_kb"] for item in granularity_buckets
    )
    oversize_files = sorted(
        getattr(scanner, "oversize_files", []),
        key=lambda item: (-item["measured_kb"], item["path"]),
    )
    oversize_files_total_kb = sum(item["measured_kb"] for item in oversize_files)
    granularity_tail_kb = (
        measured_total_kb - granularity_bucket_total_kb - oversize_files_total_kb
    )

    accounting_equation = {
        "data_used_kb": disk_stats["used_kb"],
        "measured_kb": measured_total_kb,
        "purgeable_kb": purgeable_info["purgeable_kb"],
        "residual_kb": residual_kb,
        "balanced": (
            measured_total_kb + purgeable_info["purgeable_kb"] + residual_kb
            == disk_stats["used_kb"]
        ),
        "displayed_buckets_kb": granularity_bucket_total_kb,
        "oversize_indivisible_files_kb": oversize_files_total_kb,
        "sub_granularity_tail_kb": granularity_tail_kb,
        "displayed_balanced": (
            granularity_bucket_total_kb
            + oversize_files_total_kb
            + granularity_tail_kb
            + purgeable_info["purgeable_kb"]
            + residual_kb
            == disk_stats["used_kb"]
        ),
        "measurement_non_atomic": used_before_kb != used_after_kb,
        "residual_label": "protected_or_apfs_allocation_not_attributable_by_this_session",
        "residual_reclaimable": False,
    }
    reasons = collections.defaultdict(list)
    for item in scanner.frontier_unfinished:
        reasons[item.get("reason") or "unknown"].append(item.get("path"))
    limits = {
        "sudo_used": False,
        "full_disk_access": "not_inferred",
        "permission_denied_or_tcc": reasons.get("permission_denied_or_tcc", []),
        "time_budget_exhausted": reasons.get("time_budget_exhausted", []),
        "node_budget_exhausted": reasons.get("node_budget_exhausted", []),
        "cross_device_boundary": reasons.get("cross_device_boundary", []),
        "max_depth_reached": reasons.get("max_depth_reached", []),
        "granularity": [
            {"reason": reason, "paths": paths}
            for reason, paths in sorted(reasons.items())
            if reason.startswith("granularity_")
        ],
    }

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
            "granularity_gib": args.granularity_gib,
            "max_bucket_gib": args.granularity_gib,
            "shallow_enumeration_depth": getattr(scanner, "shallow_enumeration_depth", 0),
            "scan_backend": getattr(scanner, "inventory_backend", None) or "frontier_per_node",
        },
        "disk_total_kb": disk_stats["total_kb"],
        "disk_used_kb": disk_stats["used_kb"],
        "disk_free_kb": disk_stats["free_kb"],
        "measurement_window": {
            "disk_used_before_kb": used_before_kb,
            "disk_used_after_kb": used_after_kb,
            "disk_used_delta_kb": used_after_kb - used_before_kb,
            "non_atomic": used_before_kb != used_after_kb,
            "residual_interval_kb": residual_interval_kb,
        },
        "measured": scanner.measured,
        "measured_total_kb": measured_total_kb,
        "granularity_buckets": granularity_buckets,
        "granularity_bucket_total_kb": granularity_bucket_total_kb,
        "granularity_tail_kb": granularity_tail_kb,
        "oversize_indivisible_files": oversize_files,
        "oversize_indivisible_files_total_kb": oversize_files_total_kb,
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
        "accounting_equation": accounting_equation,
        "apfs_accounting": apfs_accounting or {},
        "limits": limits,
        "nodes_processed": scanner.nodes_processed,
        "max_concurrent_du_observed": scanner.tracker.peak(),
        "warnings": scanner.warnings,
        "top_level_children_total": len(top_level_ledger),
        "top_level_children_accounted": len(top_level_ledger),
        "top_level_status_counts": dict(sorted(status_counts.items())),
        "top_level_ledger": top_level_ledger,
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
    p.add_argument(
        "--shallow-enumeration-depth", type=int, default=None,
        help="enumerate directories through this depth before measuring them; "
             "defaults to 2 for the Data-volume root and 0 for custom roots",
    )
    p.add_argument(
        "--granularity-gib", type=float, default=0.0,
        help="maximum size of each non-overlapping displayed path bucket; "
             "larger directories are subdivided and larger indivisible files "
             "are reported separately (0 disables)",
    )
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
    if args.shallow_enumeration_depth is None:
        args.shallow_enumeration_depth = (
            SHALLOW_ENUMERATION_MAX_DEPTH if args.root == DEFAULT_ROOT else 0
        )
    args.timeout_tiers = [int(x) for x in args.timeout_tiers.split(",") if x.strip()]
    if not args.timeout_tiers:
        args.timeout_tiers = list(DEFAULT_TIMEOUT_TIERS)
    return args


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])

    disk_stats_before = get_disk_stats(args.root)
    scanner = FrontierScanner(args)
    err = scanner.run()
    elapsed_s = scanner.elapsed()

    if err:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "tool": "disk_frontier_scan", **err}))
        return 1

    disk_stats = get_disk_stats(args.root)
    if args.disk_used_kb_override is not None:
        disk_stats_before["used_kb"] = args.disk_used_kb_override
        disk_stats["used_kb"] = args.disk_used_kb_override

    sibling_volumes = {}
    apfs_accounting = {}
    if not args.no_sibling_volumes:
        sibling_volumes = get_sibling_volumes(
            args.root, scanner.warnings, apfs_accounting
        )

    purgeable_info = {
        "purgeable_kb": 0,
        "purgeable_estimate_method": "skipped (--no-purgeable)",
        "local_snapshots": [],
        "local_snapshots_count": 0,
    }
    if not args.no_purgeable:
        purgeable_info = get_purgeable_info(args.root, scanner.warnings)

    report = build_report(
        scanner, disk_stats, sibling_volumes, purgeable_info, elapsed_s, args,
        apfs_accounting=apfs_accounting,
        disk_stats_before=disk_stats_before,
    )

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

#!/usr/bin/env python3
"""prune_aside_sessions.py — Prune stale Aside browser sessions and deduplicate static assets.

Safety and retention tool for ~/.aside/u/*/sessions/ (bead disk_magician-18q):
  - Two-signal clearability:
    * Signal A: Session folder age >= max_age_days (via YYYY-MM-DD prefix or mtime).
    * Signal B: lsof +D <session_path> confirms no active browser/aside processes hold open handles.
  - Reclaims disk space by pruning stale session directories.
  - Reclaims disk space by hardlinking duplicate static assets across retained sessions.
  - Fails closed on any lsof error or active lock.

Defaults to dry-run (pass --clean or --apply to execute).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

DEFAULT_MAX_AGE_DAYS = 7
DEFAULT_MIN_DEDUP_SIZE = 1024  # 1 KB
DATE_PREFIX_REGEX = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:_.*)?$")


def format_size(bytes_val: int) -> str:
    """Format byte count into human-readable string."""
    v = float(bytes_val)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if v < 1024.0 or unit == "TB":
            return f"{v:.2f} {unit}"
        v /= 1024.0
    return f"{v:.2f} TB"


def get_dir_size(dir_path: Path) -> int:
    """Return total bytes of all files in dir_path."""
    total = 0
    try:
        for root, _, files in os.walk(dir_path):
            for f in files:
                try:
                    total += (Path(root) / f).stat().st_size
                except OSError:
                    continue
    except OSError:
        pass
    return total


def get_dir_max_mtime(dir_path: Path) -> float:
    """Return the most recent mtime of any file inside dir_path, or dir mtime."""
    max_mtime = 0.0
    try:
        max_mtime = dir_path.stat().st_mtime
    except OSError:
        return 0.0

    try:
        for root, _, files in os.walk(dir_path):
            for f in files:
                try:
                    mt = (Path(root) / f).stat().st_mtime
                    if mt > max_mtime:
                        max_mtime = mt
                except OSError:
                    continue
    except OSError:
        pass
    return max_mtime


def parse_session_age_days(session_dir: Path, ref_time: Optional[float] = None) -> Tuple[float, str]:
    """Determine session age in days and the method used ('date_prefix' or 'mtime')."""
    now = ref_time if ref_time is not None else time.time()
    name = session_dir.name
    m = DATE_PREFIX_REGEX.match(name)
    if m:
        date_str = m.group(1)
        try:
            dt = datetime.datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
            session_epoch = dt.timestamp()
            age_days = (now - session_epoch) / 86400.0
            if age_days >= 0:
                return age_days, "date_prefix"
        except (ValueError, OverflowError):
            pass

    # Fallback to mtime
    max_mtime = get_dir_max_mtime(session_dir)
    if max_mtime <= 0.0:
        return 0.0, "unknown"
    age_days = max(0.0, (now - max_mtime) / 86400.0)
    return age_days, "mtime"


def get_open_session_paths(container: Path, lsof_bin: Optional[str] = None) -> Tuple[bool, Set[Path]]:
    """Query open file descriptors under a sessions container using a single batch lsof call.

    Returns:
        (is_valid, open_paths):
          is_valid=True: lsof completed normally; open_paths contains session directories with open handles.
          is_valid=False: lsof failed/timed out (FAIL CLOSED -> caller must treat ALL sessions as in-use).
    """
    bin_path = lsof_bin or os.environ.get("DISK_MAGICIAN_LSOF_BIN")
    if not bin_path:
        if os.path.exists("/usr/sbin/lsof") and os.access("/usr/sbin/lsof", os.X_OK):
            bin_path = "/usr/sbin/lsof"
        else:
            bin_path = shutil.which("lsof")

    if not bin_path:
        return False, set()

    try:
        res = subprocess.run(
            [bin_path, "+w", "+D", str(container)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
        # rc=1 with empty stdout is lsof's standard 'no matches' result -- but
        # only when stderr is also empty. +w turns lsof's warnings ON (not
        # off -- see `lsof -h`'s "+|-w Warnings (+)"; the run below deliberately
        # asks for them), so any stderr content on rc=1 is a genuine anomaly,
        # not the normal no-matches case; fail closed on it instead of
        # treating it as "confirmed no open files" (found in /advice review
        # of PR #59). This check must cover EVERY rc=1 path, not just the
        # stdout-empty fast path below it -- a first round of this fix only
        # gated the fast path, so rc=1 + empty stdout + non-empty stderr fell
        # through the "returncode not in (0, 1)" check (1 IS in that set)
        # straight into the stdout-parsing loop, which found nothing in the
        # (empty) stdout and returned the same unsafe "confirmed no open
        # files" result the fast-path guard was meant to prevent.
        if res.returncode == 1 and res.stderr.strip():
            return False, set()

        if res.returncode == 1 and not res.stdout.strip():
            return True, set()

        if res.returncode not in (0, 1):
            return False, set()

        open_dirs: Set[Path] = set()
        container_resolved = container.resolve()
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("COMMAND"):
                continue
            parts = line.split(None, 8)
            if len(parts) >= 9:
                file_path_str = parts[8]
                try:
                    fpath = Path(file_path_str).resolve()
                    # Find which direct child of container this belongs to
                    rel = fpath.relative_to(container_resolved)
                    if rel.parts:
                        top_child = container_resolved / rel.parts[0]
                        open_dirs.add(top_child)
                except (ValueError, OSError):
                    pass

        return True, open_dirs
    except (subprocess.SubprocessError, OSError):
        return False, set()


def check_open_files(session_dir: Path, lsof_bin: Optional[str] = None) -> bool:
    """Check if any active process holds open file descriptors in session_dir.

    Returns:
        True: Files are open or lsof failed (FAIL CLOSED -> treat as active/in-use).
        False: Verified no active handles (safe to prune).
    """
    bin_path = lsof_bin or os.environ.get("DISK_MAGICIAN_LSOF_BIN")
    if not bin_path:
        if os.path.exists("/usr/sbin/lsof") and os.access("/usr/sbin/lsof", os.X_OK):
            bin_path = "/usr/sbin/lsof"
        else:
            bin_path = shutil.which("lsof")

    if not bin_path:
        # lsof unavailable -> fail closed
        return True

    try:
        # +w turns lsof's warnings ON (not off -- see `lsof -h`'s
        # "+|-w Warnings (+)"); +D causes lsof to search directory recursively.
        res = subprocess.run(
            [bin_path, "+w", "+D", str(session_dir)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        if res.stdout.strip():
            return True
        # rc=0 or rc=1 with empty stdout means no open files found -- but
        # only when stderr is also empty. Any stderr content here is a
        # genuine anomaly (warnings are deliberately requested via +w above),
        # not the normal case; fail closed on it (/advice review of PR #59).
        if res.returncode in (0, 1) and not res.stderr.strip():
            return False
        # Any other returncode or diagnostic output is treated as in-use (fail-closed)
        return True
    except (subprocess.SubprocessError, OSError):
        # Fail closed on timeout, execution error, or missing permission
        return True


def hash_file_sha256(file_path: Path, block_size: int = 65536) -> Optional[str]:
    """Compute SHA256 checksum for a file."""
    h = hashlib.sha256()
    try:
        with open(file_path, "rb") as f:
            while True:
                buf = f.read(block_size)
                if not buf:
                    break
                h.update(buf)
        return h.hexdigest()
    except OSError:
        return None


class AsideSessionPruner:
    """Prune stale Aside browser sessions and deduplicate static assets."""

    def __init__(
        self,
        aside_dir: Optional[Path] = None,
        sessions_dirs: Optional[List[Path]] = None,
        max_age_days: int = DEFAULT_MAX_AGE_DAYS,
        dry_run: bool = True,
        dedup_assets: bool = True,
        min_dedup_size: int = DEFAULT_MIN_DEDUP_SIZE,
        lsof_bin: Optional[str] = None,
        ref_time: Optional[float] = None,
        verbose: bool = False,
    ):
        self.aside_dir = Path(aside_dir).expanduser().resolve() if aside_dir else (Path.home() / ".aside").resolve()
        self.sessions_dirs = [Path(d).expanduser().resolve() for d in sessions_dirs] if sessions_dirs else []
        self.max_age_days = max_age_days
        self.dry_run = dry_run
        self.dedup_assets = dedup_assets
        self.min_dedup_size = min_dedup_size
        self.lsof_bin = lsof_bin
        self.ref_time = ref_time if ref_time is not None else time.time()
        self.verbose = verbose

        self.stats = {
            "sessions_scanned": 0,
            "sessions_retained_recent": 0,
            "sessions_retained_in_use": 0,
            "sessions_pruned": 0,
            "bytes_pruned": 0,
            "assets_scanned": 0,
            "assets_deduped": 0,
            "bytes_deduped": 0,
        }

    def discover_session_containers(self) -> List[Path]:
        """Find all sessions directories (e.g. ~/.aside/u/0/sessions, ~/.aside/u/1/sessions)."""
        if self.sessions_dirs:
            return [d for d in self.sessions_dirs if d.is_dir()]

        containers = []
        u_dir = self.aside_dir / "u"
        if u_dir.is_dir():
            for child in sorted(u_dir.iterdir()):
                if child.is_dir():
                    s_dir = child / "sessions"
                    if s_dir.is_dir():
                        containers.append(s_dir)

        # Also check top-level sessions if any
        top_sessions = self.aside_dir / "sessions"
        if top_sessions.is_dir() and top_sessions not in containers:
            containers.append(top_sessions)

        return containers

    def is_safe_session_path(self, session_dir: Path, container: Path) -> bool:
        """Safety validation: path must be a direct child directory of the sessions container."""
        try:
            session_res = session_dir.resolve()
            container_res = container.resolve()
            if session_res.parent != container_res:
                return False
            if not session_res.is_dir():
                return False
            # Never delete root or critical directories
            if str(session_res) in ("/", str(Path.home()), str(self.aside_dir), str(container_res)):
                return False
            return True
        except OSError:
            return False

    def dedup_static_assets(self, candidate_dirs: List[Path]) -> None:
        """Deduplicate identical static assets across candidate sessions using hardlinks."""
        size_map: Dict[int, List[Path]] = {}
        inode_seen: Dict[Tuple[int, int], Path] = {}  # (dev, ino) -> first Path

        for sdir in candidate_dirs:
            if not sdir.is_dir():
                continue
            for root, _, files in os.walk(sdir):
                for f in files:
                    fpath = Path(root) / f
                    try:
                        st = fpath.stat()
                        # Only regular files >= min_dedup_size
                        if not fpath.is_file() or fpath.is_symlink():
                            continue
                        if st.st_size < self.min_dedup_size:
                            continue

                        self.stats["assets_scanned"] += 1
                        file_key = (st.st_dev, st.st_ino)
                        if file_key in inode_seen:
                            # Already sharing inode
                            continue
                        inode_seen[file_key] = fpath

                        size_map.setdefault(st.st_size, []).append(fpath)
                    except OSError:
                        continue

        # Only hash files where at least 2 files share the exact same size
        file_map: Dict[Tuple[int, str], List[Path]] = {}
        for size, paths in size_map.items():
            if len(paths) <= 1:
                continue
            for fpath in paths:
                digest = hash_file_sha256(fpath)
                if digest:
                    file_map.setdefault((size, digest), []).append(fpath)

        # Process duplicates
        for (size, digest), paths in file_map.items():
            if len(paths) <= 1:
                continue

            primary = paths[0]
            try:
                primary_stat = primary.stat()
                primary_dev = primary_stat.st_dev
                primary_ino = primary_stat.st_ino
            except OSError:
                continue

            for dup in paths[1:]:
                try:
                    dup_stat = dup.stat()
                    # If already hardlinked, skip
                    if dup_stat.st_dev == primary_dev and dup_stat.st_ino == primary_ino:
                        continue
                    # Cross-device cannot hardlink
                    if dup_stat.st_dev != primary_dev:
                        continue

                    self.stats["assets_deduped"] += 1
                    self.stats["bytes_deduped"] += size

                    if self.dry_run:
                        if self.verbose:
                            print(f"[DRY-RUN] Would hardlink duplicate asset: {dup} -> {primary} ({format_size(size)})")
                    else:
                        # Atomic replace via temp hardlink
                        tmp_link = dup.with_name(f".tmp_dedup_{os.getpid()}_{time.time_ns()}")
                        try:
                            os.link(primary, tmp_link)
                            os.replace(tmp_link, dup)
                            if self.verbose:
                                print(f"Hardlinked duplicate asset: {dup} -> {primary} ({format_size(size)})")
                        finally:
                            if tmp_link.exists():
                                try:
                                    tmp_link.unlink()
                                except OSError:
                                    pass
                except OSError as exc:
                    if self.verbose:
                        print(f"Warning: Failed to dedup {dup}: {exc}", file=sys.stderr)

    def run(self) -> Dict[str, any]:
        """Execute pruning and deduplication."""
        containers = self.discover_session_containers()
        if not containers:
            if self.verbose:
                print(f"No Aside sessions containers found in {self.aside_dir}.")
            return self.stats

        stale_candidates: List[Tuple[Path, Path, float, int]] = []
        retained_dirs: List[Path] = []

        for container in containers:
            try:
                entries = sorted(container.iterdir())
            except OSError as exc:
                if self.verbose:
                    print(f"Cannot read container {container}: {exc}", file=sys.stderr)
                continue

            # Batch check open files for container
            lsof_valid, open_session_paths = get_open_session_paths(container, self.lsof_bin)

            for entry in entries:
                if not entry.is_dir():
                    continue

                self.stats["sessions_scanned"] += 1
                age_days, method = parse_session_age_days(entry, self.ref_time)

                # Signal A: Age check
                if age_days < self.max_age_days:
                    self.stats["sessions_retained_recent"] += 1
                    retained_dirs.append(entry)
                    if self.verbose:
                        print(f"Retaining recent session: {entry.name} ({age_days:.1f}d < {self.max_age_days}d)")
                    continue

                # Signal B: Active handle / process check
                is_in_use = False
                if not lsof_valid:
                    # If batch lsof failed, fall back to per-session check (fail-closed)
                    is_in_use = check_open_files(entry, self.lsof_bin)
                elif entry.resolve() in open_session_paths:
                    is_in_use = True

                if is_in_use:
                    self.stats["sessions_retained_in_use"] += 1
                    retained_dirs.append(entry)
                    if self.verbose:
                        print(f"Retaining in-use session (open files/lsof active): {entry.name}")
                    continue

                # Safety validation
                if not self.is_safe_session_path(entry, container):
                    self.stats["sessions_retained_in_use"] += 1
                    retained_dirs.append(entry)
                    if self.verbose:
                        print(f"Safety guard: path rejected for deletion: {entry}")
                    continue

                size = get_dir_size(entry)
                stale_candidates.append((entry, container, age_days, size))

        # Execute Session Pruning
        for session_dir, container, age_days, size in stale_candidates:
            self.stats["sessions_pruned"] += 1
            self.stats["bytes_pruned"] += size

            if self.dry_run:
                print(f"[DRY-RUN] Would prune stale session: {session_dir} ({format_size(size)}, {age_days:.1f} days old)")
            else:
                try:
                    shutil.rmtree(session_dir)
                    print(f"Pruned stale session: {session_dir} ({format_size(size)}, {age_days:.1f} days old)")
                except OSError as exc:
                    print(f"Error removing {session_dir}: {exc}", file=sys.stderr)
                    # Revert stats for failed removal
                    self.stats["sessions_pruned"] -= 1
                    self.stats["bytes_pruned"] -= size
                    retained_dirs.append(session_dir)

        # Execute Deduplication on Retained Sessions (if enabled)
        if self.dedup_assets and retained_dirs:
            self.dedup_static_assets(retained_dirs)

        return self.stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prune stale Aside browser sessions and deduplicate static assets."
    )
    parser.add_argument(
        "--clean", "--apply",
        dest="clean",
        action="store_true",
        help="Actually delete stale sessions and deduplicate assets (default: dry-run).",
    )
    parser.add_argument(
        "--dry-run",
        dest="clean",
        action="store_false",
        help="Run in preview mode without deleting or modifying files (default).",
    )
    parser.set_defaults(clean=False)
    parser.add_argument(
        "--max-age-days", "--days",
        dest="max_age_days",
        type=int,
        default=DEFAULT_MAX_AGE_DAYS,
        help=f"Age threshold in days for session pruning (default: {DEFAULT_MAX_AGE_DAYS}).",
    )
    parser.add_argument(
        "--aside-dir",
        type=str,
        default=None,
        help="Override path to ~/.aside directory.",
    )
    parser.add_argument(
        "--sessions-dir",
        action="append",
        dest="sessions_dirs",
        type=str,
        default=None,
        help="Override path to specific sessions directory (repeatable).",
    )
    parser.add_argument(
        "--no-dedup",
        dest="dedup_assets",
        action="store_false",
        default=True,
        help="Disable static asset deduplication across retained sessions.",
    )
    parser.add_argument(
        "--min-dedup-size",
        type=int,
        default=DEFAULT_MIN_DEDUP_SIZE,
        help=f"Minimum file size in bytes to consider for deduplication (default: {DEFAULT_MIN_DEDUP_SIZE}).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output summary statistics as JSON.",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose per-session logging.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    mode_str = "CLEAN / APPLY" if args.clean else "DRY-RUN"
    if not args.json:
        print(f"=== Aside Browser Session Pruner [{mode_str}] ===")
        print(f"Max Age Threshold: {args.max_age_days} days")
        print(f"Asset Deduplication: {'Enabled' if args.dedup_assets else 'Disabled'}")
        print()

    pruner = AsideSessionPruner(
        aside_dir=Path(args.aside_dir) if args.aside_dir else None,
        sessions_dirs=[Path(p) for p in args.sessions_dirs] if args.sessions_dirs else None,
        max_age_days=args.max_age_days,
        dry_run=not args.clean,
        dedup_assets=args.dedup_assets,
        min_dedup_size=args.min_dedup_size,
        verbose=args.verbose,
    )

    stats = pruner.run()

    if args.json:
        print(json.dumps(stats, indent=2))
    else:
        print()
        print("=== Summary ===")
        print(f"Sessions Scanned:          {stats['sessions_scanned']}")
        print(f"Recent Sessions Retained:  {stats['sessions_retained_recent']}")
        print(f"In-Use Sessions Retained:  {stats['sessions_retained_in_use']}")
        print(f"Stale Sessions Pruned:     {stats['sessions_pruned']}")
        print(f"Space Freed (Pruned):      {format_size(stats['bytes_pruned'])}")
        if args.dedup_assets:
            print(f"Assets Scanned:            {stats['assets_scanned']}")
            print(f"Duplicate Assets Deduped:  {stats['assets_deduped']}")
            print(f"Space Saved (Dedup):       {format_size(stats['bytes_deduped'])}")
        total_freed = stats["bytes_pruned"] + stats["bytes_deduped"]
        prefix = "Would Reclaim" if not args.clean else "Total Reclaimed"
        print(f"{prefix}:             {format_size(total_freed)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

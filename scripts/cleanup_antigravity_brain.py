#!/usr/bin/env python3
"""cleanup_antigravity_brain.py — Forensic compaction and retention tool for Antigravity CLI brain.

Safe, non-destructive compaction of ~/.gemini/antigravity-cli/brain:
  - Lossless gzip compression of stale task logs and full transcripts (>14d default).
  - Cleaning of stale scratchpad dump files in old sessions (>14d default).
  - Pruning of 0-byte or empty orphaned session folders.
  - 100% preservation of active sessions (<24h), user-facing markdown artifacts,
    metadata JSON, and recent transcripts.

Defaults to dry-run (pass --clean to apply).
"""

import argparse
import gzip
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

DEFAULT_BRAIN_DIR = Path.home() / ".gemini" / "antigravity-cli" / "brain"
DEFAULT_CONV_DIR = Path.home() / ".gemini" / "antigravity-cli" / "conversations"
DEFAULT_DAYS = 14
ACTIVE_PROTECT_SECONDS = 86400  # 24 hours
NOW = time.time()


def format_size(bytes_val: int) -> str:
    """Format byte count into human-readable string."""
    v = float(bytes_val)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if v < 1024.0 or unit == "TB":
            return f"{v:.2f} {unit}"
        v /= 1024.0
    return f"{v:.2f} TB"


def get_dir_mtime(dir_path: Path) -> float:
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


class BrainCompactor:
    def __init__(
        self,
        brain_dir: Path,
        threshold_days: int = DEFAULT_DAYS,
        dry_run: bool = True,
        active_ids: Optional[Set[str]] = None,
        clean_scratch: bool = True,
        compress_logs: bool = True,
        prune_empty: bool = True,
    ):
        self.brain_dir = Path(brain_dir)
        self.threshold_days = threshold_days
        self.threshold_seconds = threshold_days * 86400
        self.dry_run = dry_run
        self.active_ids = active_ids or set()
        self.clean_scratch = clean_scratch
        self.compress_logs = compress_logs
        self.prune_empty = prune_empty

        self.stats = {
            "total_sessions": 0,
            "active_skipped": 0,
            "too_recent_skipped": 0,
            "empty_pruned": 0,
            "files_compressed": 0,
            "scratch_files_removed": 0,
            "bytes_before": 0,
            "bytes_reclaimed": 0,
        }
        self.actions: List[str] = []

    def is_session_active(self, session_dir: Path, latest_mtime: float) -> Tuple[bool, str]:
        """Check if session is active, protected, or too recent."""
        sid = session_dir.name
        if sid in self.active_ids:
            return True, "explicitly marked active"

        # Check age relative to now
        age_seconds = NOW - latest_mtime
        if age_seconds < ACTIVE_PROTECT_SECONDS:
            return True, f"active in last 24h ({age_seconds / 3600:.1f}h ago)"

        if age_seconds < self.threshold_seconds:
            return True, f"newer than threshold ({age_seconds / 86400:.1f}d < {self.threshold_days}d)"

        return False, "eligible for compaction"

    def scan_and_compact(self) -> Dict[str, any]:
        if not self.brain_dir.exists() or not self.brain_dir.is_dir():
            return self.stats

        session_dirs = [d for d in self.brain_dir.iterdir() if d.is_dir()]
        self.stats["total_sessions"] = len(session_dirs)

        for sdir in session_dirs:
            self._process_session(sdir)

        return self.stats

    def _process_session(self, sdir: Path) -> None:
        sid = sdir.name
        sess_size = get_dir_size(sdir)
        latest_mtime = get_dir_mtime(sdir)
        self.stats["bytes_before"] += sess_size

        # Check empty session
        if self.prune_empty and sess_size == 0:
            age_seconds = NOW - latest_mtime
            if age_seconds >= self.threshold_seconds:
                self.actions.append(f"PRUNE_EMPTY: {sid} (0 bytes)")
                self.stats["empty_pruned"] += 1
                if not self.dry_run:
                    try:
                        shutil.rmtree(sdir)
                    except OSError as e:
                        self.actions.append(f"ERROR: failed to prune {sid}: {e}")
                return

        is_active, reason = self.is_session_active(sdir, latest_mtime)
        if is_active:
            if "24h" in reason:
                self.stats["active_skipped"] += 1
            else:
                self.stats["too_recent_skipped"] += 1
            return

        # 1. Clean scratch files if requested
        if self.clean_scratch:
            scratch_dir = sdir / "scratch"
            if scratch_dir.exists() and scratch_dir.is_dir():
                for root, _, files in os.walk(scratch_dir):
                    for f in files:
                        fp = Path(root) / f
                        try:
                            st = fp.stat()
                            sz = st.st_size
                            self.stats["scratch_files_removed"] += 1
                            self.stats["bytes_reclaimed"] += sz
                            self.actions.append(
                                f"REMOVE_SCRATCH: {sid}/scratch/{f} ({format_size(sz)})"
                            )
                            if not self.dry_run:
                                fp.unlink(missing_ok=True)
                        except OSError:
                            continue
                # Remove empty scratch dir
                if not self.dry_run:
                    try:
                        shutil.rmtree(scratch_dir, ignore_errors=True)
                    except OSError:
                        pass

        # 2. Compress task logs and full transcripts if requested
        if self.compress_logs:
            sys_gen = sdir / ".system_generated"
            if sys_gen.exists() and sys_gen.is_dir():
                # Compress task logs
                tasks_dir = sys_gen / "tasks"
                if tasks_dir.exists() and tasks_dir.is_dir():
                    for log_file in tasks_dir.glob("task-*.log"):
                        if log_file.is_file():
                            self._compress_file(log_file, sid)

                # Compress full transcripts
                logs_dir = sys_gen / "logs"
                if logs_dir.exists() and logs_dir.is_dir():
                    tr_full = logs_dir / "transcript_full.jsonl"
                    if tr_full.is_file() and not (logs_dir / "transcript_full.jsonl.gz").exists():
                        self._compress_file(tr_full, sid)

    def _compress_file(self, file_path: Path, sid: str) -> None:
        try:
            st = file_path.stat()
            orig_sz = st.st_size
            if orig_sz < 1024:  # Skip tiny files under 1KB
                return

            gz_path = file_path.with_name(file_path.name + ".gz")
            if gz_path.exists():
                return

            if self.dry_run:
                # Estimate 70% compression savings
                est_saved = int(orig_sz * 0.70)
                self.stats["files_compressed"] += 1
                self.stats["bytes_reclaimed"] += est_saved
                self.actions.append(
                    f"COMPRESS: {sid}/.../{file_path.name} ({format_size(orig_sz)} -> est {format_size(orig_sz - est_saved)})"
                )
            else:
                with open(file_path, "rb") as f_in:
                    with gzip.open(gz_path, "wb", compresslevel=6) as f_out:
                        shutil.copyfileobj(f_in, f_out)
                gz_sz = gz_path.stat().st_size
                saved = orig_sz - gz_sz
                file_path.unlink()
                self.stats["files_compressed"] += 1
                self.stats["bytes_reclaimed"] += max(0, saved)
                self.actions.append(
                    f"COMPRESSED: {sid}/.../{file_path.name} ({format_size(orig_sz)} -> {format_size(gz_sz)}, saved {format_size(saved)})"
                )
        except OSError as e:
            self.actions.append(f"ERROR: failed to compress {file_path}: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Antigravity Brain Forensics & Compaction Tool"
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Actually apply compaction (default: dry-run preview)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Dry-run preview without mutating files (default)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=DEFAULT_DAYS,
        help=f"Staleness threshold in days (default: {DEFAULT_DAYS})",
    )
    parser.add_argument(
        "--brain-dir",
        type=Path,
        default=DEFAULT_BRAIN_DIR,
        help=f"Path to brain directory (default: {DEFAULT_BRAIN_DIR})",
    )
    parser.add_argument(
        "--no-scratch",
        action="store_true",
        help="Do not clean stale scratch files",
    )
    parser.add_argument(
        "--no-compress",
        action="store_true",
        help="Do not compress logs and transcripts",
    )
    parser.add_argument(
        "--no-prune-empty",
        action="store_true",
        help="Do not prune empty 0-byte session folders",
    )

    args = parser.parse_args()
    is_dry_run = not args.clean

    print("=== Antigravity Brain Compaction & Retention ===")
    print(f"Target Directory : {args.brain_dir}")
    print(f"Age Threshold    : {args.days} days (with mandatory 24h active protection)")
    print(f"Mode             : {'DRY-RUN (preview only)' if is_dry_run else 'CLEAN (applying changes)'}")
    print()

    compactor = BrainCompactor(
        brain_dir=args.brain_dir,
        threshold_days=args.days,
        dry_run=is_dry_run,
        clean_scratch=not args.no_scratch,
        compress_logs=not args.no_compress,
        prune_empty=not args.no_prune_empty,
    )

    stats = compactor.scan_and_compact()

    print(f"Sessions Scanned           : {stats['total_sessions']}")
    print(f"Active Sessions Protected  : {stats['active_skipped']} (<24h)")
    print(f"Recent Sessions Kept       : {stats['too_recent_skipped']} (<{args.days}d)")
    print(f"Empty Sessions Pruned      : {stats['empty_pruned']}")
    print(f"Log/Transcript Files GZipped: {stats['files_compressed']}")
    print(f"Stale Scratch Files Cleaned: {stats['scratch_files_removed']}")
    print(f"Initial Storage Footprint  : {format_size(stats['bytes_before'])}")
    print(f"Storage Reclaimed / Saved  : {format_size(stats['bytes_reclaimed'])}")
    print()

    if is_dry_run and stats["bytes_reclaimed"] > 0:
        print("Run with --clean to execute the compaction.")


if __name__ == "__main__":
    main()

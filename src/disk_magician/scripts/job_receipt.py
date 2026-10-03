#!/usr/bin/env python3
"""scripts/job_receipt.py — Atomic typed job receipts for Disk Magician.

Implements small standard-library typed atomic receipt helper:
- Fixed terminal outcomes: skipped_lock, skipped_threshold, blocked_safety, error,
  timeout, success_noop, success.
- Started without terminal => outcome 'unknown', freed_bytes unknown/null never fake zero.
- Retains <=64 completed summaries and <=2 active/started per job.
- Preserves independent active, last_success, and last_skipped identities so contenders
  never overwrite active writer or prior success.
- Atomic file write: temp file in same directory + flush + fsync + os.replace.
- Concurrency serialization via fcntl.flock on a dedicated lock file.
- Storage root: DISK_MAGICIAN_STATE_DIR (default: ~/.disk_magician_state).
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, Dict, List, Optional
import uuid

SCHEMA_VERSION = 1

TERMINAL_OUTCOMES = {
    "skipped_lock",
    "skipped_threshold",
    "blocked_safety",
    "error",
    "timeout",
    "success_noop",
    "success",
}

ALL_ALLOWED_OUTCOMES = TERMINAL_OUTCOMES | {"unknown"}

MAX_COMPLETED_RETENTION = 64
MAX_ACTIVE_RETENTION = 2


def now_utc_iso() -> str:
    """Return current UTC time in ISO-8601 format with Z."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(ts_str: str) -> datetime:
    """Parse ISO-8601 timestamp string into datetime."""
    if ts_str.endswith("Z"):
        ts_str = ts_str[:-1] + "+00:00"
    return datetime.fromisoformat(ts_str)


def compute_duration_seconds(start_iso: str, end_iso: str) -> float:
    """Compute duration in seconds between two ISO-8601 timestamps."""
    try:
        start_dt = parse_iso(start_iso)
        end_dt = parse_iso(end_iso)
        return max(0.0, round((end_dt - start_dt).total_seconds(), 3))
    except Exception:
        return 0.0


def resolve_state_dir(override: Optional[str] = None) -> Path:
    """Resolve state directory from argument, environment, or default."""
    if override:
        path = Path(override).expanduser().resolve()
    elif "DISK_MAGICIAN_STATE_DIR" in os.environ and os.environ["DISK_MAGICIAN_STATE_DIR"].strip():
        path = Path(os.environ["DISK_MAGICIAN_STATE_DIR"].strip()).expanduser().resolve()
    else:
        path = Path.home() / ".disk_magician_state"
    return path


class JobReceiptStore:
    """Manages atomic, serialized receipt storage for jobs."""

    def __init__(self, state_dir: Optional[str] = None):
        self.state_dir = resolve_state_dir(state_dir)
        self.receipts_dir = self.state_dir / "receipts"

    def _ensure_dir(self) -> None:
        self.receipts_dir.mkdir(parents=True, exist_ok=True)

    def _get_paths(self, job: str) -> tuple[Path, Path]:
        self._ensure_dir()
        safe_job = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in job)
        receipt_path = self.receipts_dir / f"{safe_job}.json"
        lock_path = self.receipts_dir / f"{safe_job}.lock"
        return receipt_path, lock_path

    def _load_data_unlocked(self, receipt_path: Path, job: str) -> Dict[str, Any]:
        if receipt_path.exists():
            try:
                with open(receipt_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    return data
            except Exception:
                pass
        return {
            "schema_version": SCHEMA_VERSION,
            "job": job,
            "active": [],
            "last_success": None,
            "last_skipped": None,
            "last_terminal": None,
            "completed": [],
        }

    def _atomic_save_unlocked(self, receipt_path: Path, data: Dict[str, Any], job: str) -> None:
        # Enforce bounded retention
        if len(data.get("active", [])) > MAX_ACTIVE_RETENTION:
            data["active"] = data["active"][-MAX_ACTIVE_RETENTION:]
        if len(data.get("completed", [])) > MAX_COMPLETED_RETENTION:
            data["completed"] = data["completed"][-MAX_COMPLETED_RETENTION:]

        tmp_fd, tmp_path_str = tempfile.mkstemp(
            dir=self.receipts_dir,
            prefix=f"{job}_",
            suffix=".tmp",
        )
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path_str, receipt_path)
        except Exception:
            try:
                os.unlink(tmp_path_str)
            except OSError:
                pass
            raise

    def begin(
        self,
        job: str,
        trigger: str = "scheduled",
        revision: Optional[str] = None,
        precondition: Optional[Dict[str, Any]] = None,
        lock: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Record the start of a job run. Returns run_id."""
        run_id = str(uuid.uuid4())
        started_at = now_utc_iso()

        receipt_path, lock_path = self._get_paths(job)
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                data = self._load_data_unlocked(receipt_path, job)
                active_record: Dict[str, Any] = {
                    "schema_version": SCHEMA_VERSION,
                    "id": run_id,
                    "job": job,
                    "run": run_id,
                    "run_id": run_id,
                    "times": {
                        "started_at": started_at,
                        "ended_at": None,
                        "duration_seconds": None,
                    },
                    "installed_revision": revision,
                    "trigger": trigger,
                    "outcome": "unknown",
                    "lock": lock or {"held": True, "acquired": True},
                    "safety": {"status": "in_progress", "reason": None, "delegated": False},
                    "candidates": {"count": None, "bytes": None},
                    "precondition": precondition or {"free_gb": None},
                    "postcondition": {"free_gb": None, "freed_bytes": None},
                    "publication": {"committed": None, "pushed": None, "status": None},
                    "reason": None,
                }
                active_list = data.get("active", [])
                active_list.append(active_record)
                if len(active_list) > MAX_ACTIVE_RETENTION:
                    active_list = active_list[-MAX_ACTIVE_RETENTION:]
                data["active"] = active_list
                self._atomic_save_unlocked(receipt_path, data, job)
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)

        return run_id

    def finish(
        self,
        job: str,
        run_id: Optional[str],
        outcome: str,
        reason: Optional[str] = None,
        lock: Optional[Dict[str, Any]] = None,
        safety: Optional[Dict[str, Any]] = None,
        candidates: Optional[Dict[str, Any]] = None,
        precondition: Optional[Dict[str, Any]] = None,
        postcondition: Optional[Dict[str, Any]] = None,
        publication: Optional[Dict[str, Any]] = None,
        revision: Optional[str] = None,
        trigger: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Record a terminal receipt for a job run."""
        if outcome not in TERMINAL_OUTCOMES:
            raise ValueError(
                f"Invalid terminal outcome '{outcome}'. Must be one of {sorted(TERMINAL_OUTCOMES)}"
            )

        ended_at = now_utc_iso()
        receipt_path, lock_path = self._get_paths(job)
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                data = self._load_data_unlocked(receipt_path, job)

                # Locate existing active record if run_id was provided
                matching_active: Optional[Dict[str, Any]] = None
                remaining_active: List[Dict[str, Any]] = []
                for rec in data.get("active", []):
                    if run_id and (rec.get("id") == run_id or rec.get("run_id") == run_id):
                        matching_active = rec
                    else:
                        remaining_active.append(rec)

                terminal_id = run_id or str(uuid.uuid4())
                started_at = (
                    matching_active["times"]["started_at"]
                    if matching_active and matching_active.get("times", {}).get("started_at")
                    else ended_at
                )
                duration_sec = compute_duration_seconds(started_at, ended_at)

                post = postcondition.copy() if postcondition else {}
                # Freed bytes must default to None/null, never fake 0
                if "freed_bytes" not in post:
                    post["freed_bytes"] = None

                rec_out: Dict[str, Any] = {
                    "schema_version": SCHEMA_VERSION,
                    "id": terminal_id,
                    "job": job,
                    "run": terminal_id,
                    "run_id": terminal_id,
                    "times": {
                        "started_at": started_at,
                        "ended_at": ended_at,
                        "duration_seconds": duration_sec,
                    },
                    "installed_revision": revision
                    or (matching_active.get("installed_revision") if matching_active else None),
                    "trigger": trigger
                    or (matching_active.get("trigger") if matching_active else "scheduled"),
                    "outcome": outcome,
                    "lock": lock
                    or (
                        matching_active.get("lock")
                        if matching_active
                        else {"held": False, "acquired": True}
                    ),
                    "safety": safety
                    or (
                        matching_active.get("safety")
                        if matching_active
                        else {"status": "completed", "reason": None, "delegated": False}
                    ),
                    "candidates": candidates
                    or (
                        matching_active.get("candidates")
                        if matching_active
                        else {"count": None, "bytes": None}
                    ),
                    "precondition": precondition
                    or (
                        matching_active.get("precondition")
                        if matching_active
                        else {"free_gb": None}
                    ),
                    "postcondition": post,
                    "publication": publication
                    or (
                        matching_active.get("publication")
                        if matching_active
                        else {"committed": None, "pushed": None, "status": None}
                    ),
                    "reason": reason or (matching_active.get("reason") if matching_active else None),
                }

                # If matching active was found, remove it from active list
                if matching_active:
                    data["active"] = remaining_active

                # Update last_terminal
                data["last_terminal"] = rec_out

                # Success identities: success or success_noop
                if outcome in ("success", "success_noop"):
                    data["last_success"] = rec_out

                # Skipped identities: skipped_lock or skipped_threshold
                if outcome in ("skipped_lock", "skipped_threshold"):
                    data["last_skipped"] = rec_out

                # Append to completed summaries
                completed = data.get("completed", [])
                completed.append(rec_out)
                if len(completed) > MAX_COMPLETED_RETENTION:
                    completed = completed[-MAX_COMPLETED_RETENTION:]
                data["completed"] = completed

                self._atomic_save_unlocked(receipt_path, data, job)
                return rec_out
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)

    def record_skip(
        self,
        job: str,
        outcome: str,
        reason: Optional[str] = None,
        lock: Optional[Dict[str, Any]] = None,
        precondition: Optional[Dict[str, Any]] = None,
        trigger: str = "scheduled",
    ) -> Dict[str, Any]:
        """Convenience method for contender skips without touching active writer."""
        return self.finish(
            job=job,
            run_id=None,
            outcome=outcome,
            reason=reason,
            lock=lock or {"held": True, "acquired": False, "reason": reason},
            precondition=precondition,
            trigger=trigger,
        )

    def read(self, job: str) -> Dict[str, Any]:
        """Read current receipt state for a job."""
        receipt_path, lock_path = self._get_paths(job)
        if not receipt_path.exists():
            return {
                "schema_version": SCHEMA_VERSION,
                "job": job,
                "active": [],
                "last_success": None,
                "last_skipped": None,
                "last_terminal": None,
                "completed": [],
            }

        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_SH)
            try:
                return self._load_data_unlocked(receipt_path, job)
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


# Module-level convenience functions
def read_receipt(job: str, state_dir: Optional[str] = None) -> Dict[str, Any]:
    return JobReceiptStore(state_dir=state_dir).read(job)


def get_last_receipt(job: str, state_dir: Optional[str] = None) -> Optional[Dict[str, Any]]:
    data = read_receipt(job, state_dir=state_dir)
    return data.get("last_terminal")


def get_effective_outcome(job: str, state_dir: Optional[str] = None) -> str:
    data = read_receipt(job, state_dir=state_dir)
    if data.get("active"):
        return "unknown"
    last = data.get("last_terminal")
    if last and "outcome" in last:
        return str(last["outcome"])
    return "unknown"


def _parse_json_arg(val: Optional[str]) -> Optional[Dict[str, Any]]:
    if not val:
        return None
    try:
        res = json.loads(val)
        if isinstance(res, dict):
            return res
        return {"value": res}
    except Exception:
        return {"raw": val}


def main() -> int:
    parser = argparse.ArgumentParser(description="Disk Magician atomic typed job receipt CLI")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # Subcommand: begin
    p_begin = subparsers.add_parser("begin", help="Record start of job run")
    p_begin.add_argument("--job", required=True, help="Job name")
    p_begin.add_argument("--trigger", default="scheduled", help="Trigger kind")
    p_begin.add_argument("--revision", help="Installed source revision / git SHA")
    p_begin.add_argument("--precondition", help="Precondition JSON string")
    p_begin.add_argument("--lock", help="Lock JSON string")

    # Subcommand: finish
    p_finish = subparsers.add_parser("finish", help="Record terminal receipt")
    p_finish.add_argument("--job", required=True, help="Job name")
    p_finish.add_argument("--run-id", help="Run ID returned by begin")
    p_finish.add_argument("--outcome", required=True, choices=sorted(TERMINAL_OUTCOMES), help="Terminal outcome")
    p_finish.add_argument("--reason", help="Skip/error reason")
    p_finish.add_argument("--lock", help="Lock state JSON")
    p_finish.add_argument("--safety", help="Safety status JSON")
    p_finish.add_argument("--candidates", help="Candidates JSON")
    p_finish.add_argument("--precondition", help="Precondition JSON")
    p_finish.add_argument("--postcondition", help="Postcondition JSON")
    p_finish.add_argument("--publication", help="Publication JSON")
    p_finish.add_argument("--revision", help="Installed source revision")
    p_finish.add_argument("--trigger", help="Trigger kind")
    p_finish.add_argument("--freed-bytes", type=int, help="Bytes freed (omitted/null if unknown)")

    # Subcommand: read
    p_read = subparsers.add_parser("read", help="Read receipt state")
    p_read.add_argument("--job", required=True, help="Job name")
    p_read.add_argument("--last", action="store_true", help="Print last_terminal receipt only")
    p_read.add_argument("--last-success", action="store_true", help="Print last_success receipt only")
    p_read.add_argument("--last-skipped", action="store_true", help="Print last_skipped receipt only")
    p_read.add_argument("--active", action="store_true", help="Print active runs only")

    args = parser.parse_args()
    store = JobReceiptStore()

    try:
        if args.subcommand == "begin":
            run_id = store.begin(
                job=args.job,
                trigger=args.trigger,
                revision=args.revision,
                precondition=_parse_json_arg(args.precondition),
                lock=_parse_json_arg(args.lock),
            )
            print(run_id)
            return 0

        elif args.subcommand == "finish":
            post = _parse_json_arg(args.postcondition) or {}
            if args.freed_bytes is not None:
                post["freed_bytes"] = args.freed_bytes
            rec = store.finish(
                job=args.job,
                run_id=args.run_id,
                outcome=args.outcome,
                reason=args.reason,
                lock=_parse_json_arg(args.lock),
                safety=_parse_json_arg(args.safety),
                candidates=_parse_json_arg(args.candidates),
                precondition=_parse_json_arg(args.precondition),
                postcondition=post,
                publication=_parse_json_arg(args.publication),
                revision=args.revision,
                trigger=args.trigger,
            )
            print(json.dumps(rec))
            return 0

        elif args.subcommand == "read":
            data = store.read(args.job)
            if args.last:
                print(json.dumps(data.get("last_terminal"), indent=2))
            elif args.last_success:
                print(json.dumps(data.get("last_success"), indent=2))
            elif args.last_skipped:
                print(json.dumps(data.get("last_skipped"), indent=2))
            elif args.active:
                print(json.dumps(data.get("active"), indent=2))
            else:
                print(json.dumps(data, indent=2))
            return 0

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

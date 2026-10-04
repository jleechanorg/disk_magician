#!/usr/bin/env python3
"""scripts/job_receipt.py — Atomic typed job receipts for Disk Magician.

Implements standard-library typed atomic receipt helper:
- Fixed terminal outcomes: skipped_lock, skipped_threshold, blocked_safety, error,
  timeout, success_noop, success.
- Started without terminal => outcome 'unknown', freed_bytes unknown/null never fake zero.
- Retains <=64 completed summaries and <=2 active/started per job.
- Preserves independent active, last_success, and last_skipped identities so contenders
  never overwrite active writer or prior success.
- Atomic file write: temp file in same directory + flush + fsync + os.replace.
- Concurrency serialization via fcntl.flock on a dedicated lock file.
- Safe read: read path does not create directories or lock files.
- Fail closed: corrupt existing JSON raises error and is never overwritten.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
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

SKIP_OUTCOMES = {
    "skipped_lock",
    "skipped_threshold",
    "blocked_safety",
}

ALL_ALLOWED_OUTCOMES = TERMINAL_OUTCOMES | {"unknown"}

MAX_COMPLETED_RETENTION = 64
MAX_ACTIVE_RETENTION = 2

JOB_NAME_PATTERN = re.compile(r"^[a-zA-Z0-9_-]+$")


def validate_job_name(job: str) -> None:
    """Validate job name contains only alphanumeric, hyphen, underscore."""
    if not job or not isinstance(job, str) or not JOB_NAME_PATTERN.match(job):
        raise ValueError(
            f"Invalid job name '{job}'. Must be non-empty matching {JOB_NAME_PATTERN.pattern}"
        )


def now_utc_iso() -> str:
    """Return current UTC time in ISO-8601 format with Z."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(ts_str: str) -> datetime:
    """Parse ISO-8601 timestamp string into datetime."""
    if not isinstance(ts_str, str):
        raise ValueError(f"Invalid timestamp type: {type(ts_str).__name__}")
    ts = ts_str
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(ts)
    except Exception as exc:
        raise ValueError(f"Invalid ISO-8601 timestamp '{ts_str}': {exc}") from exc
    if dt.tzinfo is None:
        raise ValueError(f"Timestamp '{ts_str}' must be timezone-aware (UTC)")
    return dt


def compute_duration_seconds(start_iso: str, end_iso: str) -> float:
    """Compute duration in seconds between two ISO-8601 timestamps."""
    start_dt = parse_iso(start_iso)
    end_dt = parse_iso(end_iso)
    diff = (end_dt - start_dt).total_seconds()
    if diff < 0:
        raise ValueError(
            f"ended_at ({end_iso}) is earlier than started_at ({start_iso}): negative duration"
        )
    return round(diff, 3)


def resolve_state_dir(override: Optional[str] = None) -> Path:
    """Resolve state directory from argument, environment, or default."""
    if override:
        path = Path(override).expanduser().resolve()
    elif "DISK_MAGICIAN_STATE_DIR" in os.environ and os.environ["DISK_MAGICIAN_STATE_DIR"].strip():
        path = Path(os.environ["DISK_MAGICIAN_STATE_DIR"].strip()).expanduser().resolve()
    else:
        path = Path.home() / ".disk_magician_state"
    return path


def sha256_file(path: Path) -> str:
    """Compute sha256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def resolve_identity(
    revision: Optional[str] = None,
    state_dir: Optional[Path] = None,
    helper_path_override: Optional[Path] = None,
) -> Dict[str, Any]:
    """Resolve executing provenance and identity without ungrounded assertions."""
    helper_file = (helper_path_override or Path(__file__)).resolve()
    actual_helper_root = helper_file.parent.parent

    # 1. Check if deployed.json exists in state_dir
    sd = state_dir or resolve_state_dir()
    deployed_file = sd / "deployed.json"
    if deployed_file.exists():
        try:
            with open(deployed_file, "r", encoding="utf-8") as f:
                dep_data = json.load(f)
            if isinstance(dep_data, dict):
                package_root_raw = dep_data.get("package_root")
                source_sha = dep_data.get("source_sha")
                package_hashes = dep_data.get("package_hashes")

                if package_root_raw and source_sha:
                    dep_package_root = Path(package_root_raw).resolve()
                    if actual_helper_root == dep_package_root:
                        # Same root. Check manifest.
                        if not isinstance(package_hashes, dict) or len(package_hashes) == 0:
                            return {
                                "kind": "unknown",
                                "source_sha": None,
                                "revision": None,
                                "reason": "empty_package_manifest",
                            }

                        # Check unsafe paths in manifest
                        for p in package_hashes.keys():
                            p_obj = Path(p)
                            if p.startswith("/") or p_obj.is_absolute() or ".." in p_obj.parts:
                                return {
                                    "kind": "unknown",
                                    "source_sha": None,
                                    "revision": None,
                                    "reason": "unsafe_manifest_path",
                                }

                        # Check helper itself against manifest
                        try:
                            rel_helper = helper_file.relative_to(actual_helper_root).as_posix()
                        except ValueError:
                            rel_helper = None

                        if not rel_helper or rel_helper not in package_hashes:
                            return {
                                "kind": "unknown",
                                "source_sha": None,
                                "revision": None,
                                "reason": "helper_not_in_manifest",
                            }

                        if sha256_file(helper_file) != package_hashes[rel_helper]:
                            return {
                                "kind": "unknown",
                                "source_sha": None,
                                "revision": None,
                                "reason": "helper_hash_mismatch",
                            }

                        # Verify all other files listed in manifest
                        mismatch = False
                        for rel_p, exp_hash in package_hashes.items():
                            f_path = actual_helper_root / rel_p
                            if not f_path.is_file() or sha256_file(f_path) != exp_hash:
                                mismatch = True
                                break
                        if mismatch:
                            return {
                                "kind": "unknown",
                                "source_sha": None,
                                "revision": None,
                                "reason": "manifest_file_hash_mismatch",
                            }

                        # Verified installed package
                        return {
                            "kind": "installed_package",
                            "source_sha": source_sha,
                            "installed_version": dep_data.get("installed_version"),
                            "package_root": str(actual_helper_root),
                            "installed_revision": source_sha,
                            "deployed_at": dep_data.get("deployed_at"),
                            "override_state": dep_data.get("override_state"),
                            "revision": source_sha,
                        }
                    else:
                        # deployed.json points at a different root
                        pass
        except Exception:
            pass

    # 2. Check if running from git source checkout
    repo_dir = actual_helper_root
    if (repo_dir / ".git").exists():
        try:
            env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
            proc = subprocess.run(
                ["git", "-C", str(repo_dir), "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
            if proc.returncode == 0:
                sha = proc.stdout.strip()
                return {
                    "kind": "source_checkout",
                    "source_sha": sha,
                    "source_root": str(repo_dir),
                    "revision": sha,
                }
        except Exception:
            pass

    # 3. Provided revision
    if revision:
        return {
            "kind": "provided_revision",
            "provided_revision": revision,
            "source_sha": None,
            "revision": revision,
        }

    return {
        "kind": "unknown",
        "source_sha": None,
        "revision": None,
    }


def validate_receipt_dict(rec: Dict[str, Any], context: str = "receipt") -> None:
    """Validate structure and required fields of a receipt dictionary."""
    if not isinstance(rec, dict):
        raise ValueError(f"{context} must be a dictionary")
    for key in ("id", "job", "outcome", "times"):
        if key not in rec:
            raise ValueError(f"{context} missing required field '{key}'")
    if rec["outcome"] not in ALL_ALLOWED_OUTCOMES:
        raise ValueError(f"{context} has invalid outcome '{rec['outcome']}'")
    times = rec.get("times")
    if not isinstance(times, dict) or "started_at" not in times:
        raise ValueError(f"{context} times must be a dict containing 'started_at'")
    parse_iso(times["started_at"])
    if times.get("ended_at") is not None:
        parse_iso(times["ended_at"])
        compute_duration_seconds(times["started_at"], times["ended_at"])


def validate_store_data(data: Any, job: str) -> Dict[str, Any]:
    """Validate full receipt store file structure; fail closed if invalid."""
    if not isinstance(data, dict):
        raise ValueError("Receipt store root must be a JSON object")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(
            f"Unsupported schema_version {data.get('schema_version')}, expected {SCHEMA_VERSION}"
        )
    if data.get("job") != job:
        raise ValueError(f"Store job mismatch: expected '{job}', found '{data.get('job')}'")
    if not isinstance(data.get("active"), list):
        raise ValueError("Receipt store 'active' must be a list")
    if not isinstance(data.get("completed"), list):
        raise ValueError("Receipt store 'completed' must be a list")

    for act in data["active"]:
        validate_receipt_dict(act, context=f"active receipt {act.get('id')}")
    for comp in data["completed"]:
        validate_receipt_dict(comp, context=f"completed receipt {comp.get('id')}")
    if data.get("last_terminal") is not None:
        validate_receipt_dict(data["last_terminal"], context="last_terminal")
    if data.get("last_success") is not None:
        validate_receipt_dict(data["last_success"], context="last_success")
    if data.get("last_skipped") is not None:
        validate_receipt_dict(data["last_skipped"], context="last_skipped")

    return data


class JobReceiptStore:
    """Manages atomic, serialized receipt storage for jobs."""

    def __init__(self, state_dir: Optional[str] = None):
        self.state_dir = resolve_state_dir(state_dir)
        self.receipts_dir = self.state_dir / "receipts"

    def _ensure_dir(self) -> None:
        self.receipts_dir.mkdir(parents=True, exist_ok=True)

    def _get_paths(self, job: str, ensure_dir: bool = True) -> tuple[Path, Path]:
        validate_job_name(job)
        if ensure_dir:
            self._ensure_dir()
        receipt_path = self.receipts_dir / f"{job}.json"
        lock_path = self.receipts_dir / f"{job}.lock"
        return receipt_path, lock_path

    def _load_data_unlocked(self, receipt_path: Path, job: str) -> Dict[str, Any]:
        """Load and validate store data. Fails closed on any error; only FileNotFoundError yields empty."""
        try:
            with open(receipt_path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except FileNotFoundError:
            return {
                "schema_version": SCHEMA_VERSION,
                "job": job,
                "active": [],
                "last_success": None,
                "last_skipped": None,
                "last_terminal": None,
                "completed": [],
            }
        except Exception as exc:
            raise ValueError(f"Corrupt or unreadable receipt file at {receipt_path}: {exc}") from exc

        return validate_store_data(raw, job)

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
        safety: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Record the start of a job run. Returns run_id."""
        validate_job_name(job)
        run_id = str(uuid.uuid4())
        started_at = now_utc_iso()
        identity_info = resolve_identity(revision, self.state_dir)
        installed_rev = (
            identity_info.get("installed_revision")
            if identity_info.get("kind") == "installed_package"
            else None
        )

        receipt_path, lock_path = self._get_paths(job, ensure_dir=True)
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
                    "installed_revision": installed_rev,
                    "identity": identity_info,
                    "trigger": trigger,
                    "outcome": "unknown",
                    "lock": lock or {"held": True, "acquired": True},
                    "safety": safety or {"status": "in_progress", "reason": None, "delegated": False},
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
        validate_job_name(job)
        if outcome not in TERMINAL_OUTCOMES:
            raise ValueError(
                f"Invalid terminal outcome '{outcome}'. Must be one of {sorted(TERMINAL_OUTCOMES)}"
            )

        # Without run_id, only direct skip/blocked outcomes are allowed
        if not run_id and outcome not in SKIP_OUTCOMES:
            raise ValueError(
                f"Outcome '{outcome}' requires an active run_id started by begin(). "
                f"Only {sorted(SKIP_OUTCOMES)} may be recorded without a prior run_id."
            )

        ended_at = now_utc_iso()
        receipt_path, lock_path = self._get_paths(job, ensure_dir=True)
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                data = self._load_data_unlocked(receipt_path, job)

                matching_active: Optional[Dict[str, Any]] = None
                remaining_active: List[Dict[str, Any]] = []
                for rec in data.get("active", []):
                    if run_id and (rec.get("id") == run_id or rec.get("run_id") == run_id):
                        matching_active = rec
                    else:
                        remaining_active.append(rec)

                if run_id and not matching_active:
                    raise ValueError(
                        f"Cannot finish run_id '{run_id}': no active matching run found for job '{job}'"
                    )

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
                else:
                    fb = post["freed_bytes"]
                    if isinstance(fb, bool):
                        raise ValueError("freed_bytes cannot be a boolean")
                    if fb is not None and (not isinstance(fb, int) or fb < 0):
                        raise ValueError(f"freed_bytes must be non-negative integer or null, got {fb}")

                identity_info = (
                    matching_active.get("identity")
                    if matching_active and matching_active.get("identity")
                    else resolve_identity(revision, self.state_dir)
                )
                installed_rev = (
                    matching_active.get("installed_revision")
                    if matching_active and matching_active.get("installed_revision") is not None
                    else (
                        identity_info.get("installed_revision")
                        if identity_info.get("kind") == "installed_package"
                        else None
                    )
                )

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
                    "installed_revision": installed_rev,
                    "identity": identity_info,
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

                validate_receipt_dict(rec_out, context="terminal receipt")

                if matching_active:
                    data["active"] = remaining_active

                data["last_terminal"] = rec_out

                if outcome in ("success", "success_noop"):
                    data["last_success"] = rec_out

                if outcome in ("skipped_lock", "skipped_threshold"):
                    data["last_skipped"] = rec_out

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
        safety: Optional[Dict[str, Any]] = None,
        trigger: str = "scheduled",
    ) -> Dict[str, Any]:
        """Convenience method for contender skips without touching active writer."""
        validate_job_name(job)
        if outcome not in SKIP_OUTCOMES:
            raise ValueError(
                f"record_skip only accepts outcomes {sorted(SKIP_OUTCOMES)}, got '{outcome}'"
            )
        return self.finish(
            job=job,
            run_id=None,
            outcome=outcome,
            reason=reason,
            lock=lock or {"held": True, "acquired": False, "reason": reason},
            precondition=precondition,
            safety=safety or {"status": "not_applicable", "reason": reason, "delegated": False},
            trigger=trigger,
        )

    def read(self, job: str) -> Dict[str, Any]:
        """Read current receipt state for a job. Read path MUST NOT mutate disk, mkdir, or create locks."""
        validate_job_name(job)
        receipt_path, _ = self._get_paths(job, ensure_dir=False)
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

        # Atomic os.replace ensures the file is always in a consistent state on POSIX filesystems
        try:
            with open(receipt_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as exc:
            raise ValueError(f"Corrupt or unreadable receipt file at {receipt_path}: {exc}") from exc

        return validate_store_data(data, job)


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
    except Exception as exc:
        raise ValueError(f"Invalid JSON string: {val} ({exc})") from exc
    if not isinstance(res, dict):
        raise ValueError(f"Expected JSON object (dict), got {type(res).__name__}")
    return res


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
    p_begin.add_argument("--safety", help="Safety JSON string")

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

    # Subcommand: skip
    p_skip = subparsers.add_parser("skip", help="Record skip or blocked outcome")
    p_skip.add_argument("--job", required=True, help="Job name")
    p_skip.add_argument("--outcome", required=True, choices=sorted(SKIP_OUTCOMES), help="Skip outcome")
    p_skip.add_argument("--reason", help="Skip reason")
    p_skip.add_argument("--lock", help="Lock state JSON")
    p_skip.add_argument("--precondition", help="Precondition JSON")
    p_skip.add_argument("--safety", help="Safety JSON")
    p_skip.add_argument("--trigger", default="scheduled", help="Trigger kind")

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
                safety=_parse_json_arg(args.safety),
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

        elif args.subcommand == "skip":
            rec = store.record_skip(
                job=args.job,
                outcome=args.outcome,
                reason=args.reason,
                lock=_parse_json_arg(args.lock),
                precondition=_parse_json_arg(args.precondition),
                safety=_parse_json_arg(args.safety),
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

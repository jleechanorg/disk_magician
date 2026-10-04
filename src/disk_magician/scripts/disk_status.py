#!/usr/bin/env python3
"""scripts/disk_status.py — Read-only typed status join across Disk Magician subsystems.

Evaluates six operational dimensions:
1. fleet: launchd automation health and liveness
2. measurement: total-coverage snapshot freshness and completeness
3. publication: strict 5G ledger integrity, canonical commit freshness, and renderer sidecar
4. action_outcome: typed receipts for snapshot_commit, pressure_sweep, and tmp_scratch_sweep
5. safety: safety policy compliance, non-mutation evidence, and blocked states
6. deployed_identity: deployed.json manifest verification, package hashes, and source sync

Exit codes:
- 0: All evaluated dimensions are healthy
- 1: One or more dimensions degraded or unknown (e.g. missing inputs, stale data)
- 2: One or more dimensions invalid (e.g. malformed JSON, corrupt receipts, schema violation)
"""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERSION = 1

# Exit codes
EXIT_HEALTHY = 0
EXIT_DEGRADED_OR_UNKNOWN = 1
EXIT_INVALID = 2

# Status constants
STATUS_HEALTHY = "healthy"
STATUS_DEGRADED = "degraded"
STATUS_UNKNOWN = "unknown"
STATUS_INVALID = "invalid"

# Add scripts directory to sys.path for internal helpers
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

try:
    import history_diff  # type: ignore
except ImportError:
    history_diff = None

try:
    import resolve_state_repo_path  # type: ignore
except ImportError:
    resolve_state_repo_path = None

try:
    from job_receipt import JobReceiptStore, resolve_identity, resolve_state_dir  # type: ignore
except ImportError:
    JobReceiptStore = None
    resolve_identity = None
    resolve_state_dir = None


def now_utc_iso() -> str:
    """Return current UTC time in ISO-8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc_timestamp(ts: Any) -> Optional[datetime]:
    """Parse UTC ISO-8601 string or numeric epoch seconds into timezone-aware datetime."""
    if ts is None:
        return None
    if isinstance(ts, (int, float)):
        if isinstance(ts, bool) or not math.isfinite(ts):
            return None
        return datetime.fromtimestamp(ts, tz=timezone.utc)
    if isinstance(ts, str):
        s = ts.strip()
        if not s:
            return None
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except Exception:
            return None
    return None


def sha256_file(path: Path) -> str:
    """Compute sha256 digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


class DiskStatusEvaluator:
    """Read-only evaluator across all Disk Magician operational dimensions."""

    def __init__(
        self,
        state_dir: Optional[Path] = None,
        state_repo: Optional[Path] = None,
        now: Optional[datetime] = None,
        fleet_json: Optional[Path] = None,
        strict_ledger_max_age_hours: float = 48.0,
        snapshot_commit_max_age_minutes: float = 90.0,
        pressure_sweep_max_age_minutes: float = 90.0,
        tmp_scratch_sweep_max_age_hours: float = 3.0,
    ):
        self.now = now or datetime.now(timezone.utc)

        # Resolve state dir (receipts, deployed.json)
        if state_dir:
            self.state_dir = Path(state_dir).expanduser().resolve()
        elif "DISK_MAGICIAN_STATE_DIR" in os.environ and os.environ["DISK_MAGICIAN_STATE_DIR"].strip():
            self.state_dir = Path(os.environ["DISK_MAGICIAN_STATE_DIR"].strip()).expanduser().resolve()
        elif resolve_state_dir:
            self.state_dir = resolve_state_dir()
        else:
            self.state_dir = Path.home() / ".disk_magician_state"

        # Resolve state repo (snapshots, ledger, markdown)
        if state_repo:
            self.state_repo = Path(state_repo).expanduser().resolve()
        elif "DISK_MAGICIAN_STATE_REPO" in os.environ and os.environ["DISK_MAGICIAN_STATE_REPO"].strip():
            self.state_repo = Path(os.environ["DISK_MAGICIAN_STATE_REPO"].strip()).expanduser().resolve()
        elif resolve_state_repo_path:
            self.state_repo = Path(resolve_state_repo_path.resolve()).expanduser().resolve()
        else:
            self.state_repo = Path.home() / ".local/state/disk-magician"

        self.fleet_json = Path(fleet_json).expanduser().resolve() if fleet_json else None
        self.strict_ledger_max_age_hours = strict_ledger_max_age_hours
        self.snapshot_commit_max_age_minutes = snapshot_commit_max_age_minutes
        self.pressure_sweep_max_age_minutes = pressure_sweep_max_age_minutes
        self.tmp_scratch_sweep_max_age_hours = tmp_scratch_sweep_max_age_hours

    def evaluate_fleet(self) -> Dict[str, Any]:
        """Evaluate launchd automation fleet health."""
        if self.fleet_json:
            if not self.fleet_json.exists():
                return {
                    "status": STATUS_UNKNOWN,
                    "reason": "fleet_json_file_not_found",
                    "owner": "launchd_fleet",
                    "source": str(self.fleet_json),
                    "paths": [str(self.fleet_json)],
                    "time": None,
                    "records": [],
                }
            try:
                with open(self.fleet_json, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception as exc:
                return {
                    "status": STATUS_INVALID,
                    "reason": f"fleet_json_malformed: {exc}",
                    "owner": "launchd_fleet",
                    "source": str(self.fleet_json),
                    "paths": [str(self.fleet_json)],
                    "time": None,
                    "records": [],
                }
            if not isinstance(data, dict):
                return {
                    "status": STATUS_INVALID,
                    "reason": "fleet_json_root_not_object",
                    "owner": "launchd_fleet",
                    "source": str(self.fleet_json),
                    "paths": [str(self.fleet_json)],
                    "time": None,
                    "records": [],
                }
            status = data.get("status", STATUS_UNKNOWN)
            if status not in (STATUS_HEALTHY, STATUS_DEGRADED, STATUS_UNKNOWN, STATUS_INVALID):
                status = STATUS_UNKNOWN
            return {
                "status": status,
                "reason": data.get("reason", f"fleet_status_{status}"),
                "owner": "launchd_fleet",
                "source": str(self.fleet_json),
                "paths": data.get("source_paths", [str(self.fleet_json)]),
                "time": data.get("checked_at"),
                "records": data.get("records", []),
            }

        # Subprocess evaluation
        if sys.platform != "darwin":
            return {
                "status": STATUS_HEALTHY,
                "reason": "launchd_not_applicable_on_platform",
                "owner": "launchd_fleet",
                "source": "platform_check",
                "paths": [],
                "time": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "records": [],
            }

        check_script = SCRIPTS_DIR / "check_launchd_fleet.sh"
        if not check_script.is_file():
            return {
                "status": STATUS_UNKNOWN,
                "reason": "check_launchd_fleet_script_missing",
                "owner": "launchd_fleet",
                "source": str(check_script),
                "paths": [str(check_script)],
                "time": None,
                "records": [],
            }

        try:
            proc = subprocess.run(
                ["/bin/bash", str(check_script), "--fleet-only", "--json"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if proc.returncode == 0 or proc.stdout.strip().startswith("{"):
                try:
                    data = json.loads(proc.stdout)
                    if isinstance(data, dict) and "status" in data:
                        return {
                            "status": data.get("status", STATUS_UNKNOWN),
                            "reason": data.get("reason", "fleet_checked"),
                            "owner": "launchd_fleet",
                            "source": str(check_script),
                            "paths": data.get("source_paths", [str(check_script)]),
                            "time": data.get("checked_at", self.now.strftime("%Y-%m-%dT%H:%M:%SZ")),
                            "records": data.get("records", []),
                        }
                except Exception:
                    pass
        except Exception:
            pass

        return {
            "status": STATUS_UNKNOWN,
            "reason": "check_launchd_fleet_unavailable_or_unsupported",
            "owner": "launchd_fleet",
            "source": str(check_script),
            "paths": [str(check_script)],
            "time": None,
            "records": [],
        }

    def evaluate_measurement(self) -> Dict[str, Any]:
        """Evaluate disk_snapshot.json measurement freshness, coverage, and completeness."""
        snapshot_file = self.state_repo / "snapshots" / "disk_snapshot.json"
        if not snapshot_file.exists():
            return {
                "status": STATUS_UNKNOWN,
                "reason": "disk_snapshot_missing",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": None,
                "details": {},
            }

        try:
            with open(snapshot_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as exc:
            return {
                "status": STATUS_INVALID,
                "reason": f"disk_snapshot_malformed: {exc}",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": None,
                "details": {},
            }

        if not isinstance(data, dict):
            return {
                "status": STATUS_INVALID,
                "reason": "disk_snapshot_not_object",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": None,
                "details": {},
            }

        meta = data.get("snapshot_metadata", {})
        if not isinstance(meta, dict):
            meta = {}

        raw_ts = meta.get("captured_at") or data.get("timestamp") or data.get("captured_at")
        captured_dt = parse_utc_timestamp(raw_ts)

        if not captured_dt:
            return {
                "status": STATUS_DEGRADED,
                "reason": "snapshot_timestamp_missing_or_invalid",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": None,
                "details": {},
            }

        if captured_dt > self.now + timedelta(minutes=5):
            return {
                "status": STATUS_DEGRADED,
                "reason": f"snapshot_timestamp_in_future ({raw_ts})",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": {},
            }

        # Check coverage
        cov_fresh = (
            data.get("coverage_fresh_pct")
            if "coverage_fresh_pct" in data
            else (data.get("snapshot_coverage_pct") if "snapshot_coverage_pct" in data else meta.get("coverage_pct"))
        )
        if (
            cov_fresh is None
            or isinstance(cov_fresh, bool)
            or not isinstance(cov_fresh, (int, float))
            or not math.isfinite(cov_fresh)
            or cov_fresh < 0.0
            or cov_fresh > 100.0
        ):
            return {
                "status": STATUS_DEGRADED,
                "reason": f"incoherent_or_missing_coverage_pct: {cov_fresh}",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": {"coverage_fresh_pct": cov_fresh},
            }

        measurement_status = data.get("measurement_status", "complete")
        carried_keys = data.get("carried_keys") or []
        unmeasured_keys = data.get("unmeasured_keys") or []
        budget_exhausted = bool(data.get("measurement_budget_exhausted", False))

        details = {
            "captured_at": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "coverage_fresh_pct": cov_fresh,
            "measurement_status": measurement_status,
            "carried_keys_count": len(carried_keys) if isinstance(carried_keys, list) else None,
            "unmeasured_keys_count": len(unmeasured_keys) if isinstance(unmeasured_keys, list) else None,
            "measurement_budget_exhausted": budget_exhausted,
        }

        # Age check (max 48 hours for measurement snapshot)
        if self.now - captured_dt > timedelta(hours=48):
            return {
                "status": STATUS_DEGRADED,
                "reason": f"snapshot_stale (captured {captured_dt.strftime('%Y-%m-%d %H:%M:%SZ')})",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": details,
            }

        if cov_fresh < 70.0:
            return {
                "status": STATUS_DEGRADED,
                "reason": f"coverage_below_floor ({cov_fresh:.1f}% < 70.0%)",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": details,
            }

        if measurement_status != "complete":
            return {
                "status": STATUS_DEGRADED,
                "reason": f"measurement_status_{measurement_status}",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": details,
            }

        if carried_keys or unmeasured_keys or budget_exhausted:
            return {
                "status": STATUS_DEGRADED,
                "reason": "measurement_incomplete_carried_or_budget_exhausted",
                "owner": "disk_snapshot",
                "source": str(snapshot_file),
                "paths": [str(snapshot_file)],
                "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": details,
            }

        return {
            "status": STATUS_HEALTHY,
            "reason": "snapshot_complete_and_fresh",
            "owner": "disk_snapshot",
            "source": str(snapshot_file),
            "paths": [str(snapshot_file)],
            "time": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "details": details,
        }

    def evaluate_publication(self) -> Dict[str, Any]:
        """Evaluate strict 5G ledger integrity, canonical git history, and renderer sidecar."""
        strict_ledger_file = self.state_repo / "ledger" / "topdown-5g.json"
        sidecar_file = self.state_repo / "ledger" / "topdown-5g.status.json"
        partial_ledger_file = self.state_repo / "ledger" / "topdown-5g.partial.json"

        paths = [
            str(p)
            for p in (strict_ledger_file, sidecar_file, partial_ledger_file)
            if p.exists()
        ]

        # 1. Check if neither exists
        if not strict_ledger_file.exists() and not partial_ledger_file.exists():
            return {
                "status": STATUS_UNKNOWN,
                "reason": "no_topdown_ledger_published",
                "owner": "topdown_ledger",
                "source": str(strict_ledger_file),
                "paths": [str(strict_ledger_file)],
                "time": None,
                "details": {},
            }

        # 2. Check partial-only case
        if not strict_ledger_file.exists() and partial_ledger_file.exists():
            try:
                with open(partial_ledger_file, "r", encoding="utf-8") as f:
                    partial_data = json.load(f)
                if not isinstance(partial_data, dict):
                    return {
                        "status": STATUS_INVALID,
                        "reason": "partial_ledger_not_object",
                        "owner": "topdown_ledger",
                        "source": str(partial_ledger_file),
                        "paths": [str(partial_ledger_file)],
                        "time": None,
                        "details": {},
                    }
            except Exception as exc:
                return {
                    "status": STATUS_INVALID,
                    "reason": f"partial_ledger_unreadable: {exc}",
                    "owner": "topdown_ledger",
                    "source": str(partial_ledger_file),
                    "paths": [str(partial_ledger_file)],
                    "time": None,
                    "details": {},
                }

            part_dt = parse_utc_timestamp(partial_data.get("captured_at"))
            return {
                "status": STATUS_DEGRADED,
                "reason": "partial_publication_only_no_strict_ledger",
                "owner": "topdown_ledger",
                "source": str(partial_ledger_file),
                "paths": [str(partial_ledger_file)],
                "time": part_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if part_dt else None,
                "details": {
                    "canonical": False,
                    "publication_kind": "partial",
                    "scope": partial_data.get("scope"),
                },
            }

        # 3. Strict ledger exists: parse and validate
        try:
            with open(strict_ledger_file, "r", encoding="utf-8") as f:
                strict_data = json.load(f)
        except Exception as exc:
            return {
                "status": STATUS_INVALID,
                "reason": f"strict_ledger_malformed: {exc}",
                "owner": "topdown_ledger",
                "source": str(strict_ledger_file),
                "paths": [str(strict_ledger_file)],
                "time": None,
                "details": {},
            }

        if not isinstance(strict_data, dict):
            return {
                "status": STATUS_INVALID,
                "reason": "strict_ledger_not_object",
                "owner": "topdown_ledger",
                "source": str(strict_ledger_file),
                "paths": [str(strict_ledger_file)],
                "time": None,
                "details": {},
            }

        # Validate with history_diff validators if available
        if history_diff:
            try:
                history_diff.validate_ledger(strict_data, label=str(strict_ledger_file))
                history_diff.validate_full_attribution_ledger(strict_data, label=str(strict_ledger_file))
            except Exception as exc:
                return {
                    "status": STATUS_INVALID,
                    "reason": f"strict_ledger_integrity_violation: {exc}",
                    "owner": "topdown_ledger",
                    "source": str(strict_ledger_file),
                    "paths": [str(strict_ledger_file)],
                    "time": None,
                    "details": {},
                }

        # Query git log for last commit touching strict ledger
        git_commit_dt: Optional[datetime] = None
        if (self.state_repo / ".git").exists():
            try:
                proc = subprocess.run(
                    ["git", "-C", str(self.state_repo), "log", "-1", "--format=%cI", "--", "ledger/topdown-5g.json"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    git_commit_dt = parse_utc_timestamp(proc.stdout.strip())
            except Exception:
                pass

        artifact_dt = parse_utc_timestamp(strict_data.get("captured_at"))
        eff_time = git_commit_dt or artifact_dt
        time_str = eff_time.strftime("%Y-%m-%dT%H:%M:%SZ") if eff_time else None

        details = {
            "git_commit_time": git_commit_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if git_commit_dt else None,
            "artifact_captured_at": artifact_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if artifact_dt else None,
            "canonical": True,
            "schema_version": strict_data.get("schema_version"),
        }

        # Check sidecar status
        sidecar_status = None
        if sidecar_file.exists():
            try:
                with open(sidecar_file, "r", encoding="utf-8") as f:
                    sidecar_data = json.load(f)
                if isinstance(sidecar_data, dict):
                    sidecar_status = sidecar_data.get("status")
                    details["sidecar_status"] = sidecar_status
            except Exception:
                pass

        if sidecar_status == "partial":
            return {
                "status": STATUS_DEGRADED,
                "reason": "current_publication_partial_in_renderer_sidecar",
                "owner": "topdown_ledger",
                "source": str(strict_ledger_file),
                "paths": paths,
                "time": time_str,
                "details": details,
            }

        # Freshness check
        max_age = timedelta(hours=self.strict_ledger_max_age_hours)
        is_stale = False
        if git_commit_dt and (self.now - git_commit_dt > max_age):
            is_stale = True
        elif artifact_dt and (self.now - artifact_dt > max_age):
            is_stale = True

        if is_stale:
            return {
                "status": STATUS_DEGRADED,
                "reason": f"strict_ledger_stale (> {self.strict_ledger_max_age_hours}h old)",
                "owner": "topdown_ledger",
                "source": str(strict_ledger_file),
                "paths": paths,
                "time": time_str,
                "details": details,
            }

        return {
            "status": STATUS_HEALTHY,
            "reason": "strict_ledger_current_and_valid",
            "owner": "topdown_ledger",
            "source": str(strict_ledger_file),
            "paths": paths,
            "time": time_str,
            "details": details,
        }

    def evaluate_action_outcome(self) -> Dict[str, Any]:
        """Evaluate action outcomes across snapshot_commit, pressure_sweep, and tmp_scratch_sweep."""
        if not JobReceiptStore:
            return {
                "status": STATUS_UNKNOWN,
                "reason": "job_receipt_store_module_unavailable",
                "owner": "job_receipts",
                "source": str(self.state_dir),
                "paths": [],
                "time": None,
                "details": {},
            }

        store = JobReceiptStore(state_dir=str(self.state_dir))
        required_jobs = {
            "snapshot_commit": timedelta(minutes=self.snapshot_commit_max_age_minutes),
            "pressure_sweep": timedelta(minutes=self.pressure_sweep_max_age_minutes),
            "tmp_scratch_sweep": timedelta(hours=self.tmp_scratch_sweep_max_age_hours),
        }

        job_statuses: Dict[str, Dict[str, Any]] = {}
        receipt_paths: List[str] = []
        overall_status = STATUS_HEALTHY
        degraded_reasons: List[str] = []

        for job, max_age in required_jobs.items():
            receipt_file = self.state_dir / "receipts" / f"{job}.json"
            if receipt_file.exists():
                receipt_paths.append(str(receipt_file))

            try:
                data = store.read(job)
            except Exception as exc:
                job_statuses[job] = {
                    "status": STATUS_INVALID,
                    "reason": f"receipt_file_corrupt: {exc}",
                    "latest_outcome": None,
                    "ended_at": None,
                }
                overall_status = STATUS_INVALID
                degraded_reasons.append(f"{job}: receipt corrupt")
                continue

            last_term = data.get("last_terminal")
            active = data.get("active") or []
            last_succ = data.get("last_success")
            last_skip = data.get("last_skipped")

            if not last_term and not active:
                job_statuses[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "no_receipts_recorded",
                    "latest_outcome": None,
                    "ended_at": None,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_UNKNOWN if overall_status == STATUS_HEALTHY else overall_status
                degraded_reasons.append(f"{job}: no receipts")
                continue

            # Check if an active run was abandoned / interrupted without finish
            interrupted = False
            for act in active:
                act_start = parse_utc_timestamp(act.get("times", {}).get("started_at"))
                if act_start and (self.now - act_start > timedelta(hours=4)):
                    interrupted = True
                    break

            if interrupted:
                job_statuses[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "active_run_started_without_terminal_interrupted",
                    "latest_outcome": "unknown",
                    "ended_at": None,
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                degraded_reasons.append(f"{job}: active run interrupted")
                continue

            if not last_term:
                job_statuses[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "in_progress_no_terminal",
                    "latest_outcome": "unknown",
                    "ended_at": None,
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                degraded_reasons.append(f"{job}: in progress")
                continue

            term_outcome = last_term.get("outcome")
            ended_at_str = last_term.get("times", {}).get("ended_at")
            ended_dt = parse_utc_timestamp(ended_at_str)

            # Age check
            stale = False
            if not ended_dt or (self.now - ended_dt > max_age):
                stale = True

            if stale:
                job_statuses[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"receipt_stale (ended {ended_at_str})",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                degraded_reasons.append(f"{job}: stale")
                continue

            if term_outcome in ("error", "timeout", "blocked_safety"):
                job_statuses[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"terminal_{term_outcome}",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                degraded_reasons.append(f"{job}: outcome {term_outcome}")
                continue

            if term_outcome in ("skipped_lock", "skipped_threshold"):
                # Must have prior success
                if last_succ:
                    job_statuses[job] = {
                        "status": STATUS_HEALTHY,
                        "reason": f"{term_outcome}_with_prior_success",
                        "latest_outcome": term_outcome,
                        "ended_at": ended_at_str,
                    }
                else:
                    job_statuses[job] = {
                        "status": STATUS_DEGRADED,
                        "reason": f"{term_outcome}_without_prior_success",
                        "latest_outcome": term_outcome,
                        "ended_at": ended_at_str,
                    }
                    if overall_status != STATUS_INVALID:
                        overall_status = STATUS_DEGRADED
                    degraded_reasons.append(f"{job}: skip without prior success")
                continue

            if term_outcome in ("success", "success_noop"):
                job_statuses[job] = {
                    "status": STATUS_HEALTHY,
                    "reason": f"terminal_{term_outcome}",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                }
                continue

            # Any unhandled outcome
            job_statuses[job] = {
                "status": STATUS_UNKNOWN,
                "reason": f"unhandled_outcome_{term_outcome}",
                "latest_outcome": term_outcome,
                "ended_at": ended_at_str,
            }
            if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                overall_status = STATUS_UNKNOWN
            degraded_reasons.append(f"{job}: unhandled outcome {term_outcome}")

        return {
            "status": overall_status,
            "reason": "; ".join(degraded_reasons) if degraded_reasons else "all_required_jobs_healthy",
            "owner": "job_receipts",
            "source": str(self.state_dir / "receipts"),
            "paths": receipt_paths,
            "time": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "details": job_statuses,
        }

    def evaluate_safety(self) -> Dict[str, Any]:
        """Evaluate explicit safety outcomes from receipts and policy file provenance."""
        roots_txt = SCRIPTS_DIR.parent / "config" / "sweeper_roots.txt"
        scratch_sh = SCRIPTS_DIR / "lib" / "scratch_roots.sh"
        policy_paths = [
            str(p) for p in (roots_txt, scratch_sh) if p.exists()
        ]

        if not JobReceiptStore:
            return {
                "status": STATUS_UNKNOWN,
                "reason": "job_receipt_store_module_unavailable",
                "owner": "safety_policies",
                "source": "receipt_safety_inspection",
                "paths": policy_paths,
                "time": None,
                "details": {},
            }

        store = JobReceiptStore(state_dir=str(self.state_dir))
        jobs = ["snapshot_commit", "pressure_sweep", "tmp_scratch_sweep"]
        blocked_reasons: List[str] = []
        safety_summaries: Dict[str, Any] = {}

        for job in jobs:
            try:
                data = store.read(job)
            except Exception:
                continue

            term = data.get("last_terminal")
            if term:
                s_info = term.get("safety") or {}
                s_status = s_info.get("status") if isinstance(s_info, dict) else None
                s_reason = s_info.get("reason") if isinstance(s_info, dict) else None
                safety_summaries[job] = s_info

                if term.get("outcome") == "blocked_safety" or s_status == "blocked_safety":
                    blocked_reasons.append(f"{job}: {s_reason or 'blocked_safety'}")

        if blocked_reasons:
            return {
                "status": STATUS_DEGRADED,
                "reason": "safety_blocks_present: " + "; ".join(blocked_reasons),
                "owner": "safety_policies",
                "source": "receipt_safety_inspection",
                "paths": policy_paths,
                "time": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "details": safety_summaries,
            }

        return {
            "status": STATUS_HEALTHY,
            "reason": "no_active_safety_blocks",
            "owner": "safety_policies",
            "source": "receipt_safety_inspection",
            "paths": policy_paths,
            "time": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "details": safety_summaries,
        }

    def evaluate_deployed_identity(self) -> Dict[str, Any]:
        """Evaluate deployed.json manifest, package hashes, and source checkout sync."""
        deployed_file = self.state_dir / "deployed.json"
        if not deployed_file.exists():
            return {
                "status": STATUS_UNKNOWN,
                "reason": "deployed_json_missing",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": None,
                "details": {},
            }

        try:
            with open(deployed_file, "r", encoding="utf-8") as f:
                dep_data = json.load(f)
        except Exception as exc:
            return {
                "status": STATUS_INVALID,
                "reason": f"deployed_json_malformed: {exc}",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": None,
                "details": {},
            }

        if not isinstance(dep_data, dict):
            return {
                "status": STATUS_INVALID,
                "reason": "deployed_json_not_object",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": None,
                "details": {},
            }

        if dep_data.get("schema_version") != 1:
            return {
                "status": STATUS_INVALID,
                "reason": f"unsupported_deployed_schema_version: {dep_data.get('schema_version')}",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": None,
                "details": {},
            }

        package_root_raw = dep_data.get("package_root")
        package_hashes = dep_data.get("package_hashes")
        source_sha = dep_data.get("source_sha")
        override_state = dep_data.get("override_state")

        if not package_root_raw or not source_sha or not isinstance(package_hashes, dict) or len(package_hashes) == 0:
            return {
                "status": STATUS_INVALID,
                "reason": "empty_or_missing_manifest_or_root",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": None,
                "details": {},
            }

        # Check for traversal / unsafe paths
        for p in package_hashes.keys():
            p_obj = Path(p)
            if p.startswith("/") or p_obj.is_absolute() or ".." in p_obj.parts:
                return {
                    "status": STATUS_INVALID,
                    "reason": "unsafe_manifest_paths",
                    "owner": "deployed_identity",
                    "source": str(deployed_file),
                    "paths": [str(deployed_file)],
                    "time": None,
                    "details": {},
                }

        pkg_root = Path(package_root_raw).expanduser().resolve()
        if not pkg_root.is_dir():
            return {
                "status": STATUS_DEGRADED,
                "reason": f"package_root_directory_missing ({pkg_root})",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": dep_data.get("deployed_at"),
                "details": {},
            }

        # Verify hashes of package files
        mismatch_files = []
        for rel_path, exp_hash in package_hashes.items():
            target_f = pkg_root / rel_path
            if not target_f.is_file() or sha256_file(target_f) != exp_hash:
                mismatch_files.append(rel_path)

        if mismatch_files:
            return {
                "status": STATUS_DEGRADED,
                "reason": f"package_hash_mismatch_on_{len(mismatch_files)}_file(s)",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": dep_data.get("deployed_at"),
                "details": {"mismatched_files": mismatch_files[:10]},
            }

        # Override state check
        if override_state:
            return {
                "status": STATUS_DEGRADED,
                "reason": f"override_state_active ({override_state})",
                "owner": "deployed_identity",
                "source": str(deployed_file),
                "paths": [str(deployed_file)],
                "time": dep_data.get("deployed_at"),
                "details": {"override_state": override_state},
            }

        # Query source checkout if source_root provided
        source_root_raw = dep_data.get("source_root")
        source_head_sha: Optional[str] = None
        if source_root_raw:
            sr = Path(source_root_raw).expanduser().resolve()
            if (sr / ".git").exists():
                try:
                    proc = subprocess.run(
                        ["git", "-C", str(sr), "rev-parse", "HEAD"],
                        capture_output=True,
                        text=True,
                        timeout=5,
                        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
                    )
                    if proc.returncode == 0 and proc.stdout.strip():
                        source_head_sha = proc.stdout.strip()
                except Exception:
                    pass

        details = {
            "installed_package": {
                "source_sha": source_sha,
                "installed_version": dep_data.get("installed_version"),
                "package_root": str(pkg_root),
                "deployed_at": dep_data.get("deployed_at"),
                "manifest_files_count": len(package_hashes),
            },
            "source_checkout": {
                "source_root": source_root_raw,
                "head_sha": source_head_sha,
                "matches_deploy_sha": (source_head_sha == source_sha) if source_head_sha else None,
            },
        }

        return {
            "status": STATUS_HEALTHY,
            "reason": "deployed_package_verified_clean",
            "owner": "deployed_identity",
            "source": str(deployed_file),
            "paths": [str(deployed_file)],
            "time": dep_data.get("deployed_at"),
            "details": details,
        }

    def evaluate(self, publication_only: bool = False) -> Dict[str, Any]:
        """Run full evaluation and roll up overall status."""
        checked_at = self.now.strftime("%Y-%m-%dT%H:%M:%SZ")

        if publication_only:
            pub = self.evaluate_publication()
            return {
                "schema_version": SCHEMA_VERSION,
                "checked_at": checked_at,
                "status": pub["status"],
                "dimensions": {
                    "publication": pub,
                },
            }

        dimensions = {
            "fleet": self.evaluate_fleet(),
            "measurement": self.evaluate_measurement(),
            "publication": self.evaluate_publication(),
            "action_outcome": self.evaluate_action_outcome(),
            "safety": self.evaluate_safety(),
            "deployed_identity": self.evaluate_deployed_identity(),
        }

        # Overall rollup:
        # Any invalid -> invalid
        # Else any degraded -> degraded
        # Else any unknown -> unknown
        # Else -> healthy
        statuses = [d["status"] for d in dimensions.values()]
        if STATUS_INVALID in statuses:
            overall = STATUS_INVALID
        elif STATUS_DEGRADED in statuses:
            overall = STATUS_DEGRADED
        elif STATUS_UNKNOWN in statuses:
            overall = STATUS_UNKNOWN
        else:
            overall = STATUS_HEALTHY

        return {
            "schema_version": SCHEMA_VERSION,
            "checked_at": checked_at,
            "status": overall,
            "dimensions": dimensions,
        }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only typed status join for Disk Magician")
    parser.add_argument("--json", action="store_true", help="Output status structure in JSON format")
    parser.add_argument("--state-dir", help="Operational state directory (receipts, deployed.json)")
    parser.add_argument("--state-repo", help="Artifact Git repository (snapshots, ledgers)")
    parser.add_argument("--fleet-json", help="Path to fixture typed fleet JSON file")
    parser.add_argument("--now", help="Fixed evaluation time (ISO-8601 UTC string or epoch seconds)")
    parser.add_argument("--publication-only", action="store_true", help="Evaluate only the publication dimension")

    parser.add_argument("--strict-ledger-max-age-hours", type=float, default=48.0, help="Max age for strict ledger (hours)")
    parser.add_argument("--snapshot-commit-max-age-minutes", type=float, default=90.0, help="Max age for snapshot commit (minutes)")
    parser.add_argument("--pressure-sweep-max-age-minutes", type=float, default=90.0, help="Max age for pressure sweep (minutes)")
    parser.add_argument("--tmp-scratch-sweep-max-age-hours", type=float, default=3.0, help="Max age for tmp scratch sweep (hours)")

    args = parser.parse_args(argv)

    now_dt: Optional[datetime] = None
    if args.now:
        now_dt = parse_utc_timestamp(args.now)
        if not now_dt:
            print(f"ERROR: invalid --now value: {args.now}", file=sys.stderr)
            return EXIT_INVALID

    evaluator = DiskStatusEvaluator(
        state_dir=Path(args.state_dir) if args.state_dir else None,
        state_repo=Path(args.state_repo) if args.state_repo else None,
        now=now_dt,
        fleet_json=Path(args.fleet_json) if args.fleet_json else None,
        strict_ledger_max_age_hours=args.strict_ledger_max_age_hours,
        snapshot_commit_max_age_minutes=args.snapshot_commit_max_age_minutes,
        pressure_sweep_max_age_minutes=args.pressure_sweep_max_age_minutes,
        tmp_scratch_sweep_max_age_hours=args.tmp_scratch_sweep_max_age_hours,
    )

    result = evaluator.evaluate(publication_only=args.publication_only)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Disk Magician Status: {result['status'].upper()} (checked: {result['checked_at']})")
        for dim_name, dim_data in result["dimensions"].items():
            print(f"  [{dim_data['status'].upper():<8}] {dim_name:<18} {dim_data['reason']}")

    status = result["status"]
    if status == STATUS_HEALTHY:
        return EXIT_HEALTHY
    elif status == STATUS_INVALID:
        return EXIT_INVALID
    else:
        return EXIT_DEGRADED_OR_UNKNOWN


if __name__ == "__main__":
    sys.exit(main())

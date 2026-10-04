#!/usr/bin/env python3
"""scripts/disk_status.py — Read-only typed status join across Disk Magician subsystems.

Evaluates six operational dimensions:
1. fleet: launchd automation health and liveness
2. measurement: total-coverage snapshot freshness and completeness
3. publication: strict 5G ledger integrity, canonical commit freshness, and renderer sidecar
4. action_outcome: typed receipts for snapshot_commit, pressure_sweep, and tmp_scratch_sweep
5. safety: safety policy compliance, non-mutation evidence, and blocked states
6. deployed_identity: deployed.json manifest verification, package hashes, source sync, and fleet binding

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
        try:
            return datetime.fromtimestamp(ts, tz=timezone.utc)
        except (OverflowError, ValueError, OSError):
            return None
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


def make_result(
    status: str,
    reason: str,
    owner: str,
    source: str,
    paths: Optional[List[str]] = None,
    time: Optional[str] = None,
    details: Optional[Dict[str, Any]] = None,
    **extra: Any,
) -> Dict[str, Any]:
    """Concise builder for standard dimension result dictionary."""
    res = {
        "status": status,
        "reason": reason,
        "owner": owner,
        "source": source,
        "paths": paths if paths is not None else ([source] if source and source != "platform_check" and not source.startswith("receipt_") else []),
        "time": time,
        "details": details if details is not None else {},
    }
    res.update(extra)
    return res


def read_json_file(path: Path) -> Tuple[Optional[Any], Optional[str]]:
    """Returns (data, None) on success, (None, error_str) on JSON error, (None, None) if file does not exist."""
    if not path.is_file():
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), None
    except Exception as exc:
        return None, str(exc)


def ignored_package_file(rel: str) -> bool:
    """Ignore only Python bytecode files and caches. All launchd plists are included."""
    parts = rel.replace("\\", "/").split("/")
    return "__pycache__" in parts or any(p.endswith(".pyc") for p in parts)


def normalize_fleet_data(data: Any, source: str, paths: Optional[List[str]] = None) -> Dict[str, Any]:
    """Validate and normalize launchd fleet data from either fixture or subprocess."""
    if not isinstance(data, dict):
        return make_result(
            status=STATUS_INVALID,
            reason="fleet_data_not_object",
            owner="launchd_fleet",
            source=source,
            paths=paths,
            records=[],
        )
    schema_v = data.get("schema_version")
    if schema_v not in (None, 1):
        return make_result(
            status=STATUS_INVALID,
            reason=f"unsupported_fleet_schema_version: {schema_v}",
            owner="launchd_fleet",
            source=source,
            paths=paths,
            records=[],
        )
    raw_status = data.get("status")
    if raw_status not in (STATUS_HEALTHY, STATUS_DEGRADED, STATUS_UNKNOWN, STATUS_INVALID):
        return make_result(
            status=STATUS_INVALID,
            reason=f"invalid_fleet_status_enum: {raw_status}",
            owner="launchd_fleet",
            source=source,
            paths=paths,
            records=[],
        )
    records = data.get("records")
    if not isinstance(records, list):
        return make_result(
            status=STATUS_INVALID,
            reason="fleet_records_not_list",
            owner="launchd_fleet",
            source=source,
            paths=paths,
            records=[],
        )

    # Classify observed consumers
    package_consumers = []
    repo_root_consumers = []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        kind = rec.get("execution_kind")
        consumer_entry = {
            "label": rec.get("label"),
            "entrypoint": rec.get("entrypoint") or rec.get("observed_entrypoint"),
            "program_arguments": rec.get("program_arguments") or rec.get("observed_program_arguments"),
            "execution_root": rec.get("execution_root") or rec.get("observed_execution_root"),
            "identity_source": rec.get("identity_source"),
        }
        if kind == "packaged_cli":
            package_consumers.append(consumer_entry)
        elif kind == "repo_helper":
            repo_root_consumers.append(consumer_entry)

    details = {
        "consumers": {
            "package_consumers": package_consumers,
            "repo_root_consumers": repo_root_consumers,
        }
    }
    checked_at = data.get("checked_at")
    return make_result(
        status=raw_status,
        reason=data.get("reason", f"fleet_status_{raw_status}"),
        owner="launchd_fleet",
        source=source,
        paths=paths or ([source] if source else []),
        time=checked_at,
        details=details,
        records=records,
    )


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
                return make_result(
                    status=STATUS_UNKNOWN,
                    reason="fleet_json_file_not_found",
                    owner="launchd_fleet",
                    source=str(self.fleet_json),
                    records=[],
                )
            data, err = read_json_file(self.fleet_json)
            if err:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"fleet_json_malformed: {err}",
                    owner="launchd_fleet",
                    source=str(self.fleet_json),
                    records=[],
                )
            return normalize_fleet_data(data, source=str(self.fleet_json))

        # Subprocess evaluation
        if sys.platform != "darwin":
            return make_result(
                status=STATUS_HEALTHY,
                reason="launchd_not_applicable_on_platform",
                owner="launchd_fleet",
                source="platform_check",
                paths=[],
                time=self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                records=[],
            )

        check_script = SCRIPTS_DIR / "check_launchd_fleet.sh"
        if not check_script.is_file():
            return make_result(
                status=STATUS_UNKNOWN,
                reason="check_launchd_fleet_script_missing",
                owner="launchd_fleet",
                source=str(check_script),
                records=[],
            )

        try:
            proc = subprocess.run(
                ["/bin/bash", str(check_script), "--fleet-only", "--json"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            stdout = proc.stdout.strip()
            if proc.returncode in (0, 1, 2) and stdout.startswith("{"):
                try:
                    data = json.loads(stdout)
                    return normalize_fleet_data(data, source=str(check_script))
                except Exception as exc:
                    return make_result(
                        status=STATUS_INVALID,
                        reason=f"check_launchd_fleet_output_malformed_json: {exc}",
                        owner="launchd_fleet",
                        source=str(check_script),
                        records=[],
                    )
        except Exception:
            pass

        return make_result(
            status=STATUS_UNKNOWN,
            reason="check_launchd_fleet_unavailable_or_unsupported",
            owner="launchd_fleet",
            source=str(check_script),
            records=[],
        )

    def evaluate_measurement(self) -> Dict[str, Any]:
        """Evaluate disk_snapshot.json measurement freshness, coverage, and completeness."""
        snapshot_file = self.state_repo / "snapshots" / "disk_snapshot.json"
        if not snapshot_file.exists():
            return make_result(
                status=STATUS_UNKNOWN,
                reason="disk_snapshot_missing",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )

        data, err = read_json_file(snapshot_file)
        if err:
            return make_result(
                status=STATUS_INVALID,
                reason=f"disk_snapshot_malformed: {err}",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )

        if not isinstance(data, dict):
            return make_result(
                status=STATUS_INVALID,
                reason="disk_snapshot_not_object",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )

        if data.get("schema_version") not in (None, 1, 2):
            return make_result(
                status=STATUS_INVALID,
                reason=f"unsupported_snapshot_schema_version: {data.get('schema_version')}",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )

        meta = data.get("snapshot_metadata")
        if meta is not None and not isinstance(meta, dict):
            return make_result(
                status=STATUS_INVALID,
                reason="snapshot_metadata_not_object",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )
        meta_dict = meta if isinstance(meta, dict) else {}

        raw_ts = meta_dict.get("captured_at") or data.get("timestamp") or data.get("captured_at")
        captured_dt = parse_utc_timestamp(raw_ts)

        if not captured_dt:
            return make_result(
                status=STATUS_DEGRADED,
                reason="snapshot_timestamp_missing_or_invalid",
                owner="disk_snapshot",
                source=str(snapshot_file),
            )

        if captured_dt > self.now + timedelta(minutes=5):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"snapshot_timestamp_in_future ({raw_ts})",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Check coverage
        cov_fresh = data.get("coverage_fresh_pct")
        if cov_fresh is None:
            cov_fresh = meta_dict.get("coverage_pct") if "coverage_pct" in meta_dict else data.get("snapshot_coverage_pct")

        if (
            cov_fresh is None
            or isinstance(cov_fresh, bool)
            or not isinstance(cov_fresh, (int, float))
            or not math.isfinite(cov_fresh)
            or cov_fresh < 0.0
            or cov_fresh > 100.0
        ):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"incoherent_or_missing_coverage_pct: {cov_fresh}",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details={"coverage_fresh_pct": cov_fresh},
            )

        # Measurement status: authoritative nested field in snapshot_metadata
        meta_status = meta_dict.get("measurement_status")
        top_status = data.get("measurement_status")
        raw_status = meta_status if meta_status is not None else top_status

        if raw_status is None:
            return make_result(
                status=STATUS_UNKNOWN,
                reason="measurement_status_missing",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        if not isinstance(raw_status, str) or raw_status not in ("complete", "partial", "timeout", "empty"):
            return make_result(
                status=STATUS_INVALID,
                reason=f"measurement_status_invalid_enum: {raw_status}",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Budget exhausted: authoritative nested field in snapshot_metadata
        meta_budget = meta_dict.get("measurement_budget_exhausted")
        top_budget = data.get("measurement_budget_exhausted")
        raw_budget = meta_budget if meta_budget is not None else top_budget

        if raw_budget is not None and not isinstance(raw_budget, bool):
            return make_result(
                status=STATUS_INVALID,
                reason=f"measurement_budget_exhausted_not_boolean: {raw_budget}",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )
        budget_exhausted = bool(raw_budget)

        carried_keys = data.get("carried_keys")
        if carried_keys is not None and not isinstance(carried_keys, list):
            return make_result(
                status=STATUS_INVALID,
                reason="carried_keys_not_list",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )
        carried_keys = carried_keys or []

        unmeasured_keys = data.get("unmeasured_keys")
        if unmeasured_keys is not None and not isinstance(unmeasured_keys, list):
            return make_result(
                status=STATUS_INVALID,
                reason="unmeasured_keys_not_list",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )
        unmeasured_keys = unmeasured_keys or []

        details = {
            "captured_at": captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "coverage_fresh_pct": cov_fresh,
            "measurement_status": raw_status,
            "carried_keys_count": len(carried_keys),
            "unmeasured_keys_count": len(unmeasured_keys),
            "measurement_budget_exhausted": budget_exhausted,
        }

        # Age check (max 48 hours for measurement snapshot)
        if self.now - captured_dt > timedelta(hours=48):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"snapshot_stale (captured {captured_dt.strftime('%Y-%m-%d %H:%M:%SZ')})",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        if cov_fresh < 70.0:
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"coverage_below_floor ({cov_fresh:.1f}% < 70.0%)",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        if raw_status != "complete":
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"measurement_status_{raw_status}",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        if carried_keys or unmeasured_keys or budget_exhausted:
            return make_result(
                status=STATUS_DEGRADED,
                reason="measurement_incomplete_carried_or_budget_exhausted",
                owner="disk_snapshot",
                source=str(snapshot_file),
                time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        return make_result(
            status=STATUS_HEALTHY,
            reason="snapshot_complete_and_fresh",
            owner="disk_snapshot",
            source=str(snapshot_file),
            time=captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            details=details,
        )

    def evaluate_publication(self) -> Dict[str, Any]:
        """Evaluate strict 5G ledger integrity, canonical git history, and renderer sidecar."""
        strict_ledger_file = self.state_repo / "ledger" / "topdown-5g.json"
        sidecar_file = self.state_repo / "ledger" / "topdown-5g.status.json"
        partial_file = self.state_repo / "ledger" / "topdown-5g.partial.json"

        paths = [
            str(p)
            for p in (strict_ledger_file, sidecar_file, partial_file)
            if p.exists()
        ]

        # Pre-validate JSON for all three files if they exist
        strict_data = None
        if strict_ledger_file.exists():
            data, err = read_json_file(strict_ledger_file)
            if err:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"strict_ledger_malformed: {err}",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                )
            if not isinstance(data, dict):
                return make_result(
                    status=STATUS_INVALID,
                    reason="strict_ledger_not_object",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                )
            if data.get("schema_version") != 2:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"unsupported_strict_ledger_schema_version: {data.get('schema_version')}",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                )
            if not history_diff:
                return make_result(
                    status=STATUS_INVALID,
                    reason="history_diff_validator_unavailable",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                )
            try:
                history_diff.validate_ledger(data, label=str(strict_ledger_file))
                history_diff.validate_full_attribution_ledger(data, label=str(strict_ledger_file))
            except Exception as exc:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"strict_ledger_integrity_violation: {exc}",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                )
            strict_data = data

        sidecar_data = None
        if sidecar_file.exists():
            data, err = read_json_file(sidecar_file)
            if err:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"sidecar_malformed: {err}",
                    owner="topdown_ledger",
                    source=str(sidecar_file),
                    paths=paths,
                )
            if not isinstance(data, dict):
                return make_result(
                    status=STATUS_INVALID,
                    reason="sidecar_not_object",
                    owner="topdown_ledger",
                    source=str(sidecar_file),
                    paths=paths,
                )
            sc_status = data.get("status")
            if sc_status is not None and (not isinstance(sc_status, str) or sc_status not in ("complete", "partial", "stale")):
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"sidecar_invalid_status: {sc_status}",
                    owner="topdown_ledger",
                    source=str(sidecar_file),
                    paths=paths,
                )
            sidecar_data = data

        partial_data = None
        if partial_file.exists():
            data, err = read_json_file(partial_file)
            if err:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"partial_ledger_malformed: {err}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            if not isinstance(data, dict):
                return make_result(
                    status=STATUS_INVALID,
                    reason="partial_ledger_not_object",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            if data.get("schema_version") != 2:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"unsupported_partial_ledger_schema_version: {data.get('schema_version')}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            if data.get("publication_kind") != "partial":
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"invalid_partial_publication_kind: {data.get('publication_kind')}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            if data.get("canonical") is not False:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"invalid_partial_canonical_flag: {data.get('canonical')}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            part_ts = data.get("captured_at")
            part_dt = parse_utc_timestamp(part_ts)
            if not part_dt:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"partial_ledger_timestamp_missing_or_invalid: {part_ts}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            if part_dt > self.now + timedelta(minutes=5):
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"partial_ledger_timestamp_in_future: {part_ts}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                    time=part_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                )
            if not history_diff:
                return make_result(
                    status=STATUS_INVALID,
                    reason="history_diff_validator_unavailable",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            try:
                history_diff.validate_ledger(data, label=str(partial_file))
            except Exception as exc:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"partial_ledger_integrity_violation: {exc}",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                )
            partial_data = data

        if not strict_data:
            if partial_data:
                return make_result(
                    status=STATUS_DEGRADED,
                    reason="partial_publication_only_no_strict_ledger",
                    owner="topdown_ledger",
                    source=str(partial_file),
                    paths=paths,
                    time=partial_data.get("captured_at"),
                    details={"canonical": False, "publication_kind": "partial"},
                )
            return make_result(
                status=STATUS_UNKNOWN,
                reason="no_topdown_ledger_published",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
                details={"canonical": False},
            )

        # Parse timestamps for comparison
        strict_artifact_dt = parse_utc_timestamp(strict_data.get("captured_at"))
        if not strict_artifact_dt:
            return make_result(
                status=STATUS_DEGRADED,
                reason="strict_ledger_timestamp_missing_or_invalid",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
            )

        if strict_artifact_dt > self.now + timedelta(minutes=5):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"strict_ledger_timestamp_in_future ({strict_data.get('captured_at')})",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
                time=strict_artifact_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        sidecar_status = sidecar_data.get("status") if sidecar_data else None
        sidecar_dt = parse_utc_timestamp(sidecar_data.get("captured_at")) if sidecar_data else None
        partial_dt = parse_utc_timestamp(partial_data.get("captured_at")) if partial_data else None

        # Query Git publication history for strict ledger
        git_commit_dt: Optional[datetime] = None
        if (self.state_repo / ".git").exists():
            try:
                proc = subprocess.run(
                    ["git", "-C", str(self.state_repo), "log", "-1", "--format=%ct", "--", "ledger/topdown-5g.json"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    epoch = int(proc.stdout.strip())
                    git_commit_dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
            except Exception:
                pass

        details = {
            "canonical": True,
            "schema_version": 2,
            "artifact_captured_at": strict_artifact_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "git_commit_time": git_commit_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if git_commit_dt else None,
            "sidecar_status": sidecar_status,
            "partial_time": partial_dt.strftime("%Y-%m-%dT%H:%M:%SZ") if partial_dt else None,
        }

        if git_commit_dt is None:
            return make_result(
                status=STATUS_UNKNOWN,
                reason="missing_git_publication_history",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
                time=strict_artifact_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        if git_commit_dt > self.now + timedelta(minutes=5):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"strict_ledger_git_commit_in_future ({git_commit_dt.strftime('%Y-%m-%dT%H:%M:%SZ')})",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
                time=git_commit_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        max_age = timedelta(hours=self.strict_ledger_max_age_hours)
        if self.now - strict_artifact_dt > max_age or self.now - git_commit_dt > max_age:
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"strict_ledger_stale (> {self.strict_ledger_max_age_hours}h old)",
                owner="topdown_ledger",
                source=str(strict_ledger_file),
                paths=paths,
                time=min(strict_artifact_dt, git_commit_dt).strftime("%Y-%m-%dT%H:%M:%SZ"),
                details=details,
            )

        # Check if newer partial evidence exists
        effective_strict = min(strict_artifact_dt, git_commit_dt)
        partial_evidence_time = max(t for t in (sidecar_dt, partial_dt) if t is not None) if (sidecar_dt or partial_dt) else None

        if (sidecar_status in ("partial", "stale") or partial_data is not None) and partial_evidence_time:
            if partial_evidence_time > effective_strict:
                reason = "newer_partial_ledger_published" if partial_data and (not sidecar_data or sidecar_status not in ("partial", "stale")) else "current_publication_partial_in_renderer_sidecar"
                return make_result(
                    status=STATUS_DEGRADED,
                    reason=f"{reason} (newer partial at {partial_evidence_time.strftime('%Y-%m-%dT%H:%M:%SZ')})",
                    owner="topdown_ledger",
                    source=str(strict_ledger_file),
                    paths=paths,
                    time=partial_evidence_time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    details=details,
                )

        return make_result(
            status=STATUS_HEALTHY,
            reason="strict_ledger_current_and_valid",
            owner="topdown_ledger",
            source=str(strict_ledger_file),
            paths=paths,
            time=effective_strict.strftime("%Y-%m-%dT%H:%M:%SZ"),
            details=details,
        )

    def evaluate_action_outcome(self) -> Dict[str, Any]:
        """Evaluate action outcomes across snapshot_commit, pressure_sweep, and tmp_scratch_sweep."""
        if not JobReceiptStore:
            return make_result(
                status=STATUS_UNKNOWN,
                reason="job_receipt_store_module_unavailable",
                owner="job_receipts",
                source=str(self.state_dir),
                paths=[],
            )

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
                    "latest_attempt": None,
                    "active_records": [],
                    "last_terminal": None,
                    "last_success": None,
                    "last_skipped": None,
                }
                overall_status = STATUS_INVALID
                degraded_reasons.append(f"{job}: receipt corrupt")
                continue

            last_term = data.get("last_terminal")
            active = data.get("active") or []
            last_succ = data.get("last_success")
            last_skip = data.get("last_skipped")

            # Check if an active run exists
            if len(active) > 0:
                interrupted = False
                for act in active:
                    act_start = parse_utc_timestamp(act.get("times", {}).get("started_at"))
                    if act_start and (self.now - act_start > timedelta(hours=4)):
                        interrupted = True
                        break

                reason_str = "active_run_started_without_terminal_interrupted" if interrupted else "active_run_in_progress"
                job_statuses[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": reason_str,
                    "latest_outcome": "unknown",
                    "ended_at": None,
                    "latest_attempt": active[-1],
                    "active_records": active,
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                msg = f"{job}: active run interrupted ({reason_str})" if interrupted else f"{job}: {reason_str}"
                degraded_reasons.append(msg)
                continue

            if not last_term:
                job_statuses[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "no_receipts_recorded",
                    "latest_outcome": None,
                    "ended_at": None,
                    "latest_attempt": None,
                    "active_records": [],
                    "last_terminal": None,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                degraded_reasons.append(f"{job}: no receipts")
                continue

            term_outcome = last_term.get("outcome")
            ended_at_str = last_term.get("times", {}).get("ended_at")
            ended_dt = parse_utc_timestamp(ended_at_str)

            if not ended_dt:
                job_statuses[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"receipt_timestamp_missing_or_invalid: {ended_at_str}",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                    "latest_attempt": last_term,
                    "active_records": [],
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                degraded_reasons.append(f"{job}: ended_at missing/invalid")
                continue

            if ended_dt > self.now + timedelta(minutes=5):
                job_statuses[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"receipt_timestamp_in_future ({ended_at_str})",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                    "latest_attempt": last_term,
                    "active_records": [],
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                degraded_reasons.append(f"{job}: future ended_at")
                continue

            if self.now - ended_dt > max_age:
                job_statuses[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"receipt_stale (ended {ended_at_str})",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                    "latest_attempt": last_term,
                    "active_records": [],
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
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
                    "latest_attempt": last_term,
                    "active_records": [],
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                degraded_reasons.append(f"{job}: outcome {term_outcome}")
                continue

            if term_outcome in ("skipped_lock", "skipped_threshold"):
                if not last_succ:
                    job_statuses[job] = {
                        "status": STATUS_DEGRADED,
                        "reason": f"{term_outcome}_without_prior_success",
                        "latest_outcome": term_outcome,
                        "ended_at": ended_at_str,
                        "latest_attempt": last_term,
                        "active_records": [],
                        "last_terminal": last_term,
                        "last_success": None,
                        "last_skipped": last_skip,
                    }
                    if overall_status != STATUS_INVALID:
                        overall_status = STATUS_DEGRADED
                    degraded_reasons.append(f"{job}: skip without prior success")
                else:
                    succ_ended_str = last_succ.get("times", {}).get("ended_at")
                    succ_ended_dt = parse_utc_timestamp(succ_ended_str)
                    succ_max_age = max(max_age, timedelta(hours=48))
                    if not succ_ended_dt or (self.now - succ_ended_dt > succ_max_age):
                        job_statuses[job] = {
                            "status": STATUS_DEGRADED,
                            "reason": f"{term_outcome}_with_stale_prior_success",
                            "latest_outcome": term_outcome,
                            "ended_at": ended_at_str,
                            "latest_attempt": last_term,
                            "active_records": [],
                            "last_terminal": last_term,
                            "last_success": last_succ,
                            "last_skipped": last_skip,
                        }
                        if overall_status != STATUS_INVALID:
                            overall_status = STATUS_DEGRADED
                        degraded_reasons.append(f"{job}: stale prior success")
                    elif succ_ended_dt > self.now + timedelta(minutes=5):
                        job_statuses[job] = {
                            "status": STATUS_DEGRADED,
                            "reason": f"{term_outcome}_with_future_prior_success",
                            "latest_outcome": term_outcome,
                            "ended_at": ended_at_str,
                            "latest_attempt": last_term,
                            "active_records": [],
                            "last_terminal": last_term,
                            "last_success": last_succ,
                            "last_skipped": last_skip,
                        }
                        if overall_status != STATUS_INVALID:
                            overall_status = STATUS_DEGRADED
                        degraded_reasons.append(f"{job}: future prior success")
                    else:
                        job_statuses[job] = {
                            "status": STATUS_HEALTHY,
                            "reason": f"{term_outcome}_with_fresh_prior_success",
                            "latest_outcome": term_outcome,
                            "ended_at": ended_at_str,
                            "latest_attempt": last_term,
                            "active_records": [],
                            "last_terminal": last_term,
                            "last_success": last_succ,
                            "last_skipped": last_skip,
                        }
                continue

            if term_outcome in ("success", "success_noop"):
                job_statuses[job] = {
                    "status": STATUS_HEALTHY,
                    "reason": f"terminal_{term_outcome}",
                    "latest_outcome": term_outcome,
                    "ended_at": ended_at_str,
                    "latest_attempt": last_term,
                    "active_records": [],
                    "last_terminal": last_term,
                    "last_success": last_succ,
                    "last_skipped": last_skip,
                }
                continue

            # Unhandled outcome
            job_statuses[job] = {
                "status": STATUS_UNKNOWN,
                "reason": f"unhandled_outcome_{term_outcome}",
                "latest_outcome": term_outcome,
                "ended_at": ended_at_str,
                "latest_attempt": last_term,
                "active_records": [],
                "last_terminal": last_term,
                "last_success": last_succ,
                "last_skipped": last_skip,
            }
            if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                overall_status = STATUS_UNKNOWN
            degraded_reasons.append(f"{job}: unhandled outcome {term_outcome}")

        return make_result(
            status=overall_status,
            reason="; ".join(degraded_reasons) if degraded_reasons else "all_required_jobs_healthy",
            owner="job_receipts",
            source=str(self.state_dir / "receipts"),
            paths=receipt_paths,
            time=self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            details=job_statuses,
        )

    def evaluate_safety(self) -> Dict[str, Any]:
        """Evaluate explicit safety outcomes from receipts and policy file provenance."""
        roots_txt = SCRIPTS_DIR.parent / "config" / "sweeper_roots.txt"
        scratch_sh = SCRIPTS_DIR / "lib" / "scratch_roots.sh"
        policy_paths = [
            str(p) for p in (roots_txt, scratch_sh) if p.exists()
        ]

        if not JobReceiptStore:
            return make_result(
                status=STATUS_UNKNOWN,
                reason="job_receipt_store_module_unavailable",
                owner="safety_policies",
                source="receipt_safety_inspection",
                paths=policy_paths,
            )

        store = JobReceiptStore(state_dir=str(self.state_dir))
        jobs = ["snapshot_commit", "pressure_sweep", "tmp_scratch_sweep"]
        safety_details: Dict[str, Any] = {}
        all_paths = list(policy_paths)
        overall_status = STATUS_HEALTHY
        status_reasons: List[str] = []

        for job in jobs:
            receipt_file = self.state_dir / "receipts" / f"{job}.json"
            if receipt_file.exists():
                all_paths.append(str(receipt_file))

            try:
                data = store.read(job)
            except Exception as exc:
                safety_details[job] = {
                    "status": STATUS_INVALID,
                    "reason": f"receipt_file_corrupt: {exc}",
                }
                overall_status = STATUS_INVALID
                status_reasons.append(f"{job}: corrupt receipt")
                continue

            active = data.get("active") or []
            if len(active) > 0:
                safety_details[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "active_run_in_progress",
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                status_reasons.append(f"{job}: active run in progress")
                continue

            term = data.get("last_terminal")
            if not term:
                safety_details[job] = {
                    "status": STATUS_UNKNOWN,
                    "reason": "no_receipt_recorded",
                }
                if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                    overall_status = STATUS_UNKNOWN
                status_reasons.append(f"{job}: no receipt")
                continue

            s_info = term.get("safety") or {}
            s_status = s_info.get("status") if isinstance(s_info, dict) else None
            s_reason = s_info.get("reason") if isinstance(s_info, dict) else None
            term_outcome = term.get("outcome")

            if term_outcome == "blocked_safety" or s_status == "blocked_safety":
                safety_details[job] = {
                    "status": STATUS_DEGRADED,
                    "reason": f"blocked_safety: {s_reason or 'unspecified'}",
                }
                if overall_status != STATUS_INVALID:
                    overall_status = STATUS_DEGRADED
                status_reasons.append(f"{job}: safety_blocks_present (blocked_safety: {s_reason or 'unspecified'})")
                continue

            if s_status in ("safe", "verified_safe", "not_applicable"):
                if s_reason and isinstance(s_reason, str) and s_reason.strip():
                    safety_details[job] = {
                        "status": STATUS_HEALTHY,
                        "reason": f"{s_status}: {s_reason}",
                    }
                else:
                    safety_details[job] = {
                        "status": STATUS_UNKNOWN,
                        "reason": f"{s_status}_missing_reason",
                    }
                    if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                        overall_status = STATUS_UNKNOWN
                    status_reasons.append(f"{job}: missing safety reason")
                continue

            # delegated, unknown, in_progress, None -> unknown
            safety_details[job] = {
                "status": STATUS_UNKNOWN,
                "reason": f"safety_{s_status or 'missing'}",
            }
            if overall_status not in (STATUS_INVALID, STATUS_DEGRADED):
                overall_status = STATUS_UNKNOWN
            status_reasons.append(f"{job}: safety {s_status or 'missing'}")

        return make_result(
            status=overall_status,
            reason="; ".join(status_reasons) if status_reasons else "all_jobs_verified_safe_or_not_applicable",
            owner="safety_policies",
            source="receipt_safety_inspection",
            paths=all_paths,
            time=self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            details=safety_details,
        )

    def evaluate_deployed_identity(self, fleet_info: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Evaluate deployed.json schema compliance, manifest hashes, source repo, and fleet consumer join."""
        deployed_file = self.state_dir / "deployed.json"
        if not deployed_file.exists():
            return make_result(
                status=STATUS_UNKNOWN,
                reason="deployed_json_missing",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        dep_data, err = read_json_file(deployed_file)
        if err:
            return make_result(
                status=STATUS_INVALID,
                reason=f"deployed_json_malformed: {err}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        if not isinstance(dep_data, dict):
            return make_result(
                status=STATUS_INVALID,
                reason="deployed_json_not_object",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        if dep_data.get("schema_version") != 1:
            return make_result(
                status=STATUS_INVALID,
                reason=f"unsupported_deployed_schema_version: {dep_data.get('schema_version')}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        source_sha = dep_data.get("source_sha")
        if not isinstance(source_sha, str) or len(source_sha) != 40 or not all(c in "0123456789abcdefABCDEF" for c in source_sha):
            return make_result(
                status=STATUS_INVALID,
                reason=f"invalid_source_sha_format: {source_sha}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        installed_version = dep_data.get("installed_version")
        if not isinstance(installed_version, str) or not installed_version.strip():
            return make_result(
                status=STATUS_INVALID,
                reason="installed_version_empty_or_missing",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        deployed_at_str = dep_data.get("deployed_at")
        deployed_dt = parse_utc_timestamp(deployed_at_str)
        if not deployed_dt:
            return make_result(
                status=STATUS_INVALID,
                reason=f"deployed_at_missing_or_invalid: {deployed_at_str}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        if deployed_dt > self.now + timedelta(minutes=5):
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"deployed_at_in_future ({deployed_at_str})",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        package_root_raw = dep_data.get("package_root")
        if not isinstance(package_root_raw, str) or not Path(package_root_raw).is_absolute():
            return make_result(
                status=STATUS_INVALID,
                reason=f"package_root_not_absolute: {package_root_raw}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        source_root_raw = dep_data.get("source_root")
        if not isinstance(source_root_raw, str) or not Path(source_root_raw).is_absolute():
            return make_result(
                status=STATUS_INVALID,
                reason=f"source_root_not_absolute: {source_root_raw}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        package_hashes = dep_data.get("package_hashes")
        if not isinstance(package_hashes, dict) or len(package_hashes) == 0:
            return make_result(
                status=STATUS_INVALID,
                reason="empty_or_missing_manifest",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        override_state = dep_data.get("override_state")
        if not isinstance(override_state, bool):
            return make_result(
                status=STATUS_INVALID,
                reason=f"override_state_not_boolean: {override_state}",
                owner="deployed_identity",
                source=str(deployed_file),
            )

        pkg_root = Path(package_root_raw).resolve()
        if not pkg_root.is_dir():
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"package_root_directory_missing ({pkg_root})",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Check for traversal, unsafe paths, and symlink escapes in package_hashes
        for rel_path, exp_hash in package_hashes.items():
            if not isinstance(rel_path, str) or not isinstance(exp_hash, str) or len(exp_hash) != 64:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"invalid_manifest_entry: {rel_path}",
                    owner="deployed_identity",
                    source=str(deployed_file),
                )
            if rel_path.startswith("/") or ".." in Path(rel_path).parts:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"unsafe_manifest_paths: {rel_path}",
                    owner="deployed_identity",
                    source=str(deployed_file),
                )
            target_f = pkg_root / rel_path
            try:
                resolved_f = target_f.resolve()
                resolved_f.relative_to(pkg_root)
            except Exception:
                return make_result(
                    status=STATUS_INVALID,
                    reason=f"symlink_target_escapes_package_root: {rel_path}",
                    owner="deployed_identity",
                    source=str(deployed_file),
                )

        # Verify hash match and presence of all manifest files
        for rel_path, exp_hash in package_hashes.items():
            target_f = pkg_root / rel_path
            if not target_f.is_file():
                return make_result(
                    status=STATUS_DEGRADED,
                    reason=f"manifest_file_missing_on_disk: {rel_path}",
                    owner="deployed_identity",
                    source=str(deployed_file),
                    time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                )
            if sha256_file(target_f) != exp_hash:
                return make_result(
                    status=STATUS_DEGRADED,
                    reason=f"package_hash_mismatch: {rel_path}",
                    owner="deployed_identity",
                    source=str(deployed_file),
                    time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                )

        # Scan files and symlinks on disk in package_root
        disk_files = []
        for p in pkg_root.rglob("*"):
            if p.is_symlink():
                try:
                    p.resolve().relative_to(pkg_root)
                except Exception:
                    return make_result(
                        status=STATUS_INVALID,
                        reason=f"symlink_target_escapes_package_root: {p.relative_to(pkg_root)}",
                        owner="deployed_identity",
                        source=str(deployed_file),
                    )
            if p.is_file():
                rel = str(p.relative_to(pkg_root)).replace(os.sep, "/")
                if not ignored_package_file(rel):
                    disk_files.append(rel)

        untracked_disk = set(disk_files) - set(package_hashes.keys())
        if untracked_disk:
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"untracked_package_files_on_disk: {sorted(untracked_disk)[:5]}",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Dist-info METADATA check
        dist_info_found = False
        dist_info_version = None
        for candidate in list(pkg_root.parent.glob("disk[-_]magician-*.dist-info/METADATA")) + list(pkg_root.glob("disk[-_]magician-*.dist-info/METADATA")):
            if candidate.is_file():
                dist_info_found = True
                try:
                    for line in candidate.read_text(encoding="utf-8").splitlines():
                        if line.startswith("Version:"):
                            dist_info_version = line.split(":", 1)[1].strip()
                            break
                except Exception:
                    pass
                break

        if dist_info_found and dist_info_version and dist_info_version != installed_version:
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"dist_info_version_mismatch: {dist_info_version} != {installed_version}",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Check override_state
        if override_state is True:
            return make_result(
                status=STATUS_DEGRADED,
                reason="override_state_active_non_production",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                details={"override_state": True},
            )

        # Source checkout verification
        sr = Path(source_root_raw).resolve()
        source_head_sha = None
        source_is_clean = None
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
                status_proc = subprocess.run(
                    ["git", "-C", str(sr), "status", "--porcelain", "--untracked-files=normal"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
                )
                if status_proc.returncode == 0:
                    source_is_clean = (status_proc.stdout.strip() == "")
            except Exception:
                pass

        if source_head_sha is None:
            return make_result(
                status=STATUS_UNKNOWN,
                reason="source_root_not_git_repository_or_rev_parse_failed",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        if source_head_sha != source_sha:
            return make_result(
                status=STATUS_DEGRADED,
                reason=f"source_checkout_diverged_from_deploy ({source_head_sha[:10]} != {source_sha[:10]})",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        if source_is_clean is False:
            return make_result(
                status=STATUS_DEGRADED,
                reason="source_checkout_dirty",
                owner="deployed_identity",
                source=str(deployed_file),
                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )

        # Fleet consumer join validation
        if fleet_info and isinstance(fleet_info, dict):
            records = fleet_info.get("records") or []
            for rec in records:
                if not isinstance(rec, dict):
                    continue
                kind = rec.get("execution_kind")
                if kind == "repo_helper":
                    obs_root = rec.get("execution_root") or rec.get("observed_execution_root")
                    if not obs_root:
                        return make_result(
                            status=STATUS_UNKNOWN,
                            reason=f"repo_helper_missing_observed_provenance: {rec.get('label')}",
                            owner="deployed_identity",
                            source=str(deployed_file),
                            time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                        )
                    if Path(obs_root).resolve() != sr:
                        return make_result(
                            status=STATUS_DEGRADED,
                            reason=f"observed_repo_helper_root_mismatch: {obs_root} != {sr}",
                            owner="deployed_identity",
                            source=str(deployed_file),
                            time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                            details={"observed_root": str(Path(obs_root).resolve()), "source_root": str(sr)},
                        )
                elif kind == "packaged_cli":
                    obs_pkg_root = rec.get("package_root") or rec.get("observed_package_root")
                    if obs_pkg_root:
                        if Path(obs_pkg_root).resolve() != pkg_root:
                            return make_result(
                                status=STATUS_DEGRADED,
                                reason=f"observed_package_root_mismatch: {obs_pkg_root} != {pkg_root}",
                                owner="deployed_identity",
                                source=str(deployed_file),
                                time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                details={"observed_package_root": str(Path(obs_pkg_root).resolve()), "package_root": str(pkg_root)},
                            )
                    launcher = rec.get("launcher_path") or rec.get("observed_launcher")
                    if launcher:
                        launcher_p = Path(launcher)
                        if launcher_p.is_symlink():
                            try:
                                resolved_launcher = launcher_p.resolve()
                                venv_root = pkg_root.parent.parent.parent
                                if not str(resolved_launcher).startswith(str(venv_root)):
                                    return make_result(
                                        status=STATUS_DEGRADED,
                                        reason=f"launcher_venv_mismatch: {resolved_launcher} not in {venv_root}",
                                        owner="deployed_identity",
                                        source=str(deployed_file),
                                        time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                    )
                            except Exception:
                                pass

        consumers = fleet_info.get("details", {}).get("consumers", {}) if fleet_info else {}
        details = {
            "installed_package": {
                "source_sha": source_sha,
                "installed_version": installed_version,
                "package_root": str(pkg_root),
                "deployed_at": deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "manifest_files_count": len(package_hashes),
                "dist_info_version": dist_info_version,
            },
            "source_checkout": {
                "source_root": str(sr),
                "head_sha": source_head_sha,
                "matches_deploy_sha": True,
                "clean": True,
            },
            "fleet_consumers": consumers,
        }

        return make_result(
            status=STATUS_HEALTHY,
            reason="deployed_package_and_source_verified_clean",
            owner="deployed_identity",
            source=str(deployed_file),
            time=deployed_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            details=details,
        )

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

        fleet = self.evaluate_fleet()
        measurement = self.evaluate_measurement()
        pub = self.evaluate_publication()
        action_outcome = self.evaluate_action_outcome()
        safety = self.evaluate_safety()
        deployed = self.evaluate_deployed_identity(fleet_info=fleet)

        dimensions = {
            "fleet": fleet,
            "measurement": measurement,
            "publication": pub,
            "action_outcome": action_outcome,
            "safety": safety,
            "deployed_identity": deployed,
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

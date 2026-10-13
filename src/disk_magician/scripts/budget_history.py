#!/usr/bin/env python3
"""Governor observations through the existing state lock and event log."""
import json
import datetime
import os
import time
from pathlib import Path

import budget_controls as controls
from c14_probe import _run_bounded

TICK_INTERVAL_S = 600
HISTORY_DAYS = 31
GIB = 1 << 30


def _append_locked(state, event):
    raw = json.dumps(event, allow_nan=False) + "\n"
    if len(raw.encode()) > 65536:
        raise ValueError("govern observation exceeds 64 KiB")
    path = Path(state) / "admission" / "events.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(raw)
        handle.flush()


def record_event(state, code, **fields):
    event = dict(fields, event=code, at=time.time())
    controls.locked_mutate(state, lambda data: _append_locked(state, event))


def record_tick(state, now=None, classes_fresh=None, fleet_status="unknown",
                zone=None, outcome="success", colima_status="unknown"):
    """Record a completed tick; readers deduplicate attempts in the same slot.

    History stays in the admission event log, not a growing budget.json array.
    Unknown class/fleet observations remain unknown, never truthy defaults.
    """
    now = time.time() if now is None else float(now)
    if not controls.finite_nonneg(now):
        raise ValueError("invalid observation time")
    fresh = {str(k): v if type(v) is bool else None
             for k, v in (classes_fresh or {}).items()}
    event = dict(event="govern_tick", at=now, slot=int(now // TICK_INTERVAL_S),
                 classes_fresh=fresh, fleet_status=fleet_status,
                 zone=zone, outcome=outcome, colima_status=colima_status)

    def mutate(data):
        _append_locked(state, event)
        data["tick_last_at"] = now
        data["tick_last_slot"] = event["slot"]
        previous = data.get("colima_observed_at")
        if (colima_status == "stopped" and data.get("colima_status") == "stopped"
                and controls.finite_nonneg(previous) and 0 <= now - previous <= 1200):
            data.setdefault("colima_stopped_since", previous)
        elif colima_status == "stopped":
            data["colima_stopped_since"] = now
        else:
            data.pop("colima_stopped_since", None)
        data["colima_status"] = colima_status
        data["colima_observed_at"] = now

    controls.locked_mutate(state, mutate)
    return event


def record_measurement(state, now=None, classes=None, carried=None, used_bytes=None):
    """Retain bounded daily accounting snapshots; unavailable values stay absent."""
    now = time.time() if now is None else float(now)
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    rows = {}
    for name, row in (classes or {}).items():
        value = row.get("used_gb") if isinstance(row, dict) else None
        rows[name] = {"used_gb": value if controls.finite_nonneg(value) else None,
                      "carried": bool(row.get("carried")) if isinstance(row, dict) else True}
    carried = sorted(set(carried or []) | {k for k, v in rows.items()
                                          if v["carried"] or v["used_gb"] is None})
    entry = dict(at=now, day=day, classes=rows, carried=carried,
                 incomplete=not rows or bool(carried), used_bytes=used_bytes)

    def mutate(data):
        old = data.get("measurements", [])
        if not isinstance(old, list):
            raise ValueError("invalid measurement history")
        history = [m for m in old if isinstance(m, dict) and m.get("day") != day
                   and controls.finite_nonneg(m.get("at"))
                   and now - HISTORY_DAYS * 86400 <= m["at"] <= now]
        history.append(entry)
        data["measurements"] = sorted(history, key=lambda m: m["at"])[-HISTORY_DAYS:]

    controls.locked_mutate(state, mutate)
    return entry


def collect_fleet_health(state=None, now=None, deadline_at=None, bin_path=None):
    """Read the inventory-derived fleet API within the tick's monotonic deadline."""
    script = bin_path or os.environ.get("DISK_MAGICIAN_FLEET_BIN") or str(
        Path(__file__).resolve().parent / "check_launchd_fleet.sh")
    try:
        result = _run_bounded(["/bin/bash", script, "--fleet-only", "--json"],
                              cap=20, deadline=deadline_at)
        if result is None:
            return "unknown", None
        rc, raw = result
        data = json.loads(raw)
        records = data.get("records")
        if (type(data.get("schema_version")) is not int or not isinstance(records, list)
                or not records or not all(isinstance(r, dict) for r in records)):
            return "unknown", None
        status = data.get("status")
        if status == "healthy" and rc == 0 and all(r.get("status") == "healthy" for r in records):
            return "healthy", 0.0
        return ("degraded", 0.0) if status == "degraded" else ("unknown", None)
    except (OSError, ValueError, TypeError):
        return "unknown", None


def collect_colima_status(deadline_at=None):
    """Read Colima's JSON instance status; a failed probe never means stopped."""
    try:
        result = _run_bounded([os.environ.get("DISK_MAGICIAN_COLIMA_BIN", "colima"),
                               "list", "--json"], cap=5, deadline=deadline_at)
        if result is None or result[0] != 0:
            return "unknown"
        rows = [json.loads(line) for line in result[1].splitlines() if line.strip()]
        row = next((r for r in rows if isinstance(r, dict) and r.get("name") == "default"), None)
        return {"Running": "running", "Stopped": "stopped"}.get(row.get("status"), "unknown") if row else "unknown"
    except (OSError, ValueError, TypeError):
        return "unknown"


def measure_parked(state, deadline_at=None, now=None):
    """Measure the reaper's fresh parked verdicts, without reclassifying owners."""
    import job_receipt
    now = time.time() if now is None else now
    result = dict(status="unknown", measured_at=now, bytes=None, source="worktree_reap_leases")
    receipt = job_receipt.get_last_receipt("worktree_reap", str(state))
    try:
        ended = datetime.datetime.fromisoformat(receipt["times"]["ended_at"].replace("Z", "+00:00")).timestamp()
        if receipt.get("outcome") != "success" or not 0 <= now - ended <= 86400:
            return result
        paths = set()
        for path in (Path(state) / "worktree_leases").glob("*.json"):
            row = controls.read_json(path)
            if not isinstance(row, dict):
                return result
            if row.get("last_verdict") != "kept:expired_owner_alive" or row.get("released_at"):
                continue
            checked = datetime.datetime.fromisoformat(row["last_checked_at"].replace("Z", "+00:00")).timestamp()
            target = row.get("path")
            if not 0 <= now - checked <= 86400 or not isinstance(target, str) or not os.path.isdir(target):
                return result
            paths.add(os.path.realpath(target))
        if not paths:
            return dict(result, status="ok", bytes=0)
        measured = _run_bounded([os.environ.get("DISK_MAGICIAN_DU_BIN", "du"), "-sk", *sorted(paths)],
                                 cap=20, deadline=deadline_at)
        if measured is None or measured[0] != 0:
            return result
        values = [int(line.split()[0]) * 1024 for line in measured[1].splitlines()]
        if len(values) != len(paths) or any(value < 0 for value in values):
            return result
        return dict(result, status="ok", bytes=sum(values), paths=len(paths))
    except (AttributeError, KeyError, TypeError, ValueError, OSError):
        return result

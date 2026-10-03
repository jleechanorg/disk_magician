#!/usr/bin/env python3
"""Read-only launchd inventory and installed-fleet status.

The committed launchd files are the catalog.  This module deliberately does
not maintain a second registry: the only synthetic entries are the primary
snapshot job emitted inline by ``disk_magician.sh`` and its receipt owner.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _strip_comments(data: bytes) -> bytes:
    # XML comments are the only reason plistlib cannot parse some committed
    # templates (their comments contain ``--``).  Removing comments is safe;
    # unlike regex extraction, no job semantics are guessed.
    return re.sub(rb"<!--.*?-->", b"", data, flags=re.DOTALL)


def parse_plist(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Parse a plist without ever writing to it."""
    try:
        proc = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if proc.returncode == 0:
            value = json.loads(proc.stdout)
        else:
            value = plistlib.loads(_strip_comments(path.read_bytes()))
    except (OSError, subprocess.TimeoutExpired, ValueError, plistlib.InvalidFileException) as exc:
        return None, f"parse failed: {exc}"
    if not isinstance(value, dict):
        return None, "top-level plist is not a dictionary"
    return value, None


def _schedule(data: dict[str, Any]) -> dict[str, Any] | None:
    if "StartInterval" in data:
        return {"StartInterval": data["StartInterval"]}
    if "StartCalendarInterval" in data:
        return {"StartCalendarInterval": data["StartCalendarInterval"]}
    if data.get("RunAtLoad") is True:
        return {"RunAtLoad": True}
    return None


def _classify(label: str, data: dict[str, Any], source: str) -> tuple[str, str]:
    args = data.get("ProgramArguments")
    args = args if isinstance(args, list) else []
    first = str(args[0]) if args else ""
    root = data.get("UserName") == "root" or label.endswith("-frontier-root")
    if root or label == "com.disk-magician.apfs-snapshots":
        return "system", "system"
    if any("/.local/bin/diskm" in str(arg) for arg in args):
        return "user", "packaged_cli"
    if first.endswith("/bash") or "/scripts/" in " ".join(map(str, args)):
        return "user", "repo_helper"
    return "user", "system"


def _owners(label: str, args: list[Any]) -> tuple[str, str]:
    joined = " ".join(map(str, args))
    if label == "com.jleechanorg.disk-magician" or "snapshot_commit.sh" in joined:
        receipt = "snapshot_commit.sh"
    elif "pressure_sweep.sh" in joined:
        receipt = "pressure_sweep.sh"
    elif "tmp_scratch_sweep.sh" in joined:
        receipt = "tmp_scratch_sweep.sh"
    else:
        receipt = "unknown"
    if "frontier" in label:
        coverage = "disk_frontier_scan.py" if label.endswith("-root") else "disk_frontier_scan.sh"
    elif label == "com.jleechanorg.disk-magician" or "snapshot_commit.sh" in joined:
        coverage = "snapshot_commit.sh"
    else:
        coverage = "unknown"
    return receipt, coverage


def _record_from_data(label: str, data: dict[str, Any], source: str) -> dict[str, Any]:
    args = data.get("ProgramArguments")
    args = args if isinstance(args, list) else []
    domain, execution_kind = _classify(label, data, source)
    receipt_owner, coverage_owner = _owners(label, args)
    return {
        "label": label,
        "domain": domain,
        "plist_path": source,
        "status": "catalog",
        "reason": "derived from committed launchd source",
        "entrypoint": str(args[0]) if args else "unknown",
        "args": [str(arg) for arg in args],
        "schedule": _schedule(data),
        "execution_kind": execution_kind,
        "receipt_owner": receipt_owner,
        "coverage_owner": coverage_owner,
        "source_path": source,
    }


def _primary_record(repo_root: Path) -> dict[str, Any]:
    source = str(repo_root / "disk_magician.sh")
    home = os.environ.get("HOME", "~")
    data = {
        "ProgramArguments": [f"{home}/.local/bin/diskm", "snapshot"],
        "StartInterval": 1800,
        "RunAtLoad": True,
    }
    return _record_from_data("com.jleechanorg.disk-magician", data, source)


def catalog(repo_root: Path) -> tuple[list[dict[str, Any]], list[str]]:
    launchd = repo_root / "launchd"
    records: list[dict[str, Any]] = []
    paths: list[str] = []
    for path in sorted(launchd.glob("*.plist")) + sorted(launchd.glob("*.plist.template")):
        parsed, error = parse_plist(path)
        paths.append(str(path))
        if parsed is None:
            # Keep malformed source visible to callers as an invalid catalog
            # record; status mode must not silently drop an expected job.
            records.append({
                "label": path.name.removesuffix(".template").removesuffix(".plist"),
                "domain": "unknown",
                "plist_path": str(path),
                "status": "invalid",
                "reason": error or "invalid plist",
                "entrypoint": "unknown",
                "args": [],
                "schedule": None,
                "execution_kind": "unknown",
                "receipt_owner": "unknown",
                "coverage_owner": "unknown",
                "source_path": str(path),
            })
            continue
        label = parsed.get("Label")
        if not isinstance(label, str) or not label:
            records.append({
                "label": path.name,
                "domain": "unknown",
                "plist_path": str(path),
                "status": "invalid",
                "reason": "missing top-level Label",
                "entrypoint": "unknown",
                "args": [],
                "schedule": None,
                "execution_kind": "unknown",
                "receipt_owner": "unknown",
                "coverage_owner": "unknown",
                "source_path": str(path),
            })
            continue
        records.append(_record_from_data(label, parsed, str(path)))
    records.append(_primary_record(repo_root))
    records.sort(key=lambda item: item["label"])
    return records, paths + [str(repo_root / "disk_magician.sh")]


def _run_launchctl(domain: str) -> tuple[set[str], str | None]:
    target = ["launchctl", "list"]
    if domain == "system":
        # ``launchctl list`` is the system-domain query when run as root; on a
        # normal user ask explicitly so the failure is reported as unknown.
        target = ["launchctl", "list", "system"]
    try:
        proc = subprocess.run(target, capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return set(), f"launchctl unavailable: {exc}"
    if proc.returncode != 0:
        return set(), f"launchctl unavailable (exit {proc.returncode})"
    labels: set[str] = set()
    for line in proc.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 3:
            labels.add(fields[2])
        elif line.strip():
            fields = line.split()
            if len(fields) >= 3:
                labels.add(fields[-1])
    return labels, None


def _installed_path(record: dict[str, Any]) -> Path:
    home = Path(os.environ.get("HOME", "~")).expanduser()
    if record["domain"] == "system":
        return Path(os.environ.get("DISK_MAGICIAN_LAUNCHDAEMONS_DIR", "/Library/LaunchDaemons")) / f"{record['label']}.plist"
    return Path(os.environ.get("DISK_MAGICIAN_LAUNCHAGENTS_DIR", str(home / "Library/LaunchAgents"))) / f"{record['label']}.plist"


def fleet(repo_root: Path) -> dict[str, Any]:
    records, source_paths = catalog(repo_root)
    platform_hint = os.environ.get("DISK_MAGICIAN_OSTYPE")
    if platform_hint is None:
        platform_hint = os.environ.get("OSTYPE", "") or sys.platform
    darwin = platform_hint.startswith("darwin")
    source_paths.extend(str(_installed_path(record)) for record in records)
    if not darwin:
        for record in records:
            record.update(plist_path=str(_installed_path(record)), status="unknown", reason="launchd not applicable on non-macOS")
        status = "unknown"
    else:
        loaded: dict[str, set[str]] = {}
        errors: dict[str, str | None] = {}
        for domain in ("user", "system"):
            loaded[domain], errors[domain] = _run_launchctl(domain)
        for record in records:
            installed = _installed_path(record)
            record["plist_path"] = str(installed)
            if not installed.is_file():
                record.update(status="degraded", reason="installed plist missing")
                continue
            parsed, error = parse_plist(installed)
            if parsed is None:
                record.update(status="invalid", reason=error or "invalid installed plist")
                continue
            if parsed.get("Label") != record["label"]:
                record.update(status="invalid", reason="installed plist Label does not match expected label")
                continue
            if errors[record["domain"]]:
                record.update(status="unknown", reason=errors[record["domain"]])
            elif record["label"] in loaded[record["domain"]]:
                record.update(status="healthy", reason="plist valid and exact label is loaded")
            else:
                record.update(status="degraded", reason="plist valid but exact label is not loaded")
        states = {record["status"] for record in records}
        if "invalid" in states:
            status = "invalid"
        elif "degraded" in states:
            status = "degraded"
        elif "unknown" in states:
            status = "unknown"
        else:
            status = "healthy"
    return {"schema_version": 1, "status": status, "checked_at": _now(), "source_paths": sorted(set(source_paths)), "records": records}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="read-only disk_magician launchd inventory")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--json", action="store_true", help="emit installed fleet status JSON")
    args = parser.parse_args(argv)
    result = fleet(Path(args.repo_root).resolve())
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "healthy" else 1


if __name__ == "__main__":
    raise SystemExit(main())

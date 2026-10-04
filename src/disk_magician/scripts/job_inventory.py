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
    plutil_unavailable = False
    try:
        proc = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        # Linux and minimal test images do not provide Apple's plutil.  The
        # standard-library parser is sufficient once XML comments are removed.
        plutil_unavailable = True
        proc = None
    if proc is not None and proc.returncode == 0:
        try:
            value = json.loads(proc.stdout)
        except (TypeError, ValueError) as exc:
            return None, f"invalid JSON from plutil: {exc}"
    else:
        try:
            value = plistlib.loads(_strip_comments(path.read_bytes()))
        except (OSError, ValueError, plistlib.InvalidFileException) as exc:
            if plutil_unavailable:
                return None, f"parse failed without plutil: {exc}"
            return None, f"parse failed: {exc}"
    try:
        is_dict = isinstance(value, dict)
    except TypeError:
        is_dict = False
    if not is_dict:
        return None, "top-level plist is not a dictionary"
    return value, None


def _strip_suffix(value: str, suffix: str) -> str:
    """Python 3.8-compatible suffix removal."""
    return value[:-len(suffix)] if suffix and value.endswith(suffix) else value


def _catalog_label(path: Path) -> str:
    name = _strip_suffix(path.name, ".template")
    return _strip_suffix(name, ".plist")


def _execution_root(args: list[Any]) -> str | None:
    """Return a concrete repo/home root when the command line identifies one."""
    for raw_arg in args:
        arg = str(raw_arg)
        if "/scripts/" in arg:
            root, _ = arg.split("/scripts/", 1)
            if root and not root.startswith("@"):
                return root
        marker = "/.local/bin/diskm"
        if marker in arg:
            root, _ = arg.split(marker, 1)
            if root and not root.startswith("@"):
                return root
        if "/libexec/" in arg and not arg.startswith("@"):
            parent = str(Path(arg).parent)
            if parent and parent != ".":
                return parent
    return None


def _materialize_args(args: list[Any], repo_root: Path) -> list[str]:
    home = os.environ.get("HOME", "~")
    bash = os.environ.get("DISK_MAGICIAN_BASH")
    if not bash:
        for candidate in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"):
            if os.path.exists(candidate):
                bash = candidate
                break
    bash = bash or "/bin/bash"
    replacements = {
        "@HOME@": home,
        "@USER_HOME@": home,
        "@REPO_ROOT@": str(repo_root),
        "@BASH@": bash,
    }
    rendered: list[str] = []
    for arg in args:
        value = str(arg)
        for token, replacement in replacements.items():
            value = value.replace(token, replacement)
        rendered.append(value)
    return rendered


def _expected_fields(record: dict[str, Any], repo_root: Path, expected_source_root: Path | None = None) -> None:
    expected_args = [str(arg) for arg in record.get("args", [])]
    materialization_root = expected_source_root or repo_root
    expected_materialized = _materialize_args(expected_args, materialization_root)
    record["expected_program_arguments"] = expected_materialized
    record["expected_entrypoint"] = expected_materialized[0] if expected_materialized else "unknown"
    record["expected_execution_kind"] = record.get("execution_kind", "unknown")
    record["expected_execution_root"] = _execution_root(expected_materialized)
    record["expected_args"] = expected_args
    record["expected_schedule"] = record.get("schedule")
    record["expected_receipt_owner"] = record.get("receipt_owner", "unknown")
    record["expected_coverage_owner"] = record.get("coverage_owner", "unknown")


def _set_actual_fields(record: dict[str, Any], data: dict[str, Any], source: str) -> None:
    args = data.get("ProgramArguments")
    args = args if isinstance(args, list) else []
    actual_args = [str(arg) for arg in args]
    actual_domain, actual_kind = _classify(record["label"], data, source)
    actual_receipt, actual_coverage = _owners(record["label"], actual_args)
    record.update(
        program_arguments=actual_args,
        entrypoint=actual_args[0] if actual_args else "unknown",
        args=actual_args,
        schedule=_schedule(data),
        execution_kind=actual_kind,
        execution_root=_execution_root(actual_args),
        installed_domain=actual_domain,
        receipt_owner=actual_receipt,
        coverage_owner=actual_coverage,
        identity_source="installed_plist",
    )


def _clear_actual_fields(record: dict[str, Any]) -> None:
    """Prevent catalog/template routing from being reported as observed state."""
    record.update(
        program_arguments=None,
        entrypoint="unknown",
        args=None,
        execution_kind="unknown",
        execution_root=None,
        installed_domain=None,
        identity_source="unavailable",
    )


def _routing_mismatches(record: dict[str, Any]) -> list[str]:
    mismatches: list[str] = []
    for field in ("program_arguments", "execution_kind", "execution_root"):
        expected = record.get(f"expected_{field}")
        actual = record.get(field)
        if expected is not None and actual != expected:
            mismatches.append(field)
    if record.get("installed_domain") != record.get("domain"):
        mismatches.append("domain")
    return mismatches


def _launchctl_target(domain: str, label: str) -> str | None:
    if domain == "system":
        return f"system/{label}"
    if domain == "user":
        uid = os.environ.get("DISK_MAGICIAN_LAUNCHCTL_UID") or str(os.getuid())
        return f"gui/{uid}/{label}"
    return None


def _launchctl_print(domain: str, label: str) -> tuple[bool | None, str | None]:
    """Inspect one exact launchd service; True=loaded, False=missing, None=unknown."""
    target = _launchctl_target(domain, label)
    if target is None:
        return None, f"cannot inspect unknown launchd domain: {domain}"
    try:
        proc = subprocess.run(
            ["launchctl", "print", target],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except OSError as exc:
        return None, f"launchctl unavailable: {exc}"
    except subprocess.TimeoutExpired as exc:
        return None, f"launchctl inspection timed out: {exc}"
    output = f"{proc.stdout}\n{proc.stderr}"
    lowered = output.lower()
    if proc.returncode != 0:
        if any(marker in lowered for marker in ("could not find service", "service not found", "no such process")):
            return False, None
        return None, f"launchctl print failed (exit {proc.returncode})"
    # A successful print of a same-label service in the other domain is not
    # evidence that this exact service is loaded.  Require the full target
    # (including ``system/`` versus ``gui/<uid>/``) in launchctl's output.
    if re.search(rf"(?<![A-Za-z0-9_.-]){re.escape(target)}(?![A-Za-z0-9_.-])", output):
        return True, None
    return None, "launchctl print returned unrelated service data"


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
    elif label == "com.jleechanorg.disk-magician-pressure-sweep" or "pressure_sweep.sh" in joined or "pressure-sweep" in args:
        receipt = "pressure_sweep.sh"
    elif label == "com.jleechanorg.disk-magician-tmp-scratch" or "tmp_scratch_sweep.sh" in joined or "tmp-scratch-sweep" in args:
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
        "program_arguments": [str(arg) for arg in args],
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
                "label": _catalog_label(path),
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


def _installed_path(record: dict[str, Any]) -> Path:
    home = Path(os.environ.get("HOME", "~")).expanduser()
    if record["domain"] == "system":
        return Path(os.environ.get("DISK_MAGICIAN_LAUNCHDAEMONS_DIR", "/Library/LaunchDaemons")) / f"{record['label']}.plist"
    return Path(os.environ.get("DISK_MAGICIAN_LAUNCHAGENTS_DIR", str(home / "Library/LaunchAgents"))) / f"{record['label']}.plist"


def fleet(repo_root: Path, expected_source_root: Path | None = None) -> dict[str, Any]:
    records, source_paths = catalog(repo_root)
    for record in records:
        _expected_fields(record, repo_root, expected_source_root)
        _clear_actual_fields(record)
    platform_hint = os.environ.get("DISK_MAGICIAN_OSTYPE")
    if platform_hint is None:
        platform_hint = os.environ.get("OSTYPE", "") or sys.platform
    darwin = platform_hint.startswith("darwin")
    if not darwin:
        for record in records:
            if record["status"] == "invalid":
                continue
            installed = _installed_path(record)
            source_paths.append(str(installed))
            record.update(
                plist_path=str(installed),
                status="unknown",
                reason="launchd not applicable on non-macOS",
                program_arguments=None,
                entrypoint="unknown",
                execution_kind="unknown",
                execution_root=None,
                identity_source="unavailable",
            )
    else:
        for record in records:
            if record["status"] == "invalid":
                continue
            installed = _installed_path(record)
            source_paths.append(str(installed))
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
            _set_actual_fields(record, parsed, str(installed))
            mismatches = _routing_mismatches(record)
            loaded, inspection_error = _launchctl_print(record["domain"], record["label"])
            if mismatches:
                record.update(status="degraded", reason="installed routing differs from expected: " + ", ".join(mismatches))
            elif inspection_error:
                record.update(status="unknown", reason=inspection_error)
            elif loaded is True:
                record.update(status="healthy", reason="installed plist matches expected routing and exact label is loaded")
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
    parser.add_argument("--expected-source-root", help="source checkout used when launchd templates were installed")
    parser.add_argument("--json", action="store_true", help="emit installed fleet status JSON")
    args = parser.parse_args(argv)
    expected_source_root = Path(args.expected_source_root).expanduser().resolve() if args.expected_source_root else None
    result = fleet(Path(args.repo_root).resolve(), expected_source_root=expected_source_root)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    if result["status"] == "healthy":
        return 0
    if result["status"] == "invalid":
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

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
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

from job_receipt import resolve_state_dir

MAIN_SWEEPER_LABEL = "com.jleechanorg.disk-magician-main-sweeper"
CONSOLIDATED_LABELS = {
    "com.disk-magician.colima-prune",
    "com.disk-magician.code-sign-clones",
    "com.disk-magician.codex-vacuum",
    "com.jleechanorg.disk-magician-pressure-sweep",
    "com.jleechanorg.disk-magician-tmp-scratch",
}


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
    elif label == "com.jleechanorg.disk-magician-main-sweeper" or "main_sweeper.sh" in joined or "main-sweeper" in args or "sweep" in args:
        receipt = "main_sweeper.sh"
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
    elif label == "com.jleechanorg.disk-magician-main-sweeper" or "main_sweeper.sh" in joined or "main-sweeper" in args or "sweep" in args:
        coverage = "main_sweeper.sh"
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


def _deployed_source_root(repo_root: Path) -> Path:
    """Use the deployment manifest for template routing, falling back to this tree."""
    try:
        manifest = json.loads((resolve_state_dir() / "deployed.json").read_text())
        source_root = manifest.get("source_root") if isinstance(manifest, dict) else None
        if isinstance(source_root, str) and Path(source_root).is_absolute():
            return Path(source_root).resolve()
    except (OSError, ValueError, RuntimeError):
        pass
    return repo_root


def _platform_read(argv: list[str]) -> tuple[str | None, str | None]:
    """Bounded platform observation only; never activate or repair a job."""
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    if proc.returncode:
        return None, f"inspection failed (exit {proc.returncode})"
    return proc.stdout, None


def _systemctl_show(namespace: str, unit: str) -> tuple[dict[str, str], str | None]:
    output, error = _platform_read(["systemctl", "--" + namespace, "show", unit, "--no-pager"])
    if error:
        return {}, error
    values = dict(line.split("=", 1) for line in (output or "").splitlines() if "=" in line)
    if values.get("Id") != unit or "LoadState" not in values:
        return {}, "systemctl returned unrelated or incomplete unit data"
    return values, None


def _systemd_argv(value: str) -> list[str] | None:
    # systemctl's effective ExecStart, not a guessed unit-file command. Multiple
    # exec blocks, unknown escaping and shell wrappers fail closed below.
    match = re.fullmatch(r"\{ path=([^;]+?) ; argv\[\]=(.*?) ; [^{}]*\}", value.strip())
    if not match or "\\" in match.group(2):
        return None
    try:
        argv = shlex.split(match.group(2))
    except ValueError:
        return None
    return argv if argv and argv[0] == match.group(1) else None


def _unit_template(repo_root: Path, unit: str) -> dict[str, str]:
    import configparser
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    path = repo_root / "templates/systemd" / (unit + ".template")
    try:
        with path.open() as stream:
            parser.read_file(stream)
        return {key: value for section in parser.sections() for key, value in parser[section].items()}
    except (OSError, ValueError, configparser.Error):
        return {}


def _receipt_evidence(job: str, max_age: int, state_dir: Path | None = None) -> dict[str, Any]:
    from job_receipt import JobReceiptStore, parse_iso
    state_dir = state_dir or resolve_state_dir()
    result: dict[str, Any] = {"receipt_source": str(state_dir / "receipts" / (job + ".json")),
                              "run_result": "unknown", "freshness": "unknown", "last_success_at": None}
    try:
        data = JobReceiptStore(str(state_dir)).read(job)
        terminal = data.get("last_terminal") or {}
        result["run_result"] = terminal.get("outcome", "unknown")
        success = data.get("last_success") or {}
        timestamp = (success.get("times") or {}).get("ended_at")
        result["last_success_at"] = timestamp
        result["receipt_trigger"] = success.get("trigger")
        if timestamp:
            age = (_dt.datetime.now(_dt.timezone.utc) - parse_iso(timestamp)).total_seconds()
            result["age_seconds"] = age
            result["freshness"] = "fresh" if 0 <= age <= max_age else "stale" if age > max_age else "unknown"
    except (OSError, ValueError, TypeError):
        result["reason"] = "receipt_unreadable"
    return result


def _trusted_program(path: str) -> bool:
    """Read-only identity check for the installer-selected root interpreter."""
    try:
        target = Path(path)
        if not target.is_absolute():
            return False
        resolved = target.resolve(strict=True)
        for item in (target, *target.parents, resolved, *resolved.parents):
            info = item.stat()
            if info.st_uid != 0 or info.st_mode & 0o022:
                return False
        return resolved.is_file() and os.access(resolved, os.X_OK)
    except (OSError, RuntimeError):
        return False


def _root_receipt_evidence(state_parent: Path) -> dict[str, Any]:
    """The root scanner's independent fixed receipt is not a user JobReceiptStore."""
    from job_receipt import parse_iso
    path = state_parent / "inventory-root-receipt.json"
    result: dict[str, Any] = {"receipt_source": str(path), "run_result": "unknown", "freshness": "unknown",
                              "last_success_at": None, "receipt_trigger": "unknown"}
    try:
        info = path.lstat()
        if path.is_symlink() or info.st_uid != 0 or info.st_mode & 0o027:
            raise ValueError("untrusted root receipt ownership or mode")
        with path.open() as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            raise ValueError("root receipt exceeds bound")
        receipt = json.loads(raw)
        result.update(run_result=receipt["status"], complete=receipt.get("complete"),
                      manifest_sha256=receipt.get("manifest_sha256"), owner_uid=info.st_uid,
                      mode=format(info.st_mode & 0o777, "04o"))
        if receipt["status"] not in ("success", "success_noop", "partial"):
            return result
        when = parse_iso(receipt["published_at"])
        age = (_dt.datetime.now(_dt.timezone.utc) - when).total_seconds()
        if not re.fullmatch(r"[a-f0-9]{64}", receipt.get("manifest_sha256", "")):
            raise ValueError("invalid root manifest hash")
        result.update(last_success_at=receipt["published_at"], age_seconds=age,
                      freshness="fresh" if 0 <= age <= 86400 else "stale" if age > 86400 else "unknown")
    except (OSError, ValueError, TypeError, KeyError):
        result["reason"] = "root_receipt_unreadable_or_unverified"
    return result


def _systemd_record(repo_root: Path, namespace: str, service: str, timer: str | None,
                    catalog_records: list[dict[str, Any]]) -> dict[str, Any]:
    observed, error = _systemctl_show(namespace, service)
    timer_data, timer_error = _systemctl_show(namespace, timer) if timer else ({}, None)
    argv = _systemd_argv(observed.get("ExecStart", ""))
    template = _unit_template(repo_root, service)
    expected_command = template.get("ExecStart", "").replace("%h", str(Path.home()))
    if "@TRUSTED_PYTHON@" in expected_command and argv and _trusted_program(argv[0]):
        expected_command = expected_command.replace("@TRUSTED_PYTHON@", argv[0])
    expected = shlex.split(expected_command)
    matched = next((r for r in catalog_records
                    if r.get("domain") == namespace and r.get("expected_program_arguments") == argv), None)
    if not expected and matched:
        expected = matched["expected_program_arguments"]
    command_valid = bool(argv and expected and argv == expected)
    is_snapshot = namespace == "user" and service == "disk-magician-snapshot.service"
    root = namespace == "system" and service == "disk-magician-inventory-root.service"
    # A system service with a user-selected principal is not the fixed root
    # collector; environment/module injection is not accepted as equivalent argv.
    if root and (observed.get("User", "root") not in ("", "root") or observed.get("EnvironmentFiles")
                 or observed.get("Environment", "") != template.get("Environment", "")
                 or any(observed.get(field) for field in ("RootDirectory", "RootImage", "ExecStartPre", "ExecStartPost"))):
        command_valid = False
    record: dict[str, Any] = {
        "label": service, "namespace": namespace, "domain": namespace,
        "scheduler": "systemd", "checked_at": _now(),
        "identity_source": "systemctl_show", "source_path": observed.get("FragmentPath"),
        "program_arguments": argv, "args": argv, "entrypoint": argv[0] if argv else "unknown",
        "expected_program_arguments": expected or None, "execution_root": _execution_root(argv or []),
        "execution_kind": "packaged_cli" if is_snapshot and command_valid else "system" if root else "unknown",
        "registration": "unknown", "loading": "unknown", "enabled": "unknown",
        "status": "unknown", "reason": error or timer_error or "schedule evidence incomplete",
        "effective_schedule": "unknown", "effective_coverage": False,
        "coverage_owner": "snapshot_commit.sh" if is_snapshot and command_valid else
                          "disk_frontier_scan.py" if root and command_valid else
                          (matched or {}).get("coverage_owner", "unknown") if command_valid else "unknown",
        "receipt_owner": "snapshot_commit" if is_snapshot else "directory_inventory" if root else "unknown",
        "schedule": None, "command_matches": command_valid,
    }
    if is_snapshot:
        record.update(_receipt_evidence("snapshot_commit", 4 * 3600))
        inventory_receipt = _receipt_evidence("directory_inventory", 24 * 3600)
        record["inventory_freshness"] = inventory_receipt["freshness"]
        record["inventory_receipt"] = inventory_receipt
    elif root:
        record.update(_root_receipt_evidence(Path("/var/lib/disk-magician")))
    else:
        record.update(freshness="unknown", run_result="unknown")
    if error or timer_error:
        return record
    if observed.get("LoadState") == "not-found" or (timer and timer_data.get("LoadState") == "not-found"):
        record.update(registration="absent", loading="unloaded", status="degraded",
                      effective_schedule="manual_only", reason="privileged_collector_unavailable" if root else "unit absent")
        return record
    record["registration"] = "registered"
    record["loading"] = "loaded" if observed.get("LoadState") == "loaded" else "unloaded"
    if timer:
        calendar = re.search(r"OnCalendar=(.*?)\s*;", timer_data.get("TimersCalendar", ""))
        record["schedule"] = {"OnCalendar": calendar.group(1) if calendar else None,
                              "Persistent": timer_data.get("Persistent") == "yes", "timer": timer}
        record["enabled"] = timer_data.get("UnitFileState", "unknown")
        schedule_valid = (timer_data.get("LoadState") == "loaded" and timer_data.get("ActiveState") == "active"
                          and record["enabled"] in ("enabled", "enabled-runtime")
                          and timer_data.get("Triggers", "").split() == [service])
        if is_snapshot:
            schedule_valid = schedule_valid and record["schedule"]["OnCalendar"] == "*-*-* 00/2:15:00" and record["schedule"]["Persistent"]
    else:
        schedule_valid = root
    if not command_valid:
        record.update(status="degraded", effective_schedule="uncovered", reason="effective executable/argv/scope differs or is unverifiable")
    elif record["loading"] != "loaded" or not schedule_valid:
        record.update(status="degraded", effective_schedule="disabled", reason="schedule is disabled, unloaded or differs from expected")
    elif observed.get("Result") not in (None, "", "success") or observed.get("ExecMainStatus", "0") != "0" or record.get("run_result") in ("error", "timeout", "partial", "blocked_safety"):
        record.update(status="degraded", effective_schedule="failed", reason="latest execution failed or was partial")
    elif record.get("freshness") != "fresh" or (not root and record.get("receipt_trigger") != "scheduled"):
        record.update(status="degraded" if record.get("freshness") == "stale" else "unknown",
                      effective_schedule="stale" if record.get("freshness") == "stale" else "unknown",
                      reason="no fresh independent scheduled success receipt")
    else:
        record.update(status="healthy", effective_schedule="scheduled" if timer else "on_demand",
                      effective_coverage=not root, reason="effective command, schedule and independent receipt verified" if not root else "on-demand root collector receipt observed; scheduled trigger not proven")
    return record


def _cron_records(catalog_records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Observe this user's crontab, never infer daemon execution from a line."""
    unknown = {"label": "crontab", "namespace": "user", "scheduler": "cron", "status": "unknown",
               "registration": "unknown", "effective_schedule": "unknown", "effective_coverage": False,
               "source_path": "crontab -l", "checked_at": _now(), "reason": "crontab unreadable"}
    try:
        proc = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return [unknown]
    if proc.returncode:
        # Only a recognizable, successful absence observation is manual-only.
        if proc.returncode == 1 and re.search(r"^no crontab for ", proc.stderr.strip(), re.I):
            return []
        return [unknown]
    records = []
    for number, line in enumerate(proc.stdout.splitlines(), 1):
        if line.lstrip().startswith("#") or not any(s in line for s in ("diskm", "disk-magician", "disk_magician")):
            continue
        fields = line.strip().split(None, 1 if line.startswith("@") else 5)
        command = fields[-1] if len(fields) in (2, 6) else ""
        try:
            argv = shlex.split(command, comments=True) if not re.search(r"[;&|<>`$%\\n]", command) else None
        except ValueError:
            argv = None
        match = next((r for r in catalog_records if r.get("domain") == "user"
                      and r.get("expected_program_arguments") == argv), None)
        records.append({**unknown, "label": f"crontab:{number}", "registration": "registered",
                        "program_arguments": argv, "command_matches": match is not None,
                        "schedule": {"cron": " ".join(fields[:-1])}, "loading": "unknown", "freshness": "unknown",
                        "coverage_owner": (match or {}).get("coverage_owner", "unknown"),
                        "effective_schedule": "unknown" if match else "uncovered",
                        "reason": "cron execution/receipt not verified" if match else "cron executable/argv/scope not verified"})
    return records


def _linux_fleet(repo_root: Path, catalog_records: list[dict[str, Any]], source_paths: list[str]) -> dict[str, Any]:
    # Adopt existing exact names, never infer a second cadence or activate units.
    targets = {("user", "disk-magician-snapshot.service", "disk-magician-snapshot.timer"),
               ("system", "disk-magician-inventory-root.service", None)}
    records = [r for r in catalog_records if r["status"] == "invalid"]
    for namespace in ("user", "system"):
        text, error = _platform_read(["systemctl", "--" + namespace, "list-unit-files", "--type=timer", "--no-legend", "--no-pager"])
        if error:
            records.append({"label": "systemd-" + namespace + "-discovery", "namespace": namespace,
                            "scheduler": "systemd", "status": "unknown", "reason": error,
                            "registration": "unknown", "effective_schedule": "unknown", "effective_coverage": False})
            continue
        for line in (text or "").splitlines()[:256]:
            fields = line.split()
            if not fields or not re.fullmatch(r"(?:disk-magician|com\.(?:disk-magician|jleechanorg\.disk-magician))[-.A-Za-z0-9]*\.timer", fields[0]):
                continue
            timer = fields[0]
            if timer == "disk-magician-snapshot.timer" and namespace == "user":
                continue
            data, err = _systemctl_show(namespace, timer)
            service = data.get("Triggers", "")
            if not err and re.fullmatch(r"[-.A-Za-z0-9]+\.service", service):
                targets.add((namespace, service, timer))
            else:
                records.append({"label": timer, "namespace": namespace, "scheduler": "systemd", "status": "unknown",
                                "reason": err or "timer service target unverified", "effective_schedule": "unknown", "effective_coverage": False})
    records.extend(_systemd_record(repo_root, ns, service, timer, catalog_records)
                   for ns, service, timer in sorted(targets, key=lambda item: (item[0], item[1], item[2] or "")))
    records.extend(_cron_records(catalog_records))
    states = {r["status"] for r in records}
    status = next((s for s in ("invalid", "degraded", "unknown") if s in states), "healthy")
    return {"schema_version": 1, "status": status, "checked_at": _now(), "records": records,
            "source_paths": sorted(set(source_paths + [r["source_path"] for r in records if r.get("source_path")]))}


def _launchd_coverage(records: list[dict[str, Any]]) -> None:
    disabled: dict[str, tuple[str | None, str | None]] = {}
    for record in records:
        namespace = record.get("domain", "unknown")
        record.update(scheduler="launchd", namespace=namespace, checked_at=_now(),
                      effective_coverage=False, effective_schedule="unknown", enabled="unknown",
                      command_matches=False, freshness="unknown", run_result="unknown")
        record.setdefault("registration", "unknown")
        record.setdefault("loading", "unknown")
        if record["registration"] == "absent":
            record.update(effective_schedule="manual_only", coverage_owner="unknown")
            continue
        if record.get("identity_source") != "installed_plist":
            record["coverage_owner"] = "unknown"
            continue
        matches = not _routing_mismatches(record)
        record["command_matches"] = matches
        if not matches:
            record.update(effective_schedule="uncovered", coverage_owner="unknown")
            continue
        if namespace not in disabled:
            domain = "system" if namespace == "system" else "gui/" + (os.environ.get("DISK_MAGICIAN_LAUNCHCTL_UID") or str(os.getuid()))
            disabled[namespace] = _platform_read(["launchctl", "print-disabled", domain])
        output, error = disabled[namespace]
        if not error and output and "disabled services" in output:
            match = re.search(r'"' + re.escape(record["label"]) + r'"\s*=>\s*(true|false)', output)
            record["enabled"] = "disabled" if match and match.group(1) == "true" else "enabled"
        owner = record.get("receipt_owner", "unknown")
        if owner != "unknown":
            interval = (record.get("schedule") or {}).get("StartInterval", 24 * 3600)
            if not isinstance(interval, (int, float)) or interval <= 0:
                interval = 24 * 3600
            record.update(_receipt_evidence(_strip_suffix(owner, ".sh"), int(interval * 2)))
        if record["loading"] == "unloaded" or record["enabled"] == "disabled":
            record["effective_schedule"] = "disabled"
        elif record["loading"] != "loaded" or record["enabled"] == "unknown":
            record["effective_schedule"] = "unknown"
        elif record["run_result"] in ("error", "timeout", "partial", "blocked_safety"):
            record["effective_schedule"] = "failed"
        elif record["freshness"] == "stale":
            record["effective_schedule"] = "stale"
        elif record["freshness"] == "fresh" and record.get("receipt_trigger") == "scheduled" and record.get("schedule"):
            record.update(effective_schedule="scheduled", effective_coverage=True)
        # status remains the backwards-compatible loaded-fleet dimension;
        # callers must use effective_schedule/coverage for the stronger claim.


def fleet(repo_root: Path, expected_source_root: Path | None = None) -> dict[str, Any]:
    if expected_source_root is None:
        expected_source_root = _deployed_source_root(repo_root)
    records, source_paths = catalog(repo_root)
    for record in records:
        _expected_fields(record, repo_root, expected_source_root)
        _clear_actual_fields(record)
    platform_hint = os.environ.get("DISK_MAGICIAN_OSTYPE")
    if platform_hint is None:
        platform_hint = os.environ.get("OSTYPE", "") or sys.platform
    darwin = platform_hint.startswith("darwin")
    if platform_hint.startswith("linux"):
        return _linux_fleet(repo_root, records, source_paths)
    if not darwin:
        for record in records:
            record.update(status="unknown", reason="scheduler inspection unsupported on this platform")
    else:
        for record in records:
            if record["status"] == "invalid":
                continue
            installed = _installed_path(record)
            source_paths.append(str(installed))
            record["plist_path"] = str(installed)
            try:
                installed.stat()
            except FileNotFoundError:
                record.update(status="degraded", reason="installed plist missing", registration="absent", loading="unloaded")
                continue
            except OSError:
                record.update(status="unknown", reason="installed plist unreadable", registration="unknown", loading="unknown")
                continue
            record["registration"] = "registered"
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
            record["loading"] = "loaded" if loaded is True else "unloaded" if loaded is False else "unknown"
            if mismatches:
                record.update(status="degraded", reason="installed routing differs from expected: " + ", ".join(mismatches))
            elif inspection_error:
                record.update(status="unknown", reason=inspection_error)
            elif loaded is True:
                record.update(status="healthy", reason="installed plist matches expected routing and exact label is loaded")
            else:
                record.update(status="degraded", reason="plist valid but exact label is not loaded")

        # Reconcile consolidation / legacy support across the fleet
        main_sweeper_record = next((r for r in records if r["label"] == MAIN_SWEEPER_LABEL), None)
        main_sweeper_active = (
            main_sweeper_record is not None
            and main_sweeper_record.get("status") == "healthy"
        )

        if main_sweeper_active:
            for record in records:
                if record["label"] in CONSOLIDATED_LABELS:
                    if record.get("status") == "degraded" and record.get("reason") in (
                        "installed plist missing",
                        "plist valid but exact label is not loaded",
                    ):
                        record.update(
                            status="healthy",
                            reason=f"consolidated: covered by {MAIN_SWEEPER_LABEL}",
                        )
        else:
            legacy_jobs_present = any(
                r["label"] in CONSOLIDATED_LABELS and r.get("status") == "healthy"
                for r in records
            )
            if legacy_jobs_present and main_sweeper_record is not None:
                if main_sweeper_record.get("status") == "degraded" and main_sweeper_record.get("reason") == "installed plist missing":
                    main_sweeper_record.update(
                        status="healthy",
                        reason="unconsolidated: legacy individual sweepers active",
                    )
    if darwin:
        _launchd_coverage(records)
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
    parser.add_argument("--text", action="store_true", help="emit native scheduler summary")
    args = parser.parse_args(argv)
    expected_source_root = Path(args.expected_source_root).expanduser().resolve() if args.expected_source_root else None
    result = fleet(Path(args.repo_root).resolve(), expected_source_root=expected_source_root)
    if args.text:
        for record in result["records"]:
            print(f"  {record['status'].upper()} {record.get('namespace', record.get('domain', 'unknown'))}/{record['label']}: {record['reason']}")
        print(f"  Fleet: {result['status']} (effective commands and independent receipts; inspection only)")
    else:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    if result["status"] == "healthy":
        return 0
    if result["status"] == "invalid":
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

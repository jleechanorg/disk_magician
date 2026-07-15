#!/usr/bin/env python3
"""Read-only, fail-closed disk inventory ledgers.

This command measures and attributes disk use.  It does not remove, erase,
prune, stop, or mutate any measured target.
"""

from __future__ import annotations

import argparse
import json
import os
import pwd
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional, Sequence


PROTECTED_PREFIXES = (
    ".codex/sessions",
    ".codex/state",
    ".codex/log",
    ".claude/projects",
)
MANAGED_LIBRARY_CACHES = {
    "claude-cli-nodejs": {"owner": "cleanup_dev_caches.sh", "age_gate_days": 30},
    "go-build": {"owner": "cleanup_dev_caches.sh", "age_gate_days": 30},
}


def _utc(epoch: Optional[float]) -> Optional[str]:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z")


def _walk_measure(path: Path, now_epoch: int) -> dict:
    allocated = 0
    apparent = 0
    latest = None
    buckets = {"younger_than_7d_bytes": 0, "age_7_to_30d_bytes": 0, "older_than_30d_bytes": 0}
    errors = 0

    def account(item: Path) -> None:
        nonlocal allocated, apparent, latest, errors
        try:
            stat = item.lstat()
        except OSError:
            errors += 1
            return
        item_allocated = int(getattr(stat, "st_blocks", 0)) * 512
        allocated += item_allocated
        if item.is_file() and not item.is_symlink():
            apparent += stat.st_size
        latest = stat.st_mtime if latest is None else max(latest, stat.st_mtime)
        age_days = max(0, (now_epoch - stat.st_mtime) / 86400)
        if age_days < 7:
            buckets["younger_than_7d_bytes"] += item_allocated
        elif age_days < 30:
            buckets["age_7_to_30d_bytes"] += item_allocated
        else:
            buckets["older_than_30d_bytes"] += item_allocated

    account(path)
    if path.is_dir() and not path.is_symlink():
        for directory, dirnames, filenames in os.walk(path, followlinks=False):
            base = Path(directory)
            for name in dirnames:
                account(base / name)
            for name in filenames:
                account(base / name)
    return {
        "allocated_bytes": allocated,
        "apparent_bytes": apparent,
        "latest_mtime": _utc(latest),
        "latest_mtime_epoch": latest,
        "age_buckets": buckets,
        "measurement_errors": errors,
    }


def _is_protected(path: Path, home: Optional[Path] = None) -> bool:
    home = home or Path.home()
    try:
        relative = path.resolve().relative_to(home.resolve())
    except (OSError, ValueError):
        return False
    text = str(relative)
    return any(text == prefix or text.startswith(prefix + os.sep) for prefix in PROTECTED_PREFIXES)


def _owner(path: Path) -> dict:
    try:
        uid = path.lstat().st_uid
        name = pwd.getpwuid(uid).pw_name
    except (OSError, KeyError):
        return {"owner_uid": None, "owner_name": None}
    return {"owner_uid": uid, "owner_name": name}


def _active_for(path: Path, open_files: Sequence[dict]) -> list:
    resolved_path = str(path.resolve())
    prefix = resolved_path + os.sep
    active = []
    seen = set()
    for item in open_files:
        raw_candidate = str(item.get("path") or "")
        try:
            candidate = str(Path(raw_candidate).resolve())
        except OSError:
            candidate = raw_candidate
        if candidate != resolved_path and not candidate.startswith(prefix):
            continue
        key = (item.get("pid"), item.get("command"))
        if key in seen:
            continue
        seen.add(key)
        active.append({"pid": item.get("pid"), "command": item.get("command")})
    return active


def collect_open_files(timeout: int = 8) -> list:
    try:
        result = subprocess.run(
            ["lsof", "-nP", "-Fpcn"], capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    entries = []
    process = {"pid": None, "command": None}
    for line in result.stdout.splitlines():
        if not line:
            continue
        prefix, value = line[0], line[1:]
        if prefix == "p":
            process = {"pid": int(value) if value.isdigit() else None, "command": None}
        elif prefix == "c":
            process["command"] = value
        elif prefix == "n" and value.startswith("/"):
            entries.append({**process, "path": value})
    return entries


def _coverage(root: Path, root_measure: dict, entries: Sequence[dict]) -> float:
    try:
        own_blocks = int(getattr(root.lstat(), "st_blocks", 0)) * 512
    except OSError:
        own_blocks = 0
    content_total = max(0, root_measure["allocated_bytes"] - own_blocks)
    measured = sum(entry["allocated_bytes"] for entry in entries)
    if content_total == 0:
        return 100.0
    return round(min(100.0, measured * 100.0 / content_total), 2)


def inventory_caches(root: Path, now_epoch: Optional[int] = None, open_files: Optional[Sequence[dict]] = None) -> dict:
    now_epoch = int(time.time()) if now_epoch is None else now_epoch
    open_files = collect_open_files() if open_files is None else list(open_files)
    root_measure = _walk_measure(root, now_epoch) if root.exists() else {
        "allocated_bytes": 0, "apparent_bytes": 0, "measurement_errors": 0,
    }
    entries = []
    if root.is_dir():
        for child in sorted(root.iterdir(), key=lambda item: item.name):
            measured = _walk_measure(child, now_epoch)
            active = _active_for(child, open_files)
            policy = MANAGED_LIBRARY_CACHES.get(child.name)
            if _is_protected(child):
                classification, rationale = "protected", "hard never-delete prefix"
            elif active:
                classification, rationale = "active", "one or more processes hold open paths"
            elif policy:
                classification, rationale = "safe_automatic", "exact path is owned by an existing age-gated cleanup adapter"
            else:
                classification, rationale = "unknown", "no existing cleanup owner or safety contract"
            old_bytes = measured["age_buckets"]["older_than_30d_bytes"]
            reclaim = old_bytes if classification == "safe_automatic" else 0
            entries.append(
                {
                    "name": child.name,
                    "path": str(child),
                    **_owner(child),
                    **measured,
                    "active_processes": active,
                    "classification": classification,
                    "classification_rationale": rationale,
                    "cleanup_owner": policy["owner"] if policy else None,
                    "cleanup_age_gate_days": policy["age_gate_days"] if policy else None,
                    "reclaim_ceiling_bytes": reclaim,
                }
            )
    return {
        "schema_version": 1,
        "tool": "disk_inventory",
        "inventory": "library_caches",
        "root": str(root),
        "root_allocated_bytes": root_measure["allocated_bytes"],
        "coverage_pct": _coverage(root, root_measure, entries),
        "measurement_errors": root_measure.get("measurement_errors", 0),
        "reclaim_ceiling_bytes": sum(entry["reclaim_ceiling_bytes"] for entry in entries),
        "entries": entries,
        "executed_commands": [],
    }


def _run(argv: Sequence[str], timeout: int = 8) -> tuple[int, str]:
    try:
        result = subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout, check=False)
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def _git_facts(path: Path) -> dict:
    rc, top = _run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    if rc:
        return {"is_git": False}
    top_path = Path(top.strip())
    _, branch = _run(["git", "-C", str(path), "branch", "--show-current"])
    _, status = _run(["git", "-C", str(path), "status", "--porcelain"])
    _, remote = _run(["git", "-C", str(path), "remote", "get-url", "origin"])
    upstream_rc, _ = _run(["git", "-C", str(path), "rev-parse", "--abbrev-ref", "@{upstream}"])
    ahead = None
    if upstream_rc == 0:
        _, ahead_text = _run(["git", "-C", str(path), "rev-list", "--count", "@{upstream}..HEAD"])
        try:
            ahead = int(ahead_text.strip())
        except ValueError:
            ahead = None
    _, worktrees = _run(["git", "-C", str(top_path), "worktree", "list", "--porcelain"])
    registered = f"worktree {top_path.resolve()}\n" in worktrees + "\n"
    return {
        "is_git": True,
        "top_level": str(top_path),
        "branch": branch.strip() or None,
        "remote": remote.strip() or None,
        "dirty": bool(status.strip()),
        "ahead_of_upstream": ahead,
        "upstream_configured": upstream_rc == 0,
        "registered_worktree": registered,
        "git_kind": "worktree" if (top_path / ".git").is_file() else "repository",
    }


def _artifacts(path: Path, now_epoch: int) -> list:
    artifacts = []
    seen = set()
    for directory, dirnames, filenames in os.walk(path, followlinks=False):
        base = Path(directory)
        artifact_type = None
        if "pyvenv.cfg" in filenames:
            artifact_type = "venv"
        elif base.name == "node_modules":
            artifact_type = "node_modules"
        elif base.name in {"build", "dist", ".build"}:
            artifact_type = "build"
        elif base.name in {"log", "logs"}:
            artifact_type = "log"
        elif base.name in {"cache", "caches", ".cache"}:
            artifact_type = "cache"
        if artifact_type and base not in seen:
            measured = _walk_measure(base, now_epoch)
            artifacts.append({"path": str(base), "artifact_type": artifact_type, **measured})
            seen.add(base)
            dirnames[:] = []
    return artifacts


def _ao_reference_map(
    paths: Sequence[Path], ao_metadata_roots: Sequence[Path], max_seconds: int = 10
) -> tuple[dict, bool]:
    canonical_paths = {str(path.resolve()) for path in paths}
    aliases = {}
    for path in paths:
        canonical = str(path.resolve())
        aliases[str(path)] = canonical
        aliases[canonical] = canonical
    references = {canonical: [] for canonical in canonical_paths}
    deadline = time.monotonic() + max_seconds
    for root in ao_metadata_roots:
        if not root.is_dir():
            continue
        for directory, _, filenames in os.walk(root, followlinks=False):
            for filename in filenames:
                if time.monotonic() >= deadline:
                    return references, False
                candidate = Path(directory) / filename
                try:
                    if candidate.stat().st_size > 2 * 1024 * 1024:
                        continue
                    content = candidate.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                for needle, canonical in aliases.items():
                    if needle in content and len(references[canonical]) < 50:
                        reference = str(candidate)
                        if reference not in references[canonical]:
                            references[canonical].append(reference)
    return references, True


def inventory_paths(
    roots: Sequence[Path], now_epoch: Optional[int] = None,
    open_files: Optional[Sequence[dict]] = None,
    ao_metadata_roots: Sequence[Path] = (),
) -> dict:
    now_epoch = int(time.time()) if now_epoch is None else now_epoch
    open_files = collect_open_files() if open_files is None else list(open_files)
    children_by_root = {
        root: sorted(root.iterdir(), key=lambda item: item.name) if root.is_dir() else []
        for root in roots
    }
    all_children = [child for children in children_by_root.values() for child in children]
    ao_reference_map, ao_attribution_complete = _ao_reference_map(all_children, ao_metadata_roots)
    root_ledgers = []
    total_reclaim = 0
    for root in roots:
        root_measure = _walk_measure(root, now_epoch) if root.exists() else {
            "allocated_bytes": 0, "apparent_bytes": 0, "measurement_errors": 0,
        }
        entries = []
        if root.is_dir():
            for child in children_by_root[root]:
                measured = _walk_measure(child, now_epoch)
                active = _active_for(child, open_files)
                git = _git_facts(child)
                ao_refs = ao_reference_map.get(str(child.resolve()), [])
                latest = measured.get("latest_mtime_epoch")
                age_days = int((now_epoch - latest) / 86400) if latest else None
                eligible_worktree = (
                    git.get("git_kind") == "worktree"
                    and git.get("registered_worktree") is True
                    and git.get("dirty") is False
                    and git.get("ahead_of_upstream") == 0
                    and age_days is not None and age_days >= 14
                    and not active and not ao_refs and not _is_protected(child)
                )
                if _is_protected(child):
                    classification, rationale = "protected", "hard never-delete prefix"
                elif active or ao_refs:
                    classification, rationale = "active", "open process or AO metadata reference"
                elif eligible_worktree:
                    classification, rationale = "approval_required", "registered clean dormant worktree; WORKTREE_APPROVED remains required"
                else:
                    classification, rationale = "unknown", "not proven eligible by the existing worktree safety contract"
                reclaim = measured["allocated_bytes"] if eligible_worktree else 0
                total_reclaim += reclaim
                entries.append(
                    {
                        "name": child.name, "path": str(child), **_owner(child), **measured,
                        "age_days": age_days,
                        "active_processes": active,
                        "ao_metadata_references": ao_refs,
                        "git": git,
                        "artifacts": _artifacts(child, now_epoch),
                        "classification": classification,
                        "classification_rationale": rationale,
                        "reclaim_ceiling_bytes": reclaim,
                    }
                )
        root_ledgers.append(
            {
                "root": str(root),
                "root_allocated_bytes": root_measure["allocated_bytes"],
                "coverage_pct": _coverage(root, root_measure, entries),
                "entries": entries,
            }
        )
    return {
        "schema_version": 1, "tool": "disk_inventory", "inventory": "workspace_paths",
        "roots": root_ledgers, "reclaim_ceiling_bytes": total_reclaim,
        "ao_attribution_complete": ao_attribution_complete,
        "approval_environment": "WORKTREE_APPROVED=1", "executed_commands": [],
    }


def inventory_simulators(home: Path, simctl_data: dict, now_epoch: Optional[int] = None) -> dict:
    now_epoch = int(time.time()) if now_epoch is None else now_epoch
    devices = []
    base = home / "Library" / "Developer" / "CoreSimulator" / "Devices"
    for runtime, runtime_devices in (simctl_data.get("devices") or {}).items():
        for raw in runtime_devices:
            udid = str(raw.get("udid") or "")
            path = base / udid
            measured = _walk_measure(path, now_epoch) if path.exists() else {
                "allocated_bytes": 0, "apparent_bytes": 0,
                "latest_mtime": None, "latest_mtime_epoch": None,
                "age_buckets": {}, "measurement_errors": 0,
            }
            available = bool(raw.get("isAvailable", False))
            devices.append(
                {
                    "name": raw.get("name"), "udid": udid, "runtime": runtime,
                    "state": raw.get("state"), "available": available,
                    "availability_error": raw.get("availabilityError"),
                    "path": str(path), **measured,
                    "last_used_at": measured.get("latest_mtime"),
                    "classification": "approval_required" if not available else "unknown",
                    "classification_rationale": "simctl reports unavailable" if not available else "available simulator is retained",
                    "supported_delete_command": ["xcrun", "simctl"] + ["delete", udid],
                    "reclaim_ceiling_bytes": measured["allocated_bytes"] if not available else 0,
                }
            )
    return {
        "schema_version": 1, "tool": "disk_inventory", "inventory": "simulators",
        "devices": devices,
        "unavailable_reclaim_ceiling_bytes": sum(item["reclaim_ceiling_bytes"] for item in devices),
        "approval_environment": "SIMULATORS_APPROVED=1", "executed_commands": [],
    }


def default_path_roots(home: Path) -> list:
    candidates = [home / "projects", home / ".worktrees", home / ".lvl-lanes"]
    candidates.extend(sorted(home.glob(".agent-*")))
    for base in (home / "projects", home / ".worktrees"):
        candidates.append(base / ".lvl-lanes")
        if base.is_dir():
            candidates.extend(sorted(base.glob(".agent-*")))
            candidates.extend(sorted(base.glob("*/.lvl-lanes")))
            candidates.extend(sorted(base.glob("*/.agent-*")))
    seen = set()
    result = []
    for path in candidates:
        if path.exists() and path not in seen:
            seen.add(path)
            result.append(path)
    return result


def _simctl_json() -> dict:
    rc, output = _run(["xcrun", "simctl", "list", "devices", "--json"], 20)
    if rc:
        return {"devices": {}, "error": f"simctl_exit_{rc}"}
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return {"devices": {}, "error": "simctl_invalid_json"}


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    cache = subparsers.add_parser("caches")
    cache.add_argument("--root", type=Path, default=Path.home() / "Library" / "Caches")
    paths = subparsers.add_parser("paths")
    paths.add_argument("--root", action="append", type=Path, dest="roots")
    paths.add_argument("--ao-root", action="append", type=Path, default=[])
    subparsers.add_parser("simulators")
    subparsers.add_parser("all")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    home = Path.home()
    open_files = collect_open_files()
    if args.command == "caches":
        result = inventory_caches(args.root, open_files=open_files)
    elif args.command == "paths":
        roots = args.roots or default_path_roots(home)
        ao_roots = args.ao_root or [home / ".ao", home / ".agent-orchestrator"]
        result = inventory_paths(roots, open_files=open_files, ao_metadata_roots=ao_roots)
    elif args.command == "simulators":
        result = inventory_simulators(home, _simctl_json())
    else:
        result = {
            "schema_version": 1, "tool": "disk_inventory", "inventory": "all",
            "caches": inventory_caches(home / "Library" / "Caches", open_files=open_files),
            "paths": inventory_paths(
                default_path_roots(home), open_files=open_files,
                ao_metadata_roots=[home / ".ao", home / ".agent-orchestrator"],
            ),
            "simulators": inventory_simulators(home, _simctl_json()),
            "executed_commands": [],
        }
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Aligned, bounded sampling for short-lived host disk swings.

The observer records facts only.  It never prunes Docker, Colima, snapshots,
processes, or files.  Process arguments and environment variables are omitted
deliberately so the JSONL log cannot capture command-line credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable, Optional, Sequence


CommandResult = namedtuple("CommandResult", "returncode stdout stderr timed_out")
Runner = Callable[[Sequence[str], int], CommandResult]

DEFAULT_LABELS = [
    "com.jleechanorg.disk-magician-pressure-sweep",
    "com.jleechanorg.disk-magician",
    "com.jleechanorg.disk-magician-drilldown",
    "com.jleechanorg.disk-magician-frontier-nightly",
    "org.jleechanorg.host-disk-guardian",
    "org.jleechanorg.ezgha",
]


def run_command(argv: Sequence[str], timeout: int = 5) -> CommandResult:
    try:
        result = subprocess.run(
            list(argv), capture_output=True, text=True, timeout=timeout, check=False
        )
        return CommandResult(result.returncode, result.stdout, result.stderr, False)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return CommandResult(124, stdout, stderr, True)
    except OSError as exc:
        return CommandResult(127, "", str(exc), False)


def _int(value: object, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _error(result: CommandResult) -> Optional[str]:
    if result.returncode == 0:
        return None
    if result.timed_out:
        return "timeout"
    return f"exit_{result.returncode}"


def collect_disk(run: Runner) -> dict:
    target = "/System/Volumes/Data" if sys.platform == "darwin" else "/"
    result = run(["df", "-kP", target], 5)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if result.returncode or len(lines) < 2:
        return {"target": target, "error": _error(result) or "unparseable"}
    fields = lines[-1].split()
    if len(fields) < 6:
        return {"target": target, "error": "unparseable"}
    return {
        "target": target,
        "total_kb": _int(fields[1]),
        "used_kb": _int(fields[2]),
        "available_kb": _int(fields[3]),
        "capacity_pct": _int(fields[4].rstrip("%")),
    }


def _du_kb(path: Path, run: Runner) -> Optional[int]:
    result = run(["du", "-sk", str(path)], 8)
    if result.returncode:
        return None
    fields = result.stdout.split()
    return _int(fields[0]) if fields else None


def _colima_datadisk_paths(root: Path, max_depth: int = 6, max_entries: int = 4096) -> tuple[list, bool]:
    paths = []
    visited = 0
    if not root.is_dir():
        return paths, True
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(directory)
        try:
            depth = len(base.relative_to(root).parts)
        except ValueError:
            continue
        dirnames[:] = [name for name in dirnames if not (base / name).is_symlink()]
        if depth >= max_depth:
            dirnames[:] = []
        for name in filenames:
            visited += 1
            if visited > max_entries:
                return sorted(paths), False
            path = base / name
            if path.is_symlink() or not path.is_file():
                continue
            if name in {"disk", "diffdisk"} or base.name == "disks":
                paths.append(path)
    return sorted(set(paths)), True


def collect_colima(home: Path, run: Runner) -> dict:
    root = home / ".colima"
    root_kb = _du_kb(root, run) if root.exists() else 0
    disk_paths, scan_complete = _colima_datadisk_paths(root)
    disks = []
    for path in disk_paths:
        try:
            apparent = path.stat().st_size
        except OSError:
            apparent = None
        disks.append(
            {
                "path": str(path),
                "allocated_kb": _du_kb(path, run),
                "apparent_bytes": apparent,
            }
        )
    return {
        "root": str(root),
        "root_allocated_kb": root_kb,
        "datadisks": disks,
        "datadisk_scan_complete": scan_complete,
    }


def collect_docker(events_since_epoch: int, now_epoch: int, run: Runner) -> dict:
    ids_result = run(["docker", "ps", "-aq"], 5)
    ids = [line.strip() for line in ids_result.stdout.splitlines() if line.strip()]
    containers = []
    if ids:
        inspect = run(["docker", "inspect", "--size", *ids], 10)
        if inspect.returncode == 0:
            try:
                raw_containers = json.loads(inspect.stdout)
            except json.JSONDecodeError:
                raw_containers = []
            for raw in raw_containers:
                state = raw.get("State") or {}
                containers.append(
                    {
                        "id": str(raw.get("Id", ""))[:12],
                        "name": str(raw.get("Name", "")).lstrip("/"),
                        "status": state.get("Status"),
                        "started_at": state.get("StartedAt"),
                        "finished_at": state.get("FinishedAt"),
                        "oom_killed": bool(state.get("OOMKilled", False)),
                        "writable_bytes": _int(raw.get("SizeRw")),
                    }
                )
    events_result = run(
        [
            "docker", "events", "--since", str(events_since_epoch), "--until", str(now_epoch),
            "--filter", "type=container", "--format", "{{json .}}",
        ],
        8,
    )
    events = []
    if events_result.returncode == 0:
        allowed_actions = {"create", "start", "die", "destroy", "oom", "stop", "kill"}
        for line in events_result.stdout.splitlines():
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue
            action = raw.get("Action") or raw.get("status")
            if action not in allowed_actions:
                continue
            actor = raw.get("Actor") or {}
            attrs = actor.get("Attributes") or {}
            events.append(
                {
                    "action": action,
                    "container_id": str(actor.get("ID") or raw.get("id") or "")[:12],
                    "name": attrs.get("name"),
                    "image": attrs.get("image"),
                    "epoch": _int(raw.get("time") or raw.get("timeNano", 0) // 1_000_000_000),
                }
            )
    return {
        "available": ids_result.returncode == 0,
        "error": _error(ids_result),
        "containers": containers,
        "total_writable_bytes": sum(item["writable_bytes"] for item in containers),
        "events": events,
        "events_error": _error(events_result),
    }


def collect_launchd(labels: Iterable[str], run: Runner) -> list:
    uid = os.getuid()
    jobs = []
    for label in labels:
        result = run(["launchctl", "print", f"gui/{uid}/{label}"], 3)
        if result.returncode:
            jobs.append({"label": label, "loaded": False, "error": _error(result)})
            continue
        values = {}
        for line in result.stdout.splitlines():
            match = re.match(r"\s*(state|pid|runs|last exit code)\s*=\s*(.+?)\s*$", line)
            if match:
                values[match.group(1)] = match.group(2)
        raw_exit_code = values.get("last exit code")
        numeric_exit_code = (
            int(raw_exit_code) if raw_exit_code and re.fullmatch(r"-?\d+", raw_exit_code) else None
        )
        jobs.append(
            {
                "label": label,
                "loaded": True,
                "state": values.get("state"),
                "pid": _int(values.get("pid")) or None,
                "runs": _int(values.get("runs")),
                "last_exit_code": numeric_exit_code,
                "last_exit_code_raw": raw_exit_code,
            }
        )
    return jobs


def collect_processes(run: Runner, limit: int = 20) -> list:
    result = run(["ps", "-axo", "pid=,rss=,comm="], 5)
    processes = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        processes.append(
            {"pid": _int(fields[0]), "rss_kb": _int(fields[1]), "command": Path(fields[2]).name}
        )
    return sorted(processes, key=lambda item: item["rss_kb"], reverse=True)[:limit]


def collect_unlinked_files(run: Runner, minimum_bytes: int = 1024 * 1024) -> list:
    result = run(["lsof", "-nP", "+L1", "-Fpcfsln"], 8)
    if result.returncode:
        return []
    files = []
    current = {"pid": None, "command": None}
    candidate = {}

    def flush() -> None:
        size = _int(candidate.get("size_bytes"))
        links = _int(candidate.get("link_count"), 1)
        if candidate.get("fd") and links < 1 and size >= minimum_bytes:
            files.append({**current, **candidate, "size_bytes": size, "link_count": links})

    for line in result.stdout.splitlines():
        if not line:
            continue
        prefix, value = line[0], line[1:]
        if prefix == "p":
            flush()
            candidate = {}
            current = {"pid": _int(value), "command": None}
        elif prefix == "c":
            current["command"] = value
        elif prefix == "f":
            flush()
            candidate = {"fd": value}
        elif prefix == "s":
            candidate["size_bytes"] = _int(value)
        elif prefix == "l":
            candidate["link_count"] = _int(value, 1)
        elif prefix == "n":
            candidate["path"] = value
    flush()
    return sorted(files, key=lambda item: item["size_bytes"], reverse=True)[:50]


def collect_time_machine(run: Runner) -> dict:
    result = run(["tmutil", "listlocalsnapshots", "/"], 5)
    snapshots = [line.strip() for line in result.stdout.splitlines() if ".local" in line]
    return {"local_snapshot_count": len(snapshots), "local_snapshots": snapshots, "error": _error(result)}


def collect_boot(now_epoch: int, run: Runner) -> dict:
    result = run(["sysctl", "-n", "kern.boottime"], 3)
    match = re.search(r"(?:sec\s*=\s*)?(\d+)", result.stdout)
    boot_epoch = _int(match.group(1)) if match else None
    return {
        "boot_epoch": boot_epoch,
        "uptime_seconds": max(0, now_epoch - boot_epoch) if boot_epoch else None,
        "error": _error(result),
    }


def collect_swap(run: Runner) -> dict:
    result = run(["sysctl", "-n", "vm.swapusage"], 3)
    empty = {"total_bytes": None, "used_bytes": None, "free_bytes": None}
    if result.returncode:
        return {**empty, "error": _error(result)}
    multipliers = {
        "K": 1024,
        "M": 1024 ** 2,
        "G": 1024 ** 3,
        "T": 1024 ** 4,
    }
    values = {}
    for name in ("total", "used", "free"):
        match = re.search(
            rf"\b{name}\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT])(?:B)?\b",
            result.stdout,
            re.IGNORECASE,
        )
        if not match:
            return {**empty, "error": "unparseable"}
        values[f"{name}_bytes"] = int(float(match.group(1)) * multipliers[match.group(2).upper()])
    return {**values, "error": None}


def collect_sample(
    home: Path,
    now_epoch: Optional[int] = None,
    events_since_epoch: Optional[int] = None,
    run: Runner = run_command,
    launchd_labels: Sequence[str] = DEFAULT_LABELS,
) -> dict:
    now_epoch = int(time.time()) if now_epoch is None else now_epoch
    events_since_epoch = now_epoch - 60 if events_since_epoch is None else events_since_epoch
    return {
        "schema_version": 1,
        "tool": "disk_observer",
        "timestamp": datetime.fromtimestamp(now_epoch, timezone.utc).isoformat().replace("+00:00", "Z"),
        "epoch": now_epoch,
        "host_disk": collect_disk(run),
        "colima": collect_colima(home, run),
        "docker": collect_docker(events_since_epoch, now_epoch, run),
        "launchd": collect_launchd(launchd_labels, run),
        "processes": collect_processes(run),
        "open_unlinked_files": collect_unlinked_files(run),
        "time_machine": collect_time_machine(run),
        "boot": collect_boot(now_epoch, run),
        "swap": collect_swap(run),
    }


def rotate_if_needed(
    path: Path, max_bytes: int, keep: int,
    max_age_seconds: int = 7 * 86400, now_epoch: Optional[float] = None,
) -> None:
    now_epoch = time.time() if now_epoch is None else now_epoch
    for index in range(1, keep + 1):
        archive = Path(f"{path}.{index}")
        try:
            expired = now_epoch - archive.stat().st_mtime > max_age_seconds
        except OSError:
            continue
        if expired:
            archive.unlink()
    if not path.exists() or path.stat().st_size <= max_bytes:
        return
    for index in range(keep, 0, -1):
        source = path if index == 1 else Path(f"{path}.{index - 1}")
        destination = Path(f"{path}.{index}")
        if not source.exists():
            continue
        if destination.exists():
            destination.unlink()
        source.replace(destination)


def append_sample(
    path: Path, sample: dict, max_bytes: int, keep: int,
    max_age_seconds: int = 7 * 86400,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rotate_if_needed(path, max_bytes, keep, max_age_seconds=max_age_seconds)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(sample, sort_keys=True, separators=(",", ":")) + "\n")


def _delta(previous: dict, current: dict) -> dict:
    previous_host = previous.get("host_disk") or {}
    current_host = current.get("host_disk") or {}
    previous_colima = previous.get("colima") or {}
    current_colima = current.get("colima") or {}
    previous_docker = previous.get("docker") or {}
    current_docker = current.get("docker") or {}
    return {
        "from_timestamp": previous.get("timestamp"),
        "to_timestamp": current.get("timestamp"),
        "elapsed_seconds": _int(current.get("epoch")) - _int(previous.get("epoch")),
        "host_available_delta_kb": _int(current_host.get("available_kb")) - _int(previous_host.get("available_kb")),
        "colima_allocated_delta_kb": _int(current_colima.get("root_allocated_kb")) - _int(previous_colima.get("root_allocated_kb")),
        "docker_writable_delta_bytes": _int(current_docker.get("total_writable_bytes")) - _int(previous_docker.get("total_writable_bytes")),
        "docker_events": current_docker.get("events") or [],
        "top_processes": (current.get("processes") or [])[:10],
        "launchd": current.get("launchd") or [],
        "large_unlinked_files": (current.get("open_unlinked_files") or [])[:10],
    }


def build_report(records: Sequence[dict], limit: int = 10) -> dict:
    swings = [_delta(previous, current) for previous, current in zip(records, records[1:])]
    return {
        "schema_version": 1,
        "tool": "disk_observer_report",
        "sample_count": len(records),
        "interval_count": len(swings),
        "largest_host_free_space_decreases": sorted(swings, key=lambda item: item["host_available_delta_kb"])[:limit],
        "largest_host_free_space_increases": sorted(swings, key=lambda item: item["host_available_delta_kb"], reverse=True)[:limit],
        "largest_colima_growth": sorted(swings, key=lambda item: item["colima_allocated_delta_kb"], reverse=True)[:limit],
        "largest_docker_writable_growth": sorted(swings, key=lambda item: item["docker_writable_delta_bytes"], reverse=True)[:limit],
    }


def read_records(paths: Sequence[Path]) -> list:
    records = []
    for path in paths:
        if not path.exists():
            continue
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return sorted(records, key=lambda item: _int(item.get("epoch")))


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("once", "watch"):
        child = subparsers.add_parser(command)
        child.add_argument("--output", type=Path, default=Path.home() / ".disk_magician_state" / "disk_observer.jsonl")
        child.add_argument("--interval", type=int, default=60)
        child.add_argument("--max-bytes", type=int, default=16 * 1024 * 1024)
        child.add_argument("--keep", type=int, default=4)
        child.add_argument("--max-age-days", type=int, default=7)
    report = subparsers.add_parser("report")
    report.add_argument("--input", type=Path, default=Path.home() / ".disk_magician_state" / "disk_observer.jsonl")
    report.add_argument("--limit", type=int, default=10)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.command == "report":
        paths = [Path(f"{args.input}.{index}") for index in range(4, 0, -1)] + [args.input]
        print(json.dumps(build_report(read_records(paths), args.limit), indent=2, sort_keys=True))
        return 0

    if args.interval < 30 or args.interval > 60:
        print("--interval must be between 30 and 60 seconds", file=sys.stderr)
        return 2
    if args.max_bytes < 1024 or args.keep < 1 or args.max_age_days < 1:
        print("--max-bytes must be >=1024; --keep and --max-age-days must be >=1", file=sys.stderr)
        return 2
    previous_epoch = int(time.time()) - args.interval
    while True:
        now_epoch = int(time.time())
        sample = collect_sample(Path.home(), now_epoch, previous_epoch)
        append_sample(
            args.output, sample, args.max_bytes, args.keep,
            max_age_seconds=args.max_age_days * 86400,
        )
        print(json.dumps({"timestamp": sample["timestamp"], "output": str(args.output)}), flush=True)
        if args.command == "once":
            return 0
        previous_epoch = now_epoch
        time.sleep(max(0, args.interval - (time.time() - now_epoch)))


if __name__ == "__main__":
    raise SystemExit(main())

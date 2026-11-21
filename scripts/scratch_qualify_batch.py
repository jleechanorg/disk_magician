#!/usr/bin/env python3
"""Run read-only canonical quarantine verdicts for exact NUL-delimited paths."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from typing import Callable, Sequence


def read_paths(path: Path) -> list[bytes]:
    raw = path.read_bytes()
    if not raw:
        return []
    parts = raw.split(b"\0")
    if parts[-1] == b"":
        parts.pop()
    if not parts or any(not part for part in parts):
        raise ValueError("paths file contains an empty path")
    for candidate in parts:
        if not os.path.isabs(candidate):
            raise ValueError("every path must be absolute")
    return parts


def _result(index: int, path: bytes, verdict: str, returncode: int | None,
            reason: str | None = None) -> dict:
    return {
        "index": index,
        "path": os.fsdecode(path),
        "path_bytes_hex": path.hex(),
        "verdict": verdict,
        "returncode": returncode,
        "reason": reason,
    }


def _default_runner(argv: Sequence[str], timeout: float) -> subprocess.CompletedProcess:
    with subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # A verdict can spawn filesystem probes. Stop only this worker's group.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def _one_verdict(
    index: int,
    path: bytes,
    executable: str,
    kind: str | None,
    deadline: float,
    runner: Callable[[Sequence[str], float], subprocess.CompletedProcess],
) -> dict:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return _result(index, path, "deferred:deadline", None, "batch deadline elapsed")

    argv = [executable, "quarantine", "verdict", os.fsdecode(path)]
    if kind:
        argv.extend(("--kind", kind))
    argv.extend(("--deadline-at", str(int(deadline))))
    try:
        completed = runner(argv, remaining)
    except subprocess.TimeoutExpired:
        return _result(index, path, "deferred:deadline", 124, "verdict timed out")
    except OSError as error:
        return _result(index, path, "deferred:command-error", None,
                       f"{error.__class__.__name__}: {error}")

    stdout = completed.stdout or b""
    if isinstance(stdout, str):
        stdout = stdout.encode("utf-8", "surrogateescape")
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    verdict = lines[0].decode("utf-8", "surrogateescape") if len(lines) == 1 else ""
    if completed.returncode == 0 and (verdict == "remove" or verdict.startswith("kept:")):
        return _result(index, path, verdict, completed.returncode)
    if verdict.startswith("deferred:"):
        return _result(index, path, verdict, completed.returncode)

    stderr = completed.stderr or b""
    if isinstance(stderr, str):
        stderr = stderr.encode("utf-8", "surrogateescape")
    detail = stderr.decode("utf-8", "surrogateescape").strip()
    return _result(index, path, "deferred:command-error", completed.returncode,
                   detail[-512:] or "canonical verdict returned an unrecognized result")


def qualify_paths(
    paths: Sequence[bytes],
    executable: str,
    jobs: int,
    timeout_seconds: float,
    kind: str | None = None,
    runner: Callable[[Sequence[str], float], subprocess.CompletedProcess] = _default_runner,
) -> list[dict]:
    """Return one result per input in its original order, within one deadline."""
    if jobs < 1:
        raise ValueError("jobs must be positive")
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("timeout must be positive")

    deadline = time.monotonic() + timeout_seconds
    results: list[dict | None] = [None] * len(paths)
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = {
            executor.submit(_one_verdict, i, path, executable, kind, deadline, runner): i
            for i, path in enumerate(paths)
        }
        try:
            for future in as_completed(futures, timeout=timeout_seconds):
                index = futures[future]
                try:
                    results[index] = future.result()
                except Exception as error:
                    results[index] = _result(
                        index, paths[index], "deferred:command-error", None,
                        f"{error.__class__.__name__}: {error}",
                    )
        except TimeoutError:
            pass

    for index, result in enumerate(results):
        if result is None:
            results[index] = _result(
                index, paths[index], "deferred:deadline", None, "batch deadline elapsed"
            )
    return [result for result in results if result is not None]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paths-from", required=True, type=Path,
                        help="file containing absolute pathnames separated by NUL bytes")
    parser.add_argument("--jobs", type=int, default=1,
                        help="maximum concurrent read-only verdict processes (default: 1)")
    parser.add_argument("--timeout-seconds", type=float, default=60,
                        help="overall monotonic deadline for the batch (default: 60)")
    parser.add_argument("--kind", choices=("rebuildable", "ephemeral"))
    args = parser.parse_args(argv)

    if args.jobs < 1 or not math.isfinite(args.timeout_seconds) or args.timeout_seconds <= 0:
        parser.error("--jobs and --timeout-seconds must be positive")
    try:
        paths = read_paths(args.paths_from)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if not paths:
        parser.error("paths file is empty")

    executable = os.environ.get("DISK_MAGICIAN_QUARANTINE_VERDICT_BIN") or shutil.which("diskm")
    if not executable:
        print("scratch-qualify: diskm executable is unavailable", file=sys.stderr)
        return 127

    results = qualify_paths(paths, executable, args.jobs, args.timeout_seconds, args.kind)
    for result in results:
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0 if all(result["returncode"] == 0 and result["verdict"] != "deferred:deadline"
                    for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

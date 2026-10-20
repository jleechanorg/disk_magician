#!/usr/bin/env python3
"""Parallel shell test runner with longest-pole-first scheduling and isolated TMPDIR."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import glob
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Sequence

REPO_ROOT = Path(__file__).resolve().parent.parent

HEAVY_PRIORITY: dict[str, tuple[int, int]] = {
    "tests/test_worktree_new.sh": (0, 1500),
    "tests/test_worktree_reap.sh": (1, 600),
    "tests/test_artifact_verdict.sh": (2, 900),
    "tests/test_worktree_hygiene_preserve_wip.sh": (3, 300),
    "tests/test_cleanup_worktrees_single_age_walk.sh": (4, 300),
    "tests/test_cleanup_tmp_pressure_budget.sh": (5, 300),
    "tests/test_cleanup_codex_documents.sh": (6, 300),
    "tests/test_snapshot_freshness.sh": (7, 300),
    "tests/test_worktree_reuse_real.sh": (8, 300),
    "tests/test_cleanup_tmp_large_protections.sh": (9, 300),
    "tests/test_cleanup_tmp_open_files.sh": (10, 300),
    "tests/test_cleanup_tmp_container_descend.sh": (11, 300),
    "tests/test_worktree_remove_hook.sh": (12, 300),
}

DEFAULT_PRIORITY = (100, 300)


@dataclass(frozen=True)
class TestSpec:
    display_name: str
    path: Path
    priority: int
    timeout_s: float


@dataclass
class TestResult:
    spec: TestSpec
    rc: int
    elapsed_s: float
    output: str
    timed_out: bool = False


def normalize_test_key(test_file: str | Path, repo_root: Path = REPO_ROOT) -> str:
    """Normalize a test path to 'tests/test_*.sh' form for priority lookup."""
    raw = str(test_file).replace("\\", "/")
    if raw in HEAVY_PRIORITY:
        return raw
    p = Path(test_file)
    if p.is_absolute():
        try:
            rel = p.resolve().relative_to(repo_root.resolve()).as_posix()
            if rel in HEAVY_PRIORITY:
                return rel
        except ValueError:
            pass
    candidate = f"tests/{p.name}"
    if candidate in HEAVY_PRIORITY:
        return candidate
    return raw


def build_test_specs(
    test_files: Sequence[str | Path] | None = None,
    repo_root: Path = REPO_ROOT,
    timeout_override: float | None = None,
) -> list[TestSpec]:
    """Return test specs ordered by (priority, display_name) so heavy suites start first."""
    if not test_files:
        pattern = str(repo_root / "tests" / "test_*.sh")
        discovered = sorted(glob.glob(pattern))
        raw_items: list[str | Path] = [
            os.path.relpath(p, repo_root) for p in discovered
        ]
    else:
        raw_items = list(test_files)

    specs: list[TestSpec] = []
    for item in raw_items:
        p = Path(item)
        resolved = p if p.is_absolute() or p.exists() else (repo_root / p)
        key = normalize_test_key(item, repo_root=repo_root)
        prio, default_timeout = HEAVY_PRIORITY.get(key, DEFAULT_PRIORITY)
        timeout_s = float(timeout_override) if timeout_override is not None else float(default_timeout)
        specs.append(
            TestSpec(
                display_name=str(item),
                path=resolved,
                priority=prio,
                timeout_s=timeout_s,
            )
        )

    specs.sort(key=lambda s: (s.priority, s.display_name))
    return specs


def _terminate_process_group(proc: subprocess.Popen[str]) -> None:
    """Terminate and, if needed, SIGKILL the child process group."""
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return

    for sig, wait_s in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 1.0)):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            try:
                proc.kill()
            except OSError:
                pass
            return
        deadline = time.monotonic() + wait_s
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.05)


def run_single_test(
    spec: TestSpec,
    shard_root: Path,
    repo_root: Path,
    lock: threading.Lock,
    concurrency_state: dict[str, int],
    index: int,
) -> TestResult:
    """Execute one shell test inside an isolated TMPDIR and its own process group."""
    stem = f"{index:03d}_{spec.path.stem}"
    test_tmpdir = shard_root / stem
    test_tmpdir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["TMPDIR"] = str(test_tmpdir)

    with lock:
        concurrency_state["active_workers"] += 1
        if concurrency_state["active_workers"] > concurrency_state["max_concurrent_workers"]:
            concurrency_state["max_concurrent_workers"] = concurrency_state["active_workers"]

    start = time.monotonic()
    timed_out = False
    output = ""
    rc = 1

    try:
        proc = subprocess.Popen(
            ["/bin/bash", str(spec.path)],
            cwd=str(repo_root),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            start_new_session=True,
        )
        try:
            stdout, _ = proc.communicate(timeout=spec.timeout_s)
            output = stdout or ""
            rc = proc.returncode if proc.returncode is not None else 1
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            _terminate_process_group(proc)
            try:
                rest, _ = proc.communicate(timeout=2.0)
            except Exception:
                rest = ""
            partial = ""
            if exc.stdout:
                partial = exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode("utf-8", "replace")
            output = f"{partial}{rest}\n[TIMEOUT] {spec.display_name} exceeded {spec.timeout_s:.1f}s\n"
            rc = 124
    finally:
        elapsed = time.monotonic() - start
        with lock:
            concurrency_state["active_workers"] -= 1
        shutil.rmtree(test_tmpdir, ignore_errors=True)

    return TestResult(
        spec=spec,
        rc=rc,
        elapsed_s=elapsed,
        output=output,
        timed_out=timed_out,
    )


def default_jobs() -> int:
    raw = os.environ.get("DISK_MAGICIAN_TEST_JOBS")
    if raw:
        try:
            return max(1, int(raw))
        except ValueError:
            pass
    return max(1, min(os.cpu_count() or 4, 8))


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run shell tests in parallel.")
    parser.add_argument(
        "tests",
        nargs="*",
        help="Optional test script paths (defaults to tests/test_*.sh).",
    )
    parser.add_argument(
        "--jobs",
        "-j",
        type=int,
        default=default_jobs(),
        help="Maximum concurrent test workers.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="Optional per-test timeout override in seconds.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root directory for resolving default test paths and cwd.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo_root = args.repo_root.resolve()
    specs = build_test_specs(
        args.tests,
        repo_root=repo_root,
        timeout_override=args.timeout,
    )
    if not specs:
        print(
            "parallel-shell-tests: no test scripts matched",
            file=sys.stderr,
            flush=True,
        )
        return 1

    jobs = max(1, min(args.jobs, len(specs)))
    shard_root = Path(tempfile.mkdtemp(prefix="dm-ci-shard-", dir="/tmp"))
    lock = threading.Lock()
    print_lock = threading.Lock()
    concurrency_state = {
        "active_workers": 0,
        "max_concurrent_workers": 0,
    }

    results: list[TestResult] = []
    wall_start = time.monotonic()
    try:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            future_map = {
                pool.submit(
                    run_single_test,
                    spec,
                    shard_root,
                    repo_root,
                    lock,
                    concurrency_state,
                    idx,
                ): spec
                for idx, spec in enumerate(specs)
            }
            for fut in as_completed(future_map):
                res = fut.result()
                results.append(res)
                with print_lock:
                    print(
                        f"::group::{res.spec.display_name} ({res.elapsed_s:.1f}s, rc={res.rc})",
                        flush=True,
                    )
                    if res.output:
                        sys.stdout.write(res.output)
                        if not res.output.endswith("\n"):
                            sys.stdout.write("\n")
                    print("::endgroup::", flush=True)
    finally:
        shutil.rmtree(shard_root, ignore_errors=True)

    wall_s = max(time.monotonic() - wall_start, 1e-6)
    serial_sum_s = sum(r.elapsed_s for r in results)
    speedup = serial_sum_s / wall_s if wall_s > 0 else 1.0

    failed_results = [r for r in results if r.rc != 0]
    total = len(results)
    failed = len(failed_results)
    passed = total - failed
    max_conc = concurrency_state["max_concurrent_workers"]

    if failed_results:
        for r in sorted(failed_results, key=lambda x: x.spec.display_name):
            reason = "TIMEOUT" if r.timed_out else f"rc={r.rc}"
            print(f"FAILED: {r.spec.display_name} ({reason}, {r.elapsed_s:.1f}s)", flush=True)

    print(
        f"parallel-shell-tests: total={total} passed={passed} failed={failed} "
        f"max_concurrent={max_conc} wall_s={wall_s:.1f} serial_sum_s={serial_sum_s:.1f} "
        f"speedup={speedup:.2f}x",
        flush=True,
    )
    return 1 if failed > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())

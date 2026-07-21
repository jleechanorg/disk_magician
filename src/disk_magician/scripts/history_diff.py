#!/usr/bin/env python3
"""history_diff.py — compare two committed ledger/topdown-5g.json snapshots
in the per-machine state repo; print bucket-level growth deltas.

Design: roadmap/2026-07-21-generic-split-state-repo-design.md ("Diff UX").
Ledger contract: roadmap/plans/2026-07-21-state-repo-pr3-plan.md
("Ledger contract this PR assumes").

No shell pipelines: all comparison/sort logic is Python (the grep-shim
pipeline-corruption class documented in this repo's operator memory).
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

GIB_KB = 1024 * 1024
LEDGER_REL_PATH = "ledger/topdown-5g.json"


class LedgerError(ValueError):
    """Ledger fails schema, the <=5 GiB ceiling, or reconciliation."""


def validate_ledger(ledger: dict, *, label: str) -> None:
    for key in ("disk_used_kb", "residual_kb", "buckets"):
        if key not in ledger:
            raise LedgerError(f"{label}: missing required key {key!r}")
    buckets = ledger["buckets"]
    if not isinstance(buckets, list):
        raise LedgerError(f"{label}: 'buckets' must be a list")
    total = 0
    for item in buckets:
        path = item.get("path")
        size = item.get("measured_kb")
        kind = item.get("kind", "dir")
        if not path or not isinstance(size, int):
            raise LedgerError(f"{label}: bucket missing path/measured_kb: {item!r}")
        if kind not in ("dir", "file"):
            raise LedgerError(f"{label}: bucket {path!r} has unknown kind {kind!r}")
        if kind == "dir" and size >= 5 * GIB_KB:
            # A directory aggregate at/above the ceiling should have been
            # broken into child buckets — refuse rather than diff a partial
            # picture. A single indivisible FILE (kind="file") is exempt: it
            # is already a leaf and cannot be decomposed further, mirroring
            # disk_frontier_scan.py's oversize_indivisible_files category.
            raise LedgerError(
                f"{label}: bucket {path!r} is {size / GIB_KB:.2f} GiB — "
                "unexplained >=5 GiB aggregate without child breakdown"
            )
        total += size
    residual = ledger["residual_kb"]
    used = ledger["disk_used_kb"]
    if total + residual != used:
        raise LedgerError(
            f"{label}: buckets ({total} KiB) + residual ({residual} KiB) "
            f"!= disk_used_kb ({used} KiB) — reconciliation failed"
        )


def compute_deltas(base: dict, target: dict) -> "tuple[list, int]":
    base_by_path = {b["path"]: b["measured_kb"] for b in base["buckets"]}
    target_by_path = {b["path"]: b["measured_kb"] for b in target["buckets"]}
    paths = set(base_by_path) | set(target_by_path)
    deltas = [
        (path, target_by_path.get(path, 0) - base_by_path.get(path, 0))
        for path in paths
    ]
    deltas.sort(key=lambda item: (-item[1], item[0]))
    residual_delta = target["residual_kb"] - base["residual_kb"]
    return deltas, residual_delta


def format_kb(delta_kb: int) -> str:
    sign = "+" if delta_kb >= 0 else "-"
    return f"{sign}{abs(delta_kb) / GIB_KB:.2f} GiB"


def format_diff(deltas: list, residual_delta: int) -> str:
    lines = [
        f"{format_kb(delta_kb)}  {path}"
        for path, delta_kb in deltas
        if delta_kb != 0
    ]
    lines.append(f"residual delta: {format_kb(residual_delta)}")
    return "\n".join(lines)


def load_ledger_from_file(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        # ValueError covers json.JSONDecodeError. Fail closed as a LedgerError
        # (cursor-agent adversarial finding 2026-07-21: malformed JSON produced
        # an uncaught traceback instead of a clean diagnostic).
        raise LedgerError(f"{path}: not readable JSON — {exc}")


def load_ledger_from_git(state_dir: pathlib.Path, ref: str) -> dict:
    result = subprocess.run(
        ["git", "-C", str(state_dir), "show", f"{ref}:{LEDGER_REL_PATH}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise LedgerError(f"{ref}: cannot read {LEDGER_REL_PATH} — {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except ValueError as exc:
        raise LedgerError(f"{ref}:{LEDGER_REL_PATH}: not readable JSON — {exc}")


def resolve_state_dir(explicit) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit)
    env = os.environ.get("DISK_MAGICIAN_STATE_REPO")
    if env:
        return pathlib.Path(env)
    home = pathlib.Path(os.environ.get("HOME", "/"))
    xdg_state = pathlib.Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    return xdg_state / "disk-magician"


def main(argv) -> int:
    parser = argparse.ArgumentParser(prog="disk-magician history diff")
    parser.add_argument("ref", nargs="?", default=None,
                         help="base ref to diff against HEAD (default: HEAD~1)")
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--validate", metavar="LEDGER_JSON", default=None,
                         help="validate a single ledger file and exit (no diff)")
    args = parser.parse_args(argv)

    if args.validate:
        try:
            validate_ledger(load_ledger_from_file(pathlib.Path(args.validate)),
                             label=args.validate)
        except LedgerError as exc:
            print(f"history diff: {exc}", file=sys.stderr)
            return 2
        print(f"history diff: {args.validate} is a valid <=5 GiB ledger")
        return 0

    state_dir = resolve_state_dir(args.state_dir)
    if not (state_dir / ".git").is_dir():
        print(f"history diff: no state repo at {state_dir} (run: state init)", file=sys.stderr)
        return 1

    base_ref = args.ref or "HEAD~1"
    try:
        base = load_ledger_from_git(state_dir, base_ref)
        target = load_ledger_from_git(state_dir, "HEAD")
        validate_ledger(base, label=base_ref)
        validate_ledger(target, label="HEAD")
    except LedgerError as exc:
        print(f"history diff: {exc}", file=sys.stderr)
        return 2

    deltas, residual_delta = compute_deltas(base, target)
    print(format_diff(deltas, residual_delta))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

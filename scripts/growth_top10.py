#!/usr/bin/env python3
"""growth_top10.py — print the top-N growing paths since the last
full-attribution floor within --days, reading "current" from the freshest
local ledger (topdown-5g.partial.json preferred, topdown-5g.json canonical
fallback) rather than re-running `du`.

Design: docs/superpowers/specs/2026-09-11-ledger-fresh-and-queryable-design.md
Component G. Imports history_diff / resolve_state_repo_path as libraries —
zero duplicated validation or diff logic; every size formatted here comes
from history_diff.format_kb / history_diff.GIB_KB.

Exit 0: printed floor/current/gap + top-N table.
Exit 1: no valid current ledger (neither partial nor canonical readable/valid).
Exit 2: no full-attribution floor in the --days window (bead disk_magician-4y6).
"""
import argparse
import json
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import history_diff
import resolve_state_repo_path

PARTIAL_LEDGER_JSON = "topdown-5g.partial.json"
LEDGER_JSON = "topdown-5g.json"


def resolve_state_dir(explicit):
    if explicit:
        return pathlib.Path(explicit)
    return pathlib.Path(resolve_state_repo_path.resolve())


def load_current(state_dir):
    """Return (ledger, source_label) — working-tree read, partial first, no
    commit-lag. Falls back to the canonical file on any read/validation
    failure. Neither valid: (None, None)."""
    for rel, label in ((PARTIAL_LEDGER_JSON, "partial"), (LEDGER_JSON, "canonical")):
        path = state_dir / "ledger" / rel
        try:
            ledger = json.loads(path.read_text())
            history_diff.validate_ledger(ledger, label=label)
        except (OSError, ValueError, history_diff.LedgerError):
            continue
        return ledger, label
    return None, None


def coverage_suffix(ledger):
    if ledger.get("mode") == "complete":
        return ""
    envelope = ledger.get("coverage_envelope") or {}
    measured = envelope.get("measured_top_level_roots")
    reachable = envelope.get("reachable_top_level_roots")
    if measured is None or reachable is None:
        return " (partial)"
    return f" (partial: {measured}/{reachable} roots measured)"


def main(argv):
    parser = argparse.ArgumentParser(prog="disk-magician history growth-top10")
    parser.add_argument("--days", type=int, default=14,
                         help="floor selection window (default: 14)")
    parser.add_argument("--limit", type=int, default=10,
                         help="max growing paths to print (default: 10)")
    parser.add_argument("--state-dir", default=None)
    args = parser.parse_args(argv)

    if args.days <= 0:
        parser.error("--days must be positive")
    if args.limit <= 0:
        parser.error("--limit must be positive")

    state_dir = resolve_state_dir(args.state_dir)

    try:
        floor_ref, floor = history_diff.select_floor_ref(state_dir, args.days)
    except history_diff.LedgerError as exc:
        print(
            f"growth-top10: no full-attribution ledger in the last {args.days} days "
            f"(see bead disk_magician-4y6): {exc}",
            file=sys.stderr,
        )
        return 2

    current, source = load_current(state_dir)
    if current is None:
        print(
            "growth-top10: no valid ledger snapshot found — run: ./disk_magician.sh frontier",
            file=sys.stderr,
        )
        return 1

    deltas, residual_delta = history_diff.compute_deltas(floor, current)

    floor_gib = floor["disk_used_kb"] / history_diff.GIB_KB
    current_gib = current["disk_used_kb"] / history_diff.GIB_KB

    print(
        f"floor ({args.days}d): {floor_gib:.2f} GiB used at "
        f"{floor.get('captured_at', 'unknown')} ({floor_ref})"
    )
    print(
        f"current ({source}): {current_gib:.2f} GiB used at "
        f"{current.get('captured_at', 'unknown')}{coverage_suffix(current)}"
    )
    print(f"gap: {history_diff.format_kb(current['disk_used_kb'] - floor['disk_used_kb'])}")
    print()
    print(f"Top {args.limit} growing paths since floor:")
    grown = [(path, delta_kb) for path, delta_kb in deltas if delta_kb > 0][: args.limit]
    if not grown:
        print("  (no growth — nothing exceeded the floor)")
    for path, delta_kb in grown:
        print(f"  {history_diff.format_kb(delta_kb)}  {path}")
    print(f"residual delta: {history_diff.format_kb(residual_delta)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

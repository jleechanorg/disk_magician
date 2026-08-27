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
import pathlib
import subprocess
import sys

import resolve_state_repo_path

GIB_KB = 1024 * 1024
LEDGER_REL_PATH = "ledger/topdown-5g.json"


class LedgerError(ValueError):
    """Ledger fails schema, the <=5 GiB ceiling, or reconciliation."""


def validate_ledger(ledger: dict, *, label: str) -> None:
    for key in ("disk_used_kb", "residual_kb"):
        if key not in ledger:
            raise LedgerError(f"{label}: missing required key {key!r}")
    if "buckets" not in ledger and "granularity_buckets" not in ledger:
        raise LedgerError(f"{label}: missing required key 'buckets' or 'granularity_buckets'")
    buckets = ledger.get("granularity_buckets", ledger.get("buckets", []))
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
    for item in ledger.get("oversize_indivisible_files", []):
        total += item.get("measured_kb", 0)
    total += ledger.get("purgeable_kb", 0)
    residual = ledger["residual_kb"]
    used = ledger["disk_used_kb"]
    if total + residual != used:
        raise LedgerError(
            f"{label}: buckets ({total} KiB) + residual ({residual} KiB) "
            f"!= disk_used_kb ({used} KiB) — reconciliation failed"
        )


def validate_full_attribution_ledger(ledger: dict, *, label: str) -> None:
    """Reject legacy or partial ledgers on the attribution-diff path.

    ``--validate`` intentionally remains a structural/partial validation
    utility, but a history comparison must never present incomplete rows as a
    full-disk attribution delta.
    """
    envelope = ledger.get("coverage_envelope")
    accounting = ledger.get("accounting_equation")
    reachable = envelope.get("reachable_top_level_roots") if isinstance(envelope, dict) else None
    measured = envelope.get("measured_top_level_roots") if isinstance(envelope, dict) else None
    unfinished = envelope.get("unfinished_top_level_roots") if isinstance(envelope, dict) else None
    if ledger.get("mode") != "complete":
        raise LedgerError(f"{label}: full-attribution ledger required (mode is not complete)")
    if not isinstance(envelope, dict) or envelope.get("complete") is not True:
        raise LedgerError(f"{label}: full-attribution ledger required (coverage envelope incomplete)")
    if envelope.get("fda_preflight_status") != "granted":
        raise LedgerError(f"{label}: full-attribution ledger required (FDA preflight not granted)")
    if (
        type(reachable) is not int
        or type(measured) is not int
        or type(unfinished) is not int
        or measured != reachable
        or unfinished != 0
    ):
        raise LedgerError(f"{label}: full-attribution ledger required (top-level roots incomplete)")
    if not isinstance(ledger.get("frontier_unfinished"), list) or ledger["frontier_unfinished"]:
        raise LedgerError(f"{label}: full-attribution ledger required (frontier unfinished)")
    if not isinstance(accounting, dict) or accounting.get("displayed_balanced") is not True:
        raise LedgerError(f"{label}: full-attribution ledger required (displayed equation unbalanced)")
    keys = ("data_used_kb", "displayed_buckets_kb", "oversize_indivisible_files_kb",
            "sub_granularity_tail_kb", "purgeable_kb", "residual_kb")
    values = [accounting.get(key) for key in keys]
    buckets = ledger.get("granularity_buckets", ledger.get("buckets", []))
    oversize = ledger.get("oversize_indivisible_files", [])
    if (
        accounting.get("display_ledger_valid") is not True
        or not all(type(value) is int and value >= 0 for value in values)
        or values[0] != ledger.get("disk_used_kb")
        or values[0] != sum(values[1:])
        or values[1] != sum(item.get("measured_kb", 0) for item in buckets)
        or values[2] != sum(item.get("measured_kb", 0) for item in oversize)
    ):
        raise LedgerError(f"{label}: full-attribution ledger required (displayed equation invalid)")


def compute_deltas(base: dict, target: dict) -> "tuple[list, int]":
    base_buckets = base.get("granularity_buckets", base.get("buckets", []))
    target_buckets = target.get("granularity_buckets", target.get("buckets", []))
    base_by_path = {b["path"]: b["measured_kb"] for b in base_buckets}
    target_by_path = {b["path"]: b["measured_kb"] for b in target_buckets}
    for item in base.get("oversize_indivisible_files", []):
        base_by_path[item["path"]] = item["measured_kb"]
    for item in target.get("oversize_indivisible_files", []):
        target_by_path[item["path"]] = item["measured_kb"]
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


def select_floor_ref(state_dir: pathlib.Path, days: int) -> "tuple[str, dict]":
    """Return the lowest-used valid ledger committed within the requested window."""
    result = subprocess.run(
        ["git", "-C", str(state_dir), "log", f"--since={days}.days.ago", "--format=%H",
         "--", LEDGER_REL_PATH],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise LedgerError(f"cannot read ledger history — {result.stderr.strip()}")
    candidates = []
    for ref in result.stdout.splitlines():
        try:
            ledger = load_ledger_from_git(state_dir, ref)
            validate_ledger(ledger, label=ref)
            validate_full_attribution_ledger(ledger, label=ref)
        except LedgerError:
            continue
        candidates.append((ledger["disk_used_kb"], ref, ledger))
    if not candidates:
        raise LedgerError(f"no valid ledger snapshots in the last {days} days")
    _, ref, ledger = min(candidates, key=lambda item: (item[0], item[1]))
    return ref, ledger


def resolve_state_dir(explicit) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit)
    return pathlib.Path(resolve_state_repo_path.resolve())


def main(argv) -> int:
    parser = argparse.ArgumentParser(prog="disk-magician history diff")
    parser.add_argument("ref", nargs="?", default=None,
                         help="base ref to diff against HEAD (default: HEAD~1)")
    parser.add_argument("--days", type=int, default=None,
                        help="select the lowest-used valid ledger from the last N days")
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--validate", metavar="LEDGER_JSON", default=None,
                         help="validate a single ledger file and exit (no diff)")
    args = parser.parse_args(argv)

    if args.validate:
        try:
            ledger = load_ledger_from_file(pathlib.Path(args.validate))
            validate_ledger(ledger, label=args.validate)
        except LedgerError as exc:
            print(f"history diff: {exc}", file=sys.stderr)
            return 2
        try:
            validate_full_attribution_ledger(ledger, label=args.validate)
        except LedgerError:
            print(f"history diff: {args.validate} is valid structural partial/legacy ledger")
        else:
            print(f"history diff: {args.validate} is a valid full-attribution ledger")
        return 0

    state_dir = resolve_state_dir(args.state_dir)
    if not (state_dir / ".git").is_dir():
        print(f"history diff: no state repo at {state_dir} (run: state init)", file=sys.stderr)
        return 1

    if args.days is not None and args.days <= 0:
        parser.error("--days must be positive")
    if args.days is not None and args.ref is not None:
        parser.error("--days cannot be combined with an explicit ref")
    base_ref = args.ref or "HEAD~1"
    try:
        if args.days is not None:
            base_ref, base = select_floor_ref(state_dir, args.days)
        else:
            base = load_ledger_from_git(state_dir, base_ref)
        target = load_ledger_from_git(state_dir, "HEAD")
        validate_ledger(base, label=base_ref)
        validate_ledger(target, label="HEAD")
        validate_full_attribution_ledger(base, label=base_ref)
        validate_full_attribution_ledger(target, label="HEAD")
    except LedgerError as exc:
        print(f"history diff: {exc}", file=sys.stderr)
        return 2

    deltas, residual_delta = compute_deltas(base, target)
    if args.days is not None:
        captured_at = base.get("captured_at", "unknown")
        print(
            f"floor ({args.days}d): {base['disk_used_kb'] / GIB_KB:.2f} GiB used "
            f"at {captured_at} ({base_ref})"
        )
    print(format_diff(deltas, residual_delta))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""growth_top10.py — truthful bucket-level growth comparison against the last
full-attribution floor within --days.

Reads current from the freshest valid local ledger (evaluating captured_at
across topdown-5g.partial.json and topdown-5g.json, requiring freshness <=36h).
Never calls compute_deltas on partial ledgers. Emits machine-readable JSON
with --json or truthful text output that never claims 'no growth' when unknown
measurements prevent that claim.
"""
import argparse
import datetime
import json
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import history_diff
import partial_history_diff
import resolve_state_repo_path

PARTIAL_LEDGER_JSON = "topdown-5g.partial.json"
LEDGER_JSON = "topdown-5g.json"
GIB_KB = 1024 * 1024


def resolve_state_dir(explicit):
    if explicit:
        return pathlib.Path(explicit)
    return pathlib.Path(resolve_state_repo_path.resolve())


def format_kb(delta_kb: int) -> str:
    sign = "+" if delta_kb >= 0 else "-"
    return f"{sign}{abs(delta_kb) / GIB_KB:.2f} GiB"


def coverage_suffix(ledger):
    if ledger.get("mode") == "complete" and ledger.get("publication_kind") != "partial":
        return ""
    envelope = ledger.get("coverage_envelope")
    if not isinstance(envelope, dict):
        return " (partial)"
    measured = envelope.get("measured_top_level_roots")
    reachable = envelope.get("reachable_top_level_roots")
    if measured is None or reachable is None:
        return " (partial)"
    return f" (partial: {measured}/{reachable} roots measured)"


def load_freshest_current(state_dir: pathlib.Path, now: datetime.datetime):
    """Select the freshest valid local partial or canonical ledger based on
    actual capture timestamp, not blindly partial first. Both must be <= 36h
    fresh. Returns (ledger, source_label) or (None, None)."""
    candidates = []
    ledger_dir = state_dir / "ledger"

    for rel, label in ((PARTIAL_LEDGER_JSON, "partial"), (LEDGER_JSON, "canonical")):
        path = ledger_dir / rel
        if not path.is_file():
            continue
        try:
            d = json.loads(path.read_text())
            history_diff.validate_ledger(d, label=label)
            captured_at = d.get("captured_at")
            ts = partial_history_diff.parse_iso_ts(captured_at)
            if not ts:
                continue
            age_hours = (now - ts).total_seconds() / 3600.0
            if -0.1 <= age_hours <= 36.0:
                candidates.append((ts, label, d))
        except Exception:
            continue

    if not candidates:
        return None, None

    # Pick candidate with newest capture timestamp
    candidates.sort(key=lambda c: c[0], reverse=True)
    best_ts, best_label, best_ledger = candidates[0]
    return best_ledger, best_label


def validate_floor_freshness(floor: dict, days: int, now: datetime.datetime):
    """Independently verify that the floor's capture timestamp is within the
    requested days window and not in the future."""
    captured_at = floor.get("captured_at")
    ts = partial_history_diff.parse_iso_ts(captured_at)
    if not ts:
        return False, "invalid_captured_at"
    age_days = (now - ts).total_seconds() / 86400.0
    if age_days < -0.01:
        return False, "floor_in_future"
    if age_days > days:
        return False, "floor_capture_outside_window"
    return True, ""


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    parser = argparse.ArgumentParser(prog="disk-magician history growth-top10")
    parser.add_argument("--days", type=int, default=14,
                        help="floor selection window in days (default: 14)")
    parser.add_argument("--limit", type=int, default=10,
                        help="max growing paths to print (default: 10)")
    parser.add_argument("--state-dir", default=None,
                        help="override state repo directory")
    parser.add_argument("--json", action="store_true", default=False,
                        help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    if args.days <= 0:
        parser.error("--days must be positive")
    if args.limit <= 0:
        parser.error("--limit must be positive")

    now = datetime.datetime.now(datetime.timezone.utc)
    state_dir = resolve_state_dir(args.state_dir)

    # 1. Floor selection
    floor_ref = None
    floor = None
    floor_err = None
    try:
        floor_ref, floor = history_diff.select_floor_ref(
            state_dir, args.days, filter_capture_window=True, now=now
        )
        is_fresh_floor, reason = validate_floor_freshness(floor, args.days, now)
        if not is_fresh_floor:
            floor = None
            floor_err = f"floor capture timestamp outside window: {reason}"
    except Exception as exc:
        floor = None
        floor_err = str(exc)

    if floor is None:
        if args.json:
            print(json.dumps({
                "comparison_kind": "no_floor",
                "reason": floor_err or "no_valid_floor",
                "floor_ref": floor_ref,
                "current_source": None,
                "deltas": [],
                "unknown": [],
                "measured_interval": None,
            }, indent=2))
        else:
            print(f"growth-top10: no valid full-attribution floor in the last {args.days} days: {floor_err}",
                  file=sys.stderr)
        return 2

    # 2. Current selection
    current, current_source = load_freshest_current(state_dir, now)
    if current is None:
        if args.json:
            print(json.dumps({
                "comparison_kind": "no_current",
                "reason": "no_fresh_current_ledger",
                "floor_ref": floor_ref,
                "current_source": None,
                "deltas": [],
                "unknown": [],
                "measured_interval": None,
            }, indent=2))
        else:
            print("growth-top10: no valid fresh current ledger found (within 36h)", file=sys.stderr)
        return 1

    # 3. Compare ledgers using partial comparator (never compute_deltas on partial)
    comp = partial_history_diff.compare_ledgers(
        floor,
        current,
        max_floor_days=args.days,
        max_current_hours=36.0,
        now=now,
    )

    floor_used_kb = floor.get("disk_used_kb", 0)
    current_used_kb = current.get("disk_used_kb", 0)

    if comp["comparison_kind"] == "nonnumeric":
        gap_kb = None
        residual_delta = None
    else:
        gap_kb = current_used_kb - floor_used_kb
        if current.get("publication_kind") == "partial" or current.get("mode") == "partial":
            residual_delta = None
        else:
            residual_delta = current.get("residual_kb", 0) - floor.get("residual_kb", 0)

    deltas = comp.get("deltas", [])
    unknown = comp.get("unknown", [])
    growing = [d for d in deltas if d.get("delta_kb", 0) > 0][:args.limit]

    if args.json:
        payload = {
            "comparison_kind": comp["comparison_kind"],
            "reason": comp["reason"],
            "floor_ref": floor_ref,
            "current_source": current_source,
            "floor_captured_at": floor.get("captured_at"),
            "current_captured_at": current.get("captured_at"),
            "floor_used_kb": floor_used_kb,
            "current_used_kb": current_used_kb,
            "gap_kb": gap_kb,
            "coverage": comp.get("coverage") or comp.get("coverage_envelope"),
            "measured_interval": comp.get("measured_interval"),
            "top_growth": growing,
            "deltas": deltas[:args.limit],
            "unknown": unknown,
        }
        if residual_delta is not None:
            payload["residual_delta_kb"] = residual_delta
        print(json.dumps(payload, indent=2))
        if comp["comparison_kind"] == "nonnumeric":
            return 1
        return 0

    if comp["comparison_kind"] == "nonnumeric":
        print(f"growth-top10: comparison non-numeric: {comp['reason']}", file=sys.stderr)
        return 1

    floor_gib = floor_used_kb / GIB_KB
    current_gib = current_used_kb / GIB_KB

    print(
        f"floor ({args.days}d): {floor_gib:.2f} GiB used at "
        f"{floor.get('captured_at', 'unknown')} ({floor_ref})"
    )
    print(
        f"current ({current_source}): {current_gib:.2f} GiB used at "
        f"{current.get('captured_at', 'unknown')}{coverage_suffix(current)}"
    )
    if gap_kb is not None:
        print(f"gap: {format_kb(gap_kb)}")
    print()
    print(f"Top {args.limit} growing paths since floor:")

    if growing:
        for item in growing:
            print(f"  {format_kb(item['delta_kb'])}  {item['path']}")
    else:
        if unknown:
            print(f"  (unmeasured/unknown components prevent confirming zero growth: {len(unknown)} unknown paths)")
        else:
            print("  (no growth — nothing exceeded the floor)")

    if unknown:
        print(f"unknown paths: {len(unknown)} paths unmeasured/carried/missing")

    if residual_delta is not None:
        print(f"residual delta: {format_kb(residual_delta)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

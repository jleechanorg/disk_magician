#!/usr/bin/env python3
"""Refresh ledger/topdown-5g.{json,md} from the frontier scanner's report
(design: roadmap/2026-07-21-generic-split-state-repo-design.md, "Snapshot/commit
flow"). Freshness-gated: silently no-ops (exit 0, ledger files untouched) when
the frontier report is missing, unreadable, or older than 36h — the same
staleness threshold scripts/disk_snapshot.sh already applies when embedding
topdown_coverage into the snapshot JSON, so a stale scan never overwrites a
fresher committed ledger with worse data.
"""
import argparse, datetime, json, os, sys

STALE_HOURS = 36


def gib(kb):
    return (kb or 0) / 1024.0 / 1024.0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--frontier", required=True)
    p.add_argument("--out-dir", required=True)
    args = p.parse_args()

    try:
        with open(args.frontier) as f:
            report = json.load(f)
    except (OSError, ValueError):
        return 0  # no frontier data yet — leave ledger untouched

    captured_at = report.get("captured_at")
    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (TypeError, ValueError):
        return 0
    age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
    if age_hours > STALE_HOURS:
        return 0  # stale — leave prior ledger in place

    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    equation = report.get("accounting_equation") or {}

    os.makedirs(args.out_dir, exist_ok=True)

    ledger = {
        "schema_version": 1,
        "captured_at": captured_at,
        "hostname": report.get("hostname"),
        "disk_used_kb": report.get("disk_used_kb"),
        "residual_kb": report.get("residual_kb"),
        "purgeable_kb": report.get("purgeable_kb"),
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": equation,
    }
    with open(os.path.join(args.out_dir, "topdown-5g.json"), "w") as f:
        json.dump(ledger, f, indent=2)
        f.write("\n")

    lines = [
        f"# Top-down 5 GiB ledger — {report.get('hostname', 'unknown')}",
        f"Captured: {captured_at}",
        "",
        "| Size (GiB) | Path |",
        "|---:|---|",
    ]
    for item in sorted(buckets, key=lambda b: -(b.get("measured_kb") or 0)):
        lines.append(f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} |")
    for item in oversize:
        lines.append(
            f"| {gib(item.get('measured_kb')):.1f} | {item.get('path')} (indivisible file) |"
        )
    lines.append(f"| {gib(report.get('residual_kb')):.1f} | _residual (unattributed)_ |")
    lines.append("")
    lines.append(f"Balanced: {str(bool(equation.get('displayed_balanced'))).lower()}")
    with open(os.path.join(args.out_dir, "topdown-5g.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

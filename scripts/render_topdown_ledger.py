#!/usr/bin/env python3
"""Refresh ledger/topdown-5g.{json,md} from the frontier scanner's report
(design: roadmap/2026-07-21-generic-split-state-repo-design.md, "Snapshot/commit
flow"). Freshness-gated: silently no-ops (exit 0, ledger files untouched) when
the frontier report is missing, unreadable, or older than 36h — the same
staleness threshold scripts/disk_snapshot.sh already applies when embedding
topdown_coverage into the snapshot JSON, so a stale scan never overwrites a
fresher committed ledger with worse data.

The mega-table is also publication-gated: only a fresh report that explicitly
declares a complete coverage envelope may replace the last published table.
Partial reports leave both table files untouched and record their status in a
sidecar (``topdown-5g.status.json``).
"""
import argparse, datetime, json, os, sys

STALE_HOURS = 36
LEDGER_JSON = "topdown-5g.json"
LEDGER_MD = "topdown-5g.md"
STATUS_JSON = "topdown-5g.status.json"


def gib(kb):
    return (kb or 0) / 1024.0 / 1024.0


def write_status(out_dir, status, reason, captured_at, age_hours, report=None):
    report = report or {}
    with open(os.path.join(out_dir, STATUS_JSON), "w") as f:
        json.dump(
            {
                "status": status,
                "reason": reason,
                "captured_at": captured_at,
                "age_hours": round(age_hours, 3),
                "mode": report.get("mode"),
                "coverage_envelope": report.get("coverage_envelope"),
            },
            f,
            indent=2,
        )
        f.write("\n")


def complete_coverage_envelope(report):
    """Return true only when the scanner made an explicit full-pass claim."""
    envelope = report.get("coverage_envelope")
    return (
        report.get("mode") == "complete"
        and isinstance(envelope, dict)
        and envelope.get("complete") is True
    )


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
        if os.path.isdir(args.out_dir):
            write_status(args.out_dir, "stale", "frontier_report_stale", captured_at, age_hours, report)
        return 0  # stale — leave prior ledger in place

    os.makedirs(args.out_dir, exist_ok=True)
    if not complete_coverage_envelope(report):
        # A partial scan is useful evidence, but it is not a replacement for
        # the last coherent mega-table. Keep the published rows byte-for-byte
        # stable and expose the current scan state separately.
        write_status(
            args.out_dir,
            "partial",
            "coverage_incomplete",
            captured_at,
            age_hours,
            report,
        )
        return 0

    buckets = report.get("granularity_buckets") or []
    oversize = report.get("oversize_indivisible_files") or []
    equation = report.get("accounting_equation") or {}

    ledger = {
        "schema_version": 1,
        "mode": report.get("mode"),
        "coverage_envelope": report.get("coverage_envelope"),
        "captured_at": captured_at,
        "hostname": report.get("hostname"),
        "disk_used_kb": report.get("disk_used_kb"),
        "residual_kb": report.get("residual_kb"),
        "purgeable_kb": report.get("purgeable_kb"),
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": equation,
    }
    with open(os.path.join(args.out_dir, LEDGER_JSON), "w") as f:
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
    with open(os.path.join(args.out_dir, LEDGER_MD), "w") as f:
        f.write("\n".join(lines) + "\n")
    write_status(
        args.out_dir,
        "published",
        "complete_coverage",
        captured_at,
        age_hours,
        report,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

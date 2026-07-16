#!/usr/bin/env python3
# disk_history.sh — Show historical disk usage trends from git-committed snapshots
#
# Usage:
#   ./scripts/disk_history.sh                    # last 30 snapshots
#   ./scripts/disk_history.sh --days 7           # last 7 days
#   ./scripts/disk_history.sh --limit 10         # last 10 snapshots
#   ./scripts/disk_history.sh --regressions      # only show regressions

import sys
import os
import json
import subprocess
import argparse
from datetime import datetime, timezone

def run_cmd(cmd, cwd=None):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True, cwd=cwd)
        return res.stdout.strip()
    except subprocess.CalledProcessError:
        return ""

def fmt_kb(kb):
    gb = kb / 1024 / 1024
    if gb >= 1.0:
        return f"{gb:.1f}G"
    elif gb >= 0.001:
        return f"{gb*1024:.0f}M"
    else:
        return f"{kb:.0f}K"

def main():
    parser = argparse.ArgumentParser(description="Show historical disk usage trends")
    parser.add_argument("--days", type=int, help="Limit history to N days ago")
    parser.add_argument("--limit", type=int, default=30, help="Max snapshots to show")
    parser.add_argument("--regressions", action="store_true", help="Show regressions only")
    parser.add_argument("--growth-rate", action="store_true",
                        help="Compute and print growth_rate_kb_per_day per top-level dir "
                             "(linear regression over snapshots in range)")
    parser.add_argument("--growth-window", type=int, default=7,
                        help="Days of history to use for --growth-rate (default 7)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    script_repo_root = os.path.dirname(script_dir)

    # Look for candidates. Honor the wrapper-provided backup repo path first,
    # then preserve the historical repo-local backup/* behavior.
    explicit_snapshot = os.environ.get("DISK_SNAPSHOT_JSON", "")
    if explicit_snapshot and os.path.exists(explicit_snapshot):
        best_path = os.path.realpath(explicit_snapshot)
        repo_root = os.path.realpath(
            run_cmd("git rev-parse --show-toplevel", cwd=os.path.dirname(best_path)) or script_repo_root
        )
    else:
        repo_root = script_repo_root

        candidates = []
        backup_dir = os.path.join(repo_root, "backup")
        if os.path.exists(backup_dir):
            for host in os.listdir(backup_dir):
                p = os.path.join(backup_dir, host, "disk_snapshot.json")
                if os.path.exists(p):
                    candidates.append(p)

        # Fallback: default backup repo at ~/.disk_magician_backup (setup target)
        if not candidates:
            home_backup = os.path.join(os.path.expanduser("~"), ".disk_magician_backup", "backup")
            if os.path.exists(home_backup):
                for host in os.listdir(home_backup):
                    p = os.path.join(home_backup, host, "disk_snapshot.json")
                    if os.path.exists(p):
                        candidates.append(p)
                if candidates:
                    repo_root = os.path.join(os.path.expanduser("~"), ".disk_magician_backup")

        if not candidates:
            print("No disk_snapshot.json found in backup/*/. Run a backup first to generate one.", file=sys.stderr)
            sys.exit(1)

        # Resolve newest snapshot
        best_path = candidates[0]
        best_ts = ""
        for path in candidates:
            try:
                data = json.load(open(path))
                ts = data.get("timestamp", "")
                if ts > best_ts:
                    best_ts = ts
                    best_path = path
            except Exception:
                pass

    rel_path = os.path.relpath(best_path, repo_root)

    since_arg = f"--since={args.days}.days.ago" if args.days else ""
    log_cmd = f"git log --format='%H %aI' {since_arg} -n {args.limit} -- {rel_path}"
    log_output = run_cmd(log_cmd, cwd=repo_root)

    commits = []
    if log_output:
        for line in log_output.split("\n"):
            if line.strip():
                parts = line.split(" ", 1)
                commits.append((parts[0], parts[1]))

    # Add current working version at the end (newest)
    if os.path.exists(best_path):
        commits.insert(0, ("WORKING", datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")))

    if not commits:
        print(f"No snapshots found in git history for {rel_path}", file=sys.stderr)
        sys.exit(1)

    # We need to process commits from oldest to newest to track changes
    commits.reverse()

    snapshots = []
    all_keys = set()
    for sha, ts in commits:
        if sha == "WORKING":
            try:
                data = json.load(open(best_path))
            except Exception:
                continue
        else:
            show_cmd = f"git show {sha}:{rel_path}"
            content = run_cmd(show_cmd, cwd=repo_root)
            try:
                data = json.loads(content)
            except Exception:
                continue

        dirs = data.get("directories", {})
        all_keys.update(dirs.keys())
        try:
            ts_obj = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except Exception:
            ts_obj = None
        # has_data: snapshot has at least one numeric (non-null) value
        has_data = any(v is not None for v in dirs.values())
        used_gb = data.get("disk_used_gb")
        coverage = data.get("snapshot_coverage_pct")
        try:
            used_gb = float(used_gb)
        except (TypeError, ValueError):
            used_gb = None
        try:
            coverage = float(coverage)
        except (TypeError, ValueError):
            coverage = None
        snapshots.append({
            "date": ts[:16],
            "date_obj": ts_obj,
            "free": data.get("disk_free_gb", 0),
            "pct": data.get("disk_pct", 0),
            "dirs": dirs,
            "has_data": has_data,
            "used_gb": used_gb,
            "coverage": coverage,
        })

    if not snapshots:
        print("No readable snapshot data found in history.", file=sys.stderr)
        sys.exit(1)

    first = snapshots[0]
    last = snapshots[-1]
    if first["used_gb"] is not None and last["used_gb"] is not None:
        used_delta = last["used_gb"] - first["used_gb"]
        print(
            f"Physical used delta: {used_delta:+.1f} GiB "
            f"({first['used_gb']:.1f} -> {last['used_gb']:.1f} GiB)"
        )
    else:
        print("Physical used delta: unavailable (disk_used_gb missing)")
    if first["coverage"] is not None and last["coverage"] is not None:
        coverage_delta = last["coverage"] - first["coverage"]
        print(
            f"Coverage changed: {coverage_delta:+.1f} percentage points "
            f"({first['coverage']:.1f}% -> {last['coverage']:.1f}%); "
            "directory-bucket deltas are coverage-sensitive and do not prove physical growth."
        )
    else:
        print(
            "Coverage changed: unavailable; directory-bucket deltas are "
            "coverage-sensitive and do not prove physical growth."
        )
    print()

    # ────────── growth_rate_kb_per_day (Lane B Section C) ──────────
    # Linear regression (slope) of (epoch_day, kb) for each top-level
    # dir, over the most-recent N days (default 7). Returns KB/day.
    # Only dirs with >= 3 numeric samples are scored — fewer points
    # would yield meaningless slopes.
    if args.growth_rate:
        growth_window = args.growth_window or 7
        from datetime import timedelta
        cutoff = datetime.now(timezone.utc) - timedelta(days=growth_window)
        in_window = [s for s in snapshots
                     if s["date_obj"] >= cutoff and s.get("has_data", True)]
        if len(in_window) < 2:
            print(f"growth_rate_kb_per_day: need >=2 snapshots in last {growth_window} days; got {len(in_window)}",
                  file=sys.stderr)
        else:
            # Per-key linear regression: slope of (day_offset, kb)
            # day_offset = (snap_date - first_snap_date).total_seconds() / 86400
            t0 = in_window[0]["date_obj"]
            growth = {}
            for k in sorted(all_keys):
                xs, ys = [], []
                for s in in_window:
                    v = s["dirs"].get(k)
                    if v is None:
                        continue
                    try:
                        ys.append(float(v))
                        xs.append((s["date_obj"] - t0).total_seconds() / 86400.0)
                    except (TypeError, ValueError):
                        continue
                if len(xs) < 3:
                    growth[k] = None
                    continue
                # Linear regression slope (least squares)
                n = len(xs)
                mx = sum(xs) / n
                my = sum(ys) / n
                num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
                den = sum((x - mx) ** 2 for x in xs)
                slope = num / den if den > 0 else 0.0
                growth[k] = slope
            # Sort by absolute growth (fastest growers first)
            sorted_growth = sorted(
                [(k, v) for k, v in growth.items() if v is not None],
                key=lambda kv: abs(kv[1]), reverse=True
            )
            print(f"growth_rate_kb_per_day (last {growth_window} days, top growers by |slope|):")
            print(f"  {'directory':<34} {'rate_KB/day':>12} {'rate_GB/day':>12}")
            print("  " + "-" * 60)
            for k, slope in sorted_growth[:25]:
                gb_day = slope / 1024 / 1024
                if abs(gb_day) >= 0.01:
                    rate_str = f"{gb_day:+.2f} GB/d"
                else:
                    rate_str = f"{slope:+.0f} KB/d"
                print(f"  {k:<34} {slope:>+12.1f} {rate_str:>12}")
            # Flag dirs with no data
            no_data = [k for k, v in growth.items() if v is None]
            if no_data:
                print(f"  (skipped {len(no_data)} dirs with <3 numeric samples: {', '.join(no_data[:5])}{'...' if len(no_data) > 5 else ''})",
                      file=sys.stderr)
        # growth_rate mode prints its own table; do not also print the row table.
        print(f"\nSource: git log -- {rel_path} ({len(commits)} snapshots shown)")
        return

    # Select top keys based on current size
    last_dirs = snapshots[-1]["dirs"]
    sorted_keys = sorted(all_keys, key=lambda k: last_dirs.get(k, 0) or 0, reverse=True)
    # limit display to top 12 keys to keep table legible
    display_keys = sorted_keys[:12]

    # Print Table Header
    print(f"{'Date':<16} {'Free':<6} {'Pct':<4}", end="")
    for k in display_keys:
        # short label (first 10 chars)
        label = k[:10]
        print(f" {label:>10}", end="")
    print()
    
    print("-" * 16 + " " + "-" * 6 + " " + "-" * 4, end="")
    for _ in display_keys:
        print(" " + "-" * 10, end="")
    print()

    # Print Rows
    prev_dirs = {}
    prev_coverage = None
    for snap in snapshots:
        date_str = snap["date"]
        free_gb = f"{snap['free']}G"
        pct_str = f"{snap['pct']}%"
        
        row_regressions = []
        coverage_comparable = (
            prev_coverage is not None
            and snap["coverage"] is not None
            and prev_coverage >= 70
            and snap["coverage"] >= 70
            and abs(snap["coverage"] - prev_coverage) <= 5
        )
        for k in display_keys:
            val = snap["dirs"].get(k)
            prev = prev_dirs.get(k)
            if coverage_comparable and val is not None and prev is not None and prev > 0:
                delta = val - prev
                # Regression threshold: grew >1GB or >50%
                if delta > 1024 * 1024 or (delta > 1024 * 100 and delta / prev > 0.5):
                    row_regressions.append(f"{k[:8]}:+{fmt_kb(delta)}")
        
        # Determine if we should print based on regressions filter
        is_low = snap["free"] < 20
        has_reg = len(row_regressions) > 0
        
        if args.regressions and not (is_low or has_reg):
            prev_dirs = snap["dirs"]
            prev_coverage = snap["coverage"]
            continue

        print(f"{date_str:<16} {free_gb:>6} {pct_str:>4}", end="")
        for k in display_keys:
            val = snap["dirs"].get(k)
            if val is None:
                print(f" {'null':>10}", end="")
            else:
                print(f" {fmt_kb(val):>10}", end="")
        
        if is_low:
            print("  LOW!", end="")
        if has_reg:
            print(f"  <- {', '.join(row_regressions)}", end="")
        if prev_dirs and not coverage_comparable:
            print("  COVERAGE_CHANGE: directory deltas incomparable", end="")
        print()
        
        prev_dirs = snap["dirs"]
        prev_coverage = snap["coverage"]

    print(f"\nLegend: sizes in KB. Regression = grew >1GB or >50% vs previous snapshot.")
    print(f"Source: git log -- {rel_path} ({len(commits)} snapshots shown)")

if __name__ == "__main__":
    main()

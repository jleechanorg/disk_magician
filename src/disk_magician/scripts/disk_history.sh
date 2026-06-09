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
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)

    # Source snapshot_lib via bash to resolve path, or do it locally
    snapshot_path = ""
    # Look for candidates
    candidates = []
    backup_dir = os.path.join(repo_root, "backup")
    if os.path.exists(backup_dir):
        for host in os.listdir(backup_dir):
            p = os.path.join(backup_dir, host, "disk_snapshot.json")
            if os.path.exists(p):
                candidates.append(p)
                
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
        snapshots.append({
            "date": ts[:16],
            "free": data.get("disk_free_gb", 0),
            "pct": data.get("disk_pct", 0),
            "dirs": dirs
        })

    if not snapshots:
        print("No readable snapshot data found in history.", file=sys.stderr)
        sys.exit(1)

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
    for snap in snapshots:
        date_str = snap["date"]
        free_gb = f"{snap['free']}G"
        pct_str = f"{snap['pct']}%"
        
        row_regressions = []
        for k in display_keys:
            val = snap["dirs"].get(k)
            prev = prev_dirs.get(k)
            if val is not None and prev is not None and prev > 0:
                delta = val - prev
                # Regression threshold: grew >1GB or >50%
                if delta > 1024 * 1024 or (delta > 1024 * 100 and delta / prev > 0.5):
                    row_regressions.append(f"{k[:8]}:+{fmt_kb(delta)}")
        
        # Determine if we should print based on regressions filter
        is_low = snap["free"] < 20
        has_reg = len(row_regressions) > 0
        
        if args.regressions and not (is_low or has_reg):
            prev_dirs = snap["dirs"]
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
        print()
        
        prev_dirs = snap["dirs"]

    print(f"\nLegend: sizes in KB. Regression = grew >1GB or >50% vs previous snapshot.")
    print(f"Source: git log -- {rel_path} ({len(commits)} snapshots shown)")

if __name__ == "__main__":
    main()

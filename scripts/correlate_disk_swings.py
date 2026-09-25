#!/usr/bin/env python3
"""correlate_disk_swings.py — attribute disk_used_gb swings to non-file signals.

Bead: disk_magician-rpv ("Attribute bidirectional df swings (±8-62 GiB
within an hour, 80+ in 10 days) via non-file signals: APFS purgeable, local
snapshots, swap/VM volume, Colima diffdisk").

Lane D found that disk_snapshot.json's disk_used_gb swings both directions
by 8-62 GiB, often reversing within 1-3 snapshots, and that file
birth/mtime probes over the usual scratch roots explain <=14% of that
movement. This script reads the git-committed history of
~/.disk_magician_backup/snapshots/disk_snapshot.json (read-only: `git log`
and `git show` only, never a write to that repo — it is another lane's
ledger, not this script's to mutate), finds swings of >= --min-swing-gib
GiB within <= --max-window-minutes minutes, and attributes each swing's
magnitude to the additive non-file signals disk_snapshot.sh now records
(scripts/disk_snapshot.sh, same bead).

Attribution method (deliberately mechanical, not hand-picked per swing):
for each candidate signal, compute its own delta over the same window; if
the signal moved in the same direction as the swing, count
min(|signal_delta|, remaining unattributed magnitude) as attributed to it.

Volume-boundary constraint on candidate signals (/advice review, Codex +
Opus, both high confidence, 2026-09-25): disk_used_gb is `df`'s Used figure
for /System/Volumes/Data specifically (see get_disk_stats() in
disk_snapshot.sh) — it is NOT a whole-container figure. VM, Preboot, and
Update are separate APFS volumes in the same container; their growth moves
the container's shared free-space pool (and therefore disk_free_gb) but
cannot move Data's own Used figure. Crediting a Data-volume swing to
VM/Preboot/Update/swap/container-free growth records a coincidence, not a
cause, and — because `swap_used_gb`, `vm_volume_used_gb`, and
`apfs_volumes_gb["VM"]` all measure the same underlying VM-volume change —
would let one physical event get credited up to three times, which is
exactly the fabricated attribution this script exists to avoid. Colima's
diffdisk lives on the Data volume itself, so it is the only signal here
that can be a genuine sub-component of a Data-volume swing, and is the only
one in ATTRIBUTION_SIGNALS. The other recorded fields (apfs_volumes_gb.VM/
Preboot/Update, apfs_container_free_gb, apfs_purgeable_estimate_gb,
swap_used_gb, vm_volume_used_gb) remain in the snapshot for their own sake
(explaining disk_free_gb / whole-container swings is a separate, unbuilt
analysis) but are deliberately excluded here.

The Data-volume's own apfs_volumes_gb["Data"] delta is reported separately
as a consistency check (it should nearly equal the swing itself, since
disk_used_gb IS the Data volume's df-reported Used) rather than folded into
the attribution sum, which would otherwise be circular.

Old snapshots predate this bead and lack every new key — a swing where
either endpoint is missing them has NO_COVERAGE and is reported as such
rather than silently attributed 0%. A signal that disk_snapshot.sh could not
measure this tick (probe failure, e.g. a `du` timeout on the diffdisk) is
recorded as JSON `null`, never a fabricated `0` — see disk_snapshot.sh's
null-vs-zero handling, same review — so a transient probe failure cannot be
misread here as a real multi-GiB swing in the signal itself.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_BACKUP_REPO = os.path.expanduser("~/.disk_magician_backup")
DEFAULT_RELPATH = "snapshots/disk_snapshot.json"

# (dotted path into the snapshot dict, human label). See module docstring
# "Volume-boundary constraint": only a signal that can be a genuine
# sub-component of disk_used_gb (the Data volume's own df Used) belongs
# here. VM/Preboot/Update/swap/container-free are excluded — they live on
# other APFS volumes or the shared container pool and cannot causally move
# Data's own Used figure; apfs_volumes_gb.Data itself is excluded because it
# IS the swing (reported separately as a consistency check, not summed).
ATTRIBUTION_SIGNALS = [
    ("colima_diffdisk_du_allocated_gb", "Colima diffdisk (du)"),
]

# Keys whose presence marks a snapshot as "post-deploy" for this bead — this
# checks KEY EXISTENCE, not a non-null value, because a transient probe
# failure on one tick (recorded as null, see disk_snapshot.sh) must not make
# an otherwise-fully-deployed snapshot look like it predates the bead.
COVERAGE_MARKER_KEYS = (
    "apfs_volumes_gb",
    "local_snapshots_count",
    "colima_diffdisk_du_allocated_gb",
)


class GitReadOnlyError(RuntimeError):
    pass


def run_git(repo, args):
    """Read-only git wrapper. Refuses any subcommand that isn't log/show."""
    if args[0] not in ("log", "show"):
        raise GitReadOnlyError(f"correlate_disk_swings.py only ever runs git log/show, refused: {args}")
    proc = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def get_nested(d, dotted_path):
    node = d
    for part in dotted_path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    if isinstance(node, (int, float)) and not isinstance(node, bool):
        return float(node)
    return None


def has_coverage(snapshot):
    # Key existence, not non-null value: a probe that failed on this one
    # tick is recorded as null (see disk_snapshot.sh's null-vs-zero fix),
    # and that single-tick failure must not make an otherwise fully-deployed
    # snapshot look pre-deploy.
    return all(key in snapshot for key in COVERAGE_MARKER_KEYS)


def parse_timestamp(snapshot, fallback_iso):
    ts = snapshot.get("timestamp")
    if isinstance(ts, str):
        try:
            return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.fromisoformat(fallback_iso)


def load_snapshot_history(repo, relpath):
    """Returns a time-ordered (oldest first) list of dicts:
    {sha, commit_time, timestamp, data} — one per commit that touched
    relpath and produced valid JSON. Commits with unparseable content are
    skipped (reported separately), never crash the walk.
    """
    log_out = run_git(repo, ["log", "--format=%H|%aI", "--", relpath])
    entries = []
    skipped = 0
    for line in reversed(log_out.strip().splitlines()):  # reversed: oldest first
        if not line:
            continue
        sha, _, commit_iso = line.partition("|")
        try:
            raw = run_git(repo, ["show", f"{sha}:{relpath}"])
            data = json.loads(raw)
        except (RuntimeError, json.JSONDecodeError):
            skipped += 1
            continue
        entries.append(
            {
                "sha": sha,
                "commit_time": datetime.fromisoformat(commit_iso),
                "timestamp": parse_timestamp(data, commit_iso),
                "data": data,
            }
        )
    return entries, skipped


def find_swings(entries, min_swing_gib, max_window_minutes):
    swings = []
    for prev, curr in zip(entries, entries[1:]):
        prev_used = prev["data"].get("disk_used_gb")
        curr_used = curr["data"].get("disk_used_gb")
        if prev_used is None or curr_used is None:
            continue
        window_minutes = (curr["timestamp"] - prev["timestamp"]).total_seconds() / 60.0
        if window_minutes <= 0:
            continue
        delta_gb = curr_used - prev_used
        if abs(delta_gb) >= min_swing_gib and window_minutes <= max_window_minutes:
            swings.append({"prev": prev, "curr": curr, "delta_gb": delta_gb, "window_minutes": window_minutes})
    return swings


def attribute_swing(swing):
    prev, curr, delta_gb = swing["prev"]["data"], swing["curr"]["data"], swing["delta_gb"]
    result = {"per_signal": [], "attributed_gb": 0.0}

    data_prev = get_nested(prev, "apfs_volumes_gb.Data")
    data_curr = get_nested(curr, "apfs_volumes_gb.Data")
    if data_prev is not None and data_curr is not None:
        data_delta = data_curr - data_prev
        result["data_volume_consistency_gb"] = round(data_delta, 3)
        result["data_volume_consistency_pct"] = (
            round(min(abs(data_delta), abs(delta_gb)) / abs(delta_gb) * 100, 1) if delta_gb else 0.0
        )
    else:
        result["data_volume_consistency_gb"] = None
        result["data_volume_consistency_pct"] = None

    remaining = abs(delta_gb)
    for path, label in ATTRIBUTION_SIGNALS:
        prev_v = get_nested(prev, path)
        curr_v = get_nested(curr, path)
        if prev_v is None or curr_v is None or remaining <= 0:
            continue
        signal_delta = curr_v - prev_v
        same_direction = (signal_delta > 0) == (delta_gb > 0) and signal_delta != 0
        if not same_direction:
            continue
        contrib = min(abs(signal_delta), remaining)
        if contrib <= 0:
            continue
        remaining -= contrib
        result["attributed_gb"] += contrib
        result["per_signal"].append({"label": label, "delta_gb": round(signal_delta, 3), "contrib_gb": round(contrib, 3)})

    result["attributed_pct"] = round(result["attributed_gb"] / abs(delta_gb) * 100, 1) if delta_gb else 0.0
    result["unexplained_gb"] = round(abs(delta_gb) - result["attributed_gb"], 3)
    result["unexplained_pct"] = round(100.0 - result["attributed_pct"], 1)
    return result


def fmt_ts(dt):
    return dt.strftime("%Y-%m-%dT%H:%M")


def build_report(entries, skipped, swings, min_swing_gib, max_window_minutes):
    lines = []
    lines.append("Non-file-signal swing correlation report (bead disk_magician-rpv)")
    if entries:
        lines.append(
            f"History: {len(entries)} snapshots ({skipped} skipped/unparseable), "
            f"{fmt_ts(entries[0]['timestamp'])} .. {fmt_ts(entries[-1]['timestamp'])}"
        )
    else:
        lines.append("History: no snapshots found.")

    coverage_start = next((e for e in entries if has_coverage(e["data"])), None)
    covered_count = sum(1 for e in entries if has_coverage(e["data"]))
    if coverage_start:
        lines.append(
            f"Non-file-signal coverage: first present at commit {coverage_start['sha'][:12]} "
            f"({fmt_ts(coverage_start['timestamp'])}); {covered_count}/{len(entries)} snapshots covered. "
            "Snapshots before this commit predate the bead and cannot be attributed."
        )
    else:
        lines.append(
            "Non-file-signal coverage: NONE of the snapshots in this history have the new keys yet — "
            "every snapshot here predates this deploy. Coverage starts at the next real 35-min snapshot; "
            "swings below are reported as NO_COVERAGE, not attributed."
        )

    lines.append("")
    lines.append(
        f"Swings found (>= {min_swing_gib} GiB within <= {max_window_minutes} min): {len(swings)}"
    )

    covered_swings = []
    uncovered_swings = []
    for s in swings:
        if has_coverage(s["prev"]["data"]) and has_coverage(s["curr"]["data"]):
            covered_swings.append(s)
        else:
            uncovered_swings.append(s)

    lines.append(f"  With coverage (attributable): {len(covered_swings)}")
    lines.append(f"  NO_COVERAGE (predates this bead, cannot attribute): {len(uncovered_swings)}")
    lines.append("")

    attributed_results = []
    if covered_swings:
        lines.append("Per-swing attribution (coverage available):")
        for i, s in enumerate(covered_swings, 1):
            attribution = attribute_swing(s)
            attributed_results.append(attribution)
            lines.append(
                f"  [{i}] {fmt_ts(s['prev']['timestamp'])} -> {fmt_ts(s['curr']['timestamp'])} "
                f"({s['window_minutes']:.0f} min): {s['delta_gb']:+.1f} GiB"
            )
            if attribution["data_volume_consistency_gb"] is not None:
                lines.append(
                    f"      Data volume confirms: {attribution['data_volume_consistency_gb']:+.2f} GiB "
                    f"({attribution['data_volume_consistency_pct']}% of swing)"
                )
            for sig in attribution["per_signal"]:
                lines.append(
                    f"      {sig['label']}: {sig['delta_gb']:+.2f} GiB (contributes {sig['contrib_gb']:.2f} GiB)"
                )
            lines.append(
                f"      Attributed: {attribution['attributed_gb']:.2f} GiB ({attribution['attributed_pct']}%) | "
                f"Unexplained: {attribution['unexplained_gb']:.2f} GiB ({attribution['unexplained_pct']}%)"
            )
        lines.append("")

    if uncovered_swings:
        lines.append("NO_COVERAGE swings (snapshot predates non-file-signal tracking):")
        for s in uncovered_swings:
            lines.append(
                f"  {fmt_ts(s['prev']['timestamp'])} -> {fmt_ts(s['curr']['timestamp'])} "
                f"({s['window_minutes']:.0f} min): {s['delta_gb']:+.1f} GiB (commit {s['curr']['sha'][:12]})"
            )
        lines.append("")

    hit_bar = sum(1 for a in attributed_results if a["attributed_pct"] >= 80.0)
    lines.append("Acceptance bar (bead disk_magician-rpv): >=10 swings correlated with >=80% of bytes attributed.")
    if len(covered_swings) == 0:
        lines.append(
            "VERDICT: NOT MET — zero swings have non-file-signal coverage yet (all history predates this "
            "deploy). Re-run this script after the next several 35-min snapshots accumulate; this run only "
            "proves the attribution logic is wired correctly (see tests/test_correlate_disk_swings.py)."
        )
    elif len(covered_swings) < 10:
        lines.append(
            f"VERDICT: NOT YET MET — only {len(covered_swings)} covered swing(s) so far "
            f"({hit_bar} at/above 80% attribution). Needs >=10 covered swings to evaluate the full bar."
        )
    elif hit_bar >= 10:
        lines.append(f"VERDICT: MET — {hit_bar}/{len(covered_swings)} covered swings reach >=80% attribution.")
    else:
        missing_signals = sorted(
            {
                path
                for path, _ in ATTRIBUTION_SIGNALS
                if not any(
                    get_nested(s["prev"]["data"], path) is not None and get_nested(s["curr"]["data"], path) is not None
                    for s in covered_swings
                )
            }
        )
        lines.append(
            f"VERDICT: NOT MET — only {hit_bar}/{len(covered_swings)} covered swings reach >=80% attribution."
        )
        if missing_signals:
            lines.append(f"  Signals never populated across these swings: {', '.join(missing_signals)}")

    return "\n".join(lines), {
        "covered_swings": len(covered_swings),
        "uncovered_swings": len(uncovered_swings),
        "hit_80pct_bar": hit_bar,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=DEFAULT_BACKUP_REPO, help="Backup repo path (default: ~/.disk_magician_backup)")
    parser.add_argument("--path", default=DEFAULT_RELPATH, help="Path within repo to the snapshot JSON (default: snapshots/disk_snapshot.json)")
    parser.add_argument("--min-swing-gib", type=float, default=8.0)
    parser.add_argument("--max-window-minutes", type=float, default=60.0)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of the text report")
    args = parser.parse_args()

    if not os.path.isdir(os.path.join(args.repo, ".git")):
        print(f"ERROR: {args.repo} is not a git repository", file=sys.stderr)
        return 2

    entries, skipped = load_snapshot_history(args.repo, args.path)
    swings = find_swings(entries, args.min_swing_gib, args.max_window_minutes)
    report, summary = build_report(entries, skipped, swings, args.min_swing_gib, args.max_window_minutes)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""check_uncovered_roots.py — flag >=5 GiB directories not covered by any
registered cleanup sweeper's root list (bead disk_magician-8to).

Never runs a fresh `du`. Reads whichever of these two already-measured
data sources is available (frontier preferred — it has per-subdir
granularity; discover is a coarser $HOME-top-level-only fallback):
  - ~/.disk_magician_state/frontier_last.json  (disk_frontier_scan.py)
  - ~/.disk_magician_state/discover_last.json  (disk_snapshot.sh --discover)

Reuses disk_report_breakdown's path-trie (Node/build_tree/extract_direct_kb)
to roll sizes up a directory tree, then drills from the root down to the
smallest >=threshold subtree that is not covered by a registered sweeper
root (config/sweeper_roots.txt) — the same "opaque leaf" drill-down pattern
disk_report_breakdown uses for undecomposed buckets, gated on sweeper
coverage instead of literal absence of children.
"""
import argparse
import glob
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disk_report_breakdown as drb  # noqa: E402

GIB_KB = 1024 * 1024
DEFAULT_THRESHOLD_GIB = 5
DEFAULT_MAX_AGE_HOURS = 72


def resolve_darwin_tmp():
    """Canonicalized `getconf DARWIN_USER_TEMP_DIR` (realpath'd, no
    trailing slash), or None if unresolvable (non-macOS, getconf missing)."""
    try:
        raw = subprocess.run(
            ["getconf", "DARWIN_USER_TEMP_DIR"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout.strip()
    except Exception:
        return None
    if not raw:
        return None
    return os.path.realpath(raw).rstrip("/")


def expand_pattern(pattern, home, darwin_tmp):
    """Substitute $HOME / $DARWIN_USER_TEMP_DIR tokens, then glob-expand any
    remaining '*'. Returns a list of no-trailing-slash roots. A
    $DARWIN_USER_TEMP_DIR pattern is dropped entirely when the token can't
    be resolved (no fabricated coverage).

    Deliberately does NOT realpath() every entry: frontier/discover bucket
    paths are recorded as-scanned (not symlink-resolved beyond whatever the
    scanner itself already did), so re-resolving symlinks only here would
    silently desync registry roots from bucket paths (e.g. macOS's
    /var -> /private/var). DARWIN_USER_TEMP_DIR is the one deliberate
    exception: `getconf DARWIN_USER_TEMP_DIR` is canonicalized once, by the
    caller, before it ever reaches this function (see resolve_darwin_tmp),
    matching disk_audit.sh's existing `pwd -P` canonicalization of the same
    value.
    """
    if "$DARWIN_USER_TEMP_DIR" in pattern:
        if not darwin_tmp:
            return []
        pattern = pattern.replace("$DARWIN_USER_TEMP_DIR", darwin_tmp)
    pattern = pattern.replace("$HOME", home)
    if "*" in pattern:
        # normpath (lexical only, e.g. collapsing "/../") — never realpath,
        # which would re-resolve symlinks glob() already walked through.
        return [os.path.normpath(m) for m in glob.glob(pattern)]
    return [os.path.normpath(pattern)]


def load_registry(path, home=None, darwin_tmp=None):
    """Parse the tab-separated sweeper root registry. Returns a list of
    (expanded_root, owner) tuples. Blank lines and '#' comments are
    skipped."""
    home = home or os.path.expanduser("~")
    roots = []
    if not path or not os.path.exists(path):
        return roots
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            pattern = parts[0].strip()
            owner = parts[1].strip() if len(parts) > 1 else ""
            if not pattern:
                continue
            for expanded in expand_pattern(pattern, home, darwin_tmp):
                if expanded:
                    roots.append((expanded, owner))
    return roots


def is_covered(path, roots):
    for root, _owner in roots:
        if not root:
            continue
        if path == root or path.startswith(root + "/"):
            return True
    return False


def load_snapshot_direct_kb(snapshot_path):
    """Frontier-schema snapshot (granularity_buckets + oversize_indivisible_files)
    -> path->kb map, via disk_report_breakdown's own loader/normalizer."""
    snap = drb.load_snapshot(snapshot_path)
    return snap, drb.extract_direct_kb(snap)


def load_discover_direct_kb(discover_path):
    """discover_last.json's flat {entries:[{path,size_kb,...}]} schema
    adapted into the same path->kb shape frontier snapshots use, so it can
    feed the same tree-rollup drill-down. Coarser than frontier: discover
    only records $HOME-top-level candidates, so drill-down here effectively
    stops at depth 1."""
    with open(discover_path) as f:
        data = json.load(f)
    direct = {}
    for entry in data.get("entries") or []:
        path = entry.get("path")
        if not path:
            continue
        path = drb.normalize_path(path)
        direct[path] = direct.get(path, 0) + int(entry.get("size_kb") or 0)
    return data, direct


def snapshot_age_hours(snapshot_path):
    try:
        snap = drb.load_snapshot(snapshot_path)
    except Exception:
        return None
    import datetime
    ts = snap.get("captured_at") or snap.get("timestamp")
    if not ts:
        return None
    try:
        t = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        if t.tzinfo is None:
            t = t.replace(tzinfo=datetime.timezone.utc)
        return (now - t).total_seconds() / 3600.0
    except Exception:
        return None


def pick_direct_kb(snapshot_path, discover_path, max_age_hours):
    """Prefer a fresh frontier/ledger-schema snapshot (deep granularity);
    fall back to discover data (coarse, $HOME-top-level only) when the
    snapshot is missing or stale. Returns (direct_kb, source_label)."""
    if snapshot_path and os.path.exists(snapshot_path):
        age = snapshot_age_hours(snapshot_path)
        if age is None or age <= max_age_hours:
            try:
                _snap, direct = load_snapshot_direct_kb(snapshot_path)
                return direct, f"snapshot:{snapshot_path}"
            except Exception:
                pass
    if discover_path and os.path.exists(discover_path):
        try:
            _data, direct = load_discover_direct_kb(discover_path)
            return direct, f"discover:{discover_path}"
        except Exception:
            pass
    return {}, "none"


def find_uncovered(node, roots, threshold_kb, path_stack=None, out=None):
    """Drill from the tree root down to the smallest >=threshold_kb subtree
    that is not covered by any registered sweeper root. Mirrors
    disk_report_breakdown.find_opaque_leaves' recursion, but the stop
    condition is "no >=threshold child AND not covered" instead of "no
    children at all"."""
    if out is None:
        out = []
    path_stack = path_stack or []
    full = drb.full_path(path_stack)
    total = drb.subtree_kb(node)
    if total < threshold_kb:
        return out
    if is_covered(full, roots):
        return out
    big_children = [
        (name, child) for name, child in node.children.items()
        if drb.subtree_kb(child) >= threshold_kb
    ]
    if not big_children:
        out.append({"path": full, "size_kb": total})
        return out
    for name, child in big_children:
        find_uncovered(child, roots, threshold_kb, path_stack + [name], out)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    default_state_dir = os.path.expanduser(
        os.environ.get("DISK_MAGICIAN_STATE_DIR", "~/.disk_magician_state")
    )
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument(
        "--snapshot", default=os.path.join(default_state_dir, "frontier_last.json"),
        help="Frontier/ledger-schema JSON (granularity_buckets). Preferred source.",
    )
    parser.add_argument(
        "--discover", default=os.path.join(default_state_dir, "discover_last.json"),
        help="discover_last.json fallback (coarser, $HOME-top-level only).",
    )
    parser.add_argument(
        "--registry", default=os.path.join(repo_root, "config", "sweeper_roots.txt"),
        help="Tab-separated sweeper root registry.",
    )
    parser.add_argument("--home", default=None, help="Override $HOME expansion (testing).")
    parser.add_argument(
        "--darwin-tmp", default=None,
        help="Override $DARWIN_USER_TEMP_DIR expansion (testing). "
             "Omit to auto-resolve via `getconf DARWIN_USER_TEMP_DIR`.",
    )
    parser.add_argument("--threshold-gib", type=float, default=DEFAULT_THRESHOLD_GIB)
    parser.add_argument("--max-age-hours", type=float, default=DEFAULT_MAX_AGE_HOURS)
    parser.add_argument("--json", action="store_true", help="Machine-readable output.")
    args = parser.parse_args(argv)

    threshold_kb = args.threshold_gib * GIB_KB
    darwin_tmp = args.darwin_tmp if args.darwin_tmp is not None else resolve_darwin_tmp()
    home = args.home or os.path.expanduser("~")

    roots = load_registry(args.registry, home=home, darwin_tmp=darwin_tmp)
    direct_kb, source = pick_direct_kb(args.snapshot, args.discover, args.max_age_hours)

    if not direct_kb:
        result = {"source": source, "threshold_gib": args.threshold_gib, "uncovered": []}
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print("check_uncovered_roots: no frontier/discover data available — skipping "
                  "(run `disk_magician.sh discover` or wait for the frontier scan).")
        return 0

    root_node = drb.build_tree(direct_kb)
    uncovered = find_uncovered(root_node, roots, threshold_kb)
    uncovered.sort(key=lambda e: e["size_kb"], reverse=True)
    for e in uncovered:
        e["size_gib"] = round(e["size_kb"] / GIB_KB, 1)

    if args.json:
        print(json.dumps(
            {"source": source, "threshold_gib": args.threshold_gib, "uncovered": uncovered},
            indent=2,
        ))
        return 0

    if not uncovered:
        print(f"check_uncovered_roots: no uncovered >= {args.threshold_gib:g} GiB "
              f"directories found (source: {source}).")
        return 0

    print(f"check_uncovered_roots: {len(uncovered)} UNCOVERED directory(ies) "
          f">= {args.threshold_gib:g} GiB with no registered sweeper owner "
          f"(source: {source}):")
    for e in uncovered:
        print(f"  UNCOVERED: {e['path']}  ({e['size_gib']} GiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

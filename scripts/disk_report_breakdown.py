#!/usr/bin/env python3
"""disk_report_breakdown.py — build a full >=5GiB-granularity disk breakdown
tree from a ledger/frontier snapshot, list opaque >5GiB leaves for parallel
drill-down, and render the final reconciled markdown report.

Two subcommands:
  list-opaque-leaves --snapshot <path>
  render --snapshot <path> --scratch-dir <dir> --df-total-kb N --df-free-kb N --out <path>

This script never spawns subagents or shells out to du/ls itself — the
parallel fan-out over opaque leaves (skills/disk-report/SKILL.md step 5)
is done by the agent runtime via Bash/Task calls. This script only parses,
reconciles, and renders.

Scratch file schema (one JSON file per drilled leaf, written by a fan-out
lane under docs/.disk-report-scratch/<slug>.json):
  {"leaf": "<path>", "children": [{"path": "<abs path>", "kb": <int>}, ...]}

Snapshot schema support: both the committed ledger
(ledger/topdown-5g.json, see scripts/render_topdown_ledger.py) and the raw
frontier scanner state (~/.disk_magician_state/frontier_last.json, see
disk_frontier_scan.py) share the same field names: captured_at,
granularity_buckets (each {"path" or "source_path", "measured_kb"}), and
oversize_indivisible_files (same shape — files too big to subdivide,
folded in as pre-existing opaque leaves). A "size_mb" fallback is also
accepted for robustness against older/adjacent schemas.

No shell pipelines: all parsing/sorting logic is Python (the grep-shim
pipeline-corruption class documented in this repo's operator memory).
"""
import argparse
import json
import os
import re
import sys

GIB_KB = 1024 * 1024
THRESHOLD_KB = 5 * GIB_KB  # 5 GiB — the repo-wide bucket granularity floor
EPSILON_KB = int(0.05 * GIB_KB)  # rounding tolerance for reconciliation gaps
BRACKET_SUFFIX_RE = re.compile(r"\s*\[[^\]]*\]\s*$")
DATA_VOLUME_PREFIX = "/System/Volumes/Data"


def gib(kb):
    """Convert KB to GiB for display."""
    return (kb or 0) / GIB_KB


def normalize_path(raw):
    """Strip a bracketed suffix (e.g. ' [direct files + directory metadata 1/2]')
    and the Data-volume mount prefix from a bucket path."""
    raw = BRACKET_SUFFIX_RE.sub("", raw or "").strip()
    if raw.startswith(DATA_VOLUME_PREFIX):
        raw = raw[len(DATA_VOLUME_PREFIX):] or "/"
    if not raw.startswith("/"):
        raw = "/" + raw
    return raw.rstrip("/") or "/"


def bucket_kb(bucket):
    """Return a bucket's size in KB, supporting measured_kb and size_mb schemas."""
    if bucket.get("measured_kb") is not None:
        return int(bucket["measured_kb"])
    if bucket.get("size_mb") is not None:
        return int(round(bucket["size_mb"] * 1024))
    return 0


def bucket_path(bucket):
    return bucket.get("path") or bucket.get("source_path")


def load_snapshot(snapshot_path):
    """Load a ledger or frontier_last.json snapshot; returns the raw dict."""
    with open(snapshot_path) as f:
        return json.load(f)


def extract_direct_kb(snapshot):
    """Build path->kb map from granularity_buckets + oversize_indivisible_files.
    Both lists are non-overlapping by construction (build_granularity_buckets
    only ever returns nodes <=5GiB; oversize_indivisible_files are the >5GiB
    indivisible remainder measured separately), so summing them is safe."""
    direct = {}
    for bucket in (snapshot.get("granularity_buckets") or []):
        path = bucket_path(bucket)
        if not path:
            continue
        path = normalize_path(path)
        direct[path] = direct.get(path, 0) + bucket_kb(bucket)
    for item in (snapshot.get("oversize_indivisible_files") or []):
        path = bucket_path(item)
        if not path:
            continue
        path = normalize_path(path)
        direct[path] = direct.get(path, 0) + bucket_kb(item)
    return direct


class Node:
    """One component of the path trie. `kb` is direct measured KB attached
    exactly at this path (0 if this path is only ever an ancestor)."""

    __slots__ = ("kb", "children")

    def __init__(self):
        self.kb = 0
        self.children = {}


def build_tree(direct_kb):
    """Insert every direct path into a component trie; returns the root Node."""
    root = Node()
    for path, kb in direct_kb.items():
        parts = [p for p in path.split("/") if p]
        node = root
        for part in parts:
            node = node.children.setdefault(part, Node())
        node.kb += kb
    return root


def full_path(path_stack):
    return "/" + "/".join(path_stack) if path_stack else "/"


def subtree_kb(node):
    total = node.kb
    for child in node.children.values():
        total += subtree_kb(child)
    return total


def find_opaque_leaves(node, path_stack=None, out=None):
    """An opaque leaf is a node with subtree_kb > threshold and zero
    children — a raw bucket/oversize-file entry the ledger measured as one
    undecomposed blob. Nodes with children are expandable, not opaque,
    even if their subtree exceeds the threshold."""
    if path_stack is None:
        path_stack = []
    if out is None:
        out = []
    if not node.children:
        total = node.kb
        if total > THRESHOLD_KB:
            out.append({"path": full_path(path_stack), "subtree_kb": total})
        return out
    for name, child in node.children.items():
        find_opaque_leaves(child, path_stack + [name], out)
    return out


def load_scratch_dir(scratch_dir):
    """Read every *.json scratch file written by a fan-out drill-down lane.
    Robust to a missing/unreadable scratch dir — falls back to an empty map
    (leaves stay opaque/undrilled rather than crashing)."""
    result = {}
    if not scratch_dir or not os.path.isdir(scratch_dir):
        return result
    for fname in sorted(os.listdir(scratch_dir)):
        if not fname.endswith(".json"):
            continue
        try:
            with open(os.path.join(scratch_dir, fname)) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        leaf = data.get("leaf")
        if not leaf:
            continue
        children = []
        for c in (data.get("children") or []):
            cpath, ckb = c.get("path"), c.get("kb")
            if cpath is None or ckb is None:
                continue
            children.append({"path": cpath, "kb": int(ckb)})
        result[normalize_path(leaf)] = {"children": children}
    return result


def render_rows(node, path_stack, depth, scratch_map, rows, gaps):
    """Recursively walk the trie, emitting one row per displayed node and
    recording any reconciliation gap (invariant a: parent == sum(children))."""
    path = full_path(path_stack)
    total = subtree_kb(node)

    if total <= THRESHOLD_KB:
        rows.append({"depth": depth, "path": path, "kb": total, "expanded": False, "opaque": False})
        return

    if not node.children:
        # Opaque >5GiB leaf — splice in scratch drill-down results if present.
        scratch = scratch_map.get(path)
        if scratch is not None:
            children_total = sum(c["kb"] for c in scratch["children"])
            rows.append({"depth": depth, "path": path, "kb": total, "expanded": True, "opaque": False})
            for c in sorted(scratch["children"], key=lambda x: (-x["kb"], x["path"])):
                rows.append({"depth": depth + 1, "path": c["path"], "kb": c["kb"], "expanded": False, "opaque": False})
            gap = total - children_total
            if abs(gap) > EPSILON_KB:
                gaps.append((path, gap, "drilled children sum vs original opaque-leaf measurement"))
        else:
            rows.append({"depth": depth, "path": path, "kb": total, "expanded": False, "opaque": True})
        return

    # Expandable parent: show every immediate child, plus a direct-files
    # row if this node itself carries undecomposed direct measurement.
    rows.append({"depth": depth, "path": path, "kb": total, "expanded": True, "opaque": False})
    children_total = 0
    if node.kb > 0:
        rows.append({
            "depth": depth + 1,
            "path": f"{path} (direct files + directory metadata)",
            "kb": node.kb,
            "expanded": False,
            "opaque": False,
        })
        children_total += node.kb
    for name, child in sorted(node.children.items(), key=lambda kv: (-subtree_kb(kv[1]), kv[0])):
        render_rows(child, path_stack + [name], depth + 1, scratch_map, rows, gaps)
        children_total += subtree_kb(child)
    gap = total - children_total
    if abs(gap) > EPSILON_KB:
        gaps.append((path, gap, "parent != sum(children)"))


def write_report(out_path, args, snapshot, rows, gaps, measured_total_kb, residual_kb, gap_b):
    parent = os.path.dirname(out_path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    captured_at = snapshot.get("captured_at", "unknown")
    hostname = snapshot.get("hostname", "unknown")
    gap_a_pass = len(gaps) == 0
    gap_b_pass = abs(gap_b) <= EPSILON_KB

    lines = [
        "# Disk Report",
        "",
        f"- **Source snapshot:** `{args.snapshot}` (captured_at: {captured_at}, hostname: {hostname})",
        f"- **df (KB):** total={args.df_total_kb} used={args.df_total_kb - args.df_free_kb} free={args.df_free_kb}",
        f"- **df (GiB):** total={gib(args.df_total_kb):.2f} free={gib(args.df_free_kb):.2f} — "
        "not exactly 1024/931 GiB even on a nominal 1TB drive: decimal-vs-binary GiB "
        "conversion plus APFS container/filesystem overhead reduce real usable capacity "
        "(this is expected; always read the live df total, never hardcode 1024 or 931 GiB).",
        f"- **Row count:** {len(rows) + len(gaps) + 1}",
        f"- **Invariant (a) parent == sum(children):** {'PASS' if gap_a_pass else 'FAIL'}"
        + ("" if gap_a_pass else f" — {len(gaps)} gap row(s) below"),
        f"- **Invariant (b) sum(top-level) + residual + free == df total:** "
        f"{'PASS' if gap_b_pass else 'FAIL'} (gap: {gib(gap_b):.2f} GiB; "
        f"measured={gib(measured_total_kb):.2f} GiB, residual={gib(residual_kb):.2f} GiB)",
        "",
        "| GiB | Path |",
        "|---:|---|",
    ]
    for row in rows:
        indent = "  " * row["depth"]
        marker = "▼ " if row["expanded"] else ""
        tag = " [opaque]" if row["opaque"] else ""
        lines.append(f"| {gib(row['kb']):.2f} | {indent}{marker}{row['path']}{tag} |")
    for path, gap_kb, reason in gaps:
        lines.append(f"| {gib(gap_kb):.2f} | (reconciliation gap at {path}: {reason}) |")
    lines.append(f"| {gib(gap_b):.2f} | (unaccounted vs df total capacity) |")

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def cmd_list_opaque_leaves(args):
    snapshot = load_snapshot(args.snapshot)
    direct = extract_direct_kb(snapshot)
    root = build_tree(direct)
    leaves = find_opaque_leaves(root)
    leaves.sort(key=lambda x: (-x["subtree_kb"], x["path"]))
    print(json.dumps(leaves, indent=2))
    return 0


def cmd_render(args):
    snapshot = load_snapshot(args.snapshot)
    direct = extract_direct_kb(snapshot)
    root = build_tree(direct)
    scratch_map = load_scratch_dir(args.scratch_dir)

    rows = []
    gaps = []
    for name, child in sorted(root.children.items(), key=lambda kv: (-subtree_kb(kv[1]), kv[0])):
        render_rows(child, [name], 0, scratch_map, rows, gaps)
    if root.kb > 0:
        rows.insert(0, {"depth": 0, "path": "/ (direct files + directory metadata)",
                         "kb": root.kb, "expanded": False, "opaque": False})

    measured_total_kb = subtree_kb(root)
    residual_kb = int(snapshot.get("residual_kb") or 0)
    gap_b = args.df_total_kb - (measured_total_kb + residual_kb + args.df_free_kb)

    write_report(args.out, args, snapshot, rows, gaps, measured_total_kb, residual_kb, gap_b)
    return 0


def main(argv=None):
    doc = __doc__ or ""
    parser = argparse.ArgumentParser(description=doc.splitlines()[0] if doc else "")
    sub = parser.add_subparsers(dest="command", required=True)

    p1 = sub.add_parser("list-opaque-leaves", help="print JSON array of opaque >5GiB leaves to drill down")
    p1.add_argument("--snapshot", required=True, help="path to ledger or frontier_last.json snapshot")
    p1.set_defaults(func=cmd_list_opaque_leaves)

    p2 = sub.add_parser("render", help="splice in scratch drill-down results and write the markdown report")
    p2.add_argument("--snapshot", required=True, help="path to ledger or frontier_last.json snapshot")
    p2.add_argument("--scratch-dir", default=None, help="dir of per-leaf drill-down JSON results (optional)")
    p2.add_argument("--df-total-kb", type=int, required=True, help="live df total capacity in KB")
    p2.add_argument("--df-free-kb", type=int, required=True, help="live df free space in KB")
    p2.add_argument("--out", required=True, help="output markdown path")
    p2.set_defaults(func=cmd_render)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

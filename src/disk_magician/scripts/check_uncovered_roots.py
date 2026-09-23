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

A directory with no sweeper is not automatically a gap: some paths
(~/.codex/sessions, ~/.claude/projects, ...) are intentionally never swept
by policy — this repo's never-delete list, in safety.local.json /
safety.local.json.template. The tree walk is protection-aware (see
classify_path_protection, ported from safety_lib.sh's safety_is_protected()
matching — cross-validated against the real scripts/safety_check.sh by
tests/test_check_uncovered_roots.py::test_matches_real_safety_check_sh
rather than shelled out to per-node, which would be too slow during a
recursive walk):
  - a directory that itself EQUALS or sits UNDER a never_delete /
    protected_live_paths rule is reported once as PROTECTED and never
    drilled into — the whole subtree is off-limits by policy.
  - under a needs_decision rule the same way, reported as NEEDS-DECISION —
    an operator call, not a permanent policy exclusion, but still an
    unswept gap worth surfacing under its own label.
  - a directory that merely CONTAINS one of those paths somewhere inside
    it (but isn't itself covered by a direct match) keeps drilling
    normally; only when the contained path is too small to form its own
    reportable child does it fall back to CONTAINS-PROTECTED /
    CONTAINS-NEEDS-DECISION, sized as the directory's total minus whatever
    is attributable to the excluded prefix. Never silently dropped.
"""
import argparse
import fnmatch
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


SAFETY_SECTIONS = ("never_delete", "protected_live_paths", "needs_decision")
PROTECTED_SECTIONS = ("never_delete", "protected_live_paths")


def _safety_canon(raw, home):
    """Mirror safety_lib.sh's canon(): expand a leading '~' via `home` (not
    the process's real $HOME, so callers/tests can point safety patterns at
    a fixture tree), expand $VARS, normpath, and strip the
    /System/Volumes/Data firmlink prefix — same normalization
    scripts/safety_lib.sh applies to both the candidate and the pattern."""
    path = raw
    if path == "~":
        path = home
    elif path.startswith("~/"):
        path = home + path[1:]
    path = os.path.expandvars(path)
    path = os.path.normpath(path)
    if path.startswith(drb.DATA_VOLUME_PREFIX + "/"):
        path = path[len(drb.DATA_VOLUME_PREFIX):]
    return path


def load_safety_rules(repo_root, home):
    """Load never_delete/protected_live_paths/needs_decision rules from the
    same file scripts/safety_lib.sh's safety_file_in_use() resolves:
    <repo-root>/safety.local.json (dev override) -> ~/.config/disk-magician/
    safety.local.json (canonical machine-local file, under `home`) -> the
    committed safety.local.json.template. Returns {section: [(pattern,
    reason), ...]}. Missing/unreadable file yields empty rules for every
    section — everything just stays UNCOVERED, which is the correct fail
    mode here (the opposite of safety_lib.sh's own fail-CLOSED default for
    actual deletions: a missing safety file must never fabricate a PROTECTED
    verdict this tool then teaches people to ignore)."""
    empty = {s: [] for s in SAFETY_SECTIONS}
    for candidate in (
        os.path.join(repo_root, "safety.local.json"),
        os.path.join(home, ".config", "disk-magician", "safety.local.json"),
        os.path.join(repo_root, "safety.local.json.template"),
    ):
        if not os.path.isfile(candidate):
            continue
        try:
            with open(candidate) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            return empty
        rules = {}
        for section in SAFETY_SECTIONS:
            entries = []
            for item in cfg.get(section) or []:
                if isinstance(item, str):
                    entries.append((item, ""))
                elif isinstance(item, dict) and item.get("path"):
                    entries.append((item["path"], item.get("reason", "")))
            rules[section] = entries
        return rules
    return empty


def classify_path_protection(full, rules, home):
    """Mirror scripts/safety_lib.sh's safety_is_protected() matching for a
    single already-normalized absolute path (no Data-volume prefix).
    Returns (direct_hits, descendant_hits), each a list of
    (section, pattern, reason):
      direct_hits      — `full` equals or is a descendant of the pattern
                          (the pattern is an ancestor-or-self match of
                          `full` via fnmatch against every ancestor,
                          including `full` itself)
      descendant_hits   — the pattern's fixed (non-glob) prefix lives
                          INSIDE `full` (`full` is an ancestor of the
                          protected path, not the protected path itself)
    Ported to run in-process rather than shelling out to
    scripts/safety_check.sh per node — this is called once per node visited
    during a recursive tree walk, and a subprocess per node does not scale.
    Cross-validated against the real scripts/safety_check.sh by
    tests/test_check_uncovered_roots.py::test_matches_real_safety_check_sh.
    """
    parts = [p for p in full.rstrip("/").split("/") if p]
    ancestors = ["/" + "/".join(parts[: i + 1]) for i in range(len(parts))] or ["/"]
    target = full.rstrip("/")

    direct_hits, descendant_hits = [], []
    for section, entries in rules.items():
        for raw, reason in entries:
            pat = _safety_canon(raw, home)
            if any(fnmatch.fnmatch(a, pat) for a in ancestors):
                direct_hits.append((section, raw, reason))
                continue
            literal = pat.split("*", 1)[0].split("?", 1)[0].split("[", 1)[0].rstrip("/")
            if literal and (literal == target or literal.startswith(target + "/")):
                descendant_hits.append((section, raw, reason))
    return direct_hits, descendant_hits


def _format_reason(section, raw, reason):
    note = f" ({reason})" if reason else ""
    return f"{section}: {raw}{note}"


def _excluded_kb(direct_kb, full, hits, home):
    """Sum direct_kb entries under `full` whose path is covered by one of
    `hits`' canonicalized literal (non-glob) prefixes — mirrors
    safety_lib.sh's own literal-prefix `startswith` check (same imprecision
    on purpose: this must classify a path identically to
    `scripts/safety_check.sh <path>`, not a stricter reimplementation)."""
    literals = set()
    for section, raw, _reason in hits:
        pat = _safety_canon(raw, home)
        literal = pat.split("*", 1)[0].split("?", 1)[0].split("[", 1)[0].rstrip("/")
        if literal:
            literals.add(literal)
    if not literals:
        return 0
    target = full.rstrip("/")
    total = 0
    for p, kb in direct_kb.items():
        if not (p == target or p.startswith(target + "/")):
            continue
        if any(p == lit or p.startswith(lit) for lit in literals):
            total += kb
    return total


def find_uncovered(node, roots, threshold_kb, rules, home, direct_kb,
                    path_stack=None, uncovered_out=None, protected_out=None,
                    needs_decision_out=None):
    """Drill from the tree root down to the smallest >=threshold_kb subtree
    that is not covered by a registered sweeper root (config/sweeper_roots.txt)
    nor by this repo's never-delete/protected-live-path/needs-decision
    policy (safety.local.json). See the module docstring for the full
    PROTECTED / NEEDS-DECISION / CONTAINS-* classification rules. Mirrors
    disk_report_breakdown.find_opaque_leaves' recursion, but the stop
    condition is "no >=threshold child AND not covered/protected" instead
    of "no children at all".

    Returns (uncovered_out, protected_out, needs_decision_out). Entries in
    uncovered_out carry a "label" of "UNCOVERED", "CONTAINS-PROTECTED", or
    "CONTAINS-NEEDS-DECISION" (the latter two also carry a "note" naming
    what was excluded and why); protected_out/needs_decision_out entries
    carry a "reason" naming the matched safety.local.json rule.
    """
    if uncovered_out is None:
        uncovered_out, protected_out, needs_decision_out = [], [], []
    path_stack = path_stack or []
    full = drb.full_path(path_stack)
    total = drb.subtree_kb(node)
    if total < threshold_kb:
        return uncovered_out, protected_out, needs_decision_out
    if is_covered(full, roots):
        return uncovered_out, protected_out, needs_decision_out

    direct_hits, descendant_hits = classify_path_protection(full, rules, home)

    protected_direct = [h for h in direct_hits if h[0] in PROTECTED_SECTIONS]
    if protected_direct:
        section, raw, reason = protected_direct[0]
        protected_out.append({
            "path": full, "size_kb": total,
            "reason": _format_reason(section, raw, reason),
        })
        return uncovered_out, protected_out, needs_decision_out

    nd_direct = [h for h in direct_hits if h[0] == "needs_decision"]
    if nd_direct:
        section, raw, reason = nd_direct[0]
        needs_decision_out.append({
            "path": full, "size_kb": total,
            "reason": _format_reason(section, raw, reason),
        })
        return uncovered_out, protected_out, needs_decision_out

    big_children = [
        (name, child) for name, child in node.children.items()
        if drb.subtree_kb(child) >= threshold_kb
    ]
    if big_children:
        for name, child in big_children:
            find_uncovered(child, roots, threshold_kb, rules, home, direct_kb,
                            path_stack + [name], uncovered_out, protected_out,
                            needs_decision_out)
        return uncovered_out, protected_out, needs_decision_out

    # Leaf-reporting case (no child alone reaches the threshold): if this
    # node merely CONTAINS a protected/needs-decision path too small to
    # isolate on its own, report the remainder instead of silently either
    # calling the whole thing UNCOVERED or PROTECTED.
    protected_descendants = [h for h in descendant_hits if h[0] in PROTECTED_SECTIONS]
    if protected_descendants:
        excluded = _excluded_kb(direct_kb, full, protected_descendants, home)
        remainder = total - excluded
        if remainder >= threshold_kb:
            reasons = "; ".join(_format_reason(*h) for h in protected_descendants)
            uncovered_out.append({
                "path": full, "size_kb": remainder, "label": "CONTAINS-PROTECTED",
                "note": f"excludes {round(excluded / GIB_KB, 1)} GiB under: {reasons}",
            })
        return uncovered_out, protected_out, needs_decision_out

    nd_descendants = [h for h in descendant_hits if h[0] == "needs_decision"]
    if nd_descendants:
        excluded = _excluded_kb(direct_kb, full, nd_descendants, home)
        remainder = total - excluded
        if remainder >= threshold_kb:
            reasons = "; ".join(_format_reason(*h) for h in nd_descendants)
            uncovered_out.append({
                "path": full, "size_kb": remainder, "label": "CONTAINS-NEEDS-DECISION",
                "note": f"excludes {round(excluded / GIB_KB, 1)} GiB under: {reasons}",
            })
        return uncovered_out, protected_out, needs_decision_out

    uncovered_out.append({"path": full, "size_kb": total, "label": "UNCOVERED"})
    return uncovered_out, protected_out, needs_decision_out


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
    rules = load_safety_rules(repo_root, home)
    direct_kb, source = pick_direct_kb(args.snapshot, args.discover, args.max_age_hours)

    empty_result = {"source": source, "threshold_gib": args.threshold_gib,
                     "uncovered": [], "protected": [], "needs_decision": []}
    if not direct_kb:
        if args.json:
            print(json.dumps(empty_result, indent=2))
        else:
            print("check_uncovered_roots: no frontier/discover data available — skipping "
                  "(run `disk_magician.sh discover` or wait for the frontier scan).")
        return 0

    root_node = drb.build_tree(direct_kb)
    uncovered, protected, needs_decision = find_uncovered(
        root_node, roots, threshold_kb, rules, home, direct_kb,
    )
    for e in uncovered + protected + needs_decision:
        e["size_gib"] = round(e["size_kb"] / GIB_KB, 1)
    uncovered.sort(key=lambda e: e["size_kb"], reverse=True)
    protected.sort(key=lambda e: e["size_kb"], reverse=True)
    needs_decision.sort(key=lambda e: e["size_kb"], reverse=True)

    if args.json:
        print(json.dumps(
            {"source": source, "threshold_gib": args.threshold_gib,
             "uncovered": uncovered, "protected": protected,
             "needs_decision": needs_decision},
            indent=2,
        ))
        return 0

    if not uncovered and not protected and not needs_decision:
        print(f"check_uncovered_roots: no uncovered >= {args.threshold_gib:g} GiB "
              f"directories found (source: {source}).")
        return 0

    if uncovered:
        print(f"check_uncovered_roots: {len(uncovered)} UNCOVERED/CONTAINS-* "
              f"directory(ies) >= {args.threshold_gib:g} GiB with no registered "
              f"sweeper owner (source: {source}):")
        for e in uncovered:
            label = e.get("label", "UNCOVERED")
            note = f"  — {e['note']}" if e.get("note") else ""
            print(f"  {label}: {e['path']}  ({e['size_gib']} GiB){note}")

    if protected:
        print(f"check_uncovered_roots: {len(protected)} PROTECTED (never-delete, no "
              f"sweeper by policy) directory(ies) >= {args.threshold_gib:g} GiB "
              f"(source: {source}):")
        for e in protected:
            print(f"  PROTECTED (never-delete, no sweeper by policy): {e['path']}  "
                  f"({e['size_gib']} GiB)  — {e['reason']}")

    if needs_decision:
        print(f"check_uncovered_roots: {len(needs_decision)} NEEDS-DECISION (operator) "
              f"directory(ies) >= {args.threshold_gib:g} GiB (source: {source}):")
        for e in needs_decision:
            print(f"  NEEDS-DECISION (operator): {e['path']}  "
                  f"({e['size_gib']} GiB)  — {e['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

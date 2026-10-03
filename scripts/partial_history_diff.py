#!/usr/bin/env python3
"""partial_history_diff.py — conservative comparator for partial and complete
disk ledgers.

Never calls compute_deltas. Never infers zero for absent paths. Requires
matching host and root scope, canonical normalized absolute paths, valid
schema/accounting, and fresh measurement windows. Carried, unmeasured,
overlapping, and unproven partitioned paths remain unknown.
"""
import datetime
import os
import sys

GIB_KB = 1024 * 1024
DEFAULT_MAX_CURRENT_HOURS = 36.0
DEFAULT_MAX_FLOOR_DAYS = 14


def is_normalized_absolute_path(path: str) -> bool:
    return (
        isinstance(path, str)
        and os.path.isabs(path)
        and os.path.normpath(path) == path
        and not any(comp in (".", "..") for comp in path.split(os.sep))
    )


def parse_iso_ts(ts_str: str):
    if not isinstance(ts_str, str):
        return None
    try:
        return datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (TypeError, ValueError):
        return None


def detect_internal_overlaps_and_duplicates(paths):
    """Return set of paths in `paths` that have duplicates or ancestor/descendant
    relationships with another path in the same set."""
    overlaps = set()
    seen = set()
    for p in paths:
        if p in seen:
            overlaps.add(p)
        seen.add(p)

    sorted_paths = sorted(seen)
    for i in range(len(sorted_paths)):
        p1 = sorted_paths[i]
        p1_prefix = p1 + "/" if not p1.endswith("/") else p1
        for j in range(i + 1, len(sorted_paths)):
            p2 = sorted_paths[j]
            if p2.startswith(p1_prefix):
                overlaps.add(p1)
                overlaps.add(p2)
            else:
                break
    return overlaps


def extract_bucket_map(ledger: dict):
    """Extract path -> dict with measured_kb, kind, etc., checking basic
    structure. Returns (buckets_by_path, list_of_raw_paths, has_malformed)."""
    raw_buckets = ledger.get("granularity_buckets") or ledger.get("buckets") or []
    oversize = ledger.get("oversize_indivisible_files") or []
    buckets = {}
    path_list = []
    has_malformed = False

    if not isinstance(raw_buckets, list) or not isinstance(oversize, list):
        return {}, [], True

    for item in raw_buckets:
        if not isinstance(item, dict):
            has_malformed = True
            continue
        p = item.get("path")
        kb = item.get("measured_kb")
        if not p or not is_normalized_absolute_path(p) or type(kb) is not int or kb < 0:
            has_malformed = True
            continue
        path_list.append(p)
        buckets[p] = dict(item)

    for item in oversize:
        if not isinstance(item, dict):
            has_malformed = True
            continue
        p = item.get("path")
        kb = item.get("measured_kb")
        if not p or not is_normalized_absolute_path(p) or type(kb) is not int or kb < 0:
            has_malformed = True
            continue
        path_list.append(p)
        item_copy = dict(item)
        item_copy["kind"] = "file"
        buckets[p] = item_copy

    return buckets, path_list, has_malformed


def extract_carried_unmeasured(ledger: dict):
    """Return (carried_set, unmeasured_set)."""
    carried = set()
    unmeasured = set()

    c_field = ledger.get("carried")
    if isinstance(c_field, dict):
        carried.update(c_field.keys())
    elif isinstance(c_field, list):
        carried.update(c_field)

    u_field = ledger.get("unmeasured")
    if isinstance(u_field, dict):
        unmeasured.update(u_field.keys())
    elif isinstance(u_field, list):
        unmeasured.update(u_field)

    for bucket in (ledger.get("granularity_buckets") or []):
        if isinstance(bucket, dict):
            p = bucket.get("path")
            if p:
                if bucket.get("carried") is True or bucket.get("source") == "carried":
                    carried.add(p)
                if bucket.get("unmeasured") is True or bucket.get("source") == "unmeasured":
                    unmeasured.add(p)

    return carried, unmeasured


def compare_ledgers(
    base: dict,
    current: dict,
    *,
    max_floor_days: int = DEFAULT_MAX_FLOOR_DAYS,
    max_current_hours: float = DEFAULT_MAX_CURRENT_HOURS,
    now: datetime.datetime = None,
) -> dict:
    """Conservatively compare base (canonical floor) and current (partial or
    canonical) ledger. Returns a dict with comparison_kind, reason, deltas,
    unknown, coverage_envelope, and measured_interval."""
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)

    coverage_envelope = {
        "base": base.get("coverage_envelope") if isinstance(base, dict) else None,
        "current": current.get("coverage_envelope") if isinstance(current, dict) else None,
    }

    base_captured_str = base.get("captured_at") if isinstance(base, dict) else None
    current_captured_str = current.get("captured_at") if isinstance(current, dict) else None

    base_ts = parse_iso_ts(base_captured_str)
    current_ts = parse_iso_ts(current_captured_str)

    interval_hours = None
    if base_ts and current_ts:
        interval_hours = (current_ts - base_ts).total_seconds() / 3600.0

    measured_interval = {
        "base_captured_at": base_captured_str,
        "current_captured_at": current_captured_str,
        "interval_hours": round(interval_hours, 3) if interval_hours is not None else None,
        "valid": False,
    }

    def nonnumeric(reason: str):
        return {
            "comparison_kind": "nonnumeric",
            "reason": reason,
            "deltas": [],
            "unknown": [],
            "coverage_envelope": coverage_envelope,
            "measured_interval": measured_interval,
        }

    if not isinstance(base, dict) or not isinstance(current, dict):
        return nonnumeric("invalid_ledger_object")

    if base.get("schema_version") != 2 or current.get("schema_version") != 2:
        return nonnumeric("unsupported_schema_version")

    # Scope validation: requires matching nonempty host+root scope
    base_scope = base.get("scope")
    current_scope = current.get("scope")
    if not isinstance(base_scope, dict) or not isinstance(current_scope, dict):
        return nonnumeric("missing_scope")

    base_host = base_scope.get("hostname")
    base_root = base_scope.get("root")
    cur_host = current_scope.get("hostname")
    cur_root = current_scope.get("root")

    if not base_host or not base_root or not cur_host or not cur_root:
        return nonnumeric("empty_scope")

    if base_host != cur_host or base_root != cur_root:
        return nonnumeric("scope_mismatch")

    # Quality and freshness validation
    if not base_ts:
        return nonnumeric("invalid_floor_captured_at")
    if not current_ts:
        return nonnumeric("invalid_current_captured_at")

    current_age_hours = (now - current_ts).total_seconds() / 3600.0
    if current_age_hours < -0.1:
        return nonnumeric("current_in_future")
    if current_age_hours > max_current_hours:
        return nonnumeric("stale_current")

    floor_age_days = (now - base_ts).total_seconds() / 86400.0
    if floor_age_days < -0.01:
        return nonnumeric("floor_in_future")
    if floor_age_days > max_floor_days:
        return nonnumeric("stale_floor")

    if interval_hours is None or interval_hours <= 0:
        return nonnumeric("nonpositive_interval")

    measured_interval["valid"] = True

    # Extract bucket structures
    base_buckets, base_paths, base_malformed = extract_bucket_map(base)
    cur_buckets, cur_paths, cur_malformed = extract_bucket_map(current)

    if base_malformed or cur_malformed:
        return nonnumeric("malformed_bucket_data")

    # Detect overlaps inside each artifact
    base_overlaps = detect_internal_overlaps_and_duplicates(base_paths)
    cur_overlaps = detect_internal_overlaps_and_duplicates(cur_paths)

    base_carried, base_unmeasured = extract_carried_unmeasured(base)
    cur_carried, cur_unmeasured = extract_carried_unmeasured(current)

    # Process explicit partition proofs if supplied
    proven_parents_base_to_cur = {}
    proven_children_base_to_cur = set()
    proven_parents_cur_to_base = {}
    proven_children_cur_to_base = set()

    for proof in (current.get("partition_proofs") or base.get("partition_proofs") or []):
        if not isinstance(proof, dict):
            continue
        parent = proof.get("parent")
        children = proof.get("children")
        disjoint = proof.get("disjoint")
        complete = proof.get("complete")
        omitted = proof.get("omitted_tail_kb", 0)
        direct_alloc = proof.get("direct_allocation_kb", 0)

        if not parent or not isinstance(children, list) or not children:
            continue
        if not disjoint or not complete or omitted != 0 or direct_alloc != 0:
            continue

        # Case A: Parent in base -> Children in current
        if parent in base_buckets and all(c in cur_buckets for c in children):
            if not any(c in cur_carried or c in cur_unmeasured or c in cur_overlaps for c in children):
                if parent not in base_carried and parent not in base_unmeasured and parent not in base_overlaps:
                    proven_parents_base_to_cur[parent] = list(children)
                    proven_children_base_to_cur.update(children)

        # Case B: Children in base -> Parent in current
        if parent in cur_buckets and all(c in base_buckets for c in children):
            if not any(c in base_carried or c in base_unmeasured or c in base_overlaps for c in children):
                if parent not in cur_carried and parent not in cur_unmeasured and parent not in cur_overlaps:
                    proven_parents_cur_to_base[parent] = list(children)
                    proven_children_cur_to_base.update(children)

    deltas = []
    unknown = []
    handled_base = set()
    handled_cur = set()

    # Reconcile Case A: parent in base, children in current
    for parent, children in proven_parents_base_to_cur.items():
        base_kb = base_buckets[parent]["measured_kb"]
        cur_sum = sum(cur_buckets[c]["measured_kb"] for c in children)
        deltas.append({
            "path": parent,
            "delta_kb": cur_sum - base_kb,
            "base_kb": base_kb,
            "current_kb": cur_sum,
            "provenance": "proven_partition_children",
            "children": children,
        })
        handled_base.add(parent)
        handled_cur.update(children)

    # Reconcile Case B: children in base, parent in current
    for parent, children in proven_parents_cur_to_base.items():
        base_sum = sum(base_buckets[c]["measured_kb"] for c in children)
        cur_kb = cur_buckets[parent]["measured_kb"]
        deltas.append({
            "path": parent,
            "delta_kb": cur_kb - base_sum,
            "base_kb": base_sum,
            "current_kb": cur_kb,
            "provenance": "proven_partition_parent",
            "children": children,
        })
        handled_cur.add(parent)
        handled_base.update(children)

    all_paths = sorted(set(base_buckets) | set(cur_buckets))

    for p in all_paths:
        if p in handled_base and p in handled_cur:
            continue

        in_base = p in base_buckets
        in_cur = p in cur_buckets

        base_val = base_buckets[p]["measured_kb"] if in_base else None
        cur_val = cur_buckets[p]["measured_kb"] if in_cur else None

        # Check overlaps
        if (in_base and p in base_overlaps) or (in_cur and p in cur_overlaps):
            unknown.append({
                "path": p,
                "reason": "ancestor_descendant_overlap",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        # Check carried or unmeasured
        if (in_cur and p in cur_unmeasured) or (in_base and p in base_unmeasured):
            unknown.append({
                "path": p,
                "reason": "unmeasured",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        if (in_cur and p in cur_carried) or (in_base and p in base_carried):
            unknown.append({
                "path": p,
                "reason": "carried",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        if in_base and not in_cur:
            if p not in handled_base:
                unknown.append({
                    "path": p,
                    "reason": "missing_in_current",
                    "base_kb": base_val,
                    "current_kb": None,
                })
            continue

        if in_cur and not in_base:
            if p not in handled_cur:
                unknown.append({
                    "path": p,
                    "reason": "missing_in_base",
                    "base_kb": None,
                    "current_kb": cur_val,
                })
            continue

        # Present in both with fresh, non-overlapping values
        delta_kb = cur_val - base_val
        deltas.append({
            "path": p,
            "delta_kb": delta_kb,
            "base_kb": base_val,
            "current_kb": cur_val,
            "provenance": "exact",
        })

    deltas.sort(key=lambda d: (-d["delta_kb"], d["path"]))
    unknown.sort(key=lambda u: u["path"])

    kind = "exact_path"
    if current.get("publication_kind") == "partial" or current.get("mode") == "partial" or unknown:
        kind = "partial"

    return {
        "comparison_kind": kind,
        "reason": "ok",
        "deltas": deltas,
        "unknown": unknown,
        "coverage_envelope": coverage_envelope,
        "measured_interval": measured_interval,
    }

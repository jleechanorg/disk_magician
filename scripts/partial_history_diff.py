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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import history_diff

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

    for p in seen:
        parts = p.strip("/").split("/")
        curr = ""
        for part in parts[:-1]:
            curr += "/" + part
            if curr in seen:
                overlaps.add(curr)
                overlaps.add(p)
    return overlaps


def extract_bucket_map(ledger: dict):
    """Extract path -> dict with measured_kb, kind, etc., checking basic
    structure. Returns (buckets_by_path, list_of_raw_paths, has_malformed)."""
    raw_buckets = ledger.get("granularity_buckets")
    if raw_buckets is None:
        raw_buckets = ledger.get("buckets")
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
        if not p or not is_normalized_absolute_path(p):
            has_malformed = True
            continue
        if kb is not None and (type(kb) is not int or kb < 0):
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
        if not p or not is_normalized_absolute_path(p):
            has_malformed = True
            continue
        if kb is not None and (type(kb) is not int or kb < 0):
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

    for field_name, target_set in (
        ("carried", carried),
        ("carried_keys", carried),
        ("unmeasured", unmeasured),
        ("unmeasured_keys", unmeasured),
    ):
        val = ledger.get(field_name)
        if isinstance(val, dict):
            target_set.update(val.keys())
        elif isinstance(val, list):
            target_set.update(val)

    raw_buckets = ledger.get("granularity_buckets")
    if raw_buckets is None:
        raw_buckets = ledger.get("buckets")
    for bucket in (raw_buckets or []):
        if isinstance(bucket, dict):
            p = bucket.get("path")
            if p:
                if (
                    bucket.get("carried") is True
                    or bucket.get("source") == "carried"
                    or bucket.get("quality") == "carried"
                    or bucket.get("status") == "carried"
                ):
                    carried.add(p)
                if (
                    bucket.get("unmeasured") is True
                    or bucket.get("source") == "unmeasured"
                    or bucket.get("quality") == "unmeasured"
                    or bucket.get("status") == "unmeasured"
                    or bucket.get("measured_kb") is None
                ):
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
    unknown, coverage, coverage_envelope, and measured_interval."""
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)

    coverage_envelope = {
        "base": base.get("coverage_envelope") if isinstance(base, dict) else None,
        "current": current.get("coverage_envelope") if isinstance(current, dict) else None,
    }

    coverage = {
        "base": {
            "coverage_envelope": base.get("coverage_envelope") if isinstance(base, dict) else None,
            "coverage_fresh_pct": base.get("coverage_fresh_pct") if isinstance(base, dict) else None,
            "coverage_carried_pct": base.get("coverage_carried_pct") if isinstance(base, dict) else None,
            "coverage_effective_pct": base.get("coverage_effective_pct") if isinstance(base, dict) else None,
            "fresh": base.get("fresh") if isinstance(base, dict) else None,
            "carried": base.get("carried") if isinstance(base, dict) else None,
            "unmeasured": base.get("unmeasured") if isinstance(base, dict) else None,
            "effective_coverage": base.get("effective_coverage") if isinstance(base, dict) else None,
        },
        "current": {
            "coverage_envelope": current.get("coverage_envelope") if isinstance(current, dict) else None,
            "coverage_fresh_pct": current.get("coverage_fresh_pct") if isinstance(current, dict) else None,
            "coverage_carried_pct": current.get("coverage_carried_pct") if isinstance(current, dict) else None,
            "coverage_effective_pct": current.get("coverage_effective_pct") if isinstance(current, dict) else None,
            "fresh": current.get("fresh") if isinstance(current, dict) else None,
            "carried": current.get("carried") if isinstance(current, dict) else None,
            "unmeasured": current.get("unmeasured") if isinstance(current, dict) else None,
            "effective_coverage": current.get("effective_coverage") if isinstance(current, dict) else None,
        },
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
            "coverage": coverage,
            "coverage_envelope": coverage_envelope,
            "measured_interval": measured_interval,
        }

    if not isinstance(base, dict) or not isinstance(current, dict):
        return nonnumeric("invalid_ledger_object")

    # Shared structural validation
    try:
        history_diff.validate_ledger(base, label="base")
        history_diff.validate_ledger(current, label="current")
    except history_diff.LedgerError as exc:
        return nonnumeric(f"invalid_ledger_structure: {exc}")

    if base.get("schema_version") != 2 or current.get("schema_version") != 2:
        return nonnumeric("unsupported_schema_version")

    # Accounting equation and version validation
    base_acct = base.get("accounting_equation")
    cur_acct = current.get("accounting_equation")
    if not isinstance(base_acct, dict) or not isinstance(cur_acct, dict):
        return nonnumeric("missing_accounting_equation")
    if base_acct.get("displayed_balanced") is not True or cur_acct.get("displayed_balanced") is not True:
        return nonnumeric("accounting_unbalanced")

    if "accounting_version" in base or "accounting_version" in current:
        v_base = base.get("accounting_version")
        v_cur = current.get("accounting_version")
        if v_base != v_cur or v_base not in (1, 2, None):
            return nonnumeric("accounting_mismatch")

    # Scope validation: requires matching nonempty host+root scope
    base_scope = base.get("scope")
    current_scope = current.get("scope")
    if not isinstance(base_scope, dict) or not isinstance(current_scope, dict):
        return nonnumeric("missing_scope")

    base_host = base_scope.get("hostname")
    base_root = base_scope.get("root")
    cur_host = current_scope.get("hostname")
    cur_root = current_scope.get("root")

    if not isinstance(base_host, str) or not base_host or not isinstance(cur_host, str) or not cur_host:
        return nonnumeric("empty_scope_hostname")
    if not is_normalized_absolute_path(base_root) or not is_normalized_absolute_path(cur_root):
        return nonnumeric("invalid_scope_root")

    if base_host != cur_host or base_root != cur_root:
        return nonnumeric("scope_mismatch")

    # Consistent duplicate fields
    if "root" in base and base["root"] != base_root:
        return nonnumeric("inconsistent_root_duplicate")
    if "hostname" in base and base["hostname"] != base_host:
        return nonnumeric("inconsistent_hostname_duplicate")
    if "root" in current and current["root"] != cur_root:
        return nonnumeric("inconsistent_root_duplicate")
    if "hostname" in current and current["hostname"] != cur_host:
        return nonnumeric("inconsistent_hostname_duplicate")

    # Extra scope identity
    b_extra = {k: v for k, v in base_scope.items() if k not in ("hostname", "root")}
    c_extra = {k: v for k, v in current_scope.items() if k not in ("hostname", "root")}
    if b_extra != c_extra:
        return nonnumeric("scope_identity_mismatch")

    # Quality and freshness validation
    if not base_ts:
        return nonnumeric("invalid_floor_captured_at")
    if not current_ts:
        return nonnumeric("invalid_current_captured_at")

    if base_ts > now:
        return nonnumeric("floor_in_future")
    if current_ts > now:
        return nonnumeric("current_in_future")

    current_age_hours = (now - current_ts).total_seconds() / 3600.0
    if current_age_hours > max_current_hours:
        return nonnumeric("stale_current")

    floor_age_days = (now - base_ts).total_seconds() / 86400.0
    if floor_age_days > max_floor_days:
        return nonnumeric("stale_floor")

    if interval_hours is None or interval_hours <= 0:
        return nonnumeric("nonpositive_interval")

    # Extract bucket structures
    base_buckets, base_paths, base_malformed = extract_bucket_map(base)
    cur_buckets, cur_paths, cur_malformed = extract_bucket_map(current)

    if base_malformed or cur_malformed:
        return nonnumeric("malformed_bucket_data")

    # Canonical bucket paths must be INSIDE scope root
    root_prefix = base_root if base_root.endswith("/") else base_root + "/"
    for p in base_paths:
        if p != base_root and not p.startswith(root_prefix):
            return nonnumeric("bucket_path_outside_scope_root")
    for p in cur_paths:
        if p != cur_root and not p.startswith(root_prefix):
            return nonnumeric("bucket_path_outside_scope_root")

    measured_interval["valid"] = True

    # Detect overlaps inside each artifact
    base_overlaps = detect_internal_overlaps_and_duplicates(base_paths)
    cur_overlaps = detect_internal_overlaps_and_duplicates(cur_paths)

    base_carried, base_unmeasured = extract_carried_unmeasured(base)
    cur_carried, cur_unmeasured = extract_carried_unmeasured(current)

    # Process explicit partition proofs
    proven_parents_base_to_cur = {}
    proven_parents_cur_to_base = {}
    invalid_partition_parents = set()

    # Case A: Parent in base -> Children in current (proof belongs to current)
    for proof in (current.get("partition_proofs") or []):
        if not isinstance(proof, dict):
            continue
        parent = proof.get("parent")
        children = proof.get("children")
        disjoint = proof.get("disjoint")
        complete = proof.get("complete")
        omitted = proof.get("omitted_tail_kb")
        direct_alloc = proof.get("direct_allocation_kb")

        if (
            not isinstance(parent, str)
            or not is_normalized_absolute_path(parent)
            or not isinstance(children, list)
            or not children
            or len(children) != len(set(children))
            or not all(isinstance(c, str) and is_normalized_absolute_path(c) for c in children)
            or type(disjoint) is not bool
            or disjoint is not True
            or type(complete) is not bool
            or complete is not True
            or type(omitted) is not int
            or omitted != 0
            or type(direct_alloc) is not int
            or direct_alloc != 0
        ):
            if parent:
                invalid_partition_parents.add(parent)
            continue

        parent_prefix = parent.rstrip("/") + "/"
        if any(not c.startswith(parent_prefix) or c == parent for c in children):
            invalid_partition_parents.add(parent)
            continue

        if detect_internal_overlaps_and_duplicates(children):
            invalid_partition_parents.add(parent)
            continue

        # If parent is also in current, exact matching takes precedence
        if parent in cur_buckets:
            continue

        # All published descendants under parent in cur_buckets must equal set(children)
        actual_cur_descendants = {p for p in cur_buckets if p.startswith(parent_prefix) and p != parent}
        if actual_cur_descendants != set(children):
            invalid_partition_parents.add(parent)
            continue

        if parent in base_buckets and all(c in cur_buckets for c in children):
            if not any(
                c in cur_carried
                or c in cur_unmeasured
                or c in cur_overlaps
                or cur_buckets[c].get("measured_kb") is None
                or cur_buckets[c].get("kind") == "direct_allocation_segment"
                for c in children
            ):
                if (
                    parent not in base_carried
                    and parent not in base_unmeasured
                    and parent not in base_overlaps
                    and base_buckets[parent].get("measured_kb") is not None
                    and base_buckets[parent].get("kind") != "direct_allocation_segment"
                ):
                    proven_parents_base_to_cur[parent] = list(children)

    # Case B: Children in base -> Parent in current (proof belongs to base)
    for proof in (base.get("partition_proofs") or []):
        if not isinstance(proof, dict):
            continue
        parent = proof.get("parent")
        children = proof.get("children")
        disjoint = proof.get("disjoint")
        complete = proof.get("complete")
        omitted = proof.get("omitted_tail_kb")
        direct_alloc = proof.get("direct_allocation_kb")

        if (
            not isinstance(parent, str)
            or not is_normalized_absolute_path(parent)
            or not isinstance(children, list)
            or not children
            or len(children) != len(set(children))
            or not all(isinstance(c, str) and is_normalized_absolute_path(c) for c in children)
            or type(disjoint) is not bool
            or disjoint is not True
            or type(complete) is not bool
            or complete is not True
            or type(omitted) is not int
            or omitted != 0
            or type(direct_alloc) is not int
            or direct_alloc != 0
        ):
            if parent:
                invalid_partition_parents.add(parent)
            continue

        parent_prefix = parent.rstrip("/") + "/"
        if any(not c.startswith(parent_prefix) or c == parent for c in children):
            invalid_partition_parents.add(parent)
            continue

        if detect_internal_overlaps_and_duplicates(children):
            invalid_partition_parents.add(parent)
            continue

        if parent in base_buckets:
            continue

        actual_base_descendants = {p for p in base_buckets if p.startswith(parent_prefix) and p != parent}
        if actual_base_descendants != set(children):
            invalid_partition_parents.add(parent)
            continue

        if parent in cur_buckets and all(c in base_buckets for c in children):
            if not any(
                c in base_carried
                or c in base_unmeasured
                or c in base_overlaps
                or base_buckets[c].get("measured_kb") is None
                or base_buckets[c].get("kind") == "direct_allocation_segment"
                for c in children
            ):
                if (
                    parent not in cur_carried
                    and parent not in cur_unmeasured
                    and parent not in cur_overlaps
                    and cur_buckets[parent].get("measured_kb") is not None
                    and cur_buckets[parent].get("kind") != "direct_allocation_segment"
                ):
                    proven_parents_cur_to_base[parent] = list(children)

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

    all_paths = sorted(set(base_buckets) | set(cur_buckets) | set(cur_unmeasured) | set(base_unmeasured) | set(cur_carried) | set(base_carried) | invalid_partition_parents)

    for p in all_paths:
        if p in handled_base and p in handled_cur:
            continue

        in_base = p in base_buckets
        in_cur = p in cur_buckets

        base_item = base_buckets.get(p)
        cur_item = cur_buckets.get(p)

        base_val = base_item.get("measured_kb") if base_item else None
        cur_val = cur_item.get("measured_kb") if cur_item else None

        if p in invalid_partition_parents:
            unknown.append({
                "path": p,
                "reason": "invalid_partition_proof",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

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
        if (in_cur and p in cur_unmeasured) or (in_base and p in base_unmeasured) or base_val is None or cur_val is None:
            if not in_base and not in_cur:
                unknown.append({
                    "path": p,
                    "reason": "unmeasured",
                    "base_kb": None,
                    "current_kb": None,
                })
                continue
            if (in_cur and p in cur_unmeasured) or (in_base and p in base_unmeasured) or (in_cur and cur_val is None) or (in_base and base_val is None):
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

        # Check direct_allocation_segment
        if (in_base and base_item.get("kind") == "direct_allocation_segment") or (
            in_cur and cur_item.get("kind") == "direct_allocation_segment"
        ):
            unknown.append({
                "path": p,
                "reason": "direct_allocation_segment",
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

        # Bucket timestamp comparison: when present, bucket timestamp takes precedence
        b_time_str = base_item.get("measured_at") or base_item.get("captured_at") or base_captured_str
        c_time_str = cur_item.get("measured_at") or cur_item.get("captured_at") or current_captured_str
        b_time_ts = parse_iso_ts(b_time_str)
        c_time_ts = parse_iso_ts(c_time_str)

        if b_time_ts and c_time_ts:
            if c_time_ts <= b_time_ts or c_time_ts > now:
                unknown.append({
                    "path": p,
                    "reason": "stale_bucket_measurement",
                    "base_kb": base_val,
                    "current_kb": cur_val,
                })
                continue

        # Present in both with fresh, non-overlapping values
        delta_kb = cur_val - base_val
        row = {
            "path": p,
            "delta_kb": delta_kb,
            "base_kb": base_val,
            "current_kb": cur_val,
            "provenance": "exact",
        }
        if b_time_ts and c_time_ts and (cur_item.get("measured_at") or base_item.get("measured_at")):
            row["measured_interval_hours"] = round((c_time_ts - b_time_ts).total_seconds() / 3600.0, 3)
            row["current_measured_at"] = c_time_str
            row["base_measured_at"] = b_time_str
        deltas.append(row)

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
        "coverage": coverage,
        "coverage_envelope": coverage_envelope,
        "measured_interval": measured_interval,
    }

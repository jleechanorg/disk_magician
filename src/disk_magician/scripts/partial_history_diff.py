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
        if p == "/":
            continue
        curr = os.path.dirname(p)
        while curr:
            if curr in seen:
                overlaps.add(curr)
                overlaps.add(p)
            if curr == "/":
                break
            curr = os.path.dirname(curr)
    return overlaps


def extract_bucket_map(ledger: dict):
    """Extract path -> dict with measured_kb, kind, etc., checking basic
    structure. Returns (buckets_by_path, list_of_raw_paths, key_to_path, has_malformed)."""
    raw_buckets = ledger.get("granularity_buckets")
    if raw_buckets is None:
        raw_buckets = ledger.get("buckets")
    oversize = ledger.get("oversize_indivisible_files") or []
    buckets = {}
    path_list = []
    key_to_path = {}
    has_malformed = False

    if not isinstance(raw_buckets, list) or not isinstance(oversize, list):
        return {}, [], {}, True

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
        k = item.get("key")
        if k and isinstance(k, str):
            key_to_path[k] = p

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
        k = item.get("key")
        if k and isinstance(k, str):
            key_to_path[k] = p

    return buckets, path_list, key_to_path, has_malformed


def extract_carried_unmeasured(ledger: dict, bucket_map: dict = None, key_to_path: dict = None):
    """Return (carried_set, unmeasured_set, unmapped_carried, unmapped_unmeasured)."""
    carried = set()
    unmeasured = set()
    unmapped_carried = []
    unmapped_unmeasured = []

    k_to_p = dict(key_to_path or {})
    p_to_p = set(bucket_map.keys()) if bucket_map else set()

    for field_names, target_set, unmapped_list in (
        (("carried", "carried_keys"), carried, unmapped_carried),
        (("unmeasured", "unmeasured_keys"), unmeasured, unmapped_unmeasured),
    ):
        for field_name in field_names:
            val = ledger.get(field_name)
            if isinstance(val, dict):
                for k, v in val.items():
                    if isinstance(k, str):
                        p = k if k in p_to_p else k_to_p.get(k)
                        if p:
                            target_set.add(p)
                        else:
                            target_set.add(k)
                            unmapped_list.append({"key": k, "value": v})
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, str):
                        p = item if item in p_to_p else k_to_p.get(item)
                        if p:
                            target_set.add(p)
                        else:
                            target_set.add(item)
                            unmapped_list.append(item)
                    elif isinstance(item, dict):
                        k = item.get("path") or item.get("key")
                        if k and isinstance(k, str):
                            p = k if k in p_to_p else k_to_p.get(k)
                            if p:
                                target_set.add(p)
                            else:
                                target_set.add(k)
                                unmapped_list.append(dict(item))
                        else:
                            unmapped_list.append(dict(item))

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

    return carried, unmeasured, unmapped_carried, unmapped_unmeasured


def check_bucket_eligibility(
    bucket: dict,
    artifact_captured_ts: datetime.datetime,
    *,
    is_current: bool,
    now: datetime.datetime,
    max_current_hours: float = DEFAULT_MAX_CURRENT_HOURS,
    max_floor_days: int = DEFAULT_MAX_FLOOR_DAYS,
    carried_paths: set = None,
    unmeasured_paths: set = None,
    overlap_paths: set = None,
):
    """Verify single bucket's freshness, quality, status, and integrity.
    Returns (is_eligible, reason_if_not, parsed_timestamp, timestamp_str)."""
    if not isinstance(bucket, dict):
        return False, "invalid_bucket_dict", None, None

    p = bucket.get("path")
    kb = bucket.get("measured_kb")
    if kb is None or type(kb) is not int or kb < 0:
        return False, "unmeasured", None, None

    kind = bucket.get("kind")
    if kind == "direct_allocation_segment":
        return False, "direct_allocation_segment", None, None

    # Quality check
    quality = bucket.get("quality")
    if quality is not None:
        if quality in ("carried", "unmeasured"):
            return False, quality, None, None
        if quality not in ("fresh", "exact", "measured"):
            return False, "unknown_bucket_quality", None, None

    # Status check
    status = bucket.get("status")
    if status is not None:
        if status in ("carried", "unmeasured"):
            return False, status, None, None
        if status not in ("fresh", "exact", "measured", "ok"):
            return False, "ineligible_status", None, None

    # Source check
    source = bucket.get("source")
    if source is not None:
        if source in ("carried", "unmeasured"):
            return False, source, None, None
        if source not in ("fresh", "exact", "measured", "frontier", "scanner"):
            return False, "ineligible_source", None, None

    # Carried / unmeasured flags & sets
    if bucket.get("carried") is True:
        return False, "carried", None, None
    if bucket.get("unmeasured") is True:
        return False, "unmeasured", None, None
    if carried_paths and p in carried_paths:
        return False, "carried", None, None
    if unmeasured_paths and p in unmeasured_paths:
        return False, "unmeasured", None, None
    if overlap_paths and p in overlap_paths:
        return False, "ancestor_descendant_overlap", None, None

    # Timestamp checks
    has_explicit_time = False
    time_str = None
    if "measured_at" in bucket and bucket["measured_at"] is not None:
        has_explicit_time = True
        time_str = bucket["measured_at"]
    elif "captured_at" in bucket and bucket["captured_at"] is not None:
        has_explicit_time = True
        time_str = bucket["captured_at"]

    if has_explicit_time:
        ts = parse_iso_ts(time_str)
        if ts is None:
            return False, "invalid_bucket_time", None, None
    else:
        ts = artifact_captured_ts
        time_str = ts.strftime("%Y-%m-%dT%H:%M:%SZ") if ts else None

    if ts is None:
        return False, "missing_timestamp", None, None

    if ts > now:
        return False, "future_bucket_time", ts, time_str

    if is_current:
        age_hours = (now - ts).total_seconds() / 3600.0
        if age_hours > max_current_hours:
            return False, "stale_bucket_measurement", ts, time_str
    else:
        age_days = (now - ts).total_seconds() / 86400.0
        if age_days > max_floor_days:
            return False, "stale_bucket_measurement", ts, time_str

    return True, None, ts, time_str


def validate_partition_proof(
    proof: dict,
    parent_ledger: dict,
    parent_buckets: dict,
    parent_ts: datetime.datetime,
    parent_is_current: bool,
    child_ledger: dict,
    child_buckets: dict,
    child_ts: datetime.datetime,
    child_is_current: bool,
    *,
    now: datetime.datetime,
    max_current_hours: float,
    max_floor_days: int,
    parent_carried: set,
    parent_unmeasured: set,
    parent_overlaps: set,
    child_carried: set,
    child_unmeasured: set,
    child_overlaps: set,
):
    """Validate a partition proof and verify all operands pass eligibility checks.
    Returns (parent, children_list_or_False)."""
    if not isinstance(proof, dict):
        return None, None
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
        or not all(isinstance(c, str) and is_normalized_absolute_path(c) for c in children)
        or len(children) != len(set(children))
        or disjoint is not True
        or complete is not True
        or type(omitted) is not int or omitted != 0
        or type(direct_alloc) is not int or direct_alloc != 0
    ):
        return (parent, False) if isinstance(parent, str) and parent else (None, None)

    parent_prefix = parent if parent == "/" else parent.rstrip("/") + "/"
    if any(not c.startswith(parent_prefix) or c == parent for c in children):
        return parent, False

    if detect_internal_overlaps_and_duplicates(children):
        return parent, False

    if parent in child_buckets:
        return None, None

    # Check frontier_unfinished in child_ledger under parent
    for entry in (child_ledger.get("frontier_unfinished") or []):
        ep = entry.get("path") if isinstance(entry, dict) else (entry if isinstance(entry, str) else None)
        if ep and isinstance(ep, str) and (ep == parent or ep.startswith(parent_prefix)):
            return parent, False

    # Check opaque_intrinsic_gates in child_ledger under parent
    for entry in (child_ledger.get("opaque_intrinsic_gates") or []):
        ep = entry.get("path") if isinstance(entry, dict) else (entry if isinstance(entry, str) else None)
        if ep and isinstance(ep, str) and (ep == parent or ep.startswith(parent_prefix)):
            return parent, False

    # Check unmeasured subtree under parent in child
    for ep in child_unmeasured:
        if isinstance(ep, str) and (ep == parent or ep.startswith(parent_prefix)):
            return parent, False

    actual_child_descendants = {p for p in child_buckets if p.startswith(parent_prefix) and p != parent}
    if actual_child_descendants != set(children):
        return parent, False

    if parent not in parent_buckets or not all(c in child_buckets for c in children):
        return parent, False

    p_ok, _, p_ts, _ = check_bucket_eligibility(
        parent_buckets[parent],
        parent_ts,
        is_current=parent_is_current,
        now=now,
        max_current_hours=max_current_hours,
        max_floor_days=max_floor_days,
        carried_paths=parent_carried,
        unmeasured_paths=parent_unmeasured,
        overlap_paths=parent_overlaps,
    )
    if not p_ok:
        return parent, False

    for c in children:
        if child_buckets[c].get("method") != parent_buckets[parent].get("method"):
            return parent, False
        c_ok, _, c_bucket_ts, _ = check_bucket_eligibility(
            child_buckets[c],
            child_ts,
            is_current=child_is_current,
            now=now,
            max_current_hours=max_current_hours,
            max_floor_days=max_floor_days,
            carried_paths=child_carried,
            unmeasured_paths=child_unmeasured,
            overlap_paths=child_overlaps,
        )
        if not c_ok:
            return parent, False
        if child_is_current:
            if c_bucket_ts and p_ts and c_bucket_ts <= p_ts:
                return parent, False
        else:
            if p_ts and c_bucket_ts and p_ts <= c_bucket_ts:
                return parent, False

    return parent, list(children)


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
    base_buckets, base_paths, base_k2p, base_malformed = extract_bucket_map(base)
    cur_buckets, cur_paths, cur_k2p, cur_malformed = extract_bucket_map(current)

    if base_malformed or cur_malformed:
        return nonnumeric("malformed_bucket_data")

    # Canonical bucket paths must be INSIDE scope root
    root_prefix = base_root if base_root == "/" else base_root + "/"
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

    base_carried, base_unmeasured, base_unmapped_carried, base_unmapped_unmeasured = extract_carried_unmeasured(
        base, base_buckets, base_k2p
    )
    cur_carried, cur_unmeasured, cur_unmapped_carried, cur_unmapped_unmeasured = extract_carried_unmeasured(
        current, cur_buckets, cur_k2p
    )

    # Process explicit partition proofs
    proven_parents_base_to_cur = {}
    proven_parents_cur_to_base = {}
    invalid_partition_parents = set()

    for proof in (current.get("partition_proofs") or []):
        p, res = validate_partition_proof(
            proof,
            base,
            base_buckets,
            base_ts,
            False,
            current,
            cur_buckets,
            current_ts,
            True,
            now=now,
            max_current_hours=max_current_hours,
            max_floor_days=max_floor_days,
            parent_carried=base_carried,
            parent_unmeasured=base_unmeasured,
            parent_overlaps=base_overlaps,
            child_carried=cur_carried,
            child_unmeasured=cur_unmeasured,
            child_overlaps=cur_overlaps,
        )
        if p and res is False:
            invalid_partition_parents.add(p)
        elif p and isinstance(res, list):
            proven_parents_base_to_cur[p] = res

    for proof in (base.get("partition_proofs") or []):
        p, res = validate_partition_proof(
            proof,
            current,
            cur_buckets,
            current_ts,
            True,
            base,
            base_buckets,
            base_ts,
            False,
            now=now,
            max_current_hours=max_current_hours,
            max_floor_days=max_floor_days,
            parent_carried=cur_carried,
            parent_unmeasured=cur_unmeasured,
            parent_overlaps=cur_overlaps,
            child_carried=base_carried,
            child_unmeasured=base_unmeasured,
            child_overlaps=base_overlaps,
        )
        if p and res is False:
            invalid_partition_parents.add(p)
        elif p and isinstance(res, list):
            proven_parents_cur_to_base[p] = res

    deltas = []
    unknown = []
    handled_base = set()
    handled_cur = set()

    # Reconcile Case A: parent in base, children in current
    for parent, children in proven_parents_base_to_cur.items():
        if parent in invalid_partition_parents:
            continue
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
        if parent in invalid_partition_parents:
            continue
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

    all_paths = sorted(
        set(base_buckets)
        | set(cur_buckets)
        | set(cur_unmeasured)
        | set(base_unmeasured)
        | set(cur_carried)
        | set(base_carried)
        | invalid_partition_parents
    )

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

        if in_base and not in_cur:
            if p in handled_base:
                continue
            b_ok, b_reason, b_ts, _ = check_bucket_eligibility(
                base_item,
                base_ts,
                is_current=False,
                now=now,
                max_current_hours=max_current_hours,
                max_floor_days=max_floor_days,
                carried_paths=base_carried,
                unmeasured_paths=base_unmeasured,
                overlap_paths=base_overlaps,
            )
            unknown.append({
                "path": p,
                "reason": b_reason if not b_ok else "missing_in_current",
                "base_kb": base_val,
                "current_kb": None,
            })
            continue

        if in_cur and not in_base:
            if p in handled_cur:
                continue
            c_ok, c_reason, c_ts, _ = check_bucket_eligibility(
                cur_item,
                current_ts,
                is_current=True,
                now=now,
                max_current_hours=max_current_hours,
                max_floor_days=max_floor_days,
                carried_paths=cur_carried,
                unmeasured_paths=cur_unmeasured,
                overlap_paths=cur_overlaps,
            )
            unknown.append({
                "path": p,
                "reason": c_reason if not c_ok else "missing_in_base",
                "base_kb": None,
                "current_kb": cur_val,
            })
            continue

        if not in_base and not in_cur:
            r = "unmeasured" if (p in cur_unmeasured or p in base_unmeasured) else "carried"
            unknown.append({
                "path": p,
                "reason": r,
                "base_kb": None,
                "current_kb": None,
            })
            continue

        # In both: check individual bucket eligibility
        b_ok, b_reason, b_ts, b_time_str = check_bucket_eligibility(
            base_item,
            base_ts,
            is_current=False,
            now=now,
            max_current_hours=max_current_hours,
            max_floor_days=max_floor_days,
            carried_paths=base_carried,
            unmeasured_paths=base_unmeasured,
            overlap_paths=base_overlaps,
        )
        c_ok, c_reason, c_ts, c_time_str = check_bucket_eligibility(
            cur_item,
            current_ts,
            is_current=True,
            now=now,
            max_current_hours=max_current_hours,
            max_floor_days=max_floor_days,
            carried_paths=cur_carried,
            unmeasured_paths=cur_unmeasured,
            overlap_paths=cur_overlaps,
        )

        if not b_ok or not c_ok:
            reason = c_reason if not c_ok else b_reason
            unknown.append({
                "path": p,
                "reason": reason,
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        # Check timestamp relationship
        if c_ts and b_ts and c_ts <= b_ts:
            unknown.append({
                "path": p,
                "reason": "stale_bucket_measurement",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        # Check kind mismatch
        b_kind = base_item.get("kind")
        c_kind = cur_item.get("kind")
        if b_kind and c_kind and b_kind != c_kind:
            unknown.append({
                "path": p,
                "reason": "kind_mismatch",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        # Check method mismatch
        b_method = base_item.get("method")
        c_method = cur_item.get("method")
        if b_method and c_method and b_method != c_method:
            unknown.append({
                "path": p,
                "reason": "method_mismatch",
                "base_kb": base_val,
                "current_kb": cur_val,
            })
            continue

        # Exact path delta
        delta_kb = cur_val - base_val
        row = {
            "path": p,
            "delta_kb": delta_kb,
            "base_kb": base_val,
            "current_kb": cur_val,
            "provenance": "exact",
        }
        if b_ts and c_ts:
            row["measured_interval_hours"] = round((c_ts - b_ts).total_seconds() / 3600.0, 3)
            row["current_measured_at"] = c_time_str
            row["base_measured_at"] = b_time_str
        deltas.append(row)

    # Add unmapped carried and unmeasured keys into unknown
    for item in cur_unmapped_carried + base_unmapped_carried:
        k = item.get("key") or item.get("path") if isinstance(item, dict) else str(item)
        kb = item.get("kb") if isinstance(item, dict) else None
        meta = item if isinstance(item, dict) else {"key": item}
        unknown.append({
            "path": k,
            "reason": "carried",
            "base_kb": None,
            "current_kb": kb,
            "metadata": meta,
        })

    for item in cur_unmapped_unmeasured + base_unmapped_unmeasured:
        k = item.get("key") or item.get("path") if isinstance(item, dict) else str(item)
        kb = item.get("kb") if isinstance(item, dict) else None
        meta = item if isinstance(item, dict) else {"key": item}
        unknown.append({
            "path": k,
            "reason": "unmeasured",
            "base_kb": None,
            "current_kb": kb,
            "metadata": meta,
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
        "coverage": coverage,
        "coverage_envelope": coverage_envelope,
        "measured_interval": measured_interval,
    }

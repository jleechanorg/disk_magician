#!/usr/bin/env python3
"""tests/test_partial_history_diff.py — unit tests for partial_history_diff.py."""
import datetime
import pathlib
import sys
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import partial_history_diff as phd  # noqa: E402
import history_diff as hd  # noqa: E402

NOW = datetime.datetime(2026, 10, 3, 12, 0, 0, tzinfo=datetime.timezone.utc)


def make_ledger(
    captured_at="2026-10-03T11:00:00Z",
    buckets=None,
    oversize=None,
    scope=None,
    disk_used_kb=None,
    residual_kb=1000,
    mode="complete",
    carried=None,
    unmeasured=None,
    carried_keys=None,
    unmeasured_keys=None,
    partition_proofs=None,
    publication_kind=None,
    accounting_equation=None,
    accounting_version=None,
    schema_version=2,
    hostname=None,
    root=None,
):
    if buckets is None:
        buckets = [{"path": "/Users/x/a", "measured_kb": 5000, "kind": "dir"}]
    else:
        buckets = [dict(b) for b in buckets]
        for b in buckets:
            if "kind" not in b:
                b["kind"] = "dir"
    oversize = [dict(o) for o in (oversize or [])]
    if scope is None:
        scope = {"hostname": "box1", "root": "/Users/x"}
    bucket_total = sum(b.get("measured_kb", 0) for b in buckets if b.get("measured_kb") is not None)
    oversize_total = sum(b.get("measured_kb", 0) for b in oversize if b.get("measured_kb") is not None)
    if disk_used_kb is None:
        disk_used_kb = bucket_total + oversize_total + residual_kb

    if accounting_equation is None:
        accounting_equation = {
            "displayed_balanced": True,
            "display_ledger_valid": True,
            "data_used_kb": disk_used_kb,
            "displayed_buckets_kb": bucket_total,
            "oversize_indivisible_files_kb": oversize_total,
            "sub_granularity_tail_kb": 0,
            "purgeable_kb": 0,
            "residual_kb": residual_kb,
            "clone_shared_adjustment_kb": 0,
        }

    h_name = hostname if hostname is not None else (scope.get("hostname") if isinstance(scope, dict) else "box1")
    r_path = root if root is not None else (scope.get("root") if isinstance(scope, dict) else "/Users/x")

    res = {
        "schema_version": schema_version,
        "mode": mode,
        "captured_at": captured_at,
        "hostname": h_name,
        "root": r_path,
        "scope": scope,
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize,
        "accounting_equation": accounting_equation,
        "opaque_intrinsic_gates": [],
        "coverage_envelope": {
            "complete": mode == "complete",
            "measured_top_level_roots": 1,
            "reachable_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
        },
    }
    if carried is not None:
        res["carried"] = carried
    if unmeasured is not None:
        res["unmeasured"] = unmeasured
    if carried_keys is not None:
        res["carried_keys"] = carried_keys
    if unmeasured_keys is not None:
        res["unmeasured_keys"] = unmeasured_keys
    if partition_proofs is not None:
        res["partition_proofs"] = partition_proofs
    if publication_kind is not None:
        res["publication_kind"] = publication_kind
    if accounting_version is not None:
        res["accounting_version"] = accounting_version
    return res


class TestPartialHistoryDiff(unittest.TestCase):
    def test_exact_path_numeric_deltas(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/a", "measured_kb": 4000}],
        )
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[{"path": "/Users/x/a", "measured_kb": 5500}],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["comparison_kind"], "exact_path")
        self.assertEqual(res["reason"], "ok")
        self.assertEqual(len(res["deltas"]), 1)
        self.assertEqual(res["deltas"][0]["path"], "/Users/x/a")
        self.assertEqual(res["deltas"][0]["delta_kb"], 1500)
        self.assertEqual(res["deltas"][0]["provenance"], "exact")
        self.assertEqual(res["unknown"], [])

    def test_unknown_not_zero_for_missing(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/only_floor", "measured_kb": 4000}],
        )
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[{"path": "/Users/x/only_current", "measured_kb": 5500}],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["deltas"], [])
        unknown_paths = {u["path"]: u["reason"] for u in res["unknown"]}
        self.assertEqual(unknown_paths.get("/Users/x/only_floor"), "missing_in_current")
        self.assertEqual(unknown_paths.get("/Users/x/only_current"), "missing_in_base")

    def test_scope_mismatch_and_missing_scope(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            scope={"hostname": "box1", "root": "/Users/x"},
        )
        current_other_host = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            scope={"hostname": "box2", "root": "/Users/x"},
        )
        res1 = phd.compare_ledgers(floor, current_other_host, now=NOW)
        self.assertEqual(res1["comparison_kind"], "nonnumeric")
        self.assertEqual(res1["reason"], "scope_mismatch")

        # Legacy floor missing scope
        floor_no_scope = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            scope=None,
        )
        floor_no_scope.pop("scope", None)
        current = make_ledger(captured_at="2026-10-03T10:00:00Z")
        res2 = phd.compare_ledgers(floor_no_scope, current, now=NOW)
        self.assertEqual(res2["comparison_kind"], "nonnumeric")
        self.assertEqual(res2["reason"], "missing_scope")

    def test_schema_mismatch(self):
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z")
        floor["schema_version"] = 1
        current = make_ledger(captured_at="2026-10-03T10:00:00Z")
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["comparison_kind"], "nonnumeric")
        self.assertIn("invalid_ledger_structure", res["reason"])

    def test_accounting_validation_and_mismatch(self):
        # Missing accounting equation
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z")
        floor.pop("accounting_equation", None)
        current = make_ledger(captured_at="2026-10-03T10:00:00Z")
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["comparison_kind"], "nonnumeric")

        # Accounting version mismatch
        floor_v1 = make_ledger(captured_at="2026-10-01T12:00:00Z", accounting_version=1)
        cur_v999 = make_ledger(captured_at="2026-10-03T10:00:00Z", accounting_version=999)
        res2 = phd.compare_ledgers(floor_v1, cur_v999, now=NOW)
        self.assertEqual(res2["comparison_kind"], "nonnumeric")
        self.assertEqual(res2["reason"], "accounting_mismatch")

    def test_scope_invalid_relative_and_outside_root(self):
        # Relative root in scope
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z", scope={"hostname": "box1", "root": "relative/path"})
        current = make_ledger(captured_at="2026-10-03T10:00:00Z", scope={"hostname": "box1", "root": "relative/path"})
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["comparison_kind"], "nonnumeric")
        self.assertEqual(res["reason"], "invalid_scope_root")

        # Bucket outside root
        floor2 = make_ledger(captured_at="2026-10-01T12:00:00Z", buckets=[{"path": "/var/other", "measured_kb": 1000}])
        current2 = make_ledger(captured_at="2026-10-03T10:00:00Z", buckets=[{"path": "/var/other", "measured_kb": 1000}])
        res2 = phd.compare_ledgers(floor2, current2, now=NOW)
        self.assertEqual(res2["comparison_kind"], "nonnumeric")
        self.assertEqual(res2["reason"], "bucket_path_outside_scope_root")

    def test_stale_current_and_stale_floor(self):
        # Current older than 36h
        floor = make_ledger(captured_at="2026-09-25T12:00:00Z")
        current_stale = make_ledger(captured_at="2026-10-01T12:00:00Z")  # 48h old relative to NOW
        res1 = phd.compare_ledgers(floor, current_stale, now=NOW)
        self.assertEqual(res1["comparison_kind"], "nonnumeric")
        self.assertEqual(res1["reason"], "stale_current")

        # Floor older than 14d
        floor_stale = make_ledger(captured_at="2026-09-10T12:00:00Z")  # >20d old
        current_fresh = make_ledger(captured_at="2026-10-03T10:00:00Z")
        res2 = phd.compare_ledgers(floor_stale, current_fresh, now=NOW)
        self.assertEqual(res2["comparison_kind"], "nonnumeric")
        self.assertEqual(res2["reason"], "stale_floor")

        # Floor at 10d (within 14d) is valid, not stale!
        floor_10d = make_ledger(captured_at="2026-09-23T12:00:00Z")  # 10d old
        res3 = phd.compare_ledgers(floor_10d, current_fresh, now=NOW)
        self.assertEqual(res3["comparison_kind"], "exact_path")
        self.assertEqual(res3["reason"], "ok")

    def test_future_and_nonpositive_interval(self):
        current_future = make_ledger(captured_at="2026-10-04T12:00:00Z")
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z")
        res1 = phd.compare_ledgers(floor, current_future, now=NOW)
        self.assertEqual(res1["comparison_kind"], "nonnumeric")
        self.assertEqual(res1["reason"], "current_in_future")

        # current <= floor
        floor_newer = make_ledger(captured_at="2026-10-03T11:00:00Z")
        current_older = make_ledger(captured_at="2026-10-03T10:00:00Z")
        res2 = phd.compare_ledgers(floor_newer, current_older, now=NOW)
        self.assertEqual(res2["comparison_kind"], "nonnumeric")
        self.assertEqual(res2["reason"], "nonpositive_interval")

    def test_carried_and_unmeasured_become_unknown(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[
                {"path": "/Users/x/carried", "measured_kb": 1000},
                {"path": "/Users/x/unmeasured", "measured_kb": 2000},
                {"path": "/Users/x/fresh", "measured_kb": 3000},
            ],
        )
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/carried", "measured_kb": 1200},
                {"path": "/Users/x/unmeasured", "measured_kb": 2200},
                {"path": "/Users/x/fresh", "measured_kb": 3500},
            ],
            carried={"/Users/x/carried": {"kb": 1200, "age_hours": 10.0}},
            unmeasured=["/Users/x/unmeasured"],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        delta_paths = [d["path"] for d in res["deltas"]]
        self.assertEqual(delta_paths, ["/Users/x/fresh"])
        unknown_reasons = {u["path"]: u["reason"] for u in res["unknown"]}
        self.assertEqual(unknown_reasons.get("/Users/x/carried"), "carried")
        self.assertEqual(unknown_reasons.get("/Users/x/unmeasured"), "unmeasured")

    def test_quality_and_carried_keys_mappings(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[
                {"path": "/Users/x/c1", "measured_kb": 1000},
                {"path": "/Users/x/u1", "measured_kb": 2000},
            ],
        )
        # current specifies quality='carried' and source='unmeasured' directly on buckets
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/c1", "measured_kb": 1500, "quality": "carried"},
                {"path": "/Users/x/u1", "measured_kb": 2500, "source": "unmeasured"},
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["deltas"], [])
        unknown_reasons = {u["path"]: u["reason"] for u in res["unknown"]}
        self.assertEqual(unknown_reasons.get("/Users/x/c1"), "carried")
        self.assertEqual(unknown_reasons.get("/Users/x/u1"), "unmeasured")

    def test_bucket_timestamp_precedence(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/a", "measured_kb": 1000, "measured_at": "2026-10-01T12:00:00Z"}],
        )
        # current bucket has old measured_at (<= floor)
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[{"path": "/Users/x/a", "measured_kb": 1500, "measured_at": "2026-10-01T11:00:00Z"}],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["deltas"], [])
        self.assertEqual(len(res["unknown"]), 1)
        self.assertEqual(res["unknown"][0]["reason"], "stale_bucket_measurement")

    def test_overlap_lexical_gap(self):
        # Repro: /Users/x/a, /Users/x/a-b, /Users/x/a/b
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[
                {"path": "/Users/x/a", "measured_kb": 1000},
                {"path": "/Users/x/a-b", "measured_kb": 2000},
                {"path": "/Users/x/a/b", "measured_kb": 500},
            ],
        )
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/a", "measured_kb": 1200},
                {"path": "/Users/x/a-b", "measured_kb": 2200},
                {"path": "/Users/x/a/b", "measured_kb": 600},
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        delta_paths = [d["path"] for d in res["deltas"]]
        self.assertEqual(delta_paths, ["/Users/x/a-b"])  # a-b is independent, not overlapping!
        unknown_paths = {u["path"]: u["reason"] for u in res["unknown"]}
        self.assertEqual(unknown_paths.get("/Users/x/a"), "ancestor_descendant_overlap")
        self.assertEqual(unknown_paths.get("/Users/x/a/b"), "ancestor_descendant_overlap")

    def test_forged_duplicate_or_unrelated_partition_rejected(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/parent", "measured_kb": 1000}],
        )
        # Probe from review: children=['/Users/x/unrelated', '/Users/x/unrelated']
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[{"path": "/Users/x/unrelated", "measured_kb": 800}],
            partition_proofs=[
                {
                    "parent": "/Users/x/parent",
                    "children": ["/Users/x/unrelated", "/Users/x/unrelated"],
                    "complete": True,
                    "disjoint": True,
                    "omitted_tail_kb": 0,
                    "direct_allocation_kb": 0,
                }
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["deltas"], [])
        unknown_paths = {u["path"] for u in res["unknown"]}
        self.assertIn("/Users/x/parent", unknown_paths)

    def test_explicit_proven_parent_children_reconciliation(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/dir", "measured_kb": 4000}],
        )
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/dir/part1", "measured_kb": 1500},
                {"path": "/Users/x/dir/part2", "measured_kb": 3000},
            ],
            partition_proofs=[
                {
                    "parent": "/Users/x/dir",
                    "children": ["/Users/x/dir/part1", "/Users/x/dir/part2"],
                    "complete": True,
                    "disjoint": True,
                    "omitted_tail_kb": 0,
                    "direct_allocation_kb": 0,
                }
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(len(res["deltas"]), 1)
        self.assertEqual(res["deltas"][0]["path"], "/Users/x/dir")
        self.assertEqual(res["deltas"][0]["delta_kb"], 500)
        self.assertEqual(res["deltas"][0]["provenance"], "proven_partition_children")
        self.assertEqual(res["unknown"], [])

    def test_regression_guard_compute_deltas_never_called_for_partial(self):
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z")
        current = make_ledger(captured_at="2026-10-03T10:00:00Z", mode="partial")
        with mock.patch("history_diff.compute_deltas") as mock_cd:
            res = phd.compare_ledgers(floor, current, now=NOW)
            self.assertEqual(mock_cd.call_count, 0)
            self.assertIn(res["comparison_kind"], ("exact_path", "partial"))


if __name__ == "__main__":
    unittest.main()

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
    disk_used_kb=10000,
    residual_kb=1000,
    mode="complete",
    carried=None,
    unmeasured=None,
    partition_proofs=None,
    publication_kind=None,
):
    if buckets is None:
        buckets = [{"path": "/Users/x/a", "measured_kb": 5000}]
    if scope is None:
        scope = {"hostname": "box1", "root": "/Users/x"}
    res = {
        "schema_version": 2,
        "mode": mode,
        "captured_at": captured_at,
        "hostname": scope.get("hostname") if isinstance(scope, dict) else "box1",
        "root": scope.get("root") if isinstance(scope, dict) else "/Users/x",
        "scope": scope,
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": oversize or [],
        "coverage_envelope": {"complete": mode == "complete"},
    }
    if carried is not None:
        res["carried"] = carried
    if unmeasured is not None:
        res["unmeasured"] = unmeasured
    if partition_proofs is not None:
        res["partition_proofs"] = partition_proofs
    if publication_kind is not None:
        res["publication_kind"] = publication_kind
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
        self.assertEqual(res["reason"], "unsupported_schema_version")

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

    def test_overlapping_and_duplicate_paths_become_unknown(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/a", "measured_kb": 4000}],
        )
        # current has ancestor and descendant
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/a", "measured_kb": 4000},
                {"path": "/Users/x/a/sub", "measured_kb": 1000},
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        unknown_paths = {u["path"]: u["reason"] for u in res["unknown"]}
        self.assertEqual(unknown_paths.get("/Users/x/a"), "ancestor_descendant_overlap")
        self.assertEqual(unknown_paths.get("/Users/x/a/sub"), "ancestor_descendant_overlap")
        self.assertEqual(res["deltas"], [])

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

    def test_unproven_partition_remains_unknown(self):
        floor = make_ledger(
            captured_at="2026-10-01T12:00:00Z",
            buckets=[{"path": "/Users/x/dir", "measured_kb": 4000}],
        )
        # Incomplete proof: omitted_tail_kb is nonzero
        current = make_ledger(
            captured_at="2026-10-03T10:00:00Z",
            buckets=[
                {"path": "/Users/x/dir/part1", "measured_kb": 1500},
                {"path": "/Users/x/dir/part2", "measured_kb": 2000},
            ],
            partition_proofs=[
                {
                    "parent": "/Users/x/dir",
                    "children": ["/Users/x/dir/part1", "/Users/x/dir/part2"],
                    "complete": True,
                    "disjoint": True,
                    "omitted_tail_kb": 500,  # nonzero omitted tail -> invalid proof!
                    "direct_allocation_kb": 0,
                }
            ],
        )
        res = phd.compare_ledgers(floor, current, now=NOW)
        self.assertEqual(res["deltas"], [])
        unknown_paths = {u["path"] for u in res["unknown"]}
        self.assertIn("/Users/x/dir", unknown_paths)
        self.assertIn("/Users/x/dir/part1", unknown_paths)
        self.assertIn("/Users/x/dir/part2", unknown_paths)

    def test_regression_guard_compute_deltas_never_called_for_partial(self):
        floor = make_ledger(captured_at="2026-10-01T12:00:00Z")
        current = make_ledger(captured_at="2026-10-03T10:00:00Z", mode="partial")
        with mock.patch("history_diff.compute_deltas") as mock_cd:
            res = phd.compare_ledgers(floor, current, now=NOW)
            self.assertEqual(mock_cd.call_count, 0)
            self.assertIn(res["comparison_kind"], ("exact_path", "partial"))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""tests/test_growth_top10.py — unit and integration tests for growth_top10.py."""
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import growth_top10 as gt  # noqa: E402
import history_diff as hd  # noqa: E402

SCRIPT = REPO / "scripts" / "growth_top10.py"
GIB_KB = 1024 * 1024

USER_PROBE_PATHS = {
    "mobile_sync": os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join(os.path.expanduser("~"), "Library", "Mail"),
    "messages": os.path.join(os.path.expanduser("~"), "Library", "Messages"),
}


def make_valid_floor(captured_at=None, buckets=None, disk_used_kb=10000000, scope=None):
    if captured_at is None:
        captured_at = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
    if buckets is None:
        buckets = [{"path": "/Users/x/a", "measured_kb": 4000000}]
    if scope is None:
        scope = {"hostname": "testhost", "root": "/Users/x"}
    bucket_total = sum(b.get("measured_kb", 0) for b in buckets)
    tail = disk_used_kb - bucket_total - 1000000
    return {
        "schema_version": 2,
        "mode": "complete",
        "scope": scope,
        "hostname": scope.get("hostname", "testhost"),
        "root": scope.get("root", "/Users/x"),
        "captured_at": captured_at,
        "run_id": "run-f1",
        "run_started_at": 100.0,
        "run_finished_at": 102.0,
        "coverage_envelope": {
            "complete": True,
            "status": "complete",
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
            "reachable_top_level_roots": 1,
            "measured_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
        },
        "fda_probe_paths": dict(USER_PROBE_PATHS),
        "fda_preflight": {
            "status": "granted",
            "probes": {
                name: {"path": path, "status": "readable"}
                for name, path in USER_PROBE_PATHS.items()
            },
        },
        "disk_used_kb": disk_used_kb,
        "residual_kb": 1000000,
        "purgeable_kb": 0,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": [],
        "frontier_unfinished": [],
        "opaque_intrinsic_gates": [],
        "accounting_equation": {
            "displayed_balanced": True,
            "display_ledger_valid": True,
            "data_used_kb": disk_used_kb,
            "displayed_buckets_kb": bucket_total,
            "oversize_indivisible_files_kb": 0,
            "sub_granularity_tail_kb": tail,
            "purgeable_kb": 0,
            "residual_kb": 1000000,
            "clone_shared_adjustment_kb": 0,
        },
    }


def make_valid_partial(captured_at=None, buckets=None, disk_used_kb=10500000, scope=None):
    if captured_at is None:
        captured_at = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    if buckets is None:
        buckets = [{"path": "/Users/x/a", "measured_kb": 4500000}]
    if scope is None:
        scope = {"hostname": "testhost", "root": "/Users/x"}
    bucket_total = sum(b.get("measured_kb", 0) for b in buckets)
    tail = disk_used_kb - bucket_total - 1000000
    return {
        "schema_version": 2,
        "mode": "partial",
        "publication_kind": "partial",
        "canonical": False,
        "scope": scope,
        "hostname": scope.get("hostname", "testhost"),
        "root": scope.get("root", "/Users/x"),
        "captured_at": captured_at,
        "run_id": "run-p1",
        "coverage_envelope": {
            "complete": False,
            "status": "partial",
            "measured_top_level_roots": 1,
            "reachable_top_level_roots": 2,
        },
        "disk_used_kb": disk_used_kb,
        "residual_kb": 1000000,
        "purgeable_kb": 0,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": [],
        "frontier_unfinished": [],
        "opaque_intrinsic_gates": [],
        "accounting_equation": {
            "displayed_balanced": True,
            "display_ledger_valid": True,
            "data_used_kb": disk_used_kb,
            "displayed_buckets_kb": bucket_total,
            "oversize_indivisible_files_kb": 0,
            "sub_granularity_tail_kb": tail,
            "purgeable_kb": 0,
            "residual_kb": 1000000,
            "clone_shared_adjustment_kb": 0,
        },
    }


class TestGrowthTop10(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state_dir = pathlib.Path(self.tmp) / "state"
        self.state_dir.mkdir()
        subprocess.run(["git", "-C", str(self.state_dir), "init", "-q"], check=True)
        (self.state_dir / "ledger").mkdir()

    def _commit_floor(self, floor_dict, commit_time=None):
        p = self.state_dir / "ledger" / "topdown-5g.json"
        p.write_text(json.dumps(floor_dict, indent=2))
        subprocess.run(["git", "-C", str(self.state_dir), "add", "ledger/topdown-5g.json"], check=True)
        if commit_time is None:
            commit_time = floor_dict.get("captured_at", (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        env = dict(os.environ, GIT_AUTHOR_DATE=commit_time, GIT_COMMITTER_DATE=commit_time)
        subprocess.run(
            ["git", "-C", str(self.state_dir), "-c", "user.email=t@test", "-c", "user.name=t", "commit", "-q", "-m", "commit floor"],
            env=env,
            check=True,
        )

    def test_json_output_with_valid_floor_and_partial(self):
        floor = make_valid_floor()
        self._commit_floor(floor)

        partial = make_valid_partial()
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir), "--json"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        data = json.loads(res.stdout)
        self.assertIn(data["comparison_kind"], ("exact_path", "partial"))
        self.assertEqual(data["reason"], "ok")
        self.assertEqual(data["current_source"], "partial")
        self.assertIn("floor_ref", data)
        self.assertIn("deltas", data)
        self.assertIn("unknown", data)
        self.assertIn("measured_interval", data)
        self.assertEqual(len(data["deltas"]), 1)
        self.assertEqual(data["deltas"][0]["path"], "/Users/x/a")
        self.assertEqual(data["deltas"][0]["delta_kb"], 500000)

    def test_no_floor_exits_2_and_emits_honest_json(self):
        # Empty repo with no floor commit
        partial = make_valid_partial()
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir), "--json"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 2)

        data = json.loads(res.stdout)
        self.assertEqual(data["comparison_kind"], "no_floor")
        self.assertEqual(data["deltas"], [])

    def test_floor_recently_committed_but_old_capture_is_refused(self):
        # Commit right now, but capture timestamp is 20 days old (outside 14d)
        old_captured = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        floor = make_valid_floor(captured_at=old_captured)
        self._commit_floor(floor)

        partial = make_valid_partial(captured_at=(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir), "--json"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 2)
        data = json.loads(res.stdout)
        self.assertEqual(data["comparison_kind"], "no_floor")
        self.assertTrue("no valid ledger snapshots" in data["reason"] or "floor capture timestamp outside window" in data["reason"])

    def test_freshest_current_selection_picks_newest_capture(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        cap_canonical = (now - datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        cap_partial = (now - datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Canonical is 2h old, partial is 5h old -> should pick canonical!
        floor = make_valid_floor(captured_at=(now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self._commit_floor(floor)

        # Write canonical to working tree (fresher than partial)
        canonical_tree = make_valid_floor(captured_at=cap_canonical)
        (self.state_dir / "ledger" / "topdown-5g.json").write_text(json.dumps(canonical_tree))

        # Write partial (older than canonical)
        partial = make_valid_partial(captured_at=cap_partial)
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        ledger, source = gt.load_freshest_current(self.state_dir, now)
        self.assertEqual(source, "canonical")
        self.assertEqual(ledger["captured_at"], cap_canonical)

    def test_text_output_never_claims_no_growth_when_unknown_exists(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        floor = make_valid_floor(captured_at=(now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self._commit_floor(floor)

        # Current has missing path and carried path -> positive growth is empty, but unknown exists!
        partial = make_valid_partial(
            captured_at=(now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            buckets=[{"path": "/Users/x/other", "measured_kb": 1000}],
        )
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir)]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn("(no growth — nothing exceeded the floor)", res.stdout)
        self.assertIn("unmeasured/unknown components prevent confirming zero growth", res.stdout)

    def test_regression_guard_compute_deltas_never_called(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        floor = make_valid_floor(captured_at=(now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self._commit_floor(floor)

        partial = make_valid_partial(captured_at=(now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        with mock.patch("history_diff.compute_deltas") as mock_cd:
            gt.main(["--state-dir", str(self.state_dir), "--json"])
            self.assertEqual(mock_cd.call_count, 0)

    def test_json_gap_kb_null_on_nonnumeric(self):
        floor = make_valid_floor(scope={"hostname": "box1", "root": "/Users/x"})
        self._commit_floor(floor)

        # Current has different hostname -> scope_mismatch nonnumeric
        partial = make_valid_partial(scope={"hostname": "box2", "root": "/Users/x"})
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir), "--json"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 1)

        data = json.loads(res.stdout)
        self.assertEqual(data["comparison_kind"], "nonnumeric")
        self.assertIsNone(data["gap_kb"])

    def test_json_limit_applied(self):
        floor = make_valid_floor(
            buckets=[
                {"path": "/Users/x/a", "measured_kb": 1000},
                {"path": "/Users/x/b", "measured_kb": 1000},
            ]
        )
        self._commit_floor(floor)

        partial = make_valid_partial(
            buckets=[
                {"path": "/Users/x/a", "measured_kb": 2000},
                {"path": "/Users/x/b", "measured_kb": 3000},
            ]
        )
        (self.state_dir / "ledger" / "topdown-5g.partial.json").write_text(json.dumps(partial))

        cmd = [sys.executable, str(SCRIPT), "--state-dir", str(self.state_dir), "--json", "--limit", "1"]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)

        data = json.loads(res.stdout)
        self.assertEqual(len(data["deltas"]), 1)
        self.assertEqual(len(data["top_growth"]), 1)

    def test_select_floor_ref_chooses_valid_captured_candidate_over_recent_commit_ancient_capture(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        # Commit 1: 3 days ago, valid capture 3 days ago, used=5000000
        valid_cap = (now - datetime.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
        c1 = make_valid_floor(captured_at=valid_cap, disk_used_kb=5000000)
        self._commit_floor(c1, commit_time=valid_cap)

        # Commit 2: committed 1 hour ago, but captured 60 days ago (outside 14d), used=1000000 (lower!)
        ancient_cap = (now - datetime.timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        c2 = make_valid_floor(captured_at=ancient_cap, disk_used_kb=1000000)
        self._commit_floor(c2, commit_time=(now - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))

        # select_floor_ref with filter_capture_window=True must choose c1!
        ref, chosen = hd.select_floor_ref(self.state_dir, days=14, filter_capture_window=True, now=now)
        self.assertEqual(chosen["captured_at"], valid_cap)
        self.assertEqual(chosen["disk_used_kb"], 5000000)


if __name__ == "__main__":
    unittest.main()

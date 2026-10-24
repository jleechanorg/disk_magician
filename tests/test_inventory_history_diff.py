"""Public inventory-history CLI contract tests (Task 5)."""
import os
import subprocess
import tempfile
import unittest
import sys
from datetime import datetime, timezone

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "disk_magician.sh"
sys.path.insert(0, str(REPO / "scripts"))
import history_diff


class InventoryHistoryDispatchTest(unittest.TestCase):
    def test_inventory_source_is_an_explicit_history_diff_mode(self):
        """The inventory source is accepted independently of strict Git-ledger mode."""
        with tempfile.TemporaryDirectory(prefix="inventory_history_cli_") as tmp:
            state = Path(tmp) / "state"
            home = Path(tmp) / "home"
            state.mkdir()
            home.mkdir()
            env = {
                "PATH": "/usr/bin:/bin",
                "HOME": str(home),
                "DISK_MAGICIAN_STATE_DIR": str(state),
                "DISK_MAGICIAN_STATE_REPO": str(Path(tmp) / "missing-git-state"),
            }
            result = subprocess.run(
                [str(CLI), "history", "diff", "--source", "inventory", "--days", "7", "--json"],
                cwd=REPO,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotIn("unrecognized arguments: --source", result.stderr)
        self.assertNotIn("unrecognized arguments: --json", result.stderr)
        self.assertNotIn("no state repo", result.stderr)
        self.assertTrue(
            result.returncode in (0, 1, 2),
            f"unexpected CLI exit {result.returncode}: {result.stderr}",
        )


class InventoryComparisonLogicTest(unittest.TestCase):
    def test_daily_minima_are_per_filesystem_and_median_is_not_a_floor(self):
        samples = [
            {"filesystem_id": "root", "sampled_at": "2026-10-20T12:00:00Z", "used_bytes": 100},
            {"filesystem_id": "root", "sampled_at": "2026-10-20T13:00:00Z", "used_bytes": 80},
            {"filesystem_id": "root", "sampled_at": "2026-10-21T12:00:00Z", "used_bytes": 90},
            {"filesystem_id": "home", "sampled_at": "2026-10-20T12:00:00Z", "used_bytes": 500},
        ]
        got = history_diff.daily_minimum_summary(samples, days=7, now=datetime(2026, 10, 22, tzinfo=timezone.utc))
        self.assertEqual(got["root"]["floor_bytes"], 80)
        self.assertEqual(got["root"]["median_daily_minimum_bytes"], 85)
        self.assertEqual(got["root"]["coverage_status"], "partial")
        self.assertEqual(got["home"]["floor_bytes"], 500)

    def test_path_delta_requires_known_generation_and_complete_subtree(self):
        base = {"canonical_path": "/home/a", "filesystem_id": "fs-home", "path_generation": {"id": "g1", "status": "known"},
                "observation": {"allocated_bytes": 100, "apparent_bytes": 130, "subtree_coverage_status": "complete", "comparable": True},
                "attribution": {"basis": "logical", "comparability": "comparable", "reason": None}}
        current = {**base, "observation": {**base["observation"], "allocated_bytes": 160, "apparent_bytes": 200}}
        got = history_diff.compare_inventory_path(base, current)
        self.assertEqual(got["logical_delta_bytes"], 60)
        self.assertEqual(got["apparent_delta_bytes"], 70)
        self.assertIsNone(got["physical_delta_bytes"])
        replaced = {**current, "path_generation": {"id": "g2", "status": "known"}}
        self.assertIsNone(history_diff.compare_inventory_path(base, replaced)["logical_delta_bytes"])
        partial = {**current, "observation": {**current["observation"], "subtree_coverage_status": "partial"}}
        self.assertIsNone(history_diff.compare_inventory_path(base, partial)["logical_delta_bytes"])

    def test_physical_delta_needs_explicit_exclusive_attribution(self):
        base = {"canonical_path": "/x", "filesystem_id": "fs", "path_generation": {"id": "g", "status": "known"},
                "observation": {"allocated_bytes": 10, "apparent_bytes": 10, "subtree_coverage_status": "complete", "comparable": True},
                "attribution": {"basis": "physical", "comparability": "comparable", "capability": "exclusive", "reason": None}}
        current = {**base, "observation": {**base["observation"], "allocated_bytes": 20}}
        self.assertEqual(history_diff.compare_inventory_path(base, current)["physical_delta_bytes"], 10)
        current["attribution"] = {**current["attribution"], "capability": "hardlinks_possible"}
        self.assertIsNone(history_diff.compare_inventory_path(base, current)["physical_delta_bytes"])


    def test_history_reader_uses_published_manifest_and_floor(self):
        import sys
        sys.path.insert(0, str(REPO / "scripts"))
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_history_publish_") as tmp:
            state = Path(tmp)
            record = {"filesystem_id": "fs", "mountpoint": "/", "canonical_path": "/x",
                "path_generation": {"id": "p", "status": "known"},
                "observation": {"scan_id": "s", "started_at": "2026-10-23T00:00:00Z", "ended_at": "2026-10-23T00:01:00Z",
                    "allocated_bytes": 100, "apparent_bytes": 120, "size_semantics": "inclusive", "source": "frontier",
                    "measurement_status": "measured", "subtree_coverage_status": "complete", "comparable": True},
                "attribution": {"basis": "logical", "capability": "logical", "comparability": "comparable", "reason": None}}
            fs = {"filesystem_id": "fs", "mountpoint": "/", "device": "/dev/test", "fstype": "fixture",
                "case_sensitive": True, "identity_status": "known", "selected_roots": ["/"], "excluded_roots": [],
                "selection_epoch": "epoch", "df_samples": [{"sampled_at": "2026-10-23T00:00:00Z",
                    "used_bytes": 100, "free_bytes": 200, "total_bytes": 300}]}
            publish_inventory([record], state_dir=state, complete=True, scan_metadata={"selected_filesystems": [fs]}, now="2026-10-23T00:01:00Z")
            current = inventory_history_report(state, days=7, now=datetime(2026, 10, 24, tzinfo=timezone.utc))
        self.assertEqual(current["filesystems"][0]["floor_used_bytes"], 100)
        self.assertEqual(current["filesystems"][0]["current_minus_floor_bytes"], 0)
        self.assertIsNone(current["host_aggregate_delta_bytes"])
    def test_changed_selection_epoch_withholds_path_deltas(self):
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_epoch_") as tmp:
            state = Path(tmp)
            rec = {"filesystem_id": "fs", "mountpoint": "/", "canonical_path": "/x",
                "path_generation": {"id": "p", "status": "known"},
                "observation": {"scan_id": "s", "started_at": "2026-10-23T00:00:00Z",
                    "ended_at": "2026-10-23T00:01:00Z", "allocated_bytes": 10, "apparent_bytes": 12,
                    "size_semantics": "inclusive", "source": "frontier", "measurement_status": "measured",
                    "subtree_coverage_status": "complete", "comparable": True},
                "attribution": {"basis": "logical", "capability": "logical", "comparability": "comparable", "reason": None}}
            def metadata(epoch, stamp, used):
                return {"selected_filesystems": [{"filesystem_id": "fs", "mountpoint": "/", "device": "/dev/test",
                    "fstype": "fixture", "case_sensitive": True, "identity_status": "known", "selected_roots": ["/"],
                    "excluded_roots": [], "selection_epoch": epoch,
                    "df_samples": [{"sampled_at": stamp, "used_bytes": used, "free_bytes": 100, "total_bytes": 200}]}]}
            publish_inventory([rec], state_dir=state, complete=True, scan_metadata=metadata("epoch-old", "2026-10-23T00:00:00Z", 10), now="2026-10-23T00:01:00Z")
            publish_inventory([{**rec, "observation": {**rec["observation"], "allocated_bytes": 20}}],
                state_dir=state, complete=True, scan_metadata=metadata("epoch-new", "2026-10-24T00:00:00Z", 20), now="2026-10-24T00:01:00Z")
            report = inventory_history_report(state, days=7, now=datetime(2026, 10, 24, tzinfo=timezone.utc))
        self.assertEqual(report["filesystems"][0]["status"], "selection_epoch_changed")
        self.assertEqual(report["filesystems"][0]["path_deltas"], [])

    def test_observer_floor_helper_uses_daily_minima_and_labels_partial_coverage(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("disk_observer_floor", REPO / "scripts" / "disk_observer.py")
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        now = datetime(2026, 10, 24, 23, tzinfo=timezone.utc)
        records = [
            {"epoch": datetime(2026, 10, 23, 12, tzinfo=timezone.utc).timestamp(), "host_disk": {"used_kb": 90}},
            {"epoch": datetime(2026, 10, 23, 13, tzinfo=timezone.utc).timestamp(), "host_disk": {"used_kb": 70}},
            {"epoch": datetime(2026, 10, 24, 12, tzinfo=timezone.utc).timestamp(), "host_disk": {"used_kb": 80}},
        ]
        result = observer.summarize_host_disk_floors(records, days=7, now=now)
        self.assertEqual(result["floor_used_kb"], 70)
        self.assertEqual(result["median_daily_minimum_kb"], 75)
        self.assertEqual(result["coverage_status"], "partial")
        self.assertEqual(result["source"], "disk_observer.jsonl")



if __name__ == "__main__":
    unittest.main()

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
            from directory_inventory import publish_inventory
            publish_inventory([], state_dir=state, complete=True)
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
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("NameError", result.stderr)
        import json
        self.assertEqual(json.loads(result.stdout)["source"], "inventory")
        self.assertEqual(result.returncode, 0)
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

class InventoryHistoryAcceptanceGapsTest(unittest.TestCase):
    def test_floor_and_path_own_minimum_are_reported_separately(self):
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_two_floors_") as tmp:
            state = Path(tmp)
            def publish(stamp, used, size):
                record = {"filesystem_id": "fs", "mountpoint": "/", "canonical_path": "/x",
                    "path_generation": {"id": "same", "status": "known"},
                    "observation": {"scan_id": stamp, "started_at": stamp, "ended_at": stamp,
                        "allocated_bytes": size, "apparent_bytes": size, "subtree_coverage_status": "complete", "comparable": True}}
                fs = {"filesystem_id": "fs", "mountpoint": "/", "selection_epoch": "epoch",
                    "df_samples": [{"sampled_at": stamp, "used_bytes": used, "free_bytes": 1, "total_bytes": used + 1}]}
                return publish_inventory([record], state_dir=state, complete=True,
                    scan_metadata={"selected_filesystems": [fs]}, now=stamp)
            publish("2026-10-23T00:00:00Z", 80, 100)
            publish("2026-10-23T12:00:00Z", 50, 80)
            publish("2026-10-24T00:00:00Z", 120, 120)
            report = inventory_history_report(state, days=7, now=datetime(2026, 10, 24, 12, tzinfo=timezone.utc))
        fs = report["filesystems"][0]
        row = next(item for item in fs["path_deltas"] if item["path"] == "/x")
        self.assertEqual(row["matching_fs_floor_delta_bytes"], 40)
        self.assertEqual(row["path_own_floor_delta_bytes"], 40)
        self.assertEqual(row["path_own_floor_at"], "2026-10-23T12:00:00+00:00")

    def test_path_first_seen_after_filesystem_floor_uses_path_own_floor(self):
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_late_path_") as tmp:
            state = Path(tmp)
            def publish(stamp, used, paths):
                records = []
                for path, size, generation in paths:
                    generation_id, generation_status = (generation if isinstance(generation, tuple) else (generation, "known"))
                    records.append({"filesystem_id": "fs", "mountpoint": "/", "canonical_path": path,
                        "path_generation": {"id": generation_id, "status": generation_status},
                        "observation": {"scan_id": stamp, "started_at": stamp, "ended_at": stamp,
                            "allocated_bytes": size, "apparent_bytes": size, "subtree_coverage_status": "complete", "comparable": True}})
                fs = {"filesystem_id": "fs", "mountpoint": "/", "selection_epoch": "epoch",
                    "df_samples": [{"sampled_at": stamp, "used_bytes": used, "free_bytes": 1, "total_bytes": used + 1}]}
                publish_inventory(records, state_dir=state, complete=True,
                    scan_metadata={"selected_filesystems": [fs]}, now=stamp)
            publish("2026-10-20T00:00:00Z", 50, [("/floor", 10, "floor")])
            publish("2026-10-21T00:00:00Z", 100, [("/floor", 10, "floor"), ("/late", 20, ("late", "unknown"))])
            publish("2026-10-22T00:00:00Z", 120, [("/floor", 10, "floor"), ("/late", 20, "late")])
            publish("2026-10-23T00:00:00Z", 150, [("/floor", 10, "floor"), ("/late", 60, "late")])
            report = inventory_history_report(state, days=7, now=datetime(2026, 10, 23, 1, tzinfo=timezone.utc))
        fs = report["filesystems"][0]
        row = next(item for item in fs["path_deltas"] if item["path"] == "/late")
        self.assertIsNone(row["matching_fs_floor_delta_bytes"])
        self.assertIsNone(row["logical_delta_bytes"])
        self.assertEqual(row["path_own_floor_bytes"], 20)
        self.assertEqual(row["path_own_floor_delta_bytes"], 40)

    def test_stale_current_observations_do_not_claim_comparable_delta(self):
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_stale_current_") as tmp:
            state = Path(tmp)
            def publish(stamp, size):
                record = {"filesystem_id": "fs", "mountpoint": "/", "canonical_path": "/x",
                    "path_generation": {"id": "same", "status": "known"},
                    "observation": {"scan_id": stamp, "started_at": stamp, "ended_at": stamp,
                        "allocated_bytes": size, "apparent_bytes": size, "subtree_coverage_status": "complete", "comparable": True}}
                fs = {"filesystem_id": "fs", "mountpoint": "/", "selection_epoch": "epoch",
                    "df_samples": [{"sampled_at": stamp, "used_bytes": size, "free_bytes": 1, "total_bytes": size + 1}]}
                publish_inventory([record], state_dir=state, complete=True,
                    scan_metadata={"selected_filesystems": [fs]}, now=stamp)
            publish("2026-10-22T00:00:00Z", 100)
            publish("2026-10-24T00:00:00Z", 120)
            report = inventory_history_report(state, days=7, now=datetime(2026, 10, 25, 12, tzinfo=timezone.utc))
        fs = report["filesystems"][0]
        self.assertEqual(fs["status"], "stale_current_observation")
        self.assertIsNone(fs["current_minus_floor_bytes"])
        self.assertEqual(fs["path_deltas"], [])
        self.assertGreater(fs["current_sample_age_hours"], 24)

    def test_daily_summary_exposes_observed_range_and_max_sample_gap(self):
        samples = [
            {"filesystem_id": "fs", "sampled_at": "2026-10-20T00:00:00Z", "used_bytes": 100},
            {"filesystem_id": "fs", "sampled_at": "2026-10-20T06:00:00Z", "used_bytes": 90},
            {"filesystem_id": "fs", "sampled_at": "2026-10-21T00:00:00Z", "used_bytes": 80},
        ]
        got = history_diff.daily_minimum_summary(samples, days=7,
            now=datetime(2026, 10, 22, tzinfo=timezone.utc))["fs"]
        self.assertEqual(got["observed_range"]["start"], "2026-10-20T00:00:00+00:00")
        self.assertEqual(got["observed_range"]["end"], "2026-10-21T00:00:00+00:00")
        self.assertEqual(got["max_sample_gap_hours"], 18)

    def test_seven_day_floor_uses_per_epoch_alignment_and_keeps_other_filesystems_out(self):
        from directory_inventory import publish_inventory
        from history_diff import inventory_history_report
        with tempfile.TemporaryDirectory(prefix="inventory_multiday_alignment_") as tmp:
            state = Path(tmp)
            def publish(stamp, fs_samples, rows):
                records = []
                for fsid, path, size in rows:
                    records.append({"filesystem_id": fsid, "mountpoint": "/" if fsid == "root" else "/home",
                        "canonical_path": path, "path_generation": {"id": "stable-" + fsid, "status": "known"},
                        "observation": {"scan_id": stamp, "started_at": stamp, "ended_at": stamp,
                            "allocated_bytes": size, "apparent_bytes": size, "subtree_coverage_status": "complete", "comparable": True}})
                filesystems = [{"filesystem_id": fsid, "mountpoint": mount, "selection_epoch": "epoch-" + fsid,
                    "df_samples": [{"sampled_at": sample_at, "used_bytes": used, "free_bytes": 10, "total_bytes": used + 10}]}
                    for fsid, mount, sample_at, used in fs_samples]
                return publish_inventory(records, state_dir=state, complete=True,
                    scan_metadata={"selected_filesystems": filesystems}, now=stamp)
            publish("2026-10-18T00:00:00Z", [("root", "/", "2026-10-18T00:00:00Z", 50), ("home", "/home", "2026-10-18T00:00:00Z", 40)],
                [("root", "/root-data", 90), ("home", "/home-data", 30)])
            publish("2026-10-19T00:00:00Z", [("root", "/", "2026-10-19T00:00:00Z", 70), ("home", "/home", "2026-10-19T00:00:00Z", 45)],
                [("root", "/root-data", 95), ("home", "/home-data", 20)])
            current = publish("2026-10-24T10:00:00Z", [("root", "/", "2026-10-24T10:00:00Z", 90), ("home", "/home", "2026-10-24T10:00:00Z", 55)],
                [("root", "/root-data", 160), ("home", "/home-data", 50)])
            report = inventory_history_report(state, days=7, now=datetime(2026, 10, 24, 12, tzinfo=timezone.utc))
        root = next(item for item in report["filesystems"] if item["filesystem_id"] == "root")
        row = next(item for item in root["path_deltas"] if item["path"] == "/root-data")
        self.assertEqual(row["matching_fs_floor_delta_bytes"], 70)
        self.assertEqual(row["floor_path_df_offset_hours"], 0)
        self.assertEqual(row["current_path_df_offset_hours"], 0)
        self.assertEqual(row["path_own_floor_bytes"], 90)
        self.assertEqual(row["path_own_floor_delta_bytes"], 70)
        self.assertIsNotNone(row["path_own_floor_manifest_sha256"])
        self.assertEqual(root["floor_manifest_sha256"], row["path_own_floor_manifest_sha256"])
        self.assertEqual([item["path"] for item in root["path_deltas"]], ["/root-data"])

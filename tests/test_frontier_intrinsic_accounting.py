import errno
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import disk_frontier_scan as frontier  # noqa: E402

GIB_KB = 1024 * 1024


class TestIntrinsicGateAccounting(unittest.TestCase):
    def scanner(self, *, effective_uid=0):
        return SimpleNamespace(
            root="/fixture",
            root_dev=1,
            effective_uid=effective_uid,
            measured={"/fixture/data": 12 * GIB_KB},
            inventory_buckets=[
                {"path": "/fixture/data [direct 1/3]", "kind": "direct_allocation_segment", "measured_kb": 5 * GIB_KB},
                {"path": "/fixture/data [direct 2/3]", "kind": "direct_allocation_segment", "measured_kb": 5 * GIB_KB},
                {"path": "/fixture/data [direct 3/3]", "kind": "direct_allocation_segment", "measured_kb": 2 * GIB_KB},
            ],
            oversize_files=[],
            frontier_unfinished=[
                {"path": "/fixture/data/denied", "reason": "inventory_permission_denied"},
                {"path": "/fixture/data/gone", "reason": "inventory_path_disappeared"},
                {"path": "/fixture/home", "reason": "cross_device_boundary"},
            ],
            deduped=[], warnings=[], nodes_processed=3,
            tracker=SimpleNamespace(peak=lambda: 1),
            level1_paths=["/fixture/data", "/fixture/home"],
            inventory_backend="gdu_one_pass", shallow_enumeration_depth=0,
            fda_preflight={"status": "granted", "probes": {}},
        )

    @staticmethod
    def args():
        return SimpleNamespace(
            workers=1, max_depth=6, max_nodes=100_000_000,
            wall_clock_cap=100, timeout_tiers=[10], granularity_gib=5,
        )

    @staticmethod
    def fake_lstat(path):
        if path.endswith("/gone"):
            raise FileNotFoundError(errno.ENOENT, "gone", path)
        return SimpleNamespace(st_dev=2 if path.endswith("/home") else 1)

    @staticmethod
    def fake_scandir(path):
        if path.endswith(("/denied", "/secret")):
            raise PermissionError(errno.EPERM, "denied", path)
        raise AssertionError(f"unexpected scandir: {path}")

    def report(self, scanner):
        with mock.patch.object(frontier.os, "lstat", side_effect=self.fake_lstat), \
             mock.patch.object(frontier.os.path, "realpath", side_effect=lambda path: path), \
             mock.patch.object(frontier.os, "scandir", side_effect=self.fake_scandir):
            return frontier.build_report(
                scanner,
                {"total_kb": 20 * GIB_KB, "used_kb": 10 * GIB_KB, "free_kb": 10 * GIB_KB},
                [],
                {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
                 "local_snapshots": [], "local_snapshots_count": 0},
                1.0,
                self.args(),
            )

    def test_privileged_persistent_gates_complete_with_signed_adjustment(self):
        report = self.report(self.scanner())

        self.assertEqual(report["mode"], "complete")
        self.assertEqual(report["frontier_unfinished"], [])
        self.assertEqual(
            {item["reason"] for item in report["opaque_intrinsic_gates"]},
            {"permission_denied_intrinsic", "vanished_during_scan", "cross_device_boundary"},
        )
        self.assertEqual(report["accounting_equation"]["clone_shared_adjustment_kb"], -2 * GIB_KB)
        self.assertTrue(report["accounting_equation"]["displayed_balanced"])
        self.assertTrue(report["coverage_envelope"]["complete"])
        self.assertEqual(report["coverage_envelope"]["reachable_top_level_roots"], 1)
        self.assertEqual(report["coverage_envelope"]["measured_top_level_roots"], 1)

    def test_unprivileged_permission_failure_remains_unfinished(self):
        report = self.report(self.scanner(effective_uid=501))

        self.assertEqual(report["mode"], "partial")
        self.assertIn("inventory_permission_denied", {item["reason"] for item in report["frontier_unfinished"]})
        self.assertFalse(report["coverage_envelope"]["complete"])

    def test_unmeasured_top_level_intrinsic_gate_is_opaque_not_unfinished(self):
        scanner = self.scanner()
        scanner.measured = {}
        scanner.inventory_buckets = []
        scanner.frontier_unfinished = [{
            "path": "/fixture/secret",
            "reason": "inventory_permission_denied",
        }]
        scanner.level1_paths = ["/fixture/secret"]

        report = self.report(scanner)

        self.assertEqual(report["mode"], "complete")
        self.assertEqual(report["frontier_unfinished"], [])
        self.assertTrue(report["coverage_envelope"]["complete"])
        self.assertEqual(report["top_level_ledger"][0]["status"], "measured_with_opaque_gates")


if __name__ == "__main__":
    unittest.main()

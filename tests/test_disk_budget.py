#!/usr/bin/env python3
"""tests/test_disk_budget.py — admission zones and the policy table (plan Task 3, spec §7.1)."""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import disk_budget  # noqa: E402

STAGES = ("observe", "warn", "refuse_red", "refuse_orange")

# (admission zone, class over budget, {stage: rc}) straight from the plan's policy table.
TABLE = [
    ("GREEN", False, dict(observe=0, warn=0, refuse_red=0, refuse_orange=0)),
    ("GREEN", True, dict(observe=0, warn=0, refuse_red=0, refuse_orange=0)),
    ("ORANGE", False, dict(observe=0, warn=10, refuse_red=10, refuse_orange=10)),
    ("ORANGE", True, dict(observe=0, warn=10, refuse_red=10, refuse_orange=75)),
    ("RED", False, dict(observe=0, warn=10, refuse_red=75, refuse_orange=75)),
    ("RED", True, dict(observe=0, warn=10, refuse_red=75, refuse_orange=75)),
]
FREE_FOR = {"GREEN": 150, "ORANGE": 80, "RED": 45, "BLACK": 25, "FLOOR": 10}


class DiskBudgetTest(unittest.TestCase):
    def test_zone_boundaries(self):
        for free, expected in [(250, "GREEN"), (100, "GREEN"), (99.9, "ORANGE"), (60, "ORANGE"), (59.9, "RED"),
                               (30, "RED"), (29.9, "BLACK"), (15, "BLACK"), (14.9, "FLOOR"), (-5, "FLOOR")]:
            with self.subTest(free=free):
                self.assertEqual(disk_budget.zone(free), expected)

    def test_policy_table_non_emergency_rows(self):
        # est 0, margin 0: admission zone == df zone; non-emergency rows ignore D2.
        for zone_name, over, expected in TABLE:
            for stage in STAGES:
                for d2 in (False, True):
                    with self.subTest(zone=zone_name, over=over, stage=stage, d2=d2):
                        self.assertEqual(disk_budget.decide(stage, FREE_FOR[zone_name], 0, 0, over, d2),
                                         (zone_name, expected[stage]))

    def test_emergency_rows_need_d2(self):
        for stage in STAGES:
            for over in (False, True):
                with self.subTest(stage=stage, over=over):
                    self.assertEqual(disk_budget.decide(stage, FREE_FOR["BLACK"], 0, 0, over, True), ("BLACK", 76))
                    self.assertEqual(disk_budget.decide(stage, FREE_FOR["FLOOR"], 0, 0, over, True), ("FLOOR", 75))
                    # Without D2 the emergency rows return 10 (warn and proceed), never 0.
                    self.assertEqual(disk_budget.decide(stage, FREE_FOR["BLACK"], 0, 0, over, False), ("BLACK", 10))
                    self.assertEqual(disk_budget.decide(stage, FREE_FOR["FLOOR"], 0, 0, over, False), ("FLOOR", 10))

    def test_margin_moves_the_admission_zone(self):
        # 105 free, est 70, margin 10 -> zone(25) BLACK -> 76; margin 0 -> zone(35) RED.
        self.assertEqual(disk_budget.decide("observe", 105, 70, 10, False, True), ("BLACK", 76))
        self.assertEqual(disk_budget.decide("refuse_red", 105, 70, 0, False, True), ("RED", 75))
        self.assertEqual(disk_budget.decide("observe", 105, 70, 0, False, True), ("RED", 0))

    def test_est_gb_rejects_non_finite_and_negative(self):
        for text in ("nan", "inf", "-inf", "-1", "-0.01", "x"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                disk_budget.est_gb(text)

    def test_est_gb_accepts_finite_non_negative(self):
        for text, value in (("0", 0.0), ("1.5", 1.5), ("1e3", 1000.0)):
            with self.subTest(text=text):
                self.assertEqual(disk_budget.est_gb(text), value)

    def test_hard_floor_on_projected_free(self):
        # projected = 105 - 95 = 10 < 15 -> FLOOR whatever the margin; oversized est likewise.
        self.assertEqual(disk_budget.decide("observe", 105, 95, 0, False, True), ("FLOOR", 75))
        self.assertEqual(disk_budget.decide("observe", 105, 200, 10, False, True), ("FLOOR", 75))



class VolumeAdmissionGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.mount = Path(self.tmp.name) / "scratch"
        (self.mount / "project").mkdir(parents=True)

    def row(self, used, quota=30 * disk_budget.GIB, volume_id="vol-1", path=None):
        return {"used": used, "quota": quota, "uuid": volume_id,
                "path": Path(path) if path else self.mount}

    def invoke(self, samples, estimate_gb):
        with patch.object(disk_budget, "_scratch_mountpoint", return_value=self.mount), \
             patch.object(disk_budget, "_volume_status", side_effect=samples), \
             patch.dict(os.environ, {"DISK_MAGICIAN_DISKM_BIN": "/fake/disk-magician"}), \
             patch.object(disk_budget.subprocess, "run", return_value=type("R", (), {"returncode": 0})()) as run:
            reason = disk_budget.volume_admission_gate(self.mount / "project" / "artifact", estimate_gb)
        return reason, run

    def test_high_water_reclaims_once_then_accepts_with_one_gib_headroom(self):
        reason, run = self.invoke([
            self.row(28 * disk_budget.GIB),
            self.row(26 * disk_budget.GIB),
        ], 2)
        self.assertIsNone(reason)
        run.assert_called_once_with(
            ["/fake/disk-magician", "volume", "reclaim", "--clean"],
            capture_output=True, text=True, timeout=300, check=False)

    def test_high_water_that_remains_after_reclaim_is_denied(self):
        reason, run = self.invoke([
            self.row(28 * disk_budget.GIB),
            self.row(28 * disk_budget.GIB),
        ], 1)
        self.assertEqual(reason, "volume_full:scratch")
        run.assert_called_once()

    def test_low_water_exact_one_gib_post_estimate_headroom_is_allowed(self):
        reason, run = self.invoke([self.row(26 * disk_budget.GIB)], 3)
        self.assertIsNone(reason)
        run.assert_not_called()

    def test_low_water_less_than_one_gib_post_estimate_headroom_is_denied(self):
        reason, run = self.invoke([self.row(26 * disk_budget.GIB)], 3 + 1 / disk_budget.GIB)
        self.assertEqual(reason, "volume_headroom:scratch")
        run.assert_not_called()

    def test_reclaim_identity_change_fails_closed(self):
        reason, _ = self.invoke([
            self.row(28 * disk_budget.GIB),
            self.row(20 * disk_budget.GIB, volume_id="different-volume"),
        ], 1)
        self.assertEqual(reason, "volume_measurement_unavailable:scratch")



class WorktreeApprovalScopeTest(unittest.TestCase):
    """Synthetic WORKTREE_APPROVED must be scoped to the supervised child."""

    def _run_dispatch(self, tmp, supervise):
        state = Path(tmp)
        row = {"act": "worktree_cleanup", "class": "worktrees", "job": "cleanup_worktrees",
               "kind": "unit", "unit_budget_s": 20}
        metrics = {"outcome": "success_noop", "reason": "test", "df_delta_bytes": 0,
                   "removed_count": 0, "deferred_count": 0, "interrupted_count": 0}
        for started in (
            patch.object(disk_budget, "eligible_actuators", return_value=([row], [])),
            patch.object(disk_budget, "_c14_complete", return_value=True),
            patch.object(disk_budget, "_adapter_command", return_value=["/bin/true"]),
            patch.object(disk_budget, "_activation_ok", return_value=True),
            patch.object(disk_budget, "supervise_actuator", side_effect=supervise),
            patch.object(disk_budget, "_df_free_bytes", return_value=0),
            patch.object(disk_budget, "_receipt_data", return_value={}),
            patch.object(disk_budget, "_write_govern_receipt", return_value=metrics),
        ):
            started.start()
            self.addCleanup(started.stop)
        disk_budget.dispatch_actuators(Path("/tmp/dm-unit-unused-scripts"), state, {"classes": {}},
                                       {}, "ORANGE", time.time(), time.monotonic() + 200, {"classes": {}})

    def test_absent_approval_is_scoped_then_absent_again(self):
        seen = []
        os.environ.pop("WORKTREE_APPROVED", None)
        self.addCleanup(os.environ.pop, "WORKTREE_APPROVED", None)
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            self._run_dispatch(tmp, lambda command, slice_end: (
                seen.append(os.environ.get("WORKTREE_APPROVED")),
                {"rc": 0, "output": "", "hard_stop": False, "orphan_survivors": []})[1])
        self.assertEqual(seen, ["1"])
        self.assertNotIn("WORKTREE_APPROVED", os.environ)

    def test_original_value_is_restored_not_leaked(self):
        seen = []
        os.environ["WORKTREE_APPROVED"] = "operator-set"
        self.addCleanup(os.environ.pop, "WORKTREE_APPROVED", None)
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            self._run_dispatch(tmp, lambda command, slice_end: (
                seen.append(os.environ.get("WORKTREE_APPROVED")),
                {"rc": 0, "output": "", "hard_stop": False, "orphan_survivors": []})[1])
        self.assertEqual(seen, ["1"])
        self.assertEqual(os.environ.get("WORKTREE_APPROVED"), "operator-set")

    def test_raised_supervision_still_restores_absent_approval(self):
        def supervise(command, slice_end):
            raise RuntimeError("supervision failed")
        os.environ.pop("WORKTREE_APPROVED", None)
        self.addCleanup(os.environ.pop, "WORKTREE_APPROVED", None)
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            with self.assertRaises(RuntimeError):
                self._run_dispatch(tmp, supervise)
        self.assertNotIn("WORKTREE_APPROVED", os.environ)


if __name__ == "__main__":
    unittest.main()

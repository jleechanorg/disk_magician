#!/usr/bin/env python3
"""Estimate promotion starts a fresh pilot; old floor evidence is never relabelled.

All state, receipts and samples are temporary fixtures. D2 is mocked as in the
existing acceptance tests; no live probe or external action is performed.
"""
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from test_budget_acceptance import (
    IsolatedConfigTest, WEEK_START, WEEK_END, passing_pilot_state,
    write_receipts, write_samples,
)
import budget_acceptance as acceptance
import budget_controls as controls
import budget_history as history


def budget(state):
    return json.loads((state / "budget.json").read_text())


def write_budget(state, data):
    (state / "budget.json").write_text(json.dumps(data))


def floor_sample(state, at):
    with (state / "disk_observer.jsonl").open("a") as handle:
        handle.write(json.dumps({"epoch": at, "host_disk": {
            "used_kb": 880 * acceptance.GIB // 1024,
            "available_kb": int(14.9 * acceptance.GIB) // 1024}}) + "\n")


def new_week(state, start, failed=False):
    end = start + acceptance.WEEK
    write_samples(state, start, end)
    write_receipts(state, start, end)
    births = json.loads((state / "admission/births.json").read_text())
    births["gens"]["new_epoch"] = {"status": "admitted", "first_seen": start + 10}
    (state / "admission/births.json").write_text(json.dumps(births))
    for at in range(int(start), int(end), acceptance.TICK_INTERVAL_S):
        history.record_tick(state, now=at, classes_fresh={"worktrees": True},
                            fleet_status="healthy", zone="orange")
    for at in range(int(start), int(end), acceptance.DAY):
        history.record_measurement(state, now=at,
                                   classes={"worktrees": {"used_gb": 20.0}}, carried=[])
    if failed:
        floor_sample(state, start + 1000)
    return end


class PilotEstimatePromotionTest(IsolatedConfigTest):
    def setUp(self):
        super().setUp()
        approval = patch.object(controls, "_d2_approved", return_value=True)
        approval.start()
        self.addCleanup(approval.stop)
        temporary = tempfile.TemporaryDirectory(prefix="pilot-promotion-")
        self.addCleanup(temporary.cleanup)
        self.state = passing_pilot_state(temporary.name)

    def promote(self, at):
        (self.state / "admission/estimates.pending.json").write_text(
            json.dumps({"producers": {"advice": 9}}))
        self.assertEqual(controls.promote_estimates(self.state, now=at), 1)

    def check(self, at, record=True):
        return acceptance.pilot_check(self.state, at, record=record)

    def test_promotion_restarts_clock_without_refreshing_baselines_or_floor_history(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.assertEqual(self.check(WEEK_END)[1], 0)
        before = budget(self.state)
        at = WEEK_END + 60
        self.promote(at)
        after = budget(self.state)
        self.assertEqual(after["pilot_start"], at)
        self.assertEqual(after["pilot_epoch"], before["pilot_epoch"] + 1)
        self.assertNotEqual(after["estimates_hash"], before["estimates_hash"])
        for key in ("pilot_stage", "pilot_margin_gb", "pilot_config_hash", "pilot_hook_hash",
                    "pilot_package_hashes", "pilot_floor_fail_epochs", "pilot_floor_checked_epoch"):
            self.assertEqual(after[key], before[key], key)
        lines, rc = self.check(at + 1)
        self.assertEqual(rc, 1)
        self.assertTrue(lines[0].startswith("insufficient_data:pilot_week_incomplete"), lines)
        self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)
        self.assertNotIn("ALERT:v2_trigger", lines)

    def test_midweek_promotion_requires_seven_days_from_the_new_start(self):
        at = WEEK_START + 2 * acceptance.DAY
        self.promote(at)
        lines, rc = self.check(WEEK_END)
        self.assertEqual(rc, 1)
        self.assertTrue(lines[0].startswith("insufficient_data:pilot_week_incomplete"), lines)
        lines, rc = self.check(at + acceptance.WEEK)
        self.assertEqual((rc, lines[0]), (1, "pilot_invalid:qualifying_days=5/7"))

    def test_legacy_promoted_after_start_is_invalid_and_does_not_recount(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        self.promote(WEEK_END + 60)
        data = budget(self.state)
        data["pilot_start"] = WEEK_START  # previously persisted promotion format
        write_budget(self.state, data)
        for record in (False, True, True):
            lines, rc = self.check(WEEK_END + 61, record=record)
            self.assertEqual((rc, lines[0]), (1, "pilot_invalid:estimates_changed"))
            self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)

    def test_malformed_promotion_timestamp_fails_closed(self):
        original = budget(self.state)
        for value in (None, True, "invalid", -1, float("nan"), float("inf")):
            with self.subTest(value=value):
                write_budget(self.state, dict(original, estimates_promoted_at=value))
                lines, rc = self.check(WEEK_END)
                self.assertEqual((rc, lines[0]), (1, "insufficient_data:estimates_promotion"))
                self.assertNotIn("pilot_floor_checked_epoch", budget(self.state))

    def test_repeated_promotion_cannot_make_old_samples_a_new_week(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        for at in (WEEK_END + 60, WEEK_END + 120):
            self.promote(at)
            self.assertEqual(budget(self.state)["pilot_start"], at)
            self.assertEqual(self.check(at + 1)[1], 1)
            self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)

    def test_new_valid_failed_week_counts_once_and_passing_week_resets_streak(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        start = WEEK_END + 60
        self.promote(start)
        end = new_week(self.state, start, failed=True)
        for at in (end, end + 1):
            lines, rc = self.check(at)
            self.assertEqual((rc, lines[0]), (0, "pilot_valid"))
            self.assertIn("ALERT:v2_trigger", lines)
            self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 2)
        start = end + 60
        self.promote(start)
        end = new_week(self.state, start)
        lines, rc = self.check(end)
        self.assertEqual((rc, lines[0]), (0, "pilot_valid"))
        self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 0)

    def test_changed_deployment_config_or_hook_proof_is_not_refreshed(self):
        pristine = self.state.parent / (self.state.name + "-pristine")
        shutil.copytree(self.state, pristine)
        self.addCleanup(shutil.rmtree, pristine)
        config = Path(os.environ["DISK_MAGICIAN_CONFIG"])
        config_bytes = config.read_bytes()
        hook = Path.home() / ".claude/hooks/disk-admission.sh"
        hook_bytes = hook.read_bytes()
        for kind in ("deploy", "config", "hook"):
            with self.subTest(kind=kind):
                shutil.rmtree(self.state)
                shutil.copytree(pristine, self.state)
                config.write_bytes(config_bytes)
                hook.write_bytes(hook_bytes)
                before = budget(self.state)
                if kind == "deploy":
                    path = self.state / "deployed.json"
                    data = json.loads(path.read_text())
                    data["package_hashes"]["scripts/budget_acceptance.py"] = "changed"
                    path.write_text(json.dumps(data))
                elif kind == "config":
                    data = json.loads(config.read_text())
                    data["budgets"]["concurrency_margin_gb"] = 20
                    config.write_text(json.dumps(data))
                else:
                    hook.write_text("# changed fixture hook\n")
                start = WEEK_END + 60
                self.promote(start)
                for key in ("pilot_package_hashes", "pilot_config_hash", "pilot_hook_hash"):
                    self.assertEqual(budget(self.state)[key], before[key])
                end = new_week(self.state, start)
                lines, rc = self.check(end)
                reason = {"deploy": "deploy_changed", "config": "budget_changed", "hook": "hook_changed"}[kind]
                self.assertEqual((rc, lines[0]), (1, "pilot_invalid:" + reason))
        config.write_bytes(config_bytes)
        hook.write_bytes(hook_bytes)

    def test_same_window_under_a_changed_epoch_does_not_count_again(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        data = budget(self.state)
        data["pilot_epoch"] += 1
        write_budget(self.state, data)
        lines, rc = self.check(WEEK_END + 1)
        self.assertEqual((rc, lines[0]), (0, "pilot_valid"))
        self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)
        self.assertNotIn("ALERT:v2_trigger", lines)

    def test_legacy_counted_window_is_not_recounted_after_epoch_change(self):
        floor_sample(self.state, WEEK_START + 1000)
        data = budget(self.state)
        data.update(pilot_epoch=2, pilot_floor_fail_epochs=1,
                    pilot_floor_checked_epoch=f"{WEEK_START}:1", pilot_floor_checked_at=WEEK_END)
        write_budget(self.state, data)
        lines, rc = self.check(WEEK_END + 1)
        self.assertEqual((rc, lines[0]), (0, "pilot_valid"))
        self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)

    def test_promotion_during_check_cannot_record_a_stale_result(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        original = acceptance._bw_estimates
        def promote_before_record(*args):
            self.promote(WEEK_END + 60)
            return original(*args)
        with patch.object(acceptance, "_bw_estimates", side_effect=promote_before_record):
            lines, rc = self.check(WEEK_END + 61)
        self.assertEqual((rc, lines[0]), (1, "pilot_invalid:pilot_changed"))
        data = budget(self.state)
        self.assertEqual(data["pilot_start"], WEEK_END + 60)
        self.assertEqual(data["pilot_floor_fail_epochs"], 1)
        self.assertEqual(data["pilot_floor_checked_epoch"], f"{WEEK_START}:1")

    def test_promotion_before_first_floor_record_does_not_record_old_evidence(self):
        original = acceptance._bw_estimates
        def promote_before_record(*args):
            self.promote(WEEK_END + 60)
            return original(*args)
        with patch.object(acceptance, "_bw_estimates", side_effect=promote_before_record):
            lines, rc = self.check(WEEK_END + 61)
        self.assertEqual((rc, lines[0]), (1, "pilot_invalid:pilot_changed"))
        self.assertNotIn("pilot_floor_checked_epoch", budget(self.state))
        self.assertNotIn("pilot_floor_fail_epochs", budget(self.state))

    def test_overlapping_relabelled_window_cannot_advance_floor_streak(self):
        floor_sample(self.state, WEEK_START + 1000)
        self.check(WEEK_END)
        data = budget(self.state)
        data.update(pilot_start=WEEK_START + acceptance.DAY, pilot_epoch=2)
        write_budget(self.state, data)
        end = new_week(self.state, data["pilot_start"], failed=True)
        lines, rc = self.check(end)
        self.assertEqual((rc, lines[0]), (1, "pilot_invalid:pilot_changed"))
        self.assertEqual(budget(self.state)["pilot_floor_fail_epochs"], 1)


class PromotionStateValidationTest(unittest.TestCase):
    def fixture(self, root, initial):
        state = Path(root)
        (state / "admission").mkdir()
        write_budget(state, initial)
        (state / "admission/estimates.json").write_text('{"advice": 2}')
        (state / "admission/estimates.pending.json").write_text('{"advice": 9}')
        return state

    def test_without_an_active_pilot_promotion_does_not_invent_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = self.fixture(tmp, {"zone": "GREEN"})
            self.assertEqual(controls.promote_estimates(state, now=100), 1)
            self.assertNotIn("pilot_start", budget(state))
            self.assertNotIn("pilot_epoch", budget(state))
            self.assertEqual(budget(state)["zone"], "GREEN")

    def test_invalid_or_backwards_clock_cannot_relabel_existing_state(self):
        for start, now in ((True, 100), (-1, 100), (float("nan"), 100),
                           (200, 100), (1, float("inf")), (1, False)):
            with self.subTest(start=start, now=now), tempfile.TemporaryDirectory() as tmp:
                state = self.fixture(tmp, {"pilot_start": start, "pilot_epoch": 1})
                before = {name: (state / name).read_bytes() for name in
                          ("budget.json", "admission/estimates.json")}
                with self.assertRaises(controls.MalformedState):
                    controls.promote_estimates(state, now=now)
                self.assertEqual(before, {name: (state / name).read_bytes() for name in before})


if __name__ == "__main__":
    unittest.main(verbosity=2)

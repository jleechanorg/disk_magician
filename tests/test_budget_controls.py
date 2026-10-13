#!/usr/bin/env python3
"""tests/test_budget_controls.py — Task 3 transactional controls, estimate validation (plan Task 3)."""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import budget_controls as bc  # noqa: E402

GIB = 1 << 30
CONFIG = {"enforcement": "warn", "concurrency_margin_gb": 10}


def state_with(tmp, budget=None, estimates=None, pending=None):
    state = Path(tmp)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    if budget is not None:
        (state / "budget.json").write_text(json.dumps(budget))
    if estimates is not None:
        (state / "admission" / "estimates.json").write_text(json.dumps(estimates))
    if pending is not None:
        (state / "admission" / "estimates.pending.json").write_text(json.dumps(pending))
    return state


class StageMarginTest(unittest.TestCase):
    def test_set_stage_records_previous_and_actual_effective_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"zone": "RED"})
            with patch.object(bc, "_check_stage_promotion"):
                prior = bc.set_stage(state, "refuse_red", CONFIG, now=100.0)
            self.assertEqual(prior, "warn")  # from config, not the budget
            data = json.loads((state / "budget.json").read_text())
            self.assertEqual(data["stage"], "refuse_red")
            self.assertEqual(data["stage_previous"], "warn")
            self.assertEqual(data["stage_changed_at"], 100.0)
            self.assertEqual(data["zone"], "RED")  # concurrent govern field preserved

    def test_bad_stage_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"zone": "RED"})
            self.assertIsNone(bc.set_stage(state, "bogus", CONFIG))
            self.assertEqual(json.loads((state / "budget.json").read_text()), {"zone": "RED"})

    def test_set_margin_records_prior_bumps_epoch_and_drives_admit(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"pilot_start": 1.0, "pilot_epoch": 1, "zone": "GREEN"})
            prior = bc.set_margin(state, 20, CONFIG, now=200.0)
            self.assertEqual(prior, 10.0)
            data = json.loads((state / "budget.json").read_text())
            self.assertEqual(data["margin_gb"], 20.0)
            self.assertEqual(data["margin_previous"], 10.0)
            self.assertEqual(data["pilot_epoch"], 2)
            self.assertEqual(bc.effective_margin(data, CONFIG), 20.0)
            self.assertEqual(data["zone"], "GREEN")

    def test_margin_without_pilot_does_not_invent_an_epoch(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"zone": "GREEN"})
            bc.set_margin(state, 12, CONFIG)
            self.assertNotIn("pilot_epoch", json.loads((state / "budget.json").read_text()))

    def test_negative_margin_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={})
            self.assertIsNone(bc.set_margin(state, -1, CONFIG))
            self.assertIsNone(bc.set_margin(state, float("nan"), CONFIG))


class PromoteEstimatesTest(unittest.TestCase):
    def test_valid_pending_promotes_hash_and_epoch(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"pilot_start": 1.0, "pilot_epoch": 3, "zone": "RED"},
                               estimates={"old": 1}, pending={"producers": {"hook:git-clone:x": 3.75}})
            self.assertEqual(bc.promote_estimates(state), 1)
            effective = json.loads((state / "admission" / "estimates.json").read_text())
            self.assertEqual(effective, {"hook:git-clone:x": 3.75})
            data = json.loads((state / "budget.json").read_text())
            self.assertEqual(data["estimates_hash"], hashlib.sha256(
                (state / "admission" / "estimates.json").read_bytes()).hexdigest())
            self.assertEqual(data["pilot_epoch"], 4)
            self.assertEqual(data["zone"], "RED")

    def test_missing_pending_is_rc2_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"estimates_hash": "keep"}, estimates={"old": 1})
            self.assertIsNone(bc.promote_estimates(state))
            self.assertEqual(json.loads((state / "admission" / "estimates.json").read_text()), {"old": 1})
            self.assertEqual(json.loads((state / "budget.json").read_text()), {"estimates_hash": "keep"})

    def test_malformed_pending_never_becomes_zeros(self):
        for bad in ({"p": True}, {"p": -1}, {"": 1}, {"p": float("inf")}, [1, 2], {"p": "x"}):
            with tempfile.TemporaryDirectory() as tmp:
                state = state_with(tmp, budget={}, pending=bad)
                self.assertIsNone(bc.validate_estimates(bad), bad)
                self.assertIsNone(bc.promote_estimates(state), bad)
                self.assertFalse((state / "admission" / "estimates.json").exists())


class EstimateResolutionTest(unittest.TestCase):
    def test_exact_prefix_and_default_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, estimates={"hook:git-clone": 4.0, "advice": 6.0})
            self.assertEqual(bc.effective_estimate(state, "hook:git-clone:example.com/a"), 4.0)
            self.assertEqual(bc.effective_estimate(state, "advice"), 6.0)
            self.assertEqual(bc.effective_estimate(state, "worktree-new"), 1.0)  # documented default
            self.assertIsNone(bc.effective_estimate(state, "unknown-producer"))

    def test_no_estimates_file_uses_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp)
            self.assertEqual(bc.effective_estimate(state, "ci"), 20.0)


class StageGatesTest(unittest.TestCase):
    def test_promotion_requires_pilot_and_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"stage": "observe"})
            with patch.object(bc, "_d2_approved", return_value=False):
                with self.assertRaises(bc.PrerequisitesMissing):
                    bc.set_stage(state, "warn", now=100)
            self.assertEqual(json.loads((state / "budget.json").read_text()), {"stage": "observe"})

    def test_rollback_preserves_emergency_decision(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"stage": "refuse_red", "emergency": "keep"})
            self.assertEqual(bc.set_stage(state, "observe"), "refuse_red")
            self.assertEqual(json.loads((state / "budget.json").read_text())["emergency"], "keep")

    def test_valid_floor_epoch_is_counted_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={})
            self.assertEqual(bc.record_floor_epoch(state, True, "first"), 1)
            self.assertEqual(bc.record_floor_epoch(state, True, "first"), 1)
            self.assertEqual(bc.record_floor_epoch(state, True, "second"), 2)
            self.assertEqual(bc.record_floor_epoch(state, False, "third"), 0)


class CliTest(unittest.TestCase):
    def run_cli(self, state, *args):
        return subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"), *args],
                              env={**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}, capture_output=True, text=True)

    def test_cli_controls_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"pilot_start": 1.0, "stage": "refuse_red"})
            self.assertEqual(self.run_cli(state, "set-stage", "observe").returncode, 0)
            self.assertEqual(self.run_cli(state, "set-margin", "20").returncode, 0)
            (state / "admission" / "estimates.pending.json").write_text(json.dumps({"advice": 5}))
            self.assertEqual(self.run_cli(state, "promote-estimates").returncode, 0)
            data = json.loads((state / "budget.json").read_text())
            self.assertEqual(data["stage"], "observe")
            self.assertEqual(data["margin_gb"], 20.0)
            self.assertEqual(data["pilot_epoch"], 3)

    def test_cli_rejects_bad_inputs_and_missing_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp)
            self.assertEqual(self.run_cli(state, "set-stage", "bogus").returncode, 2)
            self.assertEqual(self.run_cli(state, "set-margin", "nope").returncode, 2)
            self.assertEqual(self.run_cli(state, "promote-estimates").returncode, 2)


if __name__ == "__main__":
    unittest.main()

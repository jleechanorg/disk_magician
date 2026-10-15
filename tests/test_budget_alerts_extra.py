#!/usr/bin/env python3
"""tests/test_budget_alerts_extra.py — Task 10 missing alert classes (plan Task 10 Step 1)."""
import json
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import budget_status as bs  # noqa: E402

GIB = 1 << 30
NOW = 1_800_000_000.0


def state_with(tmp, events=(), budget=None, sched=None, receipts=None, parked=None):
    state = Path(tmp)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    (state / "admission" / "events.jsonl").write_text(
        "\n".join(json.dumps(e) for e in events) + ("\n" if events else ""))
    if budget is not None:
        (state / "budget.json").write_text(json.dumps(budget))
    if sched is not None:
        (state / "govern_sched.json").write_text(json.dumps(sched))
    if receipts is not None:
        (state / "receipts").mkdir(parents=True, exist_ok=True)
        for name, data in receipts.items():
            (state / "receipts" / name).write_text(json.dumps(data))
    if parked is not None:
        (state / "parked.jsonl").write_text("\n".join(json.dumps(p) for p in parked))
    return state


def codes(lines):
    return [line.split()[0][len("ALERT:"):] for line in lines if line.startswith("ALERT:")]


def alerts(state):
    return bs.alerts(state, NOW, 10)


class IsolatedConfigTest(unittest.TestCase):
    """Isolate HOME and DISK_MAGICIAN_CONFIG from the live machine."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(tmp.cleanup)
        cfg = Path(tmp.name) / "config.json"
        cfg.write_text(json.dumps({"budgets": {"concurrency_margin_gb": 10, "classes": {}}}))
        env = patch.dict(os.environ, {"DISK_MAGICIAN_CONFIG": str(cfg), "HOME": tmp.name})
        env.start()
        self.addCleanup(env.stop)


class ExtraAlertsTest(IsolatedConfigTest):
    def test_event_backed_alerts(self):
        for token in ("activation_blocked:c14_missing", "quarantine_conflict:abc",
                      "quarantine_partial_kept:x", "exclusive_rename_unavailable",
                      "reuse_incomplete", "hard_stop", "archive_overcap_kept"):
            with tempfile.TemporaryDirectory() as tmp:
                state = state_with(tmp, events=[{"event": token, "at": NOW - 600}])
                self.assertIn(token.split(":")[0], codes(alerts(state)), token)

    def test_stale_class_uses_measured_age_threshold(self):
        with tempfile.TemporaryDirectory() as stale_tmp, tempfile.TemporaryDirectory() as fresh_tmp:
            stale = state_with(stale_tmp, budget={"classes": {"worktrees": {"measured_at": NOW - 10801, "used_gb": 1}}})
            fresh = state_with(fresh_tmp, budget={"classes": {"worktrees": {"measured_at": NOW - 10799, "used_gb": 1}}})
            self.assertIn("class_stale", codes(alerts(stale)))
            self.assertNotIn("class_stale", codes(alerts(fresh)))

    def test_bypass_high_prints_ci_admission_beside_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"births": {"ratio": 0.12, "ci_admission": {"jobs": 7}}})
            lines = alerts(state)
            self.assertIn("bypass_high", codes(lines))
            self.assertTrue(any("ci_admission jobs=7" in l for l in lines), lines)

    def test_scheduler_starvation_alerts(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, sched={"classes": {"tmp_containers": {"no_progress_ticks": 3, "deferred_ticks": 3}}})
            found = codes(alerts(state))
            self.assertIn("reclaim_starved", found)
            self.assertIn("actuator_starved", found)

    def test_actuator_dead_requires_three_zero_progress_receipts(self):
        dead = [{"postcondition": {"df_delta_bytes": 0}, "candidates": {"removed_count": 0}} for _ in range(3)]
        alive = dead[:2] + [{"postcondition": {"df_delta_bytes": 0}, "candidates": {"removed_count": 1}}]
        with tempfile.TemporaryDirectory() as tmp, patch("budget_acceptance._config_budget", return_value={"classes": {"x": {"budget_gb": 1}}}):
            budget = {"classes": {"x": {"used_gb": 2}}}
            self.assertIn("actuator_dead", codes(alerts(state_with(tmp, budget=budget, receipts={"govern_x.json": {"completed": dead}}))))
            self.assertNotIn("actuator_dead", codes(alerts(state_with(tmp, budget=budget, receipts={"govern_x.json": {"completed": alive}}))))
            budget["classes"]["x"]["used_gb"] = .5
            self.assertNotIn("actuator_dead", codes(alerts(state_with(tmp, budget=budget, receipts={"govern_x.json": {"completed": dead}}))))

    def test_main_sweeper_two_consecutive_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = {"completed": [{"outcome": "error"}, {"outcome": "error"}]}
            good = {"completed": [{"outcome": "error"}, {"outcome": "success"}]}
            self.assertIn("main_sweeper_error", codes(alerts(state_with(tmp, receipts={"main_sweeper.json": bad}))))
            self.assertNotIn("main_sweeper_error", codes(alerts(state_with(tmp, receipts={"main_sweeper.json": good}))))

    def test_parked_large_over_twenty_gib(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIn("parked_large", codes(alerts(state_with(tmp, budget={"parked_measurement": {"status": "ok", "measured_at": NOW, "bytes": 21 * GIB}}))))
            self.assertNotIn("parked_large", codes(alerts(state_with(tmp, budget={"parked_measurement": {"status": "ok", "measured_at": NOW, "bytes": 19 * GIB}}))))

    def test_colima_stopped_since_over_one_hour(self):
        with tempfile.TemporaryDirectory() as stopped_tmp, tempfile.TemporaryDirectory() as running_tmp:
            stopped = state_with(stopped_tmp, budget={"colima_stopped_since": NOW - 3601, "colima_status": "stopped", "colima_observed_at": NOW})
            running = state_with(running_tmp, budget={"colima_stopped_since": NOW - 3599, "colima_status": "stopped", "colima_observed_at": NOW})
            self.assertIn("colima_stopped", codes(alerts(stopped)))
            self.assertNotIn("colima_stopped", codes(alerts(running)))

    def test_free_text_does_not_manufacture_alerts(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, events=[{"event": "review", "reason": "not hard_stop or activation_blocked", "at": NOW}])
            self.assertNotIn("hard_stop", codes(alerts(state)))
            self.assertNotIn("activation_blocked", codes(alerts(state)))
            state_with(tmp, receipts={"main_sweeper.json": {"completed": [None, None]}})
            self.assertNotIn("main_sweeper_error", codes(alerts(state)))

    def test_quiet_state_stays_quiet(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = state_with(tmp, budget={"zone": "GREEN", "zone_at": NOW})
            self.assertEqual(codes(alerts(state)), [])


class ProducerAlertsTest(IsolatedConfigTest):
    def test_colima_observations_reach_alert_and_recovery_clears_it(self):
        import budget_history as bh
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            for at in range(int(NOW - 4200), int(NOW) + 1, 600):
                with patch.object(bh, "_run_bounded", return_value=(0,
                        '{"name":"default","status":"Stopped"}\n')):
                    status = bh.collect_colima_status()
                bh.record_tick(state, now=at, colima_status=status)
            self.assertIn("colima_stopped", codes(alerts(state)))
            bh.record_tick(state, now=NOW, colima_status="running")
            self.assertNotIn("colima_stopped", codes(alerts(state)))

    def test_parked_measurement_reaches_alert(self):
        import budget_history as bh
        import budget_controls as bc
        import datetime
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            leases = state / "worktree_leases"
            leases.mkdir()
            target = state / "parked-worktree"
            target.mkdir()
            stamp = datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc).isoformat()
            (leases / "lease.json").write_text(json.dumps(dict(path=str(target),
                last_verdict="kept:expired_owner_alive", last_checked_at=stamp)))
            terminal = dict(outcome="success", times=dict(ended_at=stamp))
            with patch("job_receipt.get_last_receipt", return_value=terminal), \
                    patch.object(bh, "_run_bounded", return_value=(0, f"{21 * GIB // 1024}\t{target}\n")):
                measurement = bh.measure_parked(state, now=NOW)
            bc.locked_mutate(state, lambda data: data.update(parked_measurement=measurement))
            self.assertIn("parked_large", codes(alerts(state)))


if __name__ == "__main__":
    unittest.main()

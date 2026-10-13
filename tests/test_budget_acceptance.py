#!/usr/bin/env python3
"""tests/test_budget_acceptance.py — Task 10 weekly-check and pilot-check (spec §7.4–§7.6, §9)."""
import datetime
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
import budget_acceptance as ba  # noqa: E402
import budget_history as bh  # noqa: E402

GIB = 1 << 30
WEEK_START = time.mktime(time.strptime("2026-10-05", "%Y-%m-%d"))  # Monday 00:00 local
WEEK_END = WEEK_START + ba.WEEK


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_samples(state, start, end, free_gib=40, used_gib=780, step=60, override=None):
    lines = []
    t = start
    while t < end:
        free, used = float(free_gib), float(used_gib)
        if override and override[0] == t:
            free, used = override[1], override[2]
        lines.append(json.dumps({"epoch": t, "host_disk": {"used_kb": int(used * GIB) // 1024,
                                                            "available_kb": int(free * GIB) // 1024}}))
        t += step
    with open(state / "disk_observer.jsonl", "a") as handle:
        handle.write("\n".join(lines) + "\n")


def receipt(epoch, df_delta=GIB, removed=1):
    return {"times": {"started_at": iso(epoch - 5), "ended_at": iso(epoch)},
            "outcome": "success", "reason": None,
            "candidates": {"removed_count": removed, "deferred_count": 0, "interrupted_count": 0},
            "postcondition": {"df_delta_bytes": df_delta, "freed_bytes": max(0, df_delta)}}


def write_receipts(state, start, end, step=600, **kw):
    entries = []
    t = start + step
    while t < end:
        entries.append(receipt(t, **kw))
        t += step
    receipts = state / "receipts"
    receipts.mkdir(parents=True, exist_ok=True)
    (receipts / "govern_worktrees.json").write_text(json.dumps({"completed": entries}))


def base_budget(state, estimates_hash=None, tick_samples=None):
    budget = {"pilot_start": WEEK_START, "pilot_epoch": 1, "stage": "observe", "margin_gb": 10,
              "fleet_unhealthy_seconds": 0, "classes": {"worktrees": {"used_gb": 20, "measured_at": WEEK_END}},
              "pilot_stage": "observe", "pilot_margin_gb": 10, "pilot_config_hash": ba.config_hash(),
              "pilot_hook_hash": ba.hook_hash(),
              "pilot_package_hashes": {name: "h" for name in ba.PILOT_HASH_FILES}}
    if tick_samples is not None:
        budget["tick_samples"] = tick_samples
    if estimates_hash is not None:
        budget["estimates_hash"] = estimates_hash
    (state / "budget.json").write_text(json.dumps(budget))
    return budget


def write_deployed(state, changed=None):
    hashes = {name: "h" for name in ba.PILOT_HASH_FILES}
    if changed:
        hashes[changed] = "CHANGED"
    (state / "deployed.json").write_text(json.dumps(
        {"schema_version": 1, "source_sha": "a" * 40, "installed_version": "1", "deployed_at": iso(WEEK_START - 100),
         "package_hashes": hashes}))


def ticks(state, fresh=True, at=None):
    stop = at if at is not None else int(WEEK_END)
    return [{"at": t, "classes_fresh": fresh} for t in range(int(WEEK_START), stop, 600)]


def passing_pilot_state(tmp):
    state = Path(tmp)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    (state / "admission" / "estimates.json").write_text(json.dumps({"advice": 2}))
    est_hash = hashlib.sha256((state / "admission" / "estimates.json").read_bytes()).hexdigest()
    (state / "policy.json").write_text(json.dumps({"admission_enforcement": {"revoked_at": None}}))
    base_budget(state, est_hash)
    write_deployed(state)
    write_samples(state, WEEK_START - 14 * 86400, WEEK_END)  # three weeks: current + prior two
    write_receipts(state, WEEK_START, WEEK_END)
    (state / "admission" / "births.json").write_text(json.dumps({
        "gens": {"a0": {"status": "admitted", "first_seen": WEEK_START - ba.WEEK + 10},
                 "a1": {"status": "admitted", "first_seen": WEEK_START + 10}}}))
    for t in range(int(WEEK_START - ba.WEEK), int(WEEK_END), ba.TICK_INTERVAL_S):
        bh.record_tick(state, now=t, classes_fresh={"worktrees": True}, fleet_status="healthy", zone="orange")
    for t in range(int(WEEK_START), int(WEEK_END), ba.DAY):
        bh.record_measurement(state, now=t, classes={"worktrees": {"used_gb": 20.0}}, carried=[])
    return state


class IsolatedConfigTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cfg = Path(tmp.name) / "config.json"
        cfg.write_text(json.dumps({"budgets": {"classes": {"worktrees": {"measure": "du"}}}}))
        hook = Path(tmp.name) / ".claude/hooks/disk-admission.sh"
        hook.parent.mkdir(parents=True)
        hook.write_text("# fixture installed hook\n")
        env = patch.dict(os.environ, {"DISK_MAGICIAN_CONFIG": str(cfg), "HOME": tmp.name})
        env.start()
        self.addCleanup(env.stop)


class WeeklyCheckTest(IsolatedConfigTest):
    def test_insufficient_coverage_at_90_percent(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "admission").mkdir(parents=True, exist_ok=True)
            write_samples(state, WEEK_START, WEEK_START + int(0.90 * 86400), step=60)
            write_samples(state, WEEK_START - 7 * 86400, WEEK_START)
            write_receipts(state, WEEK_START, WEEK_END)
            lines, rc = ba.weekly_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(any("insufficient_data" in l for l in lines), lines)

    def test_full_passing_week_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            lines, rc = ba.weekly_check(state, WEEK_END)
            self.assertEqual(rc, 0, lines)
            self.assertIn("result=pass", lines)
            self.assertTrue(any("min_free=pass" in l for l in lines))
            self.assertTrue(any("bypass_ratio=pass" in l for l in lines))

    def test_floor_sample_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            with open(state / "disk_observer.jsonl", "a") as handle:
                handle.write(json.dumps({"epoch": WEEK_START + 1000,
                                         "host_disk": {"used_kb": int(880 * GIB) // 1024,
                                                       "available_kb": int(14.9 * GIB) // 1024}}) + "\n")
            lines, rc = ba.weekly_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(any(l.startswith("floor_samples=fail") for l in lines), lines)

    def test_bypass_ratio_over_slo_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            (state / "admission" / "births.json").write_text(json.dumps({
                "gens": {f"k{i}": {"status": "bypass", "first_seen": WEEK_START + i} for i in range(2)} |
                        {f"a{i}": {"status": "admitted", "first_seen": WEEK_START + i} for i in range(18)}}))
            lines, rc = ba.weekly_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(any(l.startswith("bypass_ratio=fail") for l in lines), lines)


class PilotCheckTest(IsolatedConfigTest):
    def setUp(self):
        super().setUp()
        self.approval = patch("budget_controls._d2_approved", return_value=True)
        self.approval.start()
        self.addCleanup(self.approval.stop)

    def test_passing_week_reports_all_required_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 0, lines)
            self.assertEqual(lines[0], "pilot_valid")
            joined = "\n".join(lines)
            for field in ("B_est=", "W_est=", "r_peak=", "admit_burst_bytes=", "floor_margin_ok=", "pilot_floor_ok="):
                self.assertIn(field, joined, field)
            self.assertIn("label=estimate", joined)

    def test_fewer_than_six_qualifying_days_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            (state / "admission" / "events.jsonl").write_text("")
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(lines[0].startswith("pilot_invalid:qualifying_days"), lines)

    def test_missing_du_freshness_evidence_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            (state / "admission" / "events.jsonl").write_text("")
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(lines[0].startswith("pilot_invalid:qualifying_days"), lines)

    def test_deploy_hash_change_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            write_deployed(state, changed=ba.PILOT_HASH_FILES[0])
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual((rc, lines[0]), (1, "pilot_invalid:deploy_changed"))

    def test_stage_change_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            budget["stage_changed_at"] = WEEK_START + 10
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual((rc, lines[0]), (1, "pilot_invalid:stage_changed"))

    def test_margin_change_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            budget["margin_changed_at"] = WEEK_START + 10
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual((rc, lines[0]), (1, "pilot_invalid:margin_changed"))

    def test_estimates_change_after_pilot_start_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            (state / "admission" / "estimates.json").write_text(json.dumps({"advice": 9}))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual((rc, lines[0]), (1, "pilot_invalid:estimates_changed"))

    def test_fleet_unhealthy_over_two_hours_invalidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            
            for t in range(int(WEEK_START), int(WEEK_START + 3 * 3600), 600):
                bh.record_tick(state, now=t + 1, classes_fresh={"worktrees": True}, fleet_status="degraded")
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 1)
            self.assertTrue(lines[0].startswith("pilot_invalid:fleet_unhealthy"), lines)

    def test_missing_fleet_health_is_insufficient_not_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            budget = json.loads((state / "budget.json").read_text())
            
            for t in range(int(WEEK_START), int(WEEK_END), 600):
                bh.record_tick(state, now=t + 1, classes_fresh={"worktrees": True}, fleet_status="unknown")
            (state / "budget.json").write_text(json.dumps(budget))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual((rc, lines[0]), (1, "insufficient_data:fleet_health"))

    def test_one_floor_sample_flips_only_pilot_floor_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            with open(state / "disk_observer.jsonl", "a") as handle:
                handle.write(json.dumps({"epoch": WEEK_START + 1000,
                                         "host_disk": {"used_kb": int(880 * GIB) // 1024,
                                                       "available_kb": int(14.9 * GIB) // 1024}}) + "\n")
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 0)  # validity and the observed floor gate are separate
            self.assertTrue(any(l.startswith("pilot_floor_ok=false") for l in lines), lines)

    def test_exposure_hand_computed_and_margin_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "admission").mkdir(parents=True, exist_ok=True)
            (state / "admission" / "estimates.json").write_text("{}")
            est_hash = hashlib.sha256((state / "admission" / "estimates.json").read_bytes()).hexdigest()
            base_budget(state, est_hash, ticks(state))
            write_deployed(state)
            (state / "admission" / "births.json").write_text(json.dumps({
                "gens": {"a1": {"status": "admitted", "first_seen": WEEK_START + 10}}}))
            # one 12 GiB rise over 600 s, then flat
            t = WEEK_START
            rows = []
            while t < WEEK_END:
                used = 780 + (12 * (t - WEEK_START) / 600 if t < WEEK_START + 600 else 12)
                rows.append(json.dumps({"epoch": t, "host_disk": {"used_kb": int(used * GIB) // 1024,
                                                                   "available_kb": int(40 * GIB) // 1024}}))
                t += 60
            (state / "disk_observer.jsonl").write_text("\n".join(rows) + "\n")
            # 4 x 5 GiB admits inside a 600 s window
            events = [{"event": "admit", "at": WEEK_START + 100 * i, "est_bytes": 5 * GIB, "decision": 0} for i in range(4)]
            (state / "admission" / "events.jsonl").write_text("\n".join(json.dumps(e) for e in events) + "\n")
            for t in range(int(WEEK_START), int(WEEK_END), 600):
                bh.record_tick(state, now=t, classes_fresh={"worktrees": True}, fleet_status="healthy", zone="orange")
            receipts = state / "receipts"; receipts.mkdir(parents=True, exist_ok=True)
            # zone tick started at t0; first positive reclaim 240 s later; other ticks no-op
            entries = [{"times": {"started_at": iso(WEEK_START), "ended_at": iso(WEEK_START + 240)},
                        "postcondition": {"df_delta_bytes": GIB}, "candidates": {"removed_count": 1}}]
            t = WEEK_START + 600
            while t < WEEK_END:
                entries.append({"times": {"started_at": iso(t - 5), "ended_at": iso(t)},
                                "postcondition": {"df_delta_bytes": 0}, "candidates": {"removed_count": 0}})
                t += 600
            (receipts / "govern_worktrees.json").write_text(json.dumps({"completed": entries}))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertEqual(rc, 0, lines)
            joined = "\n".join(lines)
            self.assertIn("admit_burst_bytes=21474836480B", joined)  # 20 GiB
            self.assertIn("floor_margin_ok=false", joined)
            self.assertIn("exposure=", joined)
            # no positive reclaim receipt -> margin_unknown
            noop = [{"times": {"started_at": iso(t - 5), "ended_at": iso(t)},
                     "postcondition": {"df_delta_bytes": 0}, "candidates": {"removed_count": 0}}
                    for t in range(int(WEEK_START) + 600, int(WEEK_END), 600)]
            (receipts / "govern_worktrees.json").write_text(json.dumps({"completed": noop}))
            lines, rc = ba.pilot_check(state, WEEK_END)
            self.assertIn("floor_margin_ok=false margin_unknown", "\n".join(lines))


class CliTest(IsolatedConfigTest):
    def run_cli(self, state, *args):
        return subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"), *args],
                              env={**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state),
                                   "DISK_MAGICIAN_POLICY_FILE": str(state / "policy.json")}, capture_output=True, text=True)

    def test_weekly_and_pilot_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            weekly = self.run_cli(state, "status", "--weekly-check", "--at", str(WEEK_END))
            self.assertEqual(weekly.returncode, 0, weekly.stdout + weekly.stderr)
            self.assertIn("result=pass", weekly.stdout)
            pilot = self.run_cli(state, "status", "--pilot-check", "--at", str(WEEK_END))
            self.assertEqual(pilot.returncode, 0, pilot.stdout + pilot.stderr)
            self.assertTrue(pilot.stdout.startswith("pilot_valid"))

    def test_bad_flag_is_rc2(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.run_cli(Path(tmp), "status", "--nope").returncode, 2)


class CoverageRegressionTest(unittest.TestCase):
    def test_hourly_samples_and_duplicate_samples_never_fill_missing_minutes(self):
        hourly = [(at, 0, 1) for at in range(0, 86400, 3600)]
        self.assertAlmostEqual(ba.coverage(hourly, 0, 86400), 1 / 60)
        self.assertEqual(ba.coverage(hourly * 60, 0, 86400), ba.coverage(hourly, 0, 86400))

    def test_allow_five_percent_missing_without_an_invented_edge_gate(self):
        pts = [(at, 0, 1) for at in range(300, 6000, 60)]
        self.assertEqual(ba.coverage(pts, 0, 6000), .95)

    def test_fixed_ten_minute_rate_and_adjacent_spike_are_distinct(self):
        pts = [(0, 0, 0), (60, 3 * GIB, 0), (600, 3 * GIB, 0)]
        rate, jump = ba.r_peak_and_largest_delta(pts)
        self.assertEqual(rate, 3 * GIB / 600)
        self.assertEqual(jump, 3 * GIB)

    def test_reclaim_uses_zone_tick_and_maximum_delay(self):
        recs = [receipt(240), receipt(1600)]
        ticks = [{"at": 0, "zone": "RED"}, {"at": 1000, "zone": "ORANGE"}]
        self.assertEqual(ba._reclaim_seconds(recs, ticks), 600)
        self.assertIsNone(ba._reclaim_seconds(recs, [{"at": 0, "zone": "GREEN"}]))

    def test_repeated_week_does_not_count_as_adjacent(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = passing_pilot_state(tmp)
            ba.weekly_check(state, WEEK_END)
            lines, rc = ba.weekly_check(state, WEEK_END)
            self.assertEqual(rc, 0, lines)
            self.assertIn("adjacent_passing_weeks=1", lines)


if __name__ == "__main__":
    unittest.main()


class ReceiptHistoryTest(unittest.TestCase):
    def test_actual_writer_survives_terminal_store_rotation(self):
        import disk_budget
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            result = {"rc": 0, "hard_stop": False, "orphan_survivors": []}
            adapter = {"outcome": "success", "candidates": {
                "removed_count": 1, "deferred_count": 0, "interrupted_count": 0}}
            with patch.dict(os.environ, {"HOME": tmp}):
                for i in range(66):
                    disk_budget._write_govern_receipt(state, "worktrees", result,
                        None if i == 0 else 10, 20, adapter)
            records = ba.completed_receipts(state, 0, time.time() + 10)
            self.assertEqual(len(records), 66)
            self.assertEqual(sum(r["postcondition"]["df_delta_bytes"] is None
                                 for r in records), 1)
            self.assertEqual(len({r["run_id"] for r in records}), 66)

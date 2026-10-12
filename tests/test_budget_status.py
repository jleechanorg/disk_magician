#!/usr/bin/env python3
"""tests/test_budget_status.py — governor alerts, weekly check and pilot floor check (plan Task 10, spec §7.4, §7.6, §9)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import budget_status as bs  # noqa: E402

GIB = 1 << 30
WEEK = datetime(2026, 10, 5).timestamp()  # Monday 00:00 local


def flat(start, days=7, free_gib=40, used_gib=780, step=60):
    return [(int(start) + i, int(used_gib * GIB), int(free_gib * GIB)) for i in range(0, int(days * 86400), step)]


def write_state(tmp, samples=(), events=(), budget=None):
    state = Path(tmp)
    (state / "admission").mkdir(parents=True, exist_ok=True)
    with open(state / "disk_observer.jsonl", "w") as f:
        for t, used, free in samples:
            f.write(json.dumps(dict(epoch=t, host_disk=dict(used_kb=used // 1024, available_kb=free // 1024))) + "\n")
    with open(state / "admission" / "events.jsonl", "w") as f:
        f.writelines(json.dumps(e) + "\n" for e in events)
    if budget is not None:
        (state / "budget.json").write_text(json.dumps(budget))
    return state


def codes(lines):
    return [line.split()[0][len("ALERT:"):] for line in lines if line.startswith("ALERT:")]


class ExposureTest(unittest.TestCase):
    def rise(self, gib):
        t0 = WEEK + 3600
        return [(t, u + int(min(max(t - t0, 0), 600) / 600 * gib * GIB), f) for t, u, f in flat(WEEK, days=1)]

    def test_r_peak_hand_computed(self):
        self.assertAlmostEqual(bs.r_peak(self.rise(12)) / GIB, 0.02)

    def test_exposure_worked_example_is_false(self):
        e = bs.exposure(0.02 * GIB, 660, 240, 10 * GIB)
        self.assertAlmostEqual(e / GIB, 28)
        self.assertFalse(e <= 15 * GIB)

    def test_exposure_small_rise_is_true(self):
        self.assertAlmostEqual(bs.exposure(0.005 * GIB, 660, 240, 2 * GIB) / GIB, 6.5)

    def test_no_positive_receipt_is_margin_unknown(self):
        self.assertIsNone(bs.exposure(0.005 * GIB, 660, None, 2 * GIB))
        r = bs.pilot_check(flat(WEEK), [], WEEK)
        self.assertEqual(r["floor_margin_ok"], "margin_unknown")

    def test_unrelated_admits_do_not_reduce_r_peak(self):
        admits = [dict(event="admit", at=WEEK + 3600 + 60 * i, est_bytes=3 * GIB, decision=0) for i in range(4)]
        s = self.rise(12) + [(t, 780 * GIB, 40 * GIB) for t in range(int(WEEK) + 86400, int(WEEK) + 7 * 86400, 60)]
        r = bs.pilot_check(s, admits, WEEK)
        self.assertAlmostEqual(r["r_peak_Bps"] / GIB, 0.02)
        self.assertEqual(r["admit_burst_bytes"], 12 * GIB)

    def test_burst_window(self):
        pts = [(WEEK + 100 * i, 5 * GIB) for i in range(4)] + [(WEEK + 5000, 5 * GIB)]
        self.assertEqual(bs.window_max(pts), 20 * GIB)


class PilotCheckTest(unittest.TestCase):
    def test_passing_week_is_valid_and_floor_ok(self):
        r = bs.pilot_check(flat(WEEK), [], WEEK)
        self.assertEqual(r["verdict"], "pilot_valid")
        self.assertIs(r["pilot_floor_ok"], True)

    def test_five_qualifying_days_invalidates(self):
        s = [x for x in flat(WEEK) if not WEEK + 86400 <= x[0] < WEEK + 3 * 86400]
        r = bs.pilot_check(s, [], WEEK)
        self.assertEqual(r["verdict"], "pilot_invalid:qualifying_days")

    def test_one_sample_under_floor_fails_pilot_floor_ok(self):
        s = flat(WEEK)
        s[5000] = (s[5000][0], s[5000][1], int(14.9 * GIB))
        r = bs.pilot_check(s, [], WEEK)
        self.assertEqual(r["verdict"], "pilot_valid")
        self.assertIs(r["pilot_floor_ok"], False)

    def test_long_lived_writer_counts_one_admit_and_shows_growth(self):
        s = flat(WEEK)
        t0 = WEEK + 3600
        s = [(t, u + int(min(max(t - t0, 0), 7200) / 600) * 2 * GIB, f) for t, u, f in s]
        r = bs.pilot_check(s, [dict(event="admit", at=t0, est_bytes=2 * GIB, decision=0)], WEEK)
        self.assertEqual(r["admit_burst_bytes"], 2 * GIB)
        self.assertAlmostEqual(r["r_peak_Bps"], 2 * GIB / 600, delta=GIB / 600)
        self.assertIs(r["pilot_floor_ok"], True)


class WeeklyCheckTest(unittest.TestCase):
    def test_full_coverage_passing_rows(self):
        r = bs.weekly_check(flat(WEEK - 7 * 86400, days=14), WEEK)
        self.assertEqual(r["verdict"], "pass")
        self.assertEqual(r["consecutive_passes"], 2)

    def test_ninety_percent_coverage_is_insufficient(self):
        s = [x for i, x in enumerate(flat(WEEK)) if i % 10]
        self.assertEqual(bs.weekly_check(s, WEEK)["verdict"], "insufficient_data")

    def test_sample_under_15_fails(self):
        s = flat(WEEK)
        s[10] = (s[10][0], s[10][1], 14 * GIB)
        r = bs.weekly_check(s, WEEK)
        self.assertEqual(r["verdict"], "fail")
        self.assertEqual(r["rows"]["samples_under_15gib"], 1)

    def test_previous_week_missing_counts_one_pass(self):
        self.assertEqual(bs.weekly_check(flat(WEEK), WEEK)["consecutive_passes"], 1)

    def test_trough_over_790_or_rising_fails(self):
        self.assertEqual(bs.weekly_check(flat(WEEK, used_gib=800), WEEK)["verdict"], "fail")
        s = flat(WEEK - 7 * 86400, used_gib=700) + flat(WEEK, used_gib=780)
        self.assertEqual(bs.weekly_check(s, WEEK)["verdict"], "fail")


class AlertsTest(unittest.TestCase):
    NOW = WEEK + 7 * 86400

    def run_alerts(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            return bs.alerts(write_state(tmp, **kw), self.NOW, 10)

    def test_quiet_state_has_no_alerts(self):
        self.assertEqual(self.run_alerts(samples=flat(WEEK)), [])

    def test_floor_breach_prints_runbook(self):
        lines = self.run_alerts(samples=[(self.NOW - 60, 880 * GIB, 14 * GIB)])
        self.assertEqual(codes(lines), ["floor_breach"])
        self.assertTrue(any("fstrim" in line for line in lines))
        self.assertTrue(any("before pausing CI" in line for line in lines))

    def test_floor_breach_event_within_24h(self):
        self.assertIn("floor_breach", codes(self.run_alerts(events=[dict(event="floor_breach", at=self.NOW - 3600)])))

    def test_govern_stale(self):
        self.assertEqual(codes(self.run_alerts(budget=dict(zone="RED", zone_at=self.NOW - 1801))), ["govern_stale"])
        self.assertEqual(self.run_alerts(budget=dict(zone="RED", zone_at=self.NOW - 1700)), [])

    def test_admission_degraded_and_kickstart_blocked_within_24h(self):
        ev = [dict(event="admit", at=self.NOW - 600, est_bytes=0, degraded="blind"),
              dict(event="kickstart_blocked:c14_missing", at=self.NOW - 600),
              dict(event="admit", at=self.NOW - 90000, est_bytes=0, degraded="blind")]
        self.assertEqual(codes(self.run_alerts(events=ev)), ["admission_degraded", "kickstart_blocked"])

    def test_burst_over_margin(self):
        ev = [dict(event="admit", at=self.NOW - 3600 + 100 * i, est_bytes=5 * GIB, decision=0) for i in range(4)]
        self.assertEqual(codes(self.run_alerts(events=ev)), ["burst_over_margin"])

    def test_trough_rise(self):
        s = flat(self.NOW - 14 * 86400, used_gib=700) + flat(self.NOW - 7 * 86400, used_gib=720)
        self.assertEqual(codes(self.run_alerts(samples=s)), ["trough_rise"])


class CliTest(unittest.TestCase):
    def test_diskm_budget_status_alerts_and_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = write_state(tmp, budget=dict(zone="RED", zone_at=1))
            for tree in (ROOT, ROOT / "src" / "disk_magician"):
                out = subprocess.run(["bash", str(tree / "disk_magician.sh"), "budget", "status"],
                                     env={**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)},
                                     capture_output=True, text=True)
                self.assertEqual(out.returncode, 1, out.stderr)
                self.assertTrue(out.stdout.startswith("ALERT:govern_stale"), out.stdout)

    def test_weekly_check_cli_insufficient_data_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = write_state(tmp)
            out = subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"), "status",
                                  "--weekly-check", "--week-start", "2026-10-05"],
                                 env={**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}, capture_output=True, text=True)
            self.assertEqual(out.returncode, 1, out.stderr)
            self.assertIn("verdict=insufficient_data", out.stdout)


class DiskStatusAlertsTest(unittest.TestCase):
    def test_disk_status_prints_alerts_before_accounting(self):
        import contextlib, io
        import disk_status
        with tempfile.TemporaryDirectory() as tmp:
            state = write_state(tmp, budget=dict(zone="RED", zone_at=1))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = disk_status.main(["--state-dir", str(state), "--state-repo", str(state)])
            self.assertEqual(rc, 1)
            self.assertTrue(buf.getvalue().startswith("ALERT:govern_stale"), buf.getvalue())
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                disk_status.main(["--state-dir", str(state), "--state-repo", str(state), "--json"])
            self.assertTrue(json.loads(buf.getvalue())["alerts"][0].startswith("ALERT:govern_stale"))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""tests/test_budget_status.py — governor alerts (plan Task 10, spec §7.6, §9)."""
import json
import os
import subprocess
import sys
import tempfile
import time
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


class AlertsTest(unittest.TestCase):
    NOW = WEEK + 7 * 86400

    def run_alerts(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            return bs.alerts(write_state(tmp, **kw), self.NOW, 10)

    def test_quiet_state_has_no_alerts(self):
        self.assertEqual(codes(self.run_alerts(samples=flat(WEEK))), [])

    def test_floor_breach_prints_runbook(self):
        lines = self.run_alerts(samples=[(self.NOW - 60, 880 * GIB, 14 * GIB)])
        self.assertEqual(codes(lines), ["floor_breach"])
        self.assertTrue(any("fstrim" in line for line in lines))
        self.assertTrue(any("before pausing CI" in line for line in lines))

    def test_floor_breach_event_within_24h(self):
        self.assertIn("floor_breach", codes(self.run_alerts(events=[dict(event="floor_breach", at=self.NOW - 3600)])))

    def test_govern_stale(self):
        self.assertEqual(codes(self.run_alerts(budget=dict(zone="RED", zone_at=self.NOW - 1801))), ["govern_stale"])
        self.assertEqual(codes(self.run_alerts(budget=dict(zone="RED", zone_at=self.NOW - 1700))), [])

    def test_admission_degraded_and_kickstart_blocked_within_24h(self):
        ev = [dict(event="admit", at=self.NOW - 600, est_bytes=0, degraded="blind"),
              dict(event="kickstart_blocked:c14_missing", at=self.NOW - 600),
              dict(event="admit", at=self.NOW - 90000, est_bytes=0, degraded="blind")]
        self.assertEqual(codes(self.run_alerts(events=ev)), ["admission_degraded", "kickstart_blocked"])

    def test_burst_over_margin(self):
        ev = [dict(event="admit", at=self.NOW - 3600 + 100 * i, est_bytes=5 * GIB, decision=0) for i in range(4)]
        self.assertEqual(codes(self.run_alerts(events=ev)), ["burst_over_margin"])
        spaced = [dict(event="admit", at=self.NOW - 3600 + 700 * i, est_bytes=5 * GIB, decision=0) for i in range(4)]
        self.assertEqual(codes(self.run_alerts(events=spaced)), [])
        refused = [dict(event="admit", at=self.NOW - 3600 + 100 * i, est_bytes=5 * GIB, decision=d) for i, d in enumerate((75, 76, 75, 10))]
        self.assertEqual(codes(self.run_alerts(events=refused)), [])  # only decisions 0 and 10 (admitted) count

    def month(self, recent_gib, older_days=23):  # govern's daily_min_used: last 7 days at recent_gib, older days at 780 GiB
        day = lambda d: time.strftime("%Y-%m-%d", time.localtime(self.NOW - d * 86400))
        mins = {day(d): int((recent_gib if d < 7 else 780) * GIB) for d in range(7 + older_days)}
        return dict(zone="GREEN", zone_at=self.NOW, daily_min_used=mins)

    def test_trough_rise_over_15_gib_above_30_day_floor(self):
        lines = self.run_alerts(samples=flat(WEEK), budget=self.month(796))
        self.assertEqual(codes(lines), ["trough_rise"])
        self.assertFalse(any("insufficient" in line for line in lines), lines)

    def test_trough_noise_and_15_gib_do_not_alert(self):
        for recent in (780.01, 795):
            lines = self.run_alerts(budget=self.month(recent))
            self.assertEqual(codes(lines), [], recent)
            self.assertFalse(bs.raised(lines))

    def test_trough_insufficient_history_is_reported_not_silent(self):
        # 11 days of observer samples (live retention) and a short govern history: explicit status, no alert
        for budget in (None, self.month(840, older_days=3), dict(zone="GREEN", zone_at=self.NOW, daily_min_used="corrupt")):
            lines = self.run_alerts(samples=flat(self.NOW - 11 * 86400, days=11, used_gib=780, step=3600), budget=budget)
            self.assertEqual(codes(lines), [])
            self.assertTrue(any(line.startswith("trough_rise:insufficient_history") for line in lines), lines)
            self.assertFalse(bs.raised(lines))


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

    def test_unknown_subcommand_exits_2(self):
        out = subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"), "bogus"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)


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

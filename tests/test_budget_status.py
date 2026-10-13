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


class C14AccountingTest(unittest.TestCase):
    """Real c14_probe account -> canonical terminal receipt -> budget status output."""

    def _account(self, state, name, entries, reason):
        inv = state / f"{name}-inv.json"
        inv.write_text(json.dumps(entries))
        ledger = state / f"{name}.jsonl"
        subprocess.run([sys.executable, str(ROOT / "scripts" / "c14_probe.py"),
                        "account", str(inv), str(ledger), reason], check=True, capture_output=True)
        return ledger

    def _govern_receipt(self, state, class_name, ledger):
        import job_receipt
        store = job_receipt.JobReceiptStore(state_dir=str(state))
        saved = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
        saved_owner = os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = str(ledger)
        try:
            rid = store.begin(f"govern_{class_name}", trigger="act")
            store.finish(f"govern_{class_name}", rid, "success",
                         candidates={"removed_count": 2, "deferred_count": 0, "interrupted_count": 0},
                         postcondition={"df_delta_bytes": 0, "freed_bytes": 0})
        finally:
            if saved is None: os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
            else: os.environ["DISK_MAGICIAN_C14_LEDGER"] = saved
            if saved_owner is not None: os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = saved_owner

    def test_real_producer_receipts_stay_isolated_per_class_and_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            a1 = self._account(state, "alpha1", [{"type": "file", "size": 1300},
                                                 {"type": "symlink", "size": 7}], "unproven-content")
            b = self._account(state, "beta", [{"type": "file", "size": 4096}], "not-pushed")
            self._govern_receipt(state, "alpha", a1)
            self._govern_receipt(state, "beta", b)
            a2 = self._account(state, "alpha2", [{"type": "file", "size": 512}], "secret-like")
            self._govern_receipt(state, "alpha", a2)  # second run replaces, never accumulates
            out = subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"), "status"],
                                 env={**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)},
                                 capture_output=True, text=True)
            self.assertIn(out.returncode, (0, 1), out.stderr)
            alpha_line = next(l for l in out.stdout.splitlines() if "class=alpha " in l)
            beta_line = next(l for l in out.stdout.splitlines() if "class=beta " in l)
            self.assertIn("baseline_bytes=unknown", alpha_line)
            self.assertIn("ledger_status=ok", alpha_line)
            self.assertIn("c14_kept_bytes=secret-like:512", alpha_line)
            self.assertNotIn("unproven-content", alpha_line)
            self.assertNotIn("not-pushed", alpha_line)
            self.assertIn("removed_count=2", alpha_line)
            self.assertIn("freed_bytes=0", alpha_line)
            self.assertIn("df_reclaimed_bytes=0", alpha_line)
            self.assertIn("c14_kept_bytes=not-pushed:4096", beta_line)
            self.assertNotIn("secret-like", beta_line)
            self.assertNotIn("unproven-content", beta_line)

    def test_accounting_reports_missing_receipt_without_fabricating_a_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            cfg = state / "config.json"
            cfg.write_text(json.dumps({"budgets": {"classes": {"alpha": {}}}}))
            saved = os.environ.get("DISK_MAGICIAN_CONFIG")
            os.environ["DISK_MAGICIAN_CONFIG"] = str(cfg)
            try:
                line = next(l for l in bs.accounting(state) if "class=alpha" in l)
            finally:
                if saved is None: os.environ.pop("DISK_MAGICIAN_CONFIG", None)
                else: os.environ["DISK_MAGICIAN_CONFIG"] = saved
            self.assertIn("baseline_bytes=unknown", line)
            self.assertIn("receipt=missing", line)


if __name__ == "__main__":
    unittest.main()

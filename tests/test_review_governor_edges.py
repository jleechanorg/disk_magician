#!/usr/bin/env python3
"""PR184 governor/accounting edges, using temporary roots and fake probes only."""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import birth_audit
import budget_status
import disk_budget

GIB = 1 << 30
MISSING = object()


class BirthFirstSightingTest(unittest.TestCase):
    def check_race(self, when, replacement, historical=False):
        with tempfile.TemporaryDirectory(prefix="dm-birth-edge-") as tmp:
            path = Path(tmp) / "birth"
            path.mkdir()
            st = path.lstat()
            row = dict(path=str(path), dev=st.st_dev, ino=st.st_ino,
                       cls="worktrees", status="admitted", producer="worktree-new",
                       bytes=None, charge="estimate" if historical else None,
                       estimate_bytes=1234 if historical else None,
                       unknown_retries=2 if historical else 0)
            original = dict(row)
            known = dict(cls="worktrees", status="admitted", charge="measured",
                         bytes=7 * GIB)
            def change_generation():
                path.rename(Path(tmp) / "old")
                if replacement:
                    path.mkdir()
            def measure(*args):
                change_generation()
                return 999 * GIB
            if when == "before":
                change_generation()
            with mock.patch.object(birth_audit, "_du_bytes", side_effect=measure) as du:
                largest = birth_audit.measure_births(
                    {"known": known, "new": row},
                    {"classes": {"worktrees": {"budget_gb": 2}}}, 200, 10, None)
            self.assertEqual(largest, {"worktrees": 7 * GIB})
            self.assertEqual(row["unknown_retries"], original["unknown_retries"])
            self.assertIsNone(row["bytes"])
            self.assertNotIn("measured_at", row)
            if historical:
                self.assertEqual(row, original, "historical estimates must not be recalculated")
            else:
                self.assertEqual(row["charge"], "estimate")
                self.assertEqual(row["estimate_bytes"], 7 * GIB)
                self.assertEqual(birth_audit._charged_bytes(row), 7 * GIB)
            self.assertEqual(birth_audit.calibration({"new": row}, 200), {})
            self.assertEqual(du.call_count, int(when == "after"))

    def test_disappeared_before_first_du_gets_estimate(self):
        self.check_race("before", False)

    def test_replaced_before_first_du_gets_estimate(self):
        self.check_race("before", True)

    def test_disappeared_during_first_du_gets_estimate(self):
        self.check_race("after", False)

    def test_replaced_during_first_du_gets_estimate(self):
        self.check_race("after", True)

    def test_historical_estimates_and_retry_counts_survive_all_races(self):
        for when in ("before", "after"):
            for replacement in (False, True):
                with self.subTest(when=when, replacement=replacement):
                    self.check_race(when, replacement, historical=True)


class DailyMeasurementRequestTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="dm-daily-edge-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.measured = self.root / "worktrees"
        self.measured.mkdir()
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"budgets": {"concurrency_margin_gb": 10,
            "classes": {"worktrees": {"measure": "du", "budget_gb": 1}}}}))
        self.du_log = self.root / "du.log"
        binaries = {
            "du": f"#!/bin/sh\necho called >> '{self.du_log}'\necho '1024 . '\n",
            "df": "#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\necho '/dev/x 999999999 1 157286400 1% /'\n",
            "colima": '#!/bin/sh\necho \'{"name":"default","status":"Running"}\'\n',
            "fleet": '#!/bin/sh\necho \'{"schema_version":1,"status":"healthy","records":[{"status":"healthy"}]}\'\n',
            "launchctl": "#!/bin/sh\nexit 1\n",
        }
        for name, content in binaries.items():
            path = self.root / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.root),
            DISK_MAGICIAN_CONFIG=str(self.config), DISK_MAGICIAN_STATE_DIR=str(self.state),
            DISK_MAGICIAN_STATE_REPO=str(self.root / "state-repo"),
            DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE=str(self.root / "private-tmp"),
            DISK_MAGICIAN_MEASURE_ROOTS_JSON=json.dumps({"worktrees": [str(self.measured)]}),
            DISK_MAGICIAN_POLICY_FILE=str(self.root / "no-policy.json"),
            **{f"DISK_MAGICIAN_{name.upper()}_BIN": str(self.root / name) for name in binaries})
        self.env.pop("DISK_MAGICIAN_TEST_PAUSE_BEFORE_MERGE", None)
        isolated = mock.patch.dict(os.environ, self.env, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)

    def command(self, *args):
        return ["bash", str(ROOT / "disk_magician.sh"), "govern", *args]

    def run_cli(self, *args):
        return subprocess.run(self.command(*args), env=self.env, capture_output=True,
                              text=True, timeout=10)

    def data(self):
        path = self.state / "budget.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def hold(self, name):
        stream = (self.state / name).open("a+")
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(stream.close)
        return stream

    def assert_snapshot(self, du_calls=1):
        data = self.data()
        self.assertNotIn("daily_measure_pending", data)
        self.assertEqual(len(data.get("measurements", [])), 1, data)
        row = data["measurements"][0]
        self.assertFalse(row["incomplete"], row)
        self.assertEqual(row["classes"]["worktrees"]["used_gb"], 1 / 1024)
        self.assertEqual(self.du_log.read_text().splitlines(), ["called"] * du_calls)

    def test_daily_entrypoint_waits_for_tick_lock_and_records_snapshot(self):
        lock = self.hold("govern.lock")
        process = subprocess.Popen(self.command("--daily-measure", "--tick-seconds", "2"),
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        try:
            deadline = time.monotonic() + 3
            while not self.data().get("daily_measure_pending") and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIsNone(process.poll(), "daily command must wait while tick owns lock")
            self.assertNotIn("measurements", self.data())
            lock.close()
            out, err = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, (out, err))
            self.assert_snapshot()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_expired_wait_is_nonzero_and_next_process_retries_daily_snapshot(self):
        lock = self.hold("govern.lock")
        started = time.monotonic()
        result = self.run_cli("--daily-measure", "--tick-seconds", "0.05")
        self.assertLess(time.monotonic() - started, 3, "lock wait must be bounded")
        self.assertEqual(result.returncode, 3, (result.stdout, result.stderr))
        self.assertIn("daily_measure_deferred:govern_lock", result.stdout + result.stderr)
        self.assertTrue(self.data().get("daily_measure_pending"))
        self.assertNotIn("measurements", self.data())
        lock.close()
        result = self.run_cli("--tick-seconds", "2")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assert_snapshot(du_calls=2)
        self.assertEqual(self.data()["zone"], "GREEN")
        self.assertIn("tick_last_at", self.data())

    def test_inner_measure_lock_preserves_pending_through_ordinary_retry(self):
        lock = self.hold("measure.lock")
        first = self.run_cli("--daily-measure", "--tick-seconds", "2")
        self.assertEqual(first.returncode, 3, (first.stdout, first.stderr))
        pending = self.data().get("daily_measure_pending")
        self.assertTrue(pending)
        second = self.run_cli("--tick-seconds", "2")
        self.assertEqual(second.returncode, 3, (second.stdout, second.stderr))
        self.assertEqual(self.data().get("daily_measure_pending"), pending)
        self.assertFalse(self.du_log.exists())
        lock.close()
        final = self.run_cli("--tick-seconds", "2")
        self.assertEqual(final.returncode, 0, (final.stdout, final.stderr))
        self.assert_snapshot(du_calls=2)

    def test_killed_daily_waiter_leaves_request_for_next_process(self):
        lock = self.hold("govern.lock")
        process = subprocess.Popen(self.command("--daily-measure", "--tick-seconds", "5"),
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        try:
            deadline = time.monotonic() + 3
            while not self.data().get("daily_measure_pending") and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.data().get("daily_measure_pending"))
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)
            lock.close()
        result = self.run_cli("--tick-seconds", "2")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assert_snapshot(du_calls=2)

    def test_snapshot_write_error_does_not_consume_request(self):
        with mock.patch.object(disk_budget.budget_history, "record_measurement", side_effect=OSError("fixture write failure")):
            self.assertEqual(disk_budget.govern(["--daily-measure", "--tick-seconds", "2"], self.state), 3)
        self.assertTrue(self.data().get("daily_measure_pending"))
        self.assertNotIn("measurements", self.data())

    def test_finishing_snapshot_does_not_clear_a_newer_request(self):
        record = disk_budget.budget_history.record_measurement
        def newer_request(*args, **kwargs):
            result = record(*args, **kwargs)
            disk_budget.state_update(self.state, {"daily_measure_pending": "newer-request"})
            return result
        with mock.patch.object(disk_budget.budget_history, "record_measurement", side_effect=newer_request):
            self.assertEqual(disk_budget.govern(["--daily-measure", "--tick-seconds", "2"], self.state), 0)
        self.assertEqual(self.data().get("daily_measure_pending"), "newer-request")
        self.assertEqual(len(self.data().get("measurements", [])), 1)

    def run_ordinary_with_pending(self, *, failure=None, emergency=False, expire=False):
        disk_budget.state_update(self.state, {"daily_measure_pending": "request", "margin_gb": 17})
        if emergency:
            df = self.root / "df"
            df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\necho '/dev/x 999999999 1 26214400 1% /'\n")
        lock = self.hold("measure.lock") if failure == "lock" else None
        calls = []
        with mock.patch.object(disk_budget, "_run_group", return_value=(0, "ok", "")), \
                mock.patch.object(disk_budget, "_run_reconcile"), \
                mock.patch.object(disk_budget, "measure_tick_class"), \
                mock.patch.object(disk_budget, "observer_refresh"), \
                mock.patch.object(disk_budget, "_run_birth_audit"), \
                mock.patch.object(disk_budget, "_record_govern_tick") as record, \
                mock.patch.object(disk_budget, "_du_kb", return_value=1024), \
                mock.patch.object(disk_budget.budget_history, "record_measurement", side_effect=OSError("fixture write failure")) as snapshot, \
                mock.patch.object(disk_budget.time, "monotonic", return_value=0) as mono:
            def dispatch(*args):
                calls.append("dispatch")
                if expire:
                    mono.return_value = 5
            with mock.patch.object(disk_budget, "dispatch_actuators", side_effect=dispatch) as actuate:
                for _ in range(2):
                    mono.return_value = 0
                    self.assertEqual(disk_budget.govern(["--mode", "act", "--tick-seconds", "2"], self.state), 3)
                    self.assertEqual(self.data()["zone"], "BLACK" if emergency else "GREEN")
                    self.assertEqual(self.data()["daily_measure_pending"], "request")
                    self.assertEqual(self.data()["margin_gb"], 17)
                self.assertEqual(actuate.call_count, 2)
                self.assertEqual(record.call_count, 2)
            if emergency or expire or failure == "lock":
                snapshot.assert_not_called()
            else:
                self.assertEqual(snapshot.call_count, 2)
        if lock:
            lock.close()
        if emergency:
            events = [json.loads(line) for line in (self.state / "admission" / "events.jsonl").read_text().splitlines()]
            self.assertEqual(sum(row.get("event") == "govern_emergency" for row in events), 2)
        self.assertEqual(calls, ["dispatch", "dispatch"])

    def test_repeated_measure_lock_failure_preserves_ordinary_actuation(self):
        self.run_ordinary_with_pending(failure="lock")

    def test_repeated_snapshot_error_preserves_ordinary_actuation(self):
        self.run_ordinary_with_pending(failure="snapshot")

    def test_emergency_tick_runs_safety_path_and_retains_daily_request(self):
        self.run_ordinary_with_pending(emergency=True)

    def test_exhausted_ordinary_deadline_retains_daily_request(self):
        self.run_ordinary_with_pending(expire=True)

    def test_regular_tick_contention_still_skips_without_request(self):
        self.hold("govern.lock")
        result = self.run_cli("--tick-seconds", "2")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertIn("skipped_tick_lock", result.stdout)
        self.assertEqual(self.data(), {})


class EffectiveMarginAlertTest(unittest.TestCase):
    def alerts(self, state_margin, configured_margin=10, explicit=None, prefix="ALERT:burst_over_margin"):
        with tempfile.TemporaryDirectory(prefix="dm-margin-edge-") as tmp:
            state = Path(tmp)
            (state / "admission").mkdir()
            config = state / "config.json"
            configured = {} if configured_margin is MISSING else {"concurrency_margin_gb": configured_margin}
            config.write_text(json.dumps({"budgets": configured}))
            data = {"zone_at": 200}
            if state_margin is not MISSING:
                data["margin_gb"] = state_margin
            (state / "budget.json").write_text(json.dumps(data))
            (state / "admission" / "events.jsonl").write_text(json.dumps(
                dict(event="admit", at=190, est_bytes=15 * GIB, decision=0)) + "\n")
            with mock.patch.dict(os.environ, {"DISK_MAGICIAN_CONFIG": str(config), "HOME": str(state)}):
                return [line for line in budget_status.alerts(state, 200, explicit)
                        if line.startswith(prefix)]

    def test_raised_effective_margin_does_not_raise_false_burst_alert(self):
        self.assertEqual(self.alerts(20), [])

    def test_lower_effective_margin_raises_burst_alert(self):
        lines = self.alerts(5, configured_margin=20)
        self.assertEqual(len(lines), 1)
        self.assertIn("margin=5.0GiB", lines[0])

    def test_explicit_callers_margin_still_wins(self):
        self.assertEqual(self.alerts(5, explicit=20), [])

    def test_config_only_margin_and_absent_default_are_preserved(self):
        self.assertEqual(self.alerts(MISSING, configured_margin=20), [])
        lines = self.alerts(MISSING, configured_margin=MISSING)
        self.assertEqual(len(lines), 1)
        self.assertIn("margin=10.0GiB", lines[0])
        self.assertIn("margin=0.0GiB", self.alerts(0)[0])

    def test_invalid_config_is_not_a_plausible_default(self):
        for invalid in ("invalid", None, True, -1):
            with self.subTest(invalid=invalid):
                lines = self.alerts(MISSING, configured_margin=invalid, prefix="ALERT:")
                self.assertEqual(len(lines), 1)
                self.assertTrue(lines[0].startswith("ALERT:margin_invalid"), lines)

    def test_status_cli_uses_the_effective_margin(self):
        with tempfile.TemporaryDirectory(prefix="dm-margin-cli-") as tmp:
            state = Path(tmp)
            (state / "admission").mkdir()
            config = state / "config.json"
            config.write_text(json.dumps({"budgets": {"concurrency_margin_gb": 10}}))
            (state / "admission" / "events.jsonl").write_text(json.dumps(
                dict(event="admit", at=190, est_bytes=15 * GIB, decision=0)) + "\n")
            for margin, expected in ((20, 0), (5, 1), ("invalid", 1)):
                with self.subTest(margin=margin):
                    (state / "budget.json").write_text(json.dumps({"zone_at": 200, "margin_gb": margin}))
                    result = subprocess.run([sys.executable, str(ROOT / "scripts" / "budget_status.py"),
                        "status", "--at", "200"], capture_output=True, text=True, timeout=10,
                        env=dict(os.environ, HOME=str(state), DISK_MAGICIAN_CONFIG=str(config),
                                 DISK_MAGICIAN_STATE_DIR=str(state)))
                    self.assertEqual(result.returncode, expected, (result.stdout, result.stderr))
                    if margin == "invalid":
                        self.assertIn("ALERT:margin_invalid", result.stdout)
                        self.assertNotIn("ALERT:burst_over_margin", result.stdout)
                    else:
                        self.assertEqual("ALERT:burst_over_margin" in result.stdout, margin == 5)

    def test_invalid_override_reports_unavailable_effective_margin(self):
        for invalid in ("invalid", None, True, -1):
            with self.subTest(invalid=invalid):
                lines = self.alerts(invalid, configured_margin=20, prefix="ALERT:")
                self.assertEqual(len(lines), 1)
                self.assertTrue(lines[0].startswith("ALERT:margin_invalid"), lines)
                self.assertNotIn("burst_over_margin", lines[0])


if __name__ == "__main__":
    unittest.main()

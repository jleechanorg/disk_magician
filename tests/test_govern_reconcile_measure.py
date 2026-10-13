#!/usr/bin/env python3
"""Task 8 govern reconcile/measure tests (bead disk_magician-cuea.12).

Hermetic fixtures only: fake df/du/launchctl, a temp HOME and STATE. The real
worktree crash test drives the canonical quarantine entrypoints in a temp repo.
No host actuator is dispatched (observe mode; dispatch is monkeypatched).
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import disk_budget  # noqa: E402

GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@t",
}


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


def run_git(args, cwd):
    env = dict(os.environ, **GIT_ENV)
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class GovernReconcileMeasureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="gov-rm-", dir="/tmp")).resolve()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.df = self.tmp / "df"
        self.du_log = self.tmp / "du.log"
        self.reconcile_calls = []
        write_exec(self.tmp / "launchctl", "#!/bin/sh\nexit 0\n")
        write_exec(self.tmp / "fleet", "#!/bin/sh\necho '{\"schema_version\":1,\"status\":\"healthy\",\"records\":[{\"status\":\"healthy\"}]}'\n")
        write_exec(self.tmp / "colima", "#!/bin/sh\necho '{\"name\":\"default\",\"status\":\"Running\"}'\n")
        isolated = mock.patch.dict(os.environ, {
            "DISK_MAGICIAN_LAUNCHCTL_BIN": str(self.tmp / "launchctl"),
            "DISK_MAGICIAN_FLEET_BIN": str(self.tmp / "fleet"),
            "DISK_MAGICIAN_COLIMA_BIN": str(self.tmp / "colima"),
            "DISK_MAGICIAN_POLICY_FILE": str(self.tmp / "no-policy.json"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"})
        isolated.start()
        self.addCleanup(isolated.stop)

    def tearDown(self):
        subprocess.run(["chmod", "-R", "u+w", str(self.tmp)], capture_output=True)
        subprocess.run(["rm", "-rf", str(self.tmp)], capture_output=True)

    # ---- fixtures -------------------------------------------------------
    def fake_df(self, free_gib):
        write_exec(self.df, "#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                            f"echo '/dev/x 999999999 1 {free_gib * 1024 * 1024} 1% /'\n")

    def fake_du(self, marker):
        write_exec(self.tmp / "du",
                   "#!/bin/sh\n"
                   f"echo \"$*\" >> {marker}\n"
                   "echo '1024\t.'\n")

    def budgets_config(self, measure_roots):
        cfg = {"budgets": {"classes": {
            "worktrees": {"budget_gb": 1, "measure": "du", "trigger": "overage", "act": "worktree_reap_remove"},
            "tmp_containers": {"budget_gb": 1, "measure": "du", "trigger": "overage", "act": "tmp_containers"},
            "tmpdir_scratch": {"budget_gb": 1, "measure": "df_delta_only", "trigger": "zone", "act": "tmpdir_scratch"},
        }}}
        path = self.tmp / "config.json"
        path.write_text(json.dumps(cfg))
        return path, measure_roots

    def stub_tick_subprocesses(self, birth_marker):
        """Patch disk_budget._run_group for the reconcile and birth-audit phases.

        du keeps using the real runner (with the fake du binary), because
        measure_tick_class still has to execute one class.
        """
        real_group = disk_budget._run_group

        def fake_group(argv, timeout, stdout=None):
            joined = " ".join(str(x) for x in argv)
            if "quarantine_rename.py" in joined and "reconcile" in joined:
                deadline = None
                if "--deadline-at" in argv:
                    deadline = float(argv[argv.index("--deadline-at") + 1])
                self.reconcile_calls.append(deadline)
                return 0, "", ""
            if "birth_audit.sh" in joined:
                Path(birth_marker).write_text("called")
                return 0, "", ""
            return real_group(argv, timeout, stdout)

        return mock.patch.object(disk_budget, "_run_group", side_effect=fake_group)

    # ---- real quarantine crash -----------------------------------------
    def build_worktree_receipt(self, main, wt):
        checkout = self.tmp / "inv.checkout"
        admin_rows = self.tmp / "inv.admin"
        receipt = self.tmp / "receipt.json"
        subprocess.run([sys.executable, str(ROOT / "scripts" / "c14_probe.py"),
                        "inventory", str(wt), str(checkout)], check=True, stdout=subprocess.DEVNULL)
        env = dict(os.environ, C14_INVENTORY_OUT=str(admin_rows), **GIT_ENV)
        subprocess.run([sys.executable, str(ROOT / "scripts" / "c14_probe.py"), "admin",
                        subprocess.run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"],
                                       capture_output=True, text=True, check=True,
                                       env=dict(os.environ, **GIT_ENV)).stdout.strip()],
                       check=True, stdout=subprocess.DEVNULL, env=env)
        subprocess.run([sys.executable, str(ROOT / "scripts" / "c14_probe.py"), "merge-inventory",
                        str(checkout), str(admin_rows), str(receipt)], check=True, stdout=subprocess.DEVNULL)
        return receipt

    def make_worktree_env(self):
        env = dict(os.environ, HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state), **GIT_ENV)
        return env

    def test_generic_reconcile_after_repair_restores_original(self):
        main = self.tmp / "main"
        main.mkdir()
        run_git(["init", "-q", "-b", "main"], main)
        run_git(["config", "user.name", "test"], main)
        run_git(["config", "user.email", "t@e"], main)
        (main / "base").write_text("base\n")
        run_git(["add", "base"], main)
        run_git(["commit", "-qm", "base"], main)
        wt = self.tmp / "wt1"
        run_git(["worktree", "add", "-q", "-b", "wt1", str(wt)], main)
        admin = Path(subprocess.run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"],
                                    capture_output=True, text=True, check=True,
                                    env=dict(os.environ, **GIT_ENV)).stdout.strip())
        gitdir_before = (admin / "gitdir").read_bytes()
        receipt = self.build_worktree_receipt(main, wt)
        env = self.make_worktree_env()
        env2 = dict(env, DISK_MAGICIAN_TEST_WRH_KILL_AT="after_repair")
        crashed = subprocess.run([sys.executable, str(ROOT / "scripts" / "worktree_quarantine.py"),
                                  "phase1", str(main), str(wt), str(receipt)], env=env2,
                                 capture_output=True, text=True)
        self.assertEqual(crashed.returncode, -9, "SIGKILL after_repair")
        self.assertFalse(wt.exists())
        self.assertTrue((admin / "locked").exists())
        reconciled = subprocess.run([sys.executable, str(ROOT / "scripts" / "quarantine_rename.py"),
                                     "reconcile"], env=env, capture_output=True, text=True)
        self.assertEqual(reconciled.returncode, 0)
        self.assertIn("rolled-back", reconciled.stdout)
        self.assertTrue(wt.is_dir(), "checkout restored")
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before, "gitdir restored")
        self.assertFalse((admin / "locked").exists(), "own lock removed")
        listing = subprocess.run(["git", "-C", str(main), "worktree", "list", "--porcelain"],
                                 capture_output=True, text=True, env=dict(os.environ, **GIT_ENV)).stdout
        self.assertNotIn(".dm-quarantine/", listing)
        run_git(["status", "--porcelain"], wt)
        index = self.state / "quarantine-index"
        leftovers = [p.name for p in index.iterdir() if p.name != "operations.lock"]
        self.assertEqual(leftovers, [], "index and sidecar retired")

    def test_generic_reconcile_deleting_tears_down_admin(self):
        main = self.tmp / "main2"
        main.mkdir()
        run_git(["init", "-q", "-b", "main"], main)
        run_git(["config", "user.name", "test"], main)
        run_git(["config", "user.email", "t@e"], main)
        (main / "base").write_text("base\n")
        run_git(["add", "base"], main)
        run_git(["commit", "-qm", "base"], main)
        wt = self.tmp / "wt2"
        run_git(["worktree", "add", "-q", "-b", "wt2", str(wt)], main)
        admin = Path(subprocess.run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"],
                                    capture_output=True, text=True, check=True,
                                    env=dict(os.environ, **GIT_ENV)).stdout.strip())
        receipt = self.build_worktree_receipt(main, wt)
        env = self.make_worktree_env()
        first = subprocess.run([sys.executable, str(ROOT / "scripts" / "worktree_quarantine.py"),
                                "phase1", str(main), str(wt), str(receipt)], env=env,
                               capture_output=True, text=True)
        self.assertTrue(first.stdout.startswith("quarantined:"), first.stdout)
        qid = first.stdout.strip().split(":", 1)[1]
        crash = subprocess.run([sys.executable, str(ROOT / "scripts" / "worktree_quarantine.py"),
                                "phase2", qid], env=dict(env, DISK_MAGICIAN_TEST_WRH_KILL_AT="after_checkout_removed"),
                               capture_output=True, text=True)
        self.assertEqual(crash.returncode, -9)
        reconciled = subprocess.run([sys.executable, str(ROOT / "scripts" / "quarantine_rename.py"),
                                     "reconcile"], env=env, capture_output=True, text=True)
        self.assertIn("removed", reconciled.stdout)
        self.assertFalse(wt.exists())
        self.assertFalse(admin.exists(), "selected admin torn down")
        listing = subprocess.run(["git", "-C", str(main), "worktree", "list", "--porcelain"],
                                 capture_output=True, text=True, env=dict(os.environ, **GIT_ENV)).stdout
        self.assertNotIn("wt2", listing)

    # ---- govern tick ---------------------------------------------------
    def test_tick_measures_oldest_du_class_after_zone(self):
        wt_root = self.tmp / "worktrees"
        (wt_root / "a").mkdir(parents=True)
        (wt_root / "a" / "f").write_text("x" * 2048)
        tmp_root = self.tmp / "tmpc"
        (tmp_root / "b").mkdir(parents=True)
        self.fake_df(150)
        cfg, roots = self.budgets_config({"worktrees": [str(wt_root)], "tmp_containers": [str(tmp_root)]})
        (self.state / "budget.json").write_text(json.dumps({"classes": {
            "worktrees": {"used_gb": 1, "measured_at": 100},
            "tmp_containers": {"used_gb": 9, "measured_at": 200}}}))
        env = dict(os.environ, HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state),
                   DISK_MAGICIAN_CONFIG=str(cfg), DISK_MAGICIAN_DF_BIN=str(self.df),
                   DISK_MAGICIAN_MEASURE_ROOTS_JSON=json.dumps(roots), **GIT_ENV)
        old = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            with self.stub_tick_subprocesses(str(self.tmp / "audit-called")), \
                 mock.patch.object(disk_budget, "measure_tick_class", wraps=disk_budget.measure_tick_class) as spy:
                started = time.monotonic()
                disk_budget.govern(["--mode", "observe", "--tick-seconds", "600"], self.state)
                elapsed = time.monotonic() - started
            self.assertLess(elapsed, 20)
            self.assertEqual(spy.call_count, 1)
            data = json.loads((self.state / "budget.json").read_text())
            self.assertEqual(data["zone"], "GREEN")
            self.assertIsInstance(data["zone_at"], (int, float))
            self.assertNotEqual(data["classes"]["worktrees"]["measured_at"], 100)
            self.assertEqual(data["classes"]["tmp_containers"]["used_gb"], 9)
            self.assertTrue(self.reconcile_calls, "reconcile invoked before measure/audit")
            budget = self.reconcile_calls[0] - time.monotonic()
            self.assertGreater(budget, 0)
            self.assertLessEqual(budget, 120.5)
        finally:
            os.environ.clear(); os.environ.update(old)

    def test_black_skips_measure_and_audit_and_caps_reconcile_at_60s(self):
        self.fake_df(25)  # BLACK
        cfg, roots = self.budgets_config({"worktrees": [str(self.tmp / "none")]})
        env = dict(os.environ, HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state),
                   DISK_MAGICIAN_CONFIG=str(cfg), DISK_MAGICIAN_DF_BIN=str(self.df),
                   DISK_MAGICIAN_MEASURE_ROOTS_JSON=json.dumps(roots), **GIT_ENV)
        old = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            captured = []
            real_group = disk_budget._run_group

            def fake_group(argv, timeout, stdout=None):
                joined = " ".join(str(x) for x in argv)
                if "quarantine_rename.py" in joined and "reconcile" in joined:
                    captured.append(float(argv[argv.index("--deadline-at") + 1]))
                    return 0, "", ""
                return real_group(argv, timeout, stdout)

            with mock.patch.object(disk_budget, "_run_group", side_effect=fake_group), \
                 mock.patch.object(disk_budget, "measure_tick_class") as measure, \
                 mock.patch.object(disk_budget, "observer_refresh") as observer:
                disk_budget.govern(["--mode", "observe"], self.state)
            measure.assert_not_called()
            observer.assert_not_called()
            self.assertFalse((self.tmp / "audit-called").exists(), "BLACK skips birth audit")
            budget = captured[0] - time.monotonic()
            self.assertGreater(budget, 0)
            self.assertLessEqual(budget, 60.5)
        finally:
            os.environ.clear(); os.environ.update(old)

    def test_observe_mode_runs_no_actuator(self):
        self.fake_df(150)
        cfg, roots = self.budgets_config({})
        env = dict(os.environ, HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state),
                   DISK_MAGICIAN_CONFIG=str(cfg), DISK_MAGICIAN_DF_BIN=str(self.df), **GIT_ENV)
        old = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            with mock.patch.object(disk_budget, "dispatch_actuators") as dispatch, \
                 self.stub_tick_subprocesses(str(self.tmp / "audit-called")):
                disk_budget.govern(["--mode", "observe"], self.state)
            dispatch.assert_not_called()
        finally:
            os.environ.clear(); os.environ.update(old)

    # ---- daily measure / locking --------------------------------------
    def test_daily_measure_respects_measure_lock(self):
        cfg, roots = self.budgets_config({"worktrees": [str(self.tmp / "none")]})
        budgets = json.loads(cfg.read_text())["budgets"]
        (self.state / "budget.json").write_text(json.dumps({"classes": {"worktrees": {"used_gb": 4}}}))
        fd = os.open(self.state / "measure.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            before = (self.state / "budget.json").read_text()
            self.assertEqual(disk_budget.daily_measure(self.state, budgets), 0)
            self.assertEqual((self.state / "budget.json").read_text(), before)
        finally:
            os.close(fd)

    def test_daily_measure_interleaves_with_tick_under_state_lock(self):
        wt_root = self.tmp / "worktrees"
        (wt_root / "a").mkdir(parents=True)
        (wt_root / "a" / "f").write_text("x" * 4096)
        cfg, roots = self.budgets_config({"worktrees": [str(wt_root)]})
        budgets = json.loads(cfg.read_text())["budgets"]
        (self.state / "budget.json").write_text(json.dumps({"classes": {"worktrees": {"used_gb": 4}}}))
        pause = self.tmp / "pause"
        pause.mkdir()
        old = dict(os.environ)
        os.environ.update({"DISK_MAGICIAN_MEASURE_ROOTS_JSON": json.dumps(roots),
                           "DISK_MAGICIAN_TEST_PAUSE_BEFORE_MERGE": str(pause)})
        try:
            result = {}

            def daily():
                result["rc"] = disk_budget.daily_measure(self.state, budgets)

            thread = threading.Thread(target=daily)
            thread.start()
            ready = pause / "ready"
            deadline = time.monotonic() + 20
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "daily job paused after scans")
            # A concurrent tick writes BLACK + a new births value while the daily
            # job holds measure.lock; the daily merge must preserve both fields.
            disk_budget.state_update(self.state, {"zone": "BLACK", "zone_at": 123.0},
                                     [{"event": "births", "count": 7}])
            disk_budget.merge_classes(self.state, {"codex_documents": {"used_gb": 2, "measured_at": 5}})
            (pause / "release").write_text("")
            thread.join(timeout=20)
            self.assertEqual(result.get("rc"), 0)
            data = json.loads((self.state / "budget.json").read_text())
            self.assertEqual(data["zone"], "BLACK")
            self.assertEqual(data["zone_at"], 123.0)
            self.assertEqual(data["classes"]["codex_documents"]["used_gb"], 2)
            self.assertTrue(data["classes"]["worktrees"]["measured_at"] >= 1)
        finally:
            os.environ.clear(); os.environ.update(old)

    def test_reconcile_deadline_caps(self):
        self.fake_df(150)
        cfg, roots = self.budgets_config({})
        env = dict(os.environ, HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state),
                   DISK_MAGICIAN_CONFIG=str(cfg), DISK_MAGICIAN_DF_BIN=str(self.df), **GIT_ENV)
        captured = []

        def capture(state, deadline_mono):
            captured.append(time.monotonic() - deadline_mono)
            return 0

        old = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            with mock.patch.object(disk_budget, "_run_reconcile", side_effect=capture), \
                 self.stub_tick_subprocesses(str(self.tmp / "audit-called")):
                disk_budget.govern(["--mode", "observe"], self.state)
            self.assertGreaterEqual(captured[0], -120.5)
            self.assertLessEqual(captured[0], -119.0)
            captured.clear()
            self.fake_df(25)
            with mock.patch.object(disk_budget, "_run_reconcile", side_effect=capture):
                disk_budget.govern(["--mode", "observe"], self.state)
            self.assertGreaterEqual(captured[0], -60.5)
            self.assertLessEqual(captured[0], -59.0)
        finally:
            os.environ.clear(); os.environ.update(old)

    # ---- focused defect tests (parent review 2xx) -----------------------
    def test_observer_refresh_reads_nested_colima_and_respects_freshness(self):
        budgets = {"classes": {"colima": {"budget_gb": 1, "measure": "observer", "trigger": "overage", "act": "colima"}}}
        now = time.time()
        (self.state / "disk_observer.jsonl").write_text(
            json.dumps({"epoch": now, "colima": {"root_allocated_kb": 2 * 1024 * 1024}}) + "\n")
        disk_budget.observer_refresh(self.state, budgets, now)
        classes = json.loads((self.state / "budget.json").read_text())["classes"]
        self.assertAlmostEqual(classes["colima"]["used_gb"], 2.0, places=6)
        self.assertEqual(classes["colima"]["measured_at"], now)
        # Stale observer row: prior value kept, measured_at stays, stale_s grows.
        (self.state / "disk_observer.jsonl").write_text(
            json.dumps({"epoch": now - 3600, "colima": {"root_allocated_kb": 99 * 1024 * 1024}}) + "\n")
        disk_budget.observer_refresh(self.state, budgets, now + 10)
        classes = json.loads((self.state / "budget.json").read_text())["classes"]
        self.assertEqual(classes["colima"]["measured_at"], now, "stale row must not look freshly measured")
        self.assertAlmostEqual(classes["colima"]["used_gb"], 2.0, places=6)
        self.assertGreaterEqual(classes["colima"]["stale_s"], 10)
        # Cold start (no prior measurement): a stale row creates nothing; it must
        # never be recorded as if observed now.
        (self.state / "budget.json").write_text(json.dumps({"classes": {}}))
        disk_budget.observer_refresh(self.state, budgets, now + 10)
        classes = json.loads((self.state / "budget.json").read_text())["classes"]
        self.assertNotIn("colima", classes, "stale observer row must not invent a measurement")

    def test_measure_bootstraps_missing_classes_and_advances_on_timeout(self):
        for name in ("alpha", "beta"):
            (self.tmp / name).mkdir()
        budgets = {"classes": {
            "alpha": {"budget_gb": 1, "measure": "du"},
            "beta": {"budget_gb": 1, "measure": "du"},
        }}
        failing = self.tmp / "du-fail"
        write_exec(failing, "#!/bin/sh\nexit 1\n")
        old = os.environ.get("DISK_MAGICIAN_DU_BIN")
        os.environ["DISK_MAGICIAN_DU_BIN"] = str(failing)
        os.environ["DISK_MAGICIAN_MEASURE_ROOTS_JSON"] = json.dumps({"alpha": [str(self.tmp / "alpha")], "beta": [str(self.tmp / "beta")]})
        try:
            first = disk_budget.measure_tick_class(self.state, budgets, 100, None)
            second = disk_budget.measure_tick_class(self.state, budgets, 200, None)
        finally:
            if old is None: os.environ.pop("DISK_MAGICIAN_DU_BIN", None)
            else: os.environ["DISK_MAGICIAN_DU_BIN"] = old
            os.environ.pop("DISK_MAGICIAN_MEASURE_ROOTS_JSON", None)
        self.assertEqual({first, second}, {"alpha", "beta"}, "timeout must still advance round-robin")
        classes = json.loads((self.state / "budget.json").read_text())["classes"]
        for name in ("alpha", "beta"):
            self.assertNotIn("measured_at", classes[name], "no fake freshness on timeout")
            self.assertIn("stale_s", classes[name])

    def test_du_kb_one_invocation_multi_root(self):
        r1, r2 = self.tmp / "r1", self.tmp / "r2"
        r1.mkdir(); r2.mkdir()
        log = self.tmp / "du-args.log"
        write_exec(self.tmp / "du", f"#!/bin/sh\necho \"$*\" >> {log}\necho '1024\t.'\n")
        old = os.environ.get("DISK_MAGICIAN_DU_BIN")
        os.environ["DISK_MAGICIAN_DU_BIN"] = str(self.tmp / "du")
        try:
            kb = disk_budget._du_kb([r1, r2], 5)
        finally:
            if old is None: os.environ.pop("DISK_MAGICIAN_DU_BIN", None)
            else: os.environ["DISK_MAGICIAN_DU_BIN"] = old
        self.assertEqual(kb, 1024)
        lines = log.read_text().splitlines()
        self.assertEqual(len(lines), 1, "one du invocation for both roots (hardlink dedup)")
        self.assertIn(str(r1), lines[0]); self.assertIn(str(r2), lines[0])

    def test_daily_df_delta_only_runs_a_real_bounded_du(self):
        root = self.tmp / "delta"
        root.mkdir()
        budgets = {"classes": {"tmpdir_scratch": {"budget_gb": 1, "measure": "df_delta_only", "trigger": "zone"}}}
        write_exec(self.tmp / "du", "#!/bin/sh\necho '2048\t.'\n")
        old_bin = os.environ.get("DISK_MAGICIAN_DU_BIN")
        old_roots = os.environ.get("DISK_MAGICIAN_MEASURE_ROOTS_JSON")
        os.environ["DISK_MAGICIAN_DU_BIN"] = str(self.tmp / "du")
        os.environ["DISK_MAGICIAN_MEASURE_ROOTS_JSON"] = json.dumps({"tmpdir_scratch": [str(root)]})
        try:
            self.assertEqual(disk_budget.daily_measure(self.state, budgets), 0)
        finally:
            if old_bin is None: os.environ.pop("DISK_MAGICIAN_DU_BIN", None)
            else: os.environ["DISK_MAGICIAN_DU_BIN"] = old_bin
            if old_roots is None: os.environ.pop("DISK_MAGICIAN_MEASURE_ROOTS_JSON", None)
            else: os.environ["DISK_MAGICIAN_MEASURE_ROOTS_JSON"] = old_roots
        stats = json.loads((self.state / "budget.json").read_text())["classes"]["tmpdir_scratch"]
        self.assertTrue(stats.get("measured_at"), "df_delta_only must record a real measurement")
        self.assertAlmostEqual(stats["used_gb"], 2048 / 1024.0 / 1024.0, places=6)
        self.assertFalse(stats["carried"])

    def test_run_group_kills_descendant_processes(self):
        pidfile = self.tmp / "child.pid"
        script = self.tmp / "spawner.sh"
        write_exec(script, f"#!/bin/sh\nsleep 300 &\necho $! > {pidfile}\nwait\n")
        rc, _, _ = disk_budget._run_group([str(script)], 1)
        self.assertEqual(rc, -9, "group runner reports the hard stop")
        child = int(pidfile.read_text().strip())
        gone = False
        for _ in range(50):
            try: os.kill(child, 0)
            except ProcessLookupError: gone = True; break
            time.sleep(0.1)
        self.assertTrue(gone, "descendant survived the group kill")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Deterministic scheduler math tests for C10; no host actuator is invoked."""
import sys
import time
import unittest
import json
import os
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import disk_budget  # noqa: E402


class GovernSchedulerTest(unittest.TestCase):
    def _full_slice_count(self, count, usable, run_s):
        eligible = [{"class": f"c{i}", "unit_budget_s": 20} for i in range(count)]
        schedule = {"classes": {}}
        now = 0.0
        deadline = usable + 60
        ran = []
        deferred = []
        while eligible:
            row, skipped = disk_budget.next_actuator(
                eligible, schedule, 100 + now, now, deadline, "RED"
            )
            deferred.extend(skipped)
            if row is None:
                break
            ran.append(row["class"])
            eligible = [item for item in eligible if item["class"] != row["class"]]
            now += run_s
        return ran, deferred

    def test_six_hundred_seconds_of_work_with_three_hundred_usable_runs_five(self):
        ran, deferred = self._full_slice_count(10, 300, 60)
        self.assertEqual(len(ran), 5)
        self.assertEqual(len(deferred), 5)

    def test_two_second_overhead_leaves_seven_full_slices(self):
        ran, deferred = self._full_slice_count(10, 478, 60)
        self.assertEqual(len(ran), 7)
        self.assertEqual(len(deferred), 3)

    def test_fast_actuators_reuse_time_for_all_ten(self):
        ran, deferred = self._full_slice_count(10, 300, 10)
        self.assertEqual(len(ran), 10)
        self.assertEqual(deferred, [])

    def test_large_unit_defers_but_next_class_still_runs(self):
        eligible = [{"class": "large", "unit_budget_s": 100},
                    {"class": "small", "unit_budget_s": 20}]
        schedule = {"classes": {}}
        row, deferred = disk_budget.next_actuator(eligible, schedule, 10, 0, 180, "RED")
        self.assertEqual(deferred, ["large"])
        self.assertEqual(row["class"], "small")
        self.assertEqual(row["slice_s"], 120)

    def test_three_tick_deferred_actuator_goes_first(self):
        eligible = [{"class": "old", "unit_budget_s": 20},
                    {"class": "new", "unit_budget_s": 20}]
        schedule = {"classes": {"new": {"deferred_ticks": 3}}}
        row, _ = disk_budget.next_actuator(eligible, schedule, 10, 0, 600, "RED")
        self.assertEqual(row["class"], "new")

    def test_persisted_deferred_queue_is_served_before_other_classes(self):
        eligible = [{"class": "old", "unit_budget_s": 20},
                    {"class": "new", "unit_budget_s": 20}]
        schedule = {"classes": {}, "deferred_queue": ["new"]}
        row, _ = disk_budget.next_actuator(eligible, schedule, 10, 0, 600, "RED")
        self.assertEqual(row["class"], "new")

    def test_eligibility_uses_only_fixed_actuator_table_and_fresh_measurements(self):
        budgets = {"classes": {
            "worktrees": {"act": "worktree_reap_remove", "trigger": "overage",
                          "budget_gb": 10, "unit_budget_s": 60},
            "codex_documents": {"act": "codex_documents", "trigger": "zone",
                                 "unit_budget_s": 30},
            "unknown": {"act": "run_this_shell", "trigger": "always"},
            "stale": {"act": "tmp_containers", "trigger": "overage", "budget_gb": 1},
        }}
        measured = {"classes": {
            "worktrees": {"used_gb": 20, "measured_at": 19500},
            "stale": {"used_gb": 20, "measured_at": 1},
        }}
        rows, reasons = disk_budget.eligible_actuators(budgets, measured, "RED", 20000)
        self.assertEqual({row["class"] for row in rows},
                         {"worktrees", "worktree_cleanup", "codex_documents"})
        self.assertEqual(next(row for row in rows if row["class"] == "worktrees")["act"],
                         "worktree_reap_remove")
        self.assertTrue(any(reason.startswith("actuator_unadapted:unknown") for reason in reasons))
        self.assertIn("class_stale:stale", reasons)

    def test_dispatch_uses_fixed_adapter_passes_deadline_and_writes_govern_receipt(self):
        with tempfile.TemporaryDirectory(prefix="govern-act-test-") as tmp:
            root = Path(tmp)
            scripts = root / "scripts"
            lib = scripts / "lib"
            lib.mkdir(parents=True)
            (scripts / "job_receipt.py").write_text(
                (Path(disk_budget.__file__).parent / "job_receipt.py").read_text()
            )
            (lib / "artifact_verdict.sh").write_text(
                'artifact_removal_verdict() { [[ "$1" == --self-test ]] && echo ok; }\n'
            )
            args_log = root / "adapter-args.json"
            adapter = scripts / "cleanup_tmp.sh"
            adapter.write_text(
                "#!/bin/bash\n"
                "python3 - \"$(cd \"$(dirname \"$0\")\" && pwd)\" \"$*\" <<'PY'\n"
                "import json,os,sys\n"
                "sys.path.insert(0,sys.argv[1])\n"
                "import job_receipt\n"
                f"open({str(args_log)!r},'w').write(json.dumps(sys.argv[2]))\n"
                "s=job_receipt.JobReceiptStore(state_dir=os.environ['DISK_MAGICIAN_STATE_DIR'])\n"
                "r=s.begin('cleanup_tmp',trigger='act')\n"
                "s.finish('cleanup_tmp',run_id=r,outcome='success',candidates={'removed_count':2,'deferred_count':1,'interrupted_count':0},postcondition={'df_delta_bytes':0,'freed_bytes':0})\n"
                "PY\n"
            )
            adapter.chmod(0o755)
            state = root / "state"
            state.mkdir()
            fake_df = root / "df"
            fake_df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                               "echo '/dev/test 999999 1 500000 1% /'\n")
            fake_df.chmod(0o755)
            prior_df = os.environ.get("DISK_MAGICIAN_DF_BIN")
            prior_state = os.environ.get("DISK_MAGICIAN_STATE_DIR")
            os.environ["DISK_MAGICIAN_DF_BIN"] = str(fake_df)
            os.environ["DISK_MAGICIAN_STATE_DIR"] = str(state)
            try:
                schedule = {"schema": 1, "classes": {}}
                now = time.time()
                disk_budget.dispatch_actuators(
                    scripts, state,
                    {"classes": {"tmp_containers": {"act": "tmp_containers",
                     "trigger": "overage", "budget_gb": 1, "unit_budget_s": 10}}},
                    {"classes": {"tmp_containers": {"used_gb": 2, "measured_at": now}}},
                    "RED", now, time.monotonic() + 200, schedule,
                )
            finally:
                if prior_df is None: os.environ.pop("DISK_MAGICIAN_DF_BIN", None)
                else: os.environ["DISK_MAGICIAN_DF_BIN"] = prior_df
                if prior_state is None: os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
                else: os.environ["DISK_MAGICIAN_STATE_DIR"] = prior_state
            passed_args = json.loads(args_log.read_text())
            self.assertIn("--deadline-at", passed_args)
            self.assertIn("--cursor", passed_args)
            self.assertTrue((state / "cursor_tmp_containers.json").exists() is False)
            receipt = disk_budget._receipt_data(state, "govern_tmp_containers")
            self.assertEqual(receipt["outcome"], "success")
            self.assertEqual(receipt["candidates"]["removed_count"], 2)
            self.assertEqual(receipt["candidates"]["deferred_count"], 1)
            self.assertEqual(receipt["postcondition"]["df_delta_bytes"], 0)

    def test_three_tick_deferred_actuator_gets_exclusive_300_second_slice(self):
        schedule = {"classes": {"stuck": {"deferred_ticks": 3}}}
        row, _ = disk_budget.next_actuator(
            [{"class": "stuck", "unit_budget_s": 20}],
            schedule, 10, 0, 600, "RED"
        )
        self.assertEqual(row["class"], "stuck")
        self.assertEqual(row["slice_s"], 300)

    def test_three_empty_measurements_trigger_exclusive_slice_and_progress_resets(self):
        schedule = {"schema": 1, "classes": {}}
        for tick in range(3):
            disk_budget.record_actuator_result(
                schedule, "scratch", 100 + tick, completed=True, df_delta_bytes=0
            )
        row, _ = disk_budget.next_actuator(
            [{"class": "scratch", "unit_budget_s": 20}],
            schedule, 104, 0, 500, "RED"
        )
        self.assertEqual(row["slice_s"], 300)
        disk_budget.record_actuator_result(
            schedule, "scratch", 105, completed=True, df_delta_bytes=1024
        )
        self.assertEqual(schedule["classes"]["scratch"]["no_progress_ticks"], 0)

    def test_interrupted_unit_is_marked_incomplete_not_as_progress(self):
        schedule = {"schema": 1, "classes": {}}
        disk_budget.record_actuator_result(
            schedule, "tmp", 100, completed=False, df_delta_bytes=None,
            hard_stop=True, orphan_survivors=True
        )
        result = schedule["classes"]["tmp"]
        self.assertEqual(result["no_progress_ticks"], 1)
        self.assertTrue(result["last_interrupted"])
        self.assertTrue(result["last_hard_stop"])
        self.assertTrue(result["last_orphan_survivors"])

    def test_black_orders_by_seven_day_delta_after_deferral_priority(self):
        eligible = [{"class": "small", "unit_budget_s": 20, "df_delta_7d": 2},
                    {"class": "large", "unit_budget_s": 20, "df_delta_7d": 8}]
        schedule = {"classes": {}}
        row, _ = disk_budget.next_actuator(eligible, schedule, 10, 0, 600, "BLACK")
        self.assertEqual(row["class"], "large")

    def test_atomic_adapter_requires_declared_runtime_and_full_slice(self):
        eligible = [{"class": "db", "kind": "atomic", "unit_budget_s": 20,
                     "max_runtime_s": 180}]
        schedule = {"classes": {}}
        row, deferred = disk_budget.next_actuator(eligible, schedule, 10, 0, 200, "RED")
        self.assertIsNone(row)
        self.assertEqual(deferred, ["db"])
        row, deferred = disk_budget.next_actuator(eligible, schedule, 10, 0, 300, "RED")
        self.assertEqual(deferred, [])
        self.assertEqual(row["class"], "db")
        self.assertGreaterEqual(row["slice_s"], 180)

    def test_atomic_adapter_reserves_term_grace_beyond_declared_runtime(self):
        eligible = [{"class": "db", "kind": "atomic", "unit_budget_s": 20,
                     "max_runtime_s": 180}]
        row, deferred = disk_budget.next_actuator(
            eligible, {"classes": {}}, 10, 0, 250, "RED"
        )
        self.assertEqual(deferred, [])
        self.assertEqual(row["slice_s"], 190)

    def test_supervisor_kills_grandchild_when_adapter_leader_exits(self):
        child_code = "import time; time.sleep(60)"
        parent_code = (
            "import subprocess,sys; "
            "p=subprocess.Popen([sys.executable,'-c',sys.argv[1]]); "
            "import os; print(p.pid, os.getpgrp(), flush=True)"
        )
        result = disk_budget.supervise_actuator(
            [sys.executable, "-c", parent_code, child_code],
            time.monotonic() + 5, term_grace=2,
        )
        self.assertEqual(result["rc"], 0)
        self.assertFalse(result["orphan_survivors"])
        child_pid, pgid = map(int, result["output"].split())
        self.assertFalse(disk_budget._process_group_has_live_members(pgid))


if __name__ == "__main__":
    unittest.main()

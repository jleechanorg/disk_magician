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
            self.assertEqual(schedule["deferred_queue"], ["tmp_containers"])
            self.assertTrue(schedule["classes"]["tmp_containers"]["last_interrupted"])

    def test_blocked_safety_adapter_outcome_and_reason_survive_govern_wrapping(self):
        import job_receipt
        with tempfile.TemporaryDirectory(prefix="govern-blocked-receipt-") as tmp:
            store = job_receipt.JobReceiptStore(state_dir=tmp)
            run_id = store.begin("cleanup_codex_db", trigger="act")
            adapter = store.finish(
                "cleanup_codex_db", run_id=run_id, outcome="blocked_safety",
                reason="live-owner",
                candidates={"removed_count": 0, "deferred_count": 0, "interrupted_count": 0},
                postcondition={"df_delta_bytes": 0, "freed_bytes": 0},
            )
            metrics = disk_budget._write_govern_receipt(
                Path(tmp), "claude_codex_state",
                {"rc": 0, "hard_stop": False, "orphan_survivors": False},
                100, 100, adapter,
            )
            wrapped = disk_budget._receipt_data(tmp, "govern_claude_codex_state")
            self.assertEqual(metrics["outcome"], "blocked_safety")
            self.assertEqual(metrics["reason"], "live-owner")
            self.assertEqual(wrapped["outcome"], "blocked_safety")
            self.assertEqual(wrapped["reason"], "live-owner")

    def test_skipped_lock_adapter_outcome_without_counts_survives_govern_wrapping(self):
        import job_receipt
        with tempfile.TemporaryDirectory(prefix="govern-skipped-lock-receipt-") as tmp:
            store = job_receipt.JobReceiptStore(state_dir=tmp)
            run_id = store.begin("worktree_reap", trigger="govern")
            adapter = store.finish(
                "worktree_reap", run_id=run_id, outcome="skipped_lock",
                reason="lock held",
                lock={"held": True},
            )
            metrics = disk_budget._write_govern_receipt(
                Path(tmp), "worktrees",
                {"rc": 0, "hard_stop": False, "orphan_survivors": False},
                100, 100, adapter,
            )
            wrapped = disk_budget._receipt_data(tmp, "govern_worktrees")
            self.assertEqual(metrics["outcome"], "skipped_lock")
            self.assertEqual(metrics["reason"], "lock held")
            self.assertEqual(wrapped["outcome"], "skipped_lock")
            self.assertEqual(wrapped["reason"], "lock held")

    def test_large_cursor_exceeding_arg_max_saves_and_loads_via_stdin(self):
        import subprocess
        root = Path(__file__).resolve().parent.parent
        helper = root / "scripts" / "lib" / "actuator_deadline.sh"
        with tempfile.TemporaryDirectory(prefix="govern-large-cursor-") as tmp:
            cursor_file = Path(tmp) / "cursor_worktrees.json"
            items = [f"/Users/test/.disk_magician_state/worktree_leases/{i:064x}.json" for i in range(17000)]
            items_json = json.dumps(items, separators=(",", ":"))
            self.assertGreater(len(items_json), 1_200_000)
            items_file = Path(tmp) / "items.json"
            items_file.write_text(items_json, encoding="utf-8")
            proc = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    'source "$1"; items="$(cat "$2")"; act_cursor_save "$3" "worktree_reap:remove" "$items" 42 && loaded="$(act_cursor_load "$3" "worktree_reap:remove")" && printf "%s" "$loaded" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\'next_index\']==42 and len(d[\'items\'])==17000"',
                    "_",
                    str(helper),
                    str(items_file),
                    str(cursor_file),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_govern_wrapper_copies_adapter_c14_bytes_without_double_counting(self):
        import subprocess
        import job_receipt
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="govern-c14-") as tmp:
            state = Path(tmp)
            inv = state / "inv.json"
            inv.write_text(json.dumps([{"type": "file", "size": 1300}]))
            ledger = state / "adapter-ledger.jsonl"
            subprocess.run([sys.executable, str(root / "scripts" / "c14_probe.py"), "account",
                            str(inv), str(ledger), "unproven-content"], check=True, capture_output=True)
            store = job_receipt.JobReceiptStore(state_dir=tmp)
            run = store.begin("cleanup_codex_db", trigger="act")
            saved = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
            os.environ["DISK_MAGICIAN_C14_LEDGER"] = str(ledger)
            try:
                adapter = store.finish("cleanup_codex_db", run_id=run, outcome="success",
                                       candidates={"removed_count": 1, "deferred_count": 0,
                                                   "interrupted_count": 0},
                                       postcondition={"df_delta_bytes": 0, "freed_bytes": 0})
            finally:
                if saved is None: os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
                else: os.environ["DISK_MAGICIAN_C14_LEDGER"] = saved
            self.assertEqual(adapter["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})
            # Govern still holds the shared per-class ledger; it must copy the
            # adapter's folded bytes, not re-fold them (which would double to 2600).
            saved = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
            saved_owner = os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
            os.environ["DISK_MAGICIAN_C14_LEDGER"] = str(ledger)
            os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = "cleanup_codex_db"
            try:
                metrics = disk_budget._write_govern_receipt(
                    state, "claude_codex_state",
                    {"rc": 0, "hard_stop": False, "orphan_survivors": False}, 100, 100, adapter)
            finally:
                if saved is None: os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
                else: os.environ["DISK_MAGICIAN_C14_LEDGER"] = saved
                if saved_owner is not None: os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = saved_owner
            self.assertEqual(metrics["outcome"], "success")
            wrapped = disk_budget._receipt_data(state, "govern_claude_codex_state")
            self.assertEqual(wrapped["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})
            self.assertEqual(wrapped["postcondition"]["c14_ledger_status"], "ok")

    def test_dispatch_assigns_per_run_ledgers_and_copies_owner_c14_once(self):
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="govern-ledger-scope-") as tmp:
            base = Path(tmp)
            scripts = base / "scripts"
            (scripts / "lib").mkdir(parents=True)
            (scripts / "job_receipt.py").write_text(
                (Path(disk_budget.__file__).parent / "job_receipt.py").read_text())
            (scripts / "lib" / "artifact_verdict.sh").write_text(
                'artifact_removal_verdict() { [[ "$1" == --self-test ]] && echo ok; }\n')
            log = base / "dispatch.jsonl"
            probe = str(root / "scripts" / "c14_probe.py")
            for fname, job in (("cleanup_tmp.sh", "cleanup_tmp"),
                               ("tmp_scratch_sweep.sh", "tmp_scratch_sweep")):
                (scripts / f"{job}_stub.py").write_text(
                    "import json, os, subprocess, sys\n"
                    "script_dir = os.path.dirname(os.path.abspath(__file__))\n"
                    "sys.path.insert(0, script_dir)\n"
                    "import job_receipt\n"
                    f"job = {job!r}\n"
                    "with open(os.environ['C14_DISPATCH_LOG'], 'a') as f:\n"
                    "    f.write(json.dumps({'job': job, 'ledger': os.environ.get('DISK_MAGICIAN_C14_LEDGER'),\n"
                    "                        'owner': os.environ.get('DISK_MAGICIAN_C14_LEDGER_OWNER')}) + '\\n')\n"
                    "inv = os.path.join(script_dir, 'inv-' + job + '.json')\n"
                    "with open(inv, 'w') as f: f.write(json.dumps([{'type': 'file', 'size': 1300}]))\n"
                    "subprocess.run([sys.executable, os.environ['C14_PROBE'], 'account', inv,\n"
                    "                os.environ['DISK_MAGICIAN_C14_LEDGER'], 'unproven-content'], check=True)\n"
                    "store = job_receipt.JobReceiptStore(state_dir=os.environ['DISK_MAGICIAN_STATE_DIR'])\n"
                    "run = store.begin(job, trigger='act')\n"
                    "store.finish(job, run_id=run, outcome='success',\n"
                    "             candidates={'removed_count': 1, 'deferred_count': 0, 'interrupted_count': 0},\n"
                    "             postcondition={'df_delta_bytes': 0, 'freed_bytes': 0})\n"
                    "nested = store.begin('nested_child', trigger='act')\n"
                    "store.finish('nested_child', run_id=nested, outcome='success_noop')\n")
                (scripts / fname).write_text(
                    "#!/bin/bash\n"
                    f'exec python3 "$(dirname "$0")/{job}_stub.py" "$@"\n')
                (scripts / fname).chmod(0o755)
            state = base / "state"
            state.mkdir()
            stale = base / "stale.jsonl"
            stale.write_text(json.dumps({"at": 1, "reason": "stale", "bytes": 999999}) + "\n")
            fake_df = base / "df"
            fake_df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                               "echo '/dev/test 999999 1 500000 1% /'\n")
            fake_df.chmod(0o755)
            budgets = {"classes": {
                "tmp_containers": {"act": "tmp_containers", "trigger": "always", "unit_budget_s": 10},
                "tmpdir_scratch": {"act": "tmpdir_scratch", "trigger": "always", "unit_budget_s": 10}}}
            saved = {k: os.environ.get(k) for k in ("DISK_MAGICIAN_DF_BIN", "DISK_MAGICIAN_STATE_DIR",
                     "DISK_MAGICIAN_C14_LEDGER", "DISK_MAGICIAN_C14_LEDGER_OWNER",
                     "C14_DISPATCH_LOG", "C14_PROBE")}
            os.environ["DISK_MAGICIAN_DF_BIN"] = str(fake_df)
            os.environ["DISK_MAGICIAN_STATE_DIR"] = str(state)
            os.environ["DISK_MAGICIAN_C14_LEDGER"] = str(stale)
            os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
            os.environ["C14_DISPATCH_LOG"] = str(log)
            os.environ["C14_PROBE"] = probe
            try:
                for _ in range(2):
                    disk_budget.dispatch_actuators(
                        scripts, state, budgets, {"classes": {}}, "RED",
                        time.time(), time.monotonic() + 200, {"schema": 1, "classes": {}})
            finally:
                for k, v in saved.items():
                    if v is None: os.environ.pop(k, None)
                    else: os.environ[k] = v
            records = [json.loads(l) for l in log.read_text().splitlines()]
            self.assertEqual(len(records), 4)
            self.assertEqual({r["job"] for r in records}, {"cleanup_tmp", "tmp_scratch_sweep"})
            for r in records: self.assertEqual(r["owner"], r["job"])
            self.assertEqual(len({r["ledger"] for r in records}), 4)  # distinct per run/class
            for job in ("cleanup_tmp", "tmp_scratch_sweep"):
                rec = disk_budget._receipt_data(state, job)
                self.assertEqual(rec["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})
                self.assertEqual(rec["postcondition"]["c14_ledger_status"], "ok")
            nested = disk_budget._receipt_data(state, "nested_child")
            self.assertNotIn("c14_kept_bytes", nested["postcondition"])
            for name in ("govern_tmp_containers", "govern_tmpdir_scratch"):
                gov = disk_budget._receipt_data(state, name)
                self.assertEqual(gov["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})
                self.assertEqual(gov["postcondition"]["c14_ledger_status"], "ok")
                self.assertNotIn("stale", gov["postcondition"]["c14_kept_bytes"])

    def test_dispatch_preserves_keeps_when_owner_terminal_absent(self):
        import subprocess
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="govern-no-terminal-") as tmp:
            base = Path(tmp)
            scripts = base / "scripts"
            (scripts / "lib").mkdir(parents=True)
            (scripts / "job_receipt.py").write_text(
                (Path(disk_budget.__file__).parent / "job_receipt.py").read_text())
            (scripts / "lib" / "artifact_verdict.sh").write_text(
                'artifact_removal_verdict() { [[ "$1" == --self-test ]] && echo ok; }\n')
            (scripts / "cleanup_tmp.sh").write_text("#!/bin/bash\ntrue\n")
            (scripts / "cleanup_tmp.sh").chmod(0o755)
            state = base / "state"
            state.mkdir()
            fake_df = base / "df"
            fake_df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                               "echo '/dev/test 999999 1 500000 1% /'\n")
            fake_df.chmod(0o755)
            ledgers = []

            def fake_supervise(command, slice_end):
                ledger = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
                ledgers.append(ledger)
                inv = base / "inv.json"
                inv.write_text(json.dumps([{"type": "file", "size": 777}]))
                subprocess.run([sys.executable, str(root / "scripts" / "c14_probe.py"), "account",
                                str(inv), ledger, "unproven-content"], check=True, capture_output=True)
                return {"rc": 1, "output": "boom", "hard_stop": False, "orphan_survivors": False}

            saved = {k: os.environ.get(k) for k in ("DISK_MAGICIAN_DF_BIN", "DISK_MAGICIAN_STATE_DIR")}
            os.environ["DISK_MAGICIAN_DF_BIN"] = str(fake_df)
            os.environ["DISK_MAGICIAN_STATE_DIR"] = str(state)
            original = disk_budget.supervise_actuator
            disk_budget.supervise_actuator = fake_supervise
            try:
                disk_budget.dispatch_actuators(
                    scripts, state,
                    {"classes": {"tmp_containers": {"act": "tmp_containers", "trigger": "always",
                     "unit_budget_s": 10}}},
                    {"classes": {}}, "RED", time.time(), time.monotonic() + 200, {"schema": 1, "classes": {}})
            finally:
                disk_budget.supervise_actuator = original
                for k, v in saved.items():
                    if v is None: os.environ.pop(k, None)
                    else: os.environ[k] = v
            gov = disk_budget._receipt_data(state, "govern_tmp_containers")
            self.assertEqual(gov["outcome"], "error")
            self.assertEqual(gov["postcondition"]["c14_kept_bytes"], {"unproven-content": 777})
            self.assertEqual(gov["postcondition"]["c14_ledger_status"], "incomplete")
            self.assertEqual(gov["postcondition"]["c14_ledger_source"], "owner_terminal_absent")
            self.assertEqual(len(ledgers), 1)
            self.assertFalse(os.path.exists(ledgers[0]))

    def test_dispatch_retains_scoped_ledger_when_govern_persist_raises(self):
        import subprocess
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="govern-persist-fail-") as tmp:
            base = Path(tmp)
            scripts = base / "scripts"
            (scripts / "lib").mkdir(parents=True)
            (scripts / "job_receipt.py").write_text(
                (Path(disk_budget.__file__).parent / "job_receipt.py").read_text())
            (scripts / "lib" / "artifact_verdict.sh").write_text(
                'artifact_removal_verdict() { [[ "$1" == --self-test ]] && echo ok; }\n')
            (scripts / "cleanup_tmp.sh").write_text("#!/bin/bash\ntrue\n")
            (scripts / "cleanup_tmp.sh").chmod(0o755)
            state = base / "state"; state.mkdir()
            fake_df = base / "df"
            fake_df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                               "echo '/dev/test 999999 1 500000 1% /'\n")
            fake_df.chmod(0o755)
            ledgers = []

            def fake_supervise(command, slice_end):
                ledger = os.environ.get("DISK_MAGICIAN_C14_LEDGER")
                ledgers.append(ledger)
                inv = base / "inv.json"
                inv.write_text(json.dumps([{"type": "file", "size": 42}]))
                subprocess.run([sys.executable, str(root / "scripts" / "c14_probe.py"), "account",
                                str(inv), ledger, "unproven-content"], check=True, capture_output=True)
                return {"rc": 1, "output": "boom", "hard_stop": False, "orphan_survivors": False}

            saved = {k: os.environ.get(k) for k in ("DISK_MAGICIAN_DF_BIN", "DISK_MAGICIAN_STATE_DIR")}
            os.environ["DISK_MAGICIAN_DF_BIN"] = str(fake_df)
            os.environ["DISK_MAGICIAN_STATE_DIR"] = str(state)
            original_sup = disk_budget.supervise_actuator
            original_write = disk_budget._write_govern_receipt
            disk_budget.supervise_actuator = fake_supervise

            def boom(*args, **kwargs):
                raise RuntimeError("govern persist failed")

            disk_budget._write_govern_receipt = boom
            try:
                with self.assertRaises(RuntimeError):
                    disk_budget.dispatch_actuators(
                        scripts, state,
                        {"classes": {"tmp_containers": {"act": "tmp_containers", "trigger": "always",
                         "unit_budget_s": 10}}},
                        {"classes": {}}, "RED", time.time(), time.monotonic() + 200,
                        {"schema": 1, "classes": {}})
            finally:
                disk_budget.supervise_actuator = original_sup
                disk_budget._write_govern_receipt = original_write
                for k, v in saved.items():
                    if v is None: os.environ.pop(k, None)
                    else: os.environ[k] = v
            # Terminal govern persistence raised, so the raw scoped ledger must
            # survive for recovery rather than being unlinked.
            self.assertEqual(len(ledgers), 1)
            self.assertTrue(os.path.exists(ledgers[0]))
            os.unlink(ledgers[0])

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

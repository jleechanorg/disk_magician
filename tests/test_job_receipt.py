#!/usr/bin/env python3
"""tests/test_job_receipt.py — Tests for atomic typed job receipts."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts directory to sys.path
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import job_receipt


class TestJobReceipt(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="dm_receipt_test_")
        self.state_dir = os.path.join(self.test_dir, "state")
        os.makedirs(self.state_dir, exist_ok=True)
        os.environ["DISK_MAGICIAN_STATE_DIR"] = self.state_dir

    def tearDown(self):
        if "DISK_MAGICIAN_STATE_DIR" in os.environ:
            del os.environ["DISK_MAGICIAN_STATE_DIR"]
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_started_without_terminal_remains_unknown(self):
        receipt_store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = receipt_store.begin(
            job="snapshot_commit",
            trigger="scheduled",
            precondition={"free_gb": 45},
        )
        self.assertTrue(run_id)

        data = receipt_store.read("snapshot_commit")
        self.assertEqual(data["job"], "snapshot_commit")
        self.assertEqual(len(data["active"]), 1)
        active_run = data["active"][0]
        self.assertEqual(active_run["id"], run_id)
        self.assertEqual(active_run["run_id"], run_id)
        self.assertEqual(active_run["outcome"], "unknown")
        self.assertIsNone(active_run["postcondition"]["freed_bytes"])
        self.assertIsNone(data["last_success"])
        self.assertIsNone(data["last_terminal"])

    def test_all_seven_terminal_outcomes(self):
        allowed_outcomes = [
            "skipped_lock",
            "skipped_threshold",
            "blocked_safety",
            "error",
            "timeout",
            "success_noop",
            "success",
        ]
        for outcome in allowed_outcomes:
            sub_dir = os.path.join(self.test_dir, f"state_{outcome}")
            store = job_receipt.JobReceiptStore(state_dir=sub_dir)
            run_id = store.begin(job="test_job", trigger="manual")
            rec = store.finish(
                job="test_job",
                run_id=run_id,
                outcome=outcome,
                reason=f"testing {outcome}",
                postcondition={"freed_bytes": None},
            )
            self.assertEqual(rec["outcome"], outcome)
            self.assertEqual(rec["id"], run_id)
            read_data = store.read("test_job")
            self.assertEqual(len(read_data["active"]), 0)
            self.assertIsNotNone(read_data["last_terminal"])
            self.assertEqual(read_data["last_terminal"]["outcome"], outcome)

            if outcome in ("success", "success_noop"):
                self.assertIsNotNone(read_data["last_success"])
                self.assertEqual(read_data["last_success"]["id"], run_id)
            else:
                self.assertIsNone(read_data["last_success"])

            if outcome in ("skipped_lock", "skipped_threshold"):
                self.assertIsNotNone(read_data["last_skipped"])
                self.assertEqual(read_data["last_skipped"]["id"], run_id)

    def test_invalid_outcome_rejected(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = store.begin(job="test_job")
        with self.assertRaises(ValueError):
            store.finish(job="test_job", run_id=run_id, outcome="partial_success")
        with self.assertRaises(ValueError):
            store.finish(job="test_job", run_id=run_id, outcome="failed")
        with self.assertRaises(ValueError):
            store.finish(job="test_job", run_id=run_id, outcome="unknown")

    def test_freed_unknown_null_never_fake_zero(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = store.begin(job="test_job")
        # Do not specify freed_bytes; must default to None / null, never 0
        rec = store.finish(job="test_job", run_id=run_id, outcome="success")
        self.assertIsNone(rec["postcondition"]["freed_bytes"])

        data = store.read("test_job")
        self.assertIsNone(data["last_success"]["postcondition"]["freed_bytes"])

        # Also when explicitly passing None
        run_id2 = store.begin(job="test_job")
        rec2 = store.finish(
            job="test_job",
            run_id=run_id2,
            outcome="success_noop",
            postcondition={"freed_bytes": None},
        )
        self.assertIsNone(rec2["postcondition"]["freed_bytes"])

    def test_independent_active_last_success_and_skipped_identity(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)

        # 1. Successful run completes
        run1 = store.begin(job="sweep", trigger="scheduled")
        store.finish(job="sweep", run_id=run1, outcome="success", postcondition={"freed_bytes": 1024})
        data = store.read("sweep")
        self.assertEqual(data["last_success"]["id"], run1)
        self.assertEqual(data["last_success"]["postcondition"]["freed_bytes"], 1024)

        # 2. Writer starts
        writer_run = store.begin(job="sweep", trigger="scheduled")
        data = store.read("sweep")
        self.assertEqual(len(data["active"]), 1)
        self.assertEqual(data["active"][0]["id"], writer_run)

        # 3. Contender attempts to run, hits lock, records skipped_lock
        # Contender does not provide run_id or begins/finishes its own skip
        contender_rec = store.record_skip(
            job="sweep",
            outcome="skipped_lock",
            reason="lock held by writer",
            lock={"held": True, "reason": "lock held by writer"},
        )
        self.assertTrue(contender_rec["id"])
        self.assertNotEqual(contender_rec["id"], writer_run)
        self.assertEqual(contender_rec["outcome"], "skipped_lock")

        # 4. Assert writer's active record and prior last_success are preserved intact
        data = store.read("sweep")
        self.assertEqual(len(data["active"]), 1)
        self.assertEqual(data["active"][0]["id"], writer_run)
        self.assertEqual(data["active"][0]["outcome"], "unknown")
        self.assertEqual(data["last_success"]["id"], run1)
        self.assertEqual(data["last_skipped"]["id"], contender_rec["id"])
        self.assertEqual(data["last_terminal"]["id"], contender_rec["id"])

        # 5. Writer finishes successfully
        store.finish(job="sweep", run_id=writer_run, outcome="success")
        data = store.read("sweep")
        self.assertEqual(len(data["active"]), 0)
        self.assertEqual(data["last_success"]["id"], writer_run)
        self.assertEqual(data["last_skipped"]["id"], contender_rec["id"])

    def test_bounded_retention_completed_and_active(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)

        # Test active capped at <= 2
        r1 = store.begin(job="job_retention")
        r2 = store.begin(job="job_retention")
        r3 = store.begin(job="job_retention")
        data = store.read("job_retention")
        self.assertLessEqual(len(data["active"]), 2)
        active_ids = [a["id"] for a in data["active"]]
        self.assertIn(r3, active_ids)
        self.assertIn(r2, active_ids)
        self.assertNotIn(r1, active_ids)

        # Test completed capped at <= 64
        for i in range(70):
            store.record_skip(
                job="job_retention",
                outcome="skipped_threshold",
                reason=f"skip {i}",
            )
        data = store.read("job_retention")
        self.assertEqual(len(data["completed"]), 64)
        # Most recent skip should be at the end
        self.assertEqual(data["completed"][-1]["reason"], "skip 69")

    def test_receipt_required_fields_and_types(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = store.begin(
            job="full_spec_job",
            trigger="scheduled",
            revision="abc1234",
            precondition={"free_gb": 20},
        )
        rec = store.finish(
            job="full_spec_job",
            run_id=run_id,
            outcome="success",
            lock={"held": False, "acquired": True},
            safety={"status": "safe", "reason": "preflight passed"},
            candidates={"count": 5, "bytes": None},
            postcondition={"free_gb": 25, "freed_bytes": None},
            publication={"committed": True, "pushed": True, "status": "published"},
        )

        expected_fields = [
            "schema_version",
            "id",
            "job",
            "run",
            "times",
            "installed_revision",
            "trigger",
            "outcome",
            "lock",
            "safety",
            "candidates",
            "precondition",
            "postcondition",
            "publication",
        ]
        for field in expected_fields:
            self.assertIn(field, rec, f"Missing required field {field}")

        self.assertEqual(rec["schema_version"], 1)
        self.assertEqual(rec["id"], run_id)
        self.assertEqual(rec["job"], "full_spec_job")
        self.assertIn("started_at", rec["times"])
        self.assertIn("ended_at", rec["times"])
        self.assertIn("duration_seconds", rec["times"])
        self.assertIsInstance(rec["times"]["duration_seconds"], (int, float))
        self.assertEqual(rec["installed_revision"], "abc1234")
        self.assertEqual(rec["trigger"], "scheduled")
        self.assertEqual(rec["outcome"], "success")

    def test_cli_helper_begin_finish_read(self):
        cli = str(SCRIPTS_DIR / "job_receipt.py")

        # 1. begin
        p_begin = subprocess.run(
            [sys.executable, cli, "begin", "--job", "cli_job", "--trigger", "cli_test"],
            capture_output=True,
            text=True,
            env={**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir},
        )
        self.assertEqual(p_begin.returncode, 0, p_begin.stderr)
        run_id = p_begin.stdout.strip()
        self.assertTrue(run_id)

        # 2. read while active
        p_read_active = subprocess.run(
            [sys.executable, cli, "read", "--job", "cli_job"],
            capture_output=True,
            text=True,
            env={**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir},
        )
        self.assertEqual(p_read_active.returncode, 0)
        data = json.loads(p_read_active.stdout)
        self.assertEqual(len(data["active"]), 1)
        self.assertEqual(data["active"][0]["id"], run_id)

        # 3. finish
        p_finish = subprocess.run(
            [
                sys.executable,
                cli,
                "finish",
                "--job",
                "cli_job",
                "--run-id",
                run_id,
                "--outcome",
                "success_noop",
                "--reason",
                "cli finished",
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir},
        )
        self.assertEqual(p_finish.returncode, 0, p_finish.stderr)

        # 4. read completed
        p_read_done = subprocess.run(
            [sys.executable, cli, "read", "--job", "cli_job", "--last"],
            capture_output=True,
            text=True,
            env={**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir},
        )
        self.assertEqual(p_read_done.returncode, 0)
        last_rec = json.loads(p_read_done.stdout)
        self.assertEqual(last_rec["id"], run_id)
        self.assertEqual(last_rec["outcome"], "success_noop")


if __name__ == "__main__":
    unittest.main()

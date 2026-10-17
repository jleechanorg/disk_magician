#!/usr/bin/env python3
"""tests/test_job_receipt.py — Tests for atomic typed job receipts."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

# Add scripts directory to sys.path
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import job_receipt


class TestJobReceipt(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="dm_receipt_test_")
        self.state_dir = os.path.join(self.test_dir, "state")
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
        self.assertEqual(data["completed"][-1]["reason"], "skip 69")

    def test_clear_stale_active_on_begin_and_finish(self):
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        stale_id = store.begin(job="exclusive_job", trigger="scheduled")
        self.assertEqual(job_receipt.get_effective_outcome("exclusive_job", state_dir=self.state_dir), "unknown")

        # Starting a new exclusive run with clear_stale_active=True drops orphaned active entries
        fresh_id = store.begin(job="exclusive_job", trigger="scheduled", clear_stale_active=True)
        data = store.read("exclusive_job")
        self.assertEqual([a["id"] for a in data["active"]], [fresh_id])
        self.assertNotIn(stale_id, [a["id"] for a in data["active"]])
        store.finish(job="exclusive_job", run_id=fresh_id, outcome="success")
        self.assertEqual(job_receipt.get_effective_outcome("exclusive_job", state_dir=self.state_dir), "success")

        # Also verify finish(..., clear_stale_active=True) clears older orphaned active entries
        orphan_id = store.begin(job="reap_job", trigger="scheduled")
        holder_id = store.begin(job="reap_job", trigger="scheduled")
        store.finish(job="reap_job", run_id=holder_id, outcome="success_noop", clear_stale_active=True)
        reap_data = store.read("reap_job")
        self.assertEqual(reap_data["active"], [])
        self.assertNotIn(orphan_id, [a["id"] for a in reap_data["active"]])
        self.assertEqual(job_receipt.get_effective_outcome("reap_job", state_dir=self.state_dir), "success_noop")

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
            "identity",
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
        self.assertIsNone(rec["installed_revision"])
        self.assertEqual(rec["trigger"], "scheduled")
        self.assertEqual(rec["outcome"], "success")

    def test_cli_helper_begin_finish_read(self):
        cli = str(SCRIPTS_DIR / "job_receipt.py")

        p_begin = subprocess.run(
            [sys.executable, cli, "begin", "--job", "cli_job", "--trigger", "cli_test"],
            capture_output=True,
            text=True,
            env={**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir},
        )
        self.assertEqual(p_begin.returncode, 0, p_begin.stderr)
        run_id = p_begin.stdout.strip()
        self.assertTrue(run_id)

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

    # --- Review Corrections Reproduction Tests ---

    def test_read_does_not_touch_disk_or_create_dirs_locks(self):
        """Review item 1: read must not create directory or lock files."""
        fresh_state = os.path.join(self.test_dir, "nonexistent_state")
        store = job_receipt.JobReceiptStore(state_dir=fresh_state)

        # Before read on absent state
        self.assertFalse(os.path.exists(fresh_state))
        data = store.read("snapshot_commit")
        self.assertEqual(data["job"], "snapshot_commit")
        self.assertEqual(data["completed"], [])
        self.assertEqual(data["active"], [])
        # Must STILL not exist
        self.assertFalse(os.path.exists(fresh_state))

        # Now test with existing state: writing one job then reading it must not create lock files
        run_id = store.begin("writer_job")
        store.finish("writer_job", run_id=run_id, outcome="success")
        receipt_file = os.path.join(fresh_state, "receipts", "writer_job.json")
        self.assertTrue(os.path.exists(receipt_file))
        mtime_before = os.path.getmtime(receipt_file)
        files_before = set(os.listdir(os.path.join(fresh_state, "receipts")))

        # Read should not modify file or leave lock file
        read_res = store.read("writer_job")
        self.assertEqual(read_res["last_terminal"]["id"], run_id)
        mtime_after = os.path.getmtime(receipt_file)
        files_after = set(os.listdir(os.path.join(fresh_state, "receipts")))

        self.assertEqual(mtime_before, mtime_after)
        # Lock file should NOT be created by read
        self.assertNotIn("writer_job.lock", files_after - files_before)

    def test_corrupt_existing_receipt_fails_closed_and_preserves_bytes(self):
        """Review item 2: corrupt json must raise error and not be overwritten."""
        receipts_dir = os.path.join(self.state_dir, "receipts")
        os.makedirs(receipts_dir, exist_ok=True)
        corrupt_file = os.path.join(receipts_dir, "corrupt_job.json")
        bad_bytes = b"{\n  \"schema_version\": 1,\n  \"job\": \"corrupt_job\",\n  [malformed json"
        with open(corrupt_file, "wb") as f:
            f.write(bad_bytes)

        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        with self.assertRaises(ValueError):
            store.read("corrupt_job")

        with self.assertRaises(ValueError):
            store.begin("corrupt_job")

        with self.assertRaises(ValueError):
            store.record_skip("corrupt_job", outcome="skipped_lock")

        # Verify exact bytes preserved
        with open(corrupt_file, "rb") as f:
            self.assertEqual(f.read(), bad_bytes)

    def test_finish_requires_active_matching_identity(self):
        """Review item 3: finish with unstarted arbitrary run_id must be rejected."""
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        with self.assertRaises(ValueError):
            store.finish("test_job", run_id="arbitrary-unstarted-id", outcome="success")

        # record_skip must reject success
        with self.assertRaises(ValueError):
            store.record_skip("test_job", outcome="success")

    def test_duration_validates_order_and_format(self):
        """Review item 4: compute_duration_seconds must validate timestamps and reject inverted order."""
        t1 = "2026-10-03T12:00:00Z"
        t2 = "2026-10-03T12:01:00Z"
        # t1 to t2 is 60s
        self.assertEqual(job_receipt.compute_duration_seconds(t1, t2), 60.0)

        # Inverted order should raise ValueError (not silently return 0.0)
        with self.assertRaises(ValueError):
            job_receipt.compute_duration_seconds(t2, t1)

        # Bad format should raise ValueError
        with self.assertRaises(ValueError):
            job_receipt.compute_duration_seconds("not-a-time", t2)

    def test_atomic_replace_failure_preserves_original(self):
        """Review item 5: failed os.replace leaves original receipt intact with no leftover temp files."""
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run1 = store.begin("atomic_job")
        store.finish("atomic_job", run_id=run1, outcome="success")
        receipt_file = os.path.join(self.state_dir, "receipts", "atomic_job.json")
        run2 = store.begin("atomic_job")
        with open(receipt_file, "rb") as f:
            original_bytes = f.read()

        with patch("os.replace", side_effect=OSError("Disk write failed")):
            with self.assertRaises(OSError):
                store.finish("atomic_job", run_id=run2, outcome="success")

        # Original bytes must be byte-identical
        with open(receipt_file, "rb") as f:
            self.assertEqual(f.read(), original_bytes)

        # No tmp files left in receipts directory
        receipts_dir = os.path.join(self.state_dir, "receipts")
        temp_files = [fn for fn in os.listdir(receipts_dir) if fn.endswith(".tmp")]
        self.assertEqual(temp_files, [])

    def test_job_name_validation(self):
        """Review item 5: reject invalid job names."""
        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        invalid_names = ["", "../escape", "/root", "foo/bar", "foo\\bar", "..", "."]
        for name in invalid_names:
            with self.assertRaises(ValueError):
                store.begin(name)
            with self.assertRaises(ValueError):
                store.read(name)

    def test_parse_json_arg_validation(self):
        """Review item 2: _parse_json_arg must reject invalid/non-dict inputs."""
        with self.assertRaises(ValueError):
            job_receipt._parse_json_arg("not json")
        with self.assertRaises(ValueError):
            job_receipt._parse_json_arg("[1, 2, 3]")
        with self.assertRaises(ValueError):
            job_receipt._parse_json_arg("123")
        self.assertEqual(job_receipt._parse_json_arg('{"a": 1}'), {"a": 1})
        self.assertIsNone(job_receipt._parse_json_arg(None))
        self.assertIsNone(job_receipt._parse_json_arg(""))

    def test_identity_deployed_different_root_not_installed_package(self):
        """Blocker A: deployed.json points at /different/root with empty manifest must NOT return installed_package."""
        os.makedirs(self.state_dir, exist_ok=True)
        deployed_path = os.path.join(self.state_dir, "deployed.json")
        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "schema_version": 1,
                    "source_sha": "fake_foreign_sha_9999",
                    "installed_version": "9.9.9",
                    "deployed_at": "2026-10-03T00:00:00Z",
                    "package_root": "/different/root/that/does/not/match",
                    "package_hashes": {},
                },
                f,
            )

        identity = job_receipt.resolve_identity(state_dir=Path(self.state_dir))
        self.assertNotEqual(identity.get("kind"), "installed_package")
        self.assertIsNone(identity.get("installed_revision"))

        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = store.begin("ident_job")
        rec = store.finish("ident_job", run_id=run_id, outcome="success")
        self.assertIsNone(rec.get("installed_revision"))

    def test_identity_deployed_same_root_mismatched_helper_hash(self):
        """Blocker A: same-root deployed.json with mismatched helper-hash must return unknown."""
        os.makedirs(self.state_dir, exist_ok=True)
        deployed_path = os.path.join(self.state_dir, "deployed.json")
        helper_path = (SCRIPTS_DIR / "job_receipt.py").resolve()
        helper_root = helper_path.parent.parent

        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "schema_version": 1,
                    "source_sha": "mismatched_sha_1234",
                    "installed_version": "1.0.0",
                    "deployed_at": "2026-10-03T00:00:00Z",
                    "package_root": str(helper_root),
                    "package_hashes": {
                        "scripts/job_receipt.py": "0000000000000000000000000000000000000000000000000000000000000000"
                    },
                },
                f,
            )

        identity = job_receipt.resolve_identity(
            state_dir=Path(self.state_dir), helper_path_override=helper_path
        )
        self.assertEqual(identity.get("kind"), "unknown")
        self.assertIsNone(identity.get("installed_revision"))

    def test_identity_deployed_matching_root_and_correct_hashes(self):
        """Blocker A: matching actual root and correct listed helper hashes returns verified installed_package."""
        os.makedirs(self.state_dir, exist_ok=True)
        deployed_path = os.path.join(self.state_dir, "deployed.json")
        helper_path = (SCRIPTS_DIR / "job_receipt.py").resolve()
        helper_root = helper_path.parent.parent
        actual_hash = job_receipt.sha256_file(helper_path)

        with open(deployed_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "schema_version": 1,
                    "source_sha": "verified_deploy_sha_5678",
                    "installed_version": "2.0.0",
                    "deployed_at": "2026-10-03T00:00:00Z",
                    "package_root": str(helper_root),
                    "package_hashes": {
                        "scripts/job_receipt.py": actual_hash,
                    },
                },
                f,
            )

        identity = job_receipt.resolve_identity(
            state_dir=Path(self.state_dir), helper_path_override=helper_path
        )
        self.assertEqual(identity.get("kind"), "installed_package")
        self.assertEqual(identity.get("source_sha"), "verified_deploy_sha_5678")
        self.assertEqual(identity.get("installed_revision"), "verified_deploy_sha_5678")

        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        run_id = store.begin("verified_deploy_job")
        rec = store.finish("verified_deploy_job", run_id=run_id, outcome="success")
        self.assertEqual(rec.get("installed_revision"), "verified_deploy_sha_5678")

    def test_concurrent_subprocess_writers(self):
        """Blocker B: 5 success + 30 skip terminals: exactly 35 completed, 5 success, 30 skipped_lock, 35 unique IDs."""
        cli = str((SCRIPTS_DIR / "job_receipt.py").resolve())
        child_env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": self.state_dir}

        p_active = subprocess.run(
            [sys.executable, cli, "begin", "--job", "concur_job", "--trigger", "active_writer"],
            capture_output=True,
            text=True,
            env=child_env,
        )
        self.assertEqual(p_active.returncode, 0)
        active_id = p_active.stdout.strip()

        # Worker 1: 5 writer begin -> finish
        writer_code = """
import subprocess, sys
cli = sys.argv[1]
for i in range(5):
    p = subprocess.run([sys.executable, cli, "begin", "--job", "concur_job", "--trigger", f"worker_{i}"], capture_output=True, text=True, check=True)
    rid = p.stdout.strip()
    subprocess.run([sys.executable, cli, "finish", "--job", "concur_job", "--run-id", rid, "--outcome", "success"], check=True)
"""
        # Workers 2, 3, 4: 10 skips each (30 skips total)
        skipper_code = """
import subprocess, sys
cli = sys.argv[1]
for i in range(10):
    subprocess.run([sys.executable, cli, "skip", "--job", "concur_job", "--outcome", "skipped_lock", "--reason", f"contention_{i}"], check=True)
"""
        workers = [
            subprocess.Popen([sys.executable, "-c", writer_code, cli], env=child_env),
            subprocess.Popen([sys.executable, "-c", skipper_code, cli], env=child_env),
            subprocess.Popen([sys.executable, "-c", skipper_code, cli], env=child_env),
            subprocess.Popen([sys.executable, "-c", skipper_code, cli], env=child_env),
        ]

        for w in workers:
            w.wait(timeout=30)
            self.assertEqual(w.returncode, 0)

        store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        data = store.read("concur_job")

        active_ids = [a["id"] for a in data["active"]]
        self.assertIn(active_id, active_ids)

        # Assert EXACTLY 35 completed
        self.assertEqual(len(data["completed"]), 35)
        successes = [c for c in data["completed"] if c["outcome"] == "success"]
        skips = [c for c in data["completed"] if c["outcome"] == "skipped_lock"]
        self.assertEqual(len(successes), 5)
        self.assertEqual(len(skips), 30)

        completed_ids = [c["id"] for c in data["completed"]]
        self.assertEqual(len(set(completed_ids)), 35)

        self.assertIsNotNone(data["last_terminal"])
        self.assertIsNotNone(data["last_success"])
        self.assertIsNotNone(data["last_skipped"])


class TestDfDelta(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dm_receipt_dfdelta_")
        self.store = job_receipt.JobReceiptStore(state_dir=self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def last(self, job):
        return job_receipt.get_last_receipt(job, state_dir=self.tmp)

    def test_finish_records_df_delta(self):
        rid = self.store.begin("govern_tmp_containers", precondition={"free_bytes_before": 10_000})
        self.store.finish("govern_tmp_containers", rid, "success",
                          postcondition={"free_bytes_after": 15_000})
        r = self.last("govern_tmp_containers")
        self.assertEqual(r["postcondition"]["df_delta_bytes"], 5_000)
        self.assertEqual(r["outcome"], "success")

    def test_governor_receipt_null_delta_is_error(self):
        rid = self.store.begin("govern_worktrees", precondition={})
        self.store.finish("govern_worktrees", rid, "success", postcondition={})
        r = self.last("govern_worktrees")
        self.assertEqual((r["outcome"], r["reason"]), ("error", "null_df_delta"))
        self.assertIsNone(r["postcondition"]["df_delta_bytes"])
        self.assertIsNone(self.store.read("govern_worktrees").get("last_success"))

    def test_existing_df_delta_is_kept(self):  # worktree_reap.sh already computes it
        rid = self.store.begin("worktree_reap")
        self.store.finish("worktree_reap", rid, "success",
                          postcondition={"df_delta_bytes": 7, "free_bytes_before": 1, "free_bytes_after": 8})
        self.assertEqual(self.last("worktree_reap")["postcondition"]["df_delta_bytes"], 7)

    def test_governor_skip_without_delta_stays_skip(self):
        self.store.finish("govern_worktrees", None, "skipped_lock", reason="lock_held")
        r = self.last("govern_worktrees")
        self.assertEqual((r["outcome"], r["reason"]), ("skipped_lock", "lock_held"))

    def test_governor_error_keeps_its_reason(self):
        rid = self.store.begin("govern_worktrees")
        self.store.finish("govern_worktrees", rid, "timeout", reason="deadline")
        self.assertEqual(self.last("govern_worktrees")["reason"], "deadline")

    def test_non_governor_without_delta_unchanged(self):
        rid = self.store.begin("snapshot_commit", precondition={"free_bytes_before": True})
        self.store.finish("snapshot_commit", rid, "success", postcondition={"free_bytes_after": 3})
        r = self.last("snapshot_commit")
        self.assertEqual(r["outcome"], "success")
        self.assertNotIn("df_delta_bytes", r["postcondition"])


class TestC14KeptBytes(unittest.TestCase):
    """C14 kept-byte folding.

    Producer contract read from scripts/c14_probe.py::account at the pinned
    commit c768858e83b0410c47a3e85ac2f522392dcec6e0: one compact JSON object per
    line, {"at": <epoch int>, "reason": <str>, "bytes": <int>}, appended with
    O_APPEND, where bytes is the sum of size for inventory entries of type
    "file". job_receipt sums only those producer rows; it never infers reclaimed
    bytes or removals.
    """

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="dm_receipt_c14_")
        self.state_dir = os.path.join(self.test_dir, "state")
        self.ledger = os.path.join(self.test_dir, "c14-ledger.jsonl")
        self.store = job_receipt.JobReceiptStore(state_dir=self.state_dir)
        self._saved_ledger_env = os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
        self._saved_owner_env = os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
        os.environ["DISK_MAGICIAN_STATE_DIR"] = self.state_dir

    def tearDown(self):
        os.environ.pop("DISK_MAGICIAN_C14_LEDGER", None)
        os.environ.pop("DISK_MAGICIAN_C14_LEDGER_OWNER", None)
        if self._saved_ledger_env is not None:
            os.environ["DISK_MAGICIAN_C14_LEDGER"] = self._saved_ledger_env
        if self._saved_owner_env is not None:
            os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = self._saved_owner_env
        os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _write_rows(self, rows):
        with open(self.ledger, "w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")

    def _finish(self, outcome="success_noop"):
        rid = self.store.begin("cleanup_tmp")
        return self.store.finish("cleanup_tmp", rid, outcome)

    def test_absent_ledger_is_backward_compatible(self):
        rec = self._finish()
        self.assertNotIn("c14_kept_bytes", rec["postcondition"])
        self.assertNotIn("c14_ledger_status", rec["postcondition"])

    def test_configured_but_missing_ledger_is_backward_compatible(self):
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = self.ledger  # never created
        rec = self._finish()
        self.assertNotIn("c14_kept_bytes", rec["postcondition"])
        self.assertNotIn("c14_ledger_status", rec["postcondition"])

    def test_producer_rows_fold_per_reason_and_preserve_typed_fields(self):
        now = int(time.time())
        self._write_rows(
            [
                {"at": now, "reason": "unproven-content", "bytes": 1234},
                {"at": now + 1, "reason": "unproven-content", "bytes": 66},
                {"at": now + 2, "reason": "not-pushed", "bytes": 4096},
                {"at": now + 3, "reason": "secret-like", "bytes": 0},
            ]
        )
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = self.ledger
        rid = self.store.begin("cleanup_tmp")
        rec = self.store.finish(
            "cleanup_tmp", rid, "success", candidates={"count": 3, "bytes": None}
        )

        self.assertEqual(
            rec["postcondition"]["c14_kept_bytes"],
            {"unproven-content": 1300, "not-pushed": 4096, "secret-like": 0},
        )
        self.assertEqual(rec["postcondition"]["c14_ledger_status"], "ok")
        # Terminal outcome and candidate fields are untouched by folding.
        self.assertEqual(rec["outcome"], "success")
        self.assertEqual(rec["candidates"], {"count": 3, "bytes": None})

        last = job_receipt.get_last_receipt("cleanup_tmp", state_dir=self.state_dir)
        self.assertEqual(last["postcondition"]["c14_kept_bytes"]["not-pushed"], 4096)
        self.assertEqual(last["id"], rid)

    def test_malformed_and_partial_rows_are_not_counted(self):
        with open(self.ledger, "w", encoding="utf-8") as f:
            f.write(json.dumps({"at": 1, "reason": "unproven-content", "bytes": 10}) + "\n")
            f.write("not json at all\n")
            f.write(json.dumps([1, 2, 3]) + "\n")
            f.write(json.dumps({"at": 2, "bytes": 999}) + "\n")  # missing reason
            f.write(json.dumps({"at": 3, "reason": "not-pushed", "bytes": -5}) + "\n")
            f.write(json.dumps({"at": 4, "reason": "dirty", "bytes": 1.5}) + "\n")
            f.write(json.dumps({"at": 5, "reason": "locked", "bytes": True}) + "\n")
            f.write(json.dumps({"at": 6, "reason": "git-metadata", "bytes": "20"}) + "\n")
            f.write('{"at": 7, "reason": "live-owner", "bytes": ')
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = self.ledger

        rec = self._finish()
        self.assertEqual(rec["postcondition"]["c14_kept_bytes"], {"unproven-content": 10})
        self.assertEqual(rec["postcondition"]["c14_ledger_status"], "incomplete")
        # A malformed ledger must not hide or rewrite the terminal receipt.
        data = self.store.read("cleanup_tmp")
        self.assertIsNotNone(data["last_terminal"])
        self.assertEqual(data["last_terminal"]["id"], rec["id"])
        self.assertEqual(data["last_terminal"]["outcome"], "success_noop")

    def test_oversized_ledger_is_bounded_and_incomplete(self):
        self._write_rows(
            [
                {"at": 1, "reason": "unproven-content", "bytes": 10},
                {"at": 2, "reason": "not-pushed", "bytes": 20},
            ]
        )
        result = job_receipt.fold_c14_ledger(self.ledger, max_bytes=60)
        self.assertEqual(result["c14_kept_bytes"], {"unproven-content": 10})
        self.assertEqual(result["c14_ledger_status"], "incomplete")

    def test_unreadable_ledger_records_error_without_hiding_terminal(self):
        ledger_dir = os.path.join(self.test_dir, "ledger-dir")
        os.makedirs(ledger_dir)
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = ledger_dir
        rec = self._finish()
        self.assertEqual(rec["postcondition"]["c14_kept_bytes"], {})
        self.assertEqual(rec["postcondition"]["c14_ledger_status"], "error")
        self.assertEqual(rec["outcome"], "success_noop")
        self.assertIsNotNone(self.store.read("cleanup_tmp")["last_terminal"])

    def test_owner_matching_job_folds_the_per_run_ledger(self):
        self._write_rows([{"at": 1, "reason": "unproven-content", "bytes": 1300}])
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = self.ledger
        os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = "cleanup_tmp"
        rec = self._finish()
        self.assertEqual(rec["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})
        self.assertEqual(rec["postcondition"]["c14_ledger_status"], "ok")

    def test_non_owning_nested_receipt_does_not_fold_the_shared_ledger(self):
        # A tmp_scratch_sweep run owns the ledger; its nested cleanup_tmp receipt
        # must not re-count the same producer rows.
        self._write_rows([{"at": 1, "reason": "unproven-content", "bytes": 1300}])
        os.environ["DISK_MAGICIAN_C14_LEDGER"] = self.ledger
        os.environ["DISK_MAGICIAN_C14_LEDGER_OWNER"] = "tmp_scratch_sweep"
        nested = self._finish()
        self.assertNotIn("c14_kept_bytes", nested["postcondition"])
        self.assertNotIn("c14_ledger_status", nested["postcondition"])
        # The owner (same ledger) folds it exactly once.
        rid = self.store.begin("tmp_scratch_sweep")
        owned = self.store.finish("tmp_scratch_sweep", rid, "success_noop")
        self.assertEqual(owned["postcondition"]["c14_kept_bytes"], {"unproven-content": 1300})


if __name__ == "__main__":
    unittest.main()

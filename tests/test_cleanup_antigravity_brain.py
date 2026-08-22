#!/usr/bin/env python3
"""Contract and safety tests for cleanup_antigravity_brain.py."""

import gzip
import os
import shutil
import tempfile
import time
import unittest
import sys
from pathlib import Path

# Add repo root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.cleanup_antigravity_brain import BrainCompactor, format_size, get_dir_mtime, get_dir_size


class TestCleanupAntigravityBrain(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.brain_dir = Path(self.temp_dir) / "brain"
        self.brain_dir.mkdir(parents=True)

        self.now = time.time()
        self.day = 86400

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_mock_session(self, sid: str, age_days: float, with_tasks=True, with_scratch=True, with_artifacts=True):
        sdir = self.brain_dir / sid
        sdir.mkdir(parents=True)

        sys_gen = sdir / ".system_generated"
        logs = sys_gen / "logs"
        tasks = sys_gen / "tasks"
        logs.mkdir(parents=True)
        tasks.mkdir(parents=True)

        # Truncated transcript
        tr = logs / "transcript.jsonl"
        tr.write_text('{"step": 0, "type": "USER_INPUT"}\n' * 50)

        # Full transcript
        tr_full = logs / "transcript_full.jsonl"
        tr_full.write_text('{"step": 0, "type": "USER_INPUT", "full_content": "A" * 10000}\n' * 100)

        if with_tasks:
            task_log = tasks / "task-1.log"
            task_log.write_text("Standard command output line\n" * 1000)

        if with_scratch:
            sc = sdir / "scratch"
            sc.mkdir(parents=True)
            scratch_file = sc / "raw_payloads.json"
            scratch_file.write_text('{"raw": "test data"}\n' * 500)

        if with_artifacts:
            art = sdir / "report.md"
            art.write_text("# Final Report\nUser artifact content.\n")
            meta = sdir / "report.md.metadata.json"
            meta.write_text('{"Summary": "Report"}\n')

        # Set mtimes for all files and directories
        target_mtime = self.now - (age_days * self.day)
        for root, dirs, files in os.walk(sdir):
            for d in dirs:
                os.utime(Path(root) / d, (target_mtime, target_mtime))
            for f in files:
                os.utime(Path(root) / f, (target_mtime, target_mtime))
        os.utime(sdir, (target_mtime, target_mtime))

        return sdir

    def test_active_session_protection(self):
        """Active sessions (<24h) must never be touched, even if clean is True."""
        sid = "active-session-123"
        sdir = self._create_mock_session(sid, age_days=0.1)  # 2.4 hours old

        compactor = BrainCompactor(brain_dir=self.brain_dir, threshold_days=7, dry_run=False)
        stats = compactor.scan_and_compact()

        self.assertEqual(stats["active_skipped"], 1)
        self.assertEqual(stats["files_compressed"], 0)
        self.assertEqual(stats["scratch_files_removed"], 0)

        # Verify scratch and task logs are completely untouched
        self.assertTrue((sdir / "scratch" / "raw_payloads.json").exists())
        self.assertTrue((sdir / ".system_generated" / "tasks" / "task-1.log").exists())
        self.assertFalse((sdir / ".system_generated" / "tasks" / "task-1.log.gz").exists())

    def test_recent_session_protection(self):
        """Sessions older than 24h but newer than threshold (e.g. 5d < 14d) must be kept intact."""
        sid = "recent-session-456"
        sdir = self._create_mock_session(sid, age_days=5.0)

        compactor = BrainCompactor(brain_dir=self.brain_dir, threshold_days=14, dry_run=False)
        stats = compactor.scan_and_compact()

        self.assertEqual(stats["too_recent_skipped"], 1)
        self.assertEqual(stats["files_compressed"], 0)
        self.assertEqual(stats["scratch_files_removed"], 0)
        self.assertTrue((sdir / "scratch" / "raw_payloads.json").exists())

    def test_dry_run_never_mutates(self):
        """Dry run mode should calculate savings but leave every file on disk unchanged."""
        sid = "old-session-789"
        sdir = self._create_mock_session(sid, age_days=20.0)

        compactor = BrainCompactor(brain_dir=self.brain_dir, threshold_days=14, dry_run=True)
        stats = compactor.scan_and_compact()

        self.assertGreater(stats["bytes_reclaimed"], 0)
        self.assertGreater(stats["files_compressed"], 0)
        self.assertGreater(stats["scratch_files_removed"], 0)

        # Verify no files were actually deleted or compressed
        self.assertTrue((sdir / "scratch" / "raw_payloads.json").exists())
        self.assertTrue((sdir / ".system_generated" / "tasks" / "task-1.log").exists())
        self.assertFalse((sdir / ".system_generated" / "tasks" / "task-1.log.gz").exists())
        self.assertTrue((sdir / ".system_generated" / "logs" / "transcript_full.jsonl").exists())

    def test_clean_mode_lossless_compaction_and_artifact_preservation(self):
        """Clean mode compresses logs losslessly, removes stale scratch, and preserves markdown artifacts."""
        sid = "old-session-clean"
        sdir = self._create_mock_session(sid, age_days=25.0)

        task_log_orig = (sdir / ".system_generated" / "tasks" / "task-1.log").read_text()
        tr_full_orig = (sdir / ".system_generated" / "logs" / "transcript_full.jsonl").read_text()

        compactor = BrainCompactor(brain_dir=self.brain_dir, threshold_days=14, dry_run=False)
        stats = compactor.scan_and_compact()

        self.assertGreater(stats["bytes_reclaimed"], 0)
        self.assertEqual(stats["scratch_files_removed"], 1)
        self.assertEqual(stats["files_compressed"], 2)  # task-1.log + transcript_full.jsonl

        # 1. Scratch file is gone
        self.assertFalse((sdir / "scratch" / "raw_payloads.json").exists())

        # 2. Log and transcript_full are compressed to .gz
        gz_task = sdir / ".system_generated" / "tasks" / "task-1.log.gz"
        gz_tr_full = sdir / ".system_generated" / "logs" / "transcript_full.jsonl.gz"
        self.assertTrue(gz_task.exists())
        self.assertTrue(gz_tr_full.exists())
        self.assertFalse((sdir / ".system_generated" / "tasks" / "task-1.log").exists())
        self.assertFalse((sdir / ".system_generated" / "logs" / "transcript_full.jsonl").exists())

        # 3. Transcript.jsonl is kept uncompressed for fast search/index
        self.assertTrue((sdir / ".system_generated" / "logs" / "transcript.jsonl").exists())

        # 4. Decompression verifies 100% lossless content preservation
        with gzip.open(gz_task, "rt") as f:
            self.assertEqual(f.read(), task_log_orig)
        with gzip.open(gz_tr_full, "rt") as f:
            self.assertEqual(f.read(), tr_full_orig)

        # 5. Markdown and metadata artifacts are completely preserved
        self.assertTrue((sdir / "report.md").exists())
        self.assertEqual((sdir / "report.md").read_text(), "# Final Report\nUser artifact content.\n")
        self.assertTrue((sdir / "report.md.metadata.json").exists())

    def test_prune_empty_sessions(self):
        """0-byte empty sessions older than threshold are pruned."""
        empty_sid = "empty-session-old"
        empty_sdir = self.brain_dir / empty_sid
        empty_sdir.mkdir()
        target_mtime = self.now - (20 * self.day)
        os.utime(empty_sdir, (target_mtime, target_mtime))

        compactor = BrainCompactor(brain_dir=self.brain_dir, threshold_days=14, dry_run=False)
        stats = compactor.scan_and_compact()

        self.assertEqual(stats["empty_pruned"], 1)
        self.assertFalse(empty_sdir.exists())


if __name__ == "__main__":
    unittest.main()

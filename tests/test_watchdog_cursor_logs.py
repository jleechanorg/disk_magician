#!/usr/bin/env python3
"""Pytest unit tests for cursor-agent log watchdog (scripts/watchdog_cursor_logs.sh)."""

import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "watchdog_cursor_logs.sh"
PLIST_TEMPLATE_PATH = REPO_ROOT / "launchd" / "com.disk-magician.cursor-logs-watchdog.plist.template"


class TestWatchdogCursorLogs(unittest.TestCase):
    def test_script_and_plist_template_exist(self):
        self.assertTrue(SCRIPT_PATH.is_file(), f"Missing script at {SCRIPT_PATH}")
        self.assertTrue(os.access(SCRIPT_PATH, os.X_OK), f"Script not executable: {SCRIPT_PATH}")
        self.assertTrue(PLIST_TEMPLATE_PATH.is_file(), f"Missing plist template at {PLIST_TEMPLATE_PATH}")

    def test_plist_template_structure(self):
        content = PLIST_TEMPLATE_PATH.read_text()
        self.assertIn("<key>Label</key>", content)
        self.assertIn("<string>com.disk-magician.cursor-logs-watchdog</string>", content)
        self.assertIn("<key>StartInterval</key>", content)
        self.assertIn("<integer>3600</integer>", content)
        self.assertIn("<key>RunAtLoad</key>", content)
        self.assertIn("<true/>", content)
        self.assertIn("@BASH@", content)
        self.assertIn("@REPO_ROOT@/scripts/watchdog_cursor_logs.sh", content)

    def test_active_writer_copytruncate_in_place(self):
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp_path = Path(tmp_str)
            logs_dir = tmp_path / "cursor-agent-logs-501"
            logs_dir.mkdir(parents=True)
            log_file = logs_dir / "session-2026-08-22T00-00-00-11111-1.log"

            # Write 2MB initial content
            initial_data = b"x" * (2 * 1024 * 1024)
            log_file.write_bytes(initial_data)
            initial_stat = log_file.stat()
            initial_ino = initial_stat.st_ino

            # Start a background process continuously appending
            py_writer_code = f"""
import time, sys
with open({repr(str(log_file))}, "a") as f:
    while True:
        f.write("append line\\n")
        f.flush()
        time.sleep(0.02)
"""
            proc = subprocess.Popen([sys.executable, "-c", py_writer_code])
            try:
                time.sleep(0.1)
                self.assertIsNone(proc.poll(), "Writer process should be running")

                # Execute watchdog with threshold 1MB
                res = subprocess.run(
                    [str(SCRIPT_PATH), "--threshold-mb", "1", "--dirs", str(tmp_path)],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(res.returncode, 0, f"Watchdog failed: {res.stderr}")

                # Process should still be alive
                self.assertIsNone(proc.poll(), "Writer process should remain alive after copytruncate")

                time.sleep(0.1)
            finally:
                proc.terminate()
                proc.wait(timeout=2)

            final_stat = log_file.stat()
            # Inode must be preserved
            self.assertEqual(final_stat.st_ino, initial_ino, "Inode must remain unchanged across in-place truncation")
            # File size must be much smaller than initial 2MB (only contains recent appends)
            self.assertLess(final_stat.st_size, 10000, f"File size did not drop: {final_stat.st_size}")
            # File must contain recent appends
            content = log_file.read_text()
            self.assertIn("append line", content)

    def test_dry_run_leaves_file_untouched(self):
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp_path = Path(tmp_str)
            logs_dir = tmp_path / "cursor-agent-logs-501"
            logs_dir.mkdir(parents=True)
            log_file = logs_dir / "session-dry.log"

            data = b"D" * (2 * 1024 * 1024)
            log_file.write_bytes(data)

            res = subprocess.run(
                [str(SCRIPT_PATH), "--threshold-mb", "1", "--dry-run", "--dirs", str(tmp_path)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0)
            self.assertIn("DRY-RUN: would truncate in-place", res.stdout)
            self.assertEqual(log_file.stat().st_size, len(data))

    def test_file_below_threshold_untouched(self):
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp_path = Path(tmp_str)
            logs_dir = tmp_path / "cursor-agent-logs-501"
            logs_dir.mkdir(parents=True)
            log_file = logs_dir / "session-small.log"

            data = b"small content"
            log_file.write_bytes(data)

            res = subprocess.run(
                [str(SCRIPT_PATH), "--threshold-mb", "1", "--dirs", str(tmp_path)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0)
            self.assertEqual(log_file.stat().st_size, len(data))
            self.assertEqual(log_file.read_bytes(), data)


if __name__ == "__main__":
    unittest.main()


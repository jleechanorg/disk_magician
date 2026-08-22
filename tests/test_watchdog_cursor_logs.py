#!/usr/bin/env python3
"""Pytest unit tests for cursor-agent log watchdog (scripts/watchdog_cursor_logs.sh)."""

import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "watchdog_cursor_logs.sh"
PLIST_TEMPLATE_PATH = REPO_ROOT / "launchd" / "com.disk-magician.cursor-logs-watchdog.plist.template"


class TestWatchdogCursorLogs:
    def test_script_and_plist_template_exist(self):
        assert SCRIPT_PATH.is_file(), f"Missing script at {SCRIPT_PATH}"
        assert os.access(SCRIPT_PATH, os.X_OK), f"Script not executable: {SCRIPT_PATH}"
        assert PLIST_TEMPLATE_PATH.is_file(), f"Missing plist template at {PLIST_TEMPLATE_PATH}"

    def test_plist_template_structure(self):
        content = PLIST_TEMPLATE_PATH.read_text()
        assert "<key>Label</key>" in content
        assert "<string>com.disk-magician.cursor-logs-watchdog</string>" in content
        assert "<key>StartInterval</key>" in content
        assert "<integer>3600</integer>" in content
        assert "<key>RunAtLoad</key>" in content
        assert "<true/>" in content
        assert "@BASH@" in content
        assert "@REPO_ROOT@/scripts/watchdog_cursor_logs.sh" in content

    def test_active_writer_copytruncate_in_place(self, tmp_path):
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
            assert proc.poll() is None, "Writer process should be running"

            # Execute watchdog with threshold 1MB
            res = subprocess.run(
                [str(SCRIPT_PATH), "--threshold-mb", "1", "--dirs", str(tmp_path)],
                capture_output=True,
                text=True,
            )
            assert res.returncode == 0, f"Watchdog failed: {res.stderr}"

            # Process should still be alive
            assert proc.poll() is None, "Writer process should remain alive after copytruncate"

            time.sleep(0.1)
        finally:
            proc.terminate()
            proc.wait(timeout=2)

        final_stat = log_file.stat()
        # Inode must be preserved
        assert final_stat.st_ino == initial_ino, "Inode must remain unchanged across in-place truncation"
        # File size must be much smaller than initial 2MB (only contains recent appends)
        assert final_stat.st_size < 10000, f"File size did not drop: {final_stat.st_size}"
        # File must contain recent appends
        content = log_file.read_text()
        assert "append line" in content

    def test_dry_run_leaves_file_untouched(self, tmp_path):
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
        assert res.returncode == 0
        assert "DRY-RUN: would truncate in-place" in res.stdout
        assert log_file.stat().st_size == len(data)

    def test_file_below_threshold_untouched(self, tmp_path):
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
        assert res.returncode == 0
        assert log_file.stat().st_size == len(data)
        assert log_file.read_bytes() == data

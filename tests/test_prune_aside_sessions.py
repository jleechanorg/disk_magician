#!/usr/bin/env python3
"""Contract, safety, and integration tests for prune_aside_sessions.py (bead disk_magician-18q)."""

import datetime
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

# Add repo root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scripts.prune_aside_sessions import (
    AsideSessionPruner,
    check_open_files,
    format_size,
    get_dir_max_mtime,
    get_dir_size,
    hash_file_sha256,
    parse_session_age_days,
)


class TestPruneAsideSessions(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp())
        self.aside_dir = self.temp_dir / ".aside"
        self.aside_dir.mkdir(parents=True)
        self.u0_sessions = self.aside_dir / "u" / "0" / "sessions"
        self.u1_sessions = self.aside_dir / "u" / "1" / "sessions"
        self.u0_sessions.mkdir(parents=True)
        self.u1_sessions.mkdir(parents=True)

        # Fixed reference time: 2026-08-23 00:00:00 UTC (1787443200)
        self.ref_dt = datetime.datetime(2026, 8, 23, 0, 0, 0, tzinfo=datetime.timezone.utc)
        self.ref_time = self.ref_dt.timestamp()
        self.day_secs = 86400

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_mock_session(
        self,
        sessions_container: Path,
        session_name: str,
        files_data: dict,
        mtime_epoch: float = None,
    ) -> Path:
        sdir = sessions_container / session_name
        sdir.mkdir(parents=True, exist_ok=True)
        for rel_path, content in files_data.items():
            fpath = sdir / rel_path
            fpath.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, str):
                fpath.write_text(content)
            else:
                fpath.write_bytes(content)

        if mtime_epoch is not None:
            for root, dirs, files in os.walk(sdir):
                for d in dirs:
                    os.utime(Path(root) / d, (mtime_epoch, mtime_epoch))
                for f in files:
                    os.utime(Path(root) / f, (mtime_epoch, mtime_epoch))
            os.utime(sdir, (mtime_epoch, mtime_epoch))

        return sdir

    def _create_mock_lsof_script(self, locked_paths: list = None, fail: bool = False) -> Path:
        """Create a mock lsof binary for testing Signal B."""
        mock_bin = self.temp_dir / "mock_lsof.sh"
        locked_list = " ".join([f'"{p}"' for p in (locked_paths or [])])
        if fail:
            mock_bin.write_text("#!/bin/sh\nexit 2\n")
        elif not locked_paths:
            mock_bin.write_text("#!/bin/sh\nexit 1\n")
        else:
            mock_bin.write_text(
                f"""#!/bin/sh
container="$3"
echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
for locked in {locked_list}; do
  if [ -d "$locked" ]; then
    echo "aside 12345 user 4u REG 1,2 1024 100 $locked/messages.jsonl"
  else
    echo "aside 12345 user 4u REG 1,2 1024 100 $container/$locked/messages.jsonl"
  fi
done
exit 0
"""
            )
        mock_bin.chmod(mock_bin.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return mock_bin

    def test_parse_session_age_date_prefix(self):
        """Verify date-prefixed folder names compute exact day age from ref_time."""
        # 2026-08-09 is 14 days before 2026-08-23
        sdir = self.u0_sessions / "2026-08-09_abc123"
        sdir.mkdir(parents=True)
        age, method = parse_session_age_days(sdir, self.ref_time)
        self.assertEqual(method, "date_prefix")
        self.assertAlmostEqual(age, 14.0, places=2)

        # 2026-08-20 is 3 days before 2026-08-23
        sdir2 = self.u0_sessions / "2026-08-20_xyz789"
        sdir2.mkdir(parents=True)
        age2, method2 = parse_session_age_days(sdir2, self.ref_time)
        self.assertEqual(method2, "date_prefix")
        self.assertAlmostEqual(age2, 3.0, places=2)

    def test_parse_session_age_mtime_fallback(self):
        """Verify non-date folders fall back to file/folder mtime."""
        sdir = self.u0_sessions / "custom_named_session"
        sdir.mkdir(parents=True)
        # 10 days before ref_time
        target_mtime = self.ref_time - (10 * self.day_secs)
        (sdir / "test.txt").write_text("hello")
        os.utime(sdir / "test.txt", (target_mtime, target_mtime))
        os.utime(sdir, (target_mtime, target_mtime))

        age, method = parse_session_age_days(sdir, self.ref_time)
        self.assertEqual(method, "mtime")
        self.assertAlmostEqual(age, 10.0, delta=0.1)

    def test_dry_run_preserves_all_sessions(self):
        """Dry-run must not delete any files or directories."""
        old_session = self._create_mock_session(
            self.u0_sessions,
            "2026-07-20_old_session",
            {"messages.jsonl": "test message content", "tmp/screenshot.png": b"PNG_DATA" * 500},
        )
        recent_session = self._create_mock_session(
            self.u0_sessions,
            "2026-08-21_recent_session",
            {"messages.jsonl": "recent message content"},
        )

        mock_lsof = self._create_mock_lsof_script()

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=True,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_scanned"], 2)
        self.assertEqual(stats["sessions_retained_recent"], 1)
        self.assertEqual(stats["sessions_pruned"], 1)
        self.assertTrue(stats["bytes_pruned"] > 0)

        # Both directories must still exist on disk
        self.assertTrue(old_session.exists())
        self.assertTrue(recent_session.exists())

    def test_clean_prunes_stale_and_preserves_recent(self):
        """Clean mode actually deletes sessions older than max_age_days and keeps recent ones."""
        old_session = self._create_mock_session(
            self.u0_sessions,
            "2026-08-01_old_session",
            {"messages.jsonl": "old data", "evidence/shot.png": b"IMG" * 1000},
        )
        recent_session = self._create_mock_session(
            self.u0_sessions,
            "2026-08-20_recent_session",
            {"messages.jsonl": "recent data", "evidence/shot.png": b"IMG" * 1000},
        )

        mock_lsof = self._create_mock_lsof_script()

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=False,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_scanned"], 2)
        self.assertEqual(stats["sessions_retained_recent"], 1)
        self.assertEqual(stats["sessions_pruned"], 1)

        # Old session is deleted; recent session is preserved intact
        self.assertFalse(old_session.exists())
        self.assertTrue(recent_session.exists())
        self.assertTrue((recent_session / "messages.jsonl").exists())

    def test_signal_b_lsof_open_files_blocks_pruning(self):
        """Signal B: If a process has open files in an old session, it must NOT be deleted."""
        old_locked_session = self._create_mock_session(
            self.u0_sessions,
            "2026-07-25_locked_session",
            {"messages.jsonl": "active session running"},
        )
        old_unlocked_session = self._create_mock_session(
            self.u0_sessions,
            "2026-07-25_unlocked_session",
            {"messages.jsonl": "finished old session"},
        )

        # Lock the first session
        mock_lsof = self._create_mock_lsof_script(locked_paths=["2026-07-25_locked_session"])

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=False,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_scanned"], 2)
        self.assertEqual(stats["sessions_retained_in_use"], 1)
        self.assertEqual(stats["sessions_pruned"], 1)

        # Locked session is protected; unlocked old session is pruned
        self.assertTrue(old_locked_session.exists())
        self.assertFalse(old_unlocked_session.exists())

    def test_lsof_failure_fails_closed(self):
        """If lsof errors out, fail-closed policy must protect all sessions."""
        old_session = self._create_mock_session(
            self.u0_sessions,
            "2026-07-15_old_session",
            {"data.txt": "data"},
        )

        mock_lsof = self._create_mock_lsof_script(fail=True)

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=False,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_retained_in_use"], 1)
        self.assertEqual(stats["sessions_pruned"], 0)
        self.assertTrue(old_session.exists())

    def test_static_asset_deduplication(self):
        """Verify duplicate static assets across retained sessions are hardlinked."""
        large_image_data = b"LARGE_PNG_HEADER_AND_IMAGE_BYTES" * 200  # ~6.4 KB (>1KB min_size)

        # Create two recent sessions sharing identical assets
        session_a = self._create_mock_session(
            self.u0_sessions,
            "2026-08-20_session_a",
            {"banner.png": large_image_data, "unique_a.txt": "a"},
        )
        session_b = self._create_mock_session(
            self.u0_sessions,
            "2026-08-21_session_b",
            {"banner.png": large_image_data, "unique_b.txt": "b"},
        )

        file_a = session_a / "banner.png"
        file_b = session_b / "banner.png"

        # Initially distinct inodes
        self.assertNotEqual(file_a.stat().st_ino, file_b.stat().st_ino)

        mock_lsof = self._create_mock_lsof_script()

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=False,
            dedup_assets=True,
            min_dedup_size=1024,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_retained_recent"], 2)
        self.assertEqual(stats["assets_deduped"], 1)
        self.assertEqual(stats["bytes_deduped"], len(large_image_data))

        # Both files now exist and share the SAME inode (hardlink)
        self.assertTrue(file_a.exists())
        self.assertTrue(file_b.exists())
        self.assertEqual(file_a.stat().st_ino, file_b.stat().st_ino)
        self.assertEqual(file_a.read_bytes(), large_image_data)
        self.assertEqual(file_b.read_bytes(), large_image_data)

    def test_multi_user_discovery(self):
        """Pruner must discover sessions in u/0/sessions and u/1/sessions."""
        s0_old = self._create_mock_session(
            self.u0_sessions,
            "2026-07-20_u0_old",
            {"test.txt": "u0"},
        )
        s1_old = self._create_mock_session(
            self.u1_sessions,
            "2026-07-20_u1_old",
            {"test.txt": "u1"},
        )

        mock_lsof = self._create_mock_lsof_script()

        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            max_age_days=14,
            dry_run=False,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()

        self.assertEqual(stats["sessions_scanned"], 2)
        self.assertEqual(stats["sessions_pruned"], 2)
        self.assertFalse(s0_old.exists())
        self.assertFalse(s1_old.exists())

    def test_safety_guard_rejects_non_child_paths(self):
        """Ensure is_safe_session_path blocks sessions container or parent dirs."""
        pruner = AsideSessionPruner(aside_dir=self.aside_dir)
        # Attempting to check container itself as candidate
        self.assertFalse(pruner.is_safe_session_path(self.u0_sessions, self.u0_sessions))
        # Direct child is safe
        child = self.u0_sessions / "2026-08-01_test"
        child.mkdir()
        self.assertTrue(pruner.is_safe_session_path(child, self.u0_sessions))

    def test_default_max_age_days_is_7(self):
        """Default max_age_days must be 7 days."""
        pruner = AsideSessionPruner(aside_dir=self.aside_dir)
        self.assertEqual(pruner.max_age_days, 7)

        # Session 8 days old (2026-08-15) vs ref_time 2026-08-23
        s_8d = self._create_mock_session(self.u0_sessions, "2026-08-15_old", {"msg.txt": "8d"})
        # Session 5 days old (2026-08-18) vs ref_time 2026-08-23
        s_5d = self._create_mock_session(self.u0_sessions, "2026-08-18_recent", {"msg.txt": "5d"})

        mock_lsof = self._create_mock_lsof_script()
        pruner = AsideSessionPruner(
            aside_dir=self.aside_dir,
            dry_run=False,
            lsof_bin=str(mock_lsof),
            ref_time=self.ref_time,
        )
        stats = pruner.run()
        self.assertEqual(stats["sessions_scanned"], 2)
        self.assertEqual(stats["sessions_pruned"], 1)
        self.assertEqual(stats["sessions_retained_recent"], 1)
        self.assertFalse(s_8d.exists())
        self.assertTrue(s_5d.exists())

    def test_cli_parse_args(self):
        """Test parse_args with various flag combinations."""
        from scripts.prune_aside_sessions import parse_args
        import unittest.mock

        with unittest.mock.patch("sys.argv", ["prune_aside_sessions.py", "--clean", "--days", "5"]):
            args = parse_args()
            self.assertTrue(args.clean)
            self.assertEqual(args.max_age_days, 5)

        with unittest.mock.patch("sys.argv", ["prune_aside_sessions.py", "--apply", "--max-age-days", "10"]):
            args = parse_args()
            self.assertTrue(args.clean)
            self.assertEqual(args.max_age_days, 10)

        with unittest.mock.patch("sys.argv", ["prune_aside_sessions.py", "--dry-run"]):
            args = parse_args()
            self.assertFalse(args.clean)
            self.assertEqual(args.max_age_days, 7)

    def test_format_size_and_helpers(self):
        """Test format_size formatting."""
        self.assertEqual(format_size(500), "500.00 B")
        self.assertEqual(format_size(1024), "1.00 KB")
        self.assertEqual(format_size(1048576), "1.00 MB")
        self.assertEqual(format_size(1073741824), "1.00 GB")


if __name__ == "__main__":
    unittest.main()


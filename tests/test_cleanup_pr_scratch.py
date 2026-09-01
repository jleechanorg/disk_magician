#!/usr/bin/env python3
"""Contract and safety tests for cleanup_pr_scratch.sh."""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "cleanup_pr_scratch.sh"


class TestCleanupPrScratch(unittest.TestCase):
    def setUp(self):
        self.test_root = Path(tempfile.mkdtemp(prefix="test_pr_scratch_py_"))
        self.tmp_dir = self.test_root / "tmp"
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        self.now = time.time()
        self.old_time = self.now - (7 * 86400)  # 7 days old

    def tearDown(self):
        shutil.rmtree(self.test_root, ignore_errors=True)

    def _backdate(self, path: Path):
        for root, dirs, files in os.walk(path):
            for d in dirs:
                p = Path(root) / d
                os.utime(p, (self.old_time, self.old_time))
            for f in files:
                p = Path(root) / f
                os.utime(p, (self.old_time, self.old_time))
        os.utime(path, (self.old_time, self.old_time))

    def _run_script(self, args, env_extra=None):
        env = os.environ.copy()
        env.setdefault("DISK_MAGICIAN_SKIP_LSOF_CHECK", "1")
        if env_extra:
            env.update(env_extra)
        cmd = ["bash", str(SCRIPT_PATH), "--tmp-dir", str(self.tmp_dir)] + args
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        return res


    def test_dry_run_preserves_everything(self):
        """Default dry-run mode previews but does not delete files/directories."""
        d1 = self.tmp_dir / "pr9128-wizard"
        d1.mkdir()
        (d1 / "payload.txt").write_text("hello")
        self._backdate(d1)

        f1 = self.tmp_dir / "pr54_body.md"
        f1.write_text("markdown body")
        self._backdate(f1)

        res = self._run_script(["--dry-run"])
        self.assertEqual(res.returncode, 0)
        self.assertIn("DRY RUN: would remove:", res.stderr)
        self.assertTrue(d1.exists())
        self.assertTrue(f1.exists())

    def test_clean_mode_removes_stale_pr_scratch(self):
        """--clean removes old directories and files matching PR/Claude scratch patterns."""
        d1 = self.tmp_dir / "pr9128-wizard"
        d1.mkdir()
        (d1 / "test.log").write_text("log")
        self._backdate(d1)

        d2 = self.tmp_dir / "claude-mcp-scratch"
        d2.mkdir()
        self._backdate(d2)

        f1 = self.tmp_dir / "pr832-evidence.out"
        f1.write_text("output")
        self._backdate(f1)

        res = self._run_script(["--clean"])
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
        self.assertIn("Removing:", res.stderr)
        self.assertFalse(d1.exists())
        self.assertFalse(d2.exists())
        self.assertFalse(f1.exists())

    def test_pattern_matching_and_unrelated_preservation(self):
        """Only matching patterns (pr*, claude*) are targeted; other dirs/files remain."""
        matching_dirs = [
            self.tmp_dir / "pr9128-fix",
            self.tmp_dir / "pr-analyze-code",
            self.tmp_dir / "pr_custom_tool",
            self.tmp_dir / "pr832-gist-review",
            self.tmp_dir / "claude-session-501",
            self.tmp_dir / "claude_ctx",
        ]
        for d in matching_dirs:
            d.mkdir()
            self._backdate(d)

        unrelated_dirs = [
            self.tmp_dir / "my_project_dir",
            self.tmp_dir / "system_important",
            self.tmp_dir / "user_data",
        ]
        for d in unrelated_dirs:
            d.mkdir()
            self._backdate(d)

        res = self._run_script(["--clean"])
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")

        for d in matching_dirs:
            self.assertFalse(d.exists(), f"Expected {d.name} to be removed")

        for d in unrelated_dirs:
            self.assertTrue(d.exists(), f"Expected {d.name} to be preserved")

    def test_recency_protection(self):
        """Directories or files with recent mtimes are preserved."""
        fresh_dir = self.tmp_dir / "pr-fresh-branch"
        fresh_dir.mkdir()
        (fresh_dir / "file.txt").write_text("recent")
        # Do not backdate -> mtime is now

        stale_dir = self.tmp_dir / "pr-stale-branch"
        stale_dir.mkdir()
        (stale_dir / "file.txt").write_text("stale")
        self._backdate(stale_dir)

        res = self._run_script(["--clean", "--min-age-hours", "48"])
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
        self.assertTrue(fresh_dir.exists())
        self.assertFalse(stale_dir.exists())
        self.assertIn("Skipping recently active path", res.stderr)

    def test_marker_protection(self):
        """.in-use and .keep markers protect old directories."""
        in_use_dir = self.tmp_dir / "pr-in-use-dir"
        in_use_dir.mkdir()
        (in_use_dir / ".in-use").touch()
        self._backdate(in_use_dir)

        keep_dir = self.tmp_dir / "pr-keep-dir"
        keep_dir.mkdir()
        (keep_dir / ".keep").touch()
        self._backdate(keep_dir)

        res = self._run_script(["--clean"])
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
        self.assertTrue(in_use_dir.exists())
        self.assertTrue(keep_dir.exists())
        self.assertIn("Skipping active-use marker", res.stderr)

    def test_git_unsaved_work_protection(self):
        """Scratch directories containing git repos with uncommitted changes are preserved."""
        git_dir = self.tmp_dir / "pr-git-scratch"
        git_dir.mkdir()
        subprocess.run(["git", "init", "-q", str(git_dir)], check=True)
        subprocess.run(["git", "-C", str(git_dir), "config", "user.name", "Test User"], check=True)
        subprocess.run(["git", "-C", str(git_dir), "config", "user.email", "jleechan2015@users.noreply.github.com"], check=True)

        (git_dir / "file.txt").write_text("initial")
        subprocess.run(["git", "-C", str(git_dir), "add", "file.txt"], check=True)
        subprocess.run(["git", "-C", str(git_dir), "commit", "-q", "-m", "init"], check=True)
        (git_dir / "file.txt").write_text("modified")
        self._backdate(git_dir)

        res = self._run_script(["--clean"])
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
        self.assertTrue(git_dir.exists())
        self.assertIn("Skipping scratch worktree with unsaved work", res.stderr)

    def test_protected_root_protection(self):
        """Roots configured in DISK_MAGICIAN_PROTECTED_TMP_ROOTS are never deleted."""
        prot_dir = self.tmp_dir / "worldarchitect.ai"
        prot_dir.mkdir()
        self._backdate(prot_dir)

        pr_prot_dir = self.tmp_dir / "pr-protected-custom"
        pr_prot_dir.mkdir()
        self._backdate(pr_prot_dir)

        res = self._run_script(
            ["--clean"],
            env_extra={"DISK_MAGICIAN_PROTECTED_TMP_ROOTS": "worldarchitect.ai pr-protected-custom"},
        )
        self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
        self.assertTrue(prot_dir.exists())
        self.assertTrue(pr_prot_dir.exists())
        self.assertIn("Skipping protected root", res.stderr)


    def test_open_files_protection(self):
        """Directories containing open files are preserved."""
        d1 = self.tmp_dir / "pr-busy-dir"
        d1.mkdir()
        busy_file = d1 / "busy.txt"
        busy_file.write_text("busy content")
        self._backdate(d1)

        # Open file in python process holding lock/handle
        with open(busy_file, "r") as fh:
            res = self._run_script(["--clean", "--min-age-hours", "0"], env_extra={"DISK_MAGICIAN_SKIP_LSOF_CHECK": "0"})
            self.assertEqual(res.returncode, 0, f"rc={res.returncode}\nstdout={res.stdout}\nstderr={res.stderr}")
            self.assertTrue(d1.exists())
            self.assertIn("Skipping in-use path (open files)", res.stderr)

    def test_lsof_error_fail_closed(self):
        """If lsof fails or returns an error, treat as active (fail-closed)."""
        d1 = self.tmp_dir / "pr-lsof-error"
        d1.mkdir()
        self._backdate(d1)

        fake_lsof = self.test_root / "fake_lsof.sh"
        fake_lsof.write_text("#!/bin/sh\nexit 2\n")
        fake_lsof.chmod(0o755)

        res = self._run_script(["--clean"], env_extra={"DISK_MAGICIAN_LSOF_BIN": str(fake_lsof), "DISK_MAGICIAN_SKIP_LSOF_CHECK": "0"})
        self.assertEqual(res.returncode, 0)
        self.assertTrue(d1.exists())
        self.assertIn("fail-closed, treating as active", res.stderr)

    def test_custom_pattern_and_min_age_days(self):
        """--pattern and --min-age-days flags configure matching and thresholds."""
        d1 = self.tmp_dir / "custom-branch-scratch"
        d1.mkdir()
        self._backdate(d1)

        res = self._run_script(["--clean", "--pattern", "custom-*", "--min-age-days", "2"])
        self.assertEqual(res.returncode, 0)
        self.assertFalse(d1.exists())

    def test_argument_validation(self):
        """Invalid flags or argument types return exit code 2."""
        res = self._run_script(["--nonexistent-flag"])
        self.assertEqual(res.returncode, 2)

        res2 = self._run_script(["--min-age-hours", "not_a_number"])
        self.assertEqual(res2.returncode, 2)


if __name__ == "__main__":
    unittest.main()

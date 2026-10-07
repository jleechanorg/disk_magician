"""Tests for scripts/layout_check.py (diskm layout-check, spec D5).

Everything runs against a temp HOME and temp repos; the real ~/.worktrees,
real repos, ~/.claude, ~/.codex and GCS are never touched.
"""
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "layout_check.py"


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                   timeout=30)


class LayoutCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="layout_check_"))
        self.home = self.tmp / "home"
        self.outside = self.tmp / "scratch"  # stands in for /tmp/<unique>
        repo = self.home / "projects" / "r"
        repo.mkdir(parents=True)
        self.outside.mkdir()
        git("init", "-q", "-b", "main", str(repo), cwd=self.tmp)
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q",
            "--allow-empty", "-m", "init", cwd=repo)
        (self.home / ".worktrees" / "r").mkdir(parents=True)
        self.wt_a = self.home / ".worktrees" / "r" / "a"
        self.wt_b = self.home / "projects" / "worktree_b"
        self.wt_c = self.outside / "c"
        for i, wt in enumerate((self.wt_a, self.wt_b, self.wt_c)):
            git("worktree", "add", "-q", "-b", f"b{i}", str(wt), cwd=repo)
            (wt / "f.txt").write_text("x")
        for d in ("dk2d_evidence", "Downloads/x_evidence", ".codex/evidence-pr1"):
            (self.home / d).mkdir(parents=True)
        state = self.home / ".disk_magician_state"
        state.mkdir()
        now = datetime.now(timezone.utc)
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        lines = [
            f"{(now - timedelta(days=9)).strftime(fmt)}\tunresolvable\told",
            f"{(now - timedelta(days=1)).strftime(fmt)}\tunresolvable\tgit worktree add \"$WT\"",
            # worktree_guard.py's own format: local time with %z (no colon)
            time.strftime("%Y-%m-%dT%H:%M:%S%z")
            + " unresolvable target='$(mktemp -d)' cmd='git worktree add'",
        ]
        (state / "worktree_guard.log").write_text("\n".join(lines) + "\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_check(self, *args):
        env = dict(os.environ, HOME=str(self.home))
        env.pop("STANDARD_WORKTREE_ROOT", None)
        start = time.monotonic()
        proc = subprocess.run(["python3", str(SCRIPT), *args], env=env,
                              capture_output=True, text=True, timeout=90)
        return proc, time.monotonic() - start

    def test_json_report(self):
        proc, elapsed = self.run_check("--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertLess(elapsed, 60)
        data = json.loads(proc.stdout)
        self.assertFalse(data["truncated"])

        groups = {os.path.realpath(g["parent"]): g
                  for g in data["worktrees_outside_root"]}
        self.assertEqual(set(groups), {os.path.realpath(self.home / "projects"),
                                       os.path.realpath(self.outside)})
        paths = {os.path.realpath(w["path"])
                 for g in groups.values() for w in g["worktrees"]}
        self.assertEqual(paths, {os.path.realpath(self.wt_b),
                                 os.path.realpath(self.wt_c)})
        for g in groups.values():
            self.assertEqual(g["count"], 1)
            self.assertEqual(g["worktrees"][0]["age_days"], 0)

        evidence = {os.path.realpath(p) for p in data["evidence_outside_tmp"]}
        self.assertEqual(evidence, {
            os.path.realpath(self.home / "dk2d_evidence"),
            os.path.realpath(self.home / "Downloads" / "x_evidence"),
            os.path.realpath(self.home / ".codex" / "evidence-pr1"),
        })
        self.assertEqual(data["guard_bypasses_7d"], 2)

    def test_human_table_default(self):
        proc, _ = self.run_check()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("worktree_b", proc.stdout)
        self.assertIn("dk2d_evidence", proc.stdout)
        self.assertNotIn(str(self.wt_a), proc.stdout)

    def test_time_cap_reports_truncated_and_exits_zero(self):
        proc, _ = self.run_check("--json", "--max-seconds", "0")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["truncated"])

    def test_empty_home_exits_zero(self):
        shutil.rmtree(self.home)
        self.home.mkdir()
        proc, _ = self.run_check("--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["worktrees_outside_root"], [])
        self.assertEqual(data["guard_bypasses_7d"], 0)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Regression test for c14_probe.admin() push obligations (bead disk_magician-vp7h).

admin() collects the commit ids under a linked worktree's admin dir and C14 then
requires every one of them to be advertised by ls-remote. Only the worktree's own
HEAD (plus refs/** and logs/**) is its work.

The defect: `rel.endswith("HEAD")` also matched FETCH_HEAD and ORIG_HEAD. FETCH_HEAD
lists every fetched branch tip, so any worktree that had ever run `git fetch`
required dozens of unrelated commits to be advertised and answered
`kept:not-pushed` forever. In practice that made worktree cleanup a silent no-op:
a real sweep reported "0 eligible, 586 preserved" immediately after the preview had
called the very same worktrees eligible.

Real repositories only; no fixture admin dirs, so the test fails if git changes the
layout in a way that matters.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PROBE = REPO_ROOT / "scripts" / "c14_probe.py"


def run(cmd: list[str], cwd: Path) -> str:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True, check=True).stdout


def git(cwd: Path, *args: str) -> str:
    return run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args], cwd)


class TestAdminHeadObligations(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.base = self.root / "base"
        self.base.mkdir()
        git(self.base, "init", "-q", "-b", "main")
        (self.base / "tracked.txt").write_text("tracked\n")
        git(self.base, "add", "-A")
        git(self.base, "commit", "-qm", "base")
        self.head_oid = git(self.base, "rev-parse", "HEAD").strip()

        # A linked worktree: its admin dir lives under base/.git/worktrees/<name>.
        self.wt = self.root / "wt"
        git(self.base, "worktree", "add", "-q", "-b", "wt-branch", str(self.wt))
        self.admin = Path(git(self.wt, "rev-parse", "--absolute-git-dir").strip())
        self.assertNotEqual(self.admin, self.base / ".git", "expected a linked worktree")

        # Produce a FETCH_HEAD whose tip is NOT this worktree's work: fetch a
        # second branch that only exists in a sibling repository.
        other = self.root / "other"
        other.mkdir()
        git(other, "init", "-q", "-b", "main")
        (other / "other.txt").write_text("other\n")
        git(other, "add", "-A")
        git(other, "commit", "-qm", "other")
        self.foreign_oid = git(other, "rev-parse", "HEAD").strip()
        git(self.wt, "fetch", "-q", str(other), "main")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def probe_admin(self) -> list[str]:
        return [
            line.strip()
            for line in run([sys.executable, str(PROBE), "admin", str(self.admin)], cwd=self.root).splitlines()
            if line.strip()
        ]

    def test_fetch_head_oids_are_not_push_obligations(self) -> None:
        fetch_head = self.admin / "FETCH_HEAD"
        self.assertTrue(fetch_head.is_file(), "git fetch did not create FETCH_HEAD in the admin dir")
        self.assertIn(self.foreign_oid, fetch_head.read_text(), "fixture must record the fetched tip")

        oids = self.probe_admin()
        self.assertNotIn(
            self.foreign_oid,
            oids,
            "FETCH_HEAD's fetched tip must not become a push obligation for this worktree",
        )

    def test_own_head_remains_a_push_obligation(self) -> None:
        oids = self.probe_admin()
        self.assertIn(
            self.head_oid,
            oids,
            "the worktree's own HEAD must stay a push obligation (unpushed WIP must still be protected)",
        )

    def test_orig_head_oid_is_not_a_push_obligation(self) -> None:
        # ORIG_HEAD is written by resets/merges; it is history, not work.
        (self.admin / "ORIG_HEAD").write_text(f"{self.foreign_oid}\n")
        self.assertNotIn(self.foreign_oid, self.probe_admin())


if __name__ == "__main__":
    unittest.main()

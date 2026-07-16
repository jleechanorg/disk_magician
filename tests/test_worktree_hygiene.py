#!/usr/bin/env python3
"""Contract tests for scripts/worktree_hygiene.sh (lane-tests deliverable).

Written independently against the exact interface contract handed to
lane-tests (identify_candidates / redact_url / classify_candidate,
sourceable bash functions guarded by the standard
`[[ "${BASH_SOURCE[0]}" == "${0}" ]]` idiom), NOT against whatever
lane-script's actual implementation happens to do. Any divergence between
this file's expectations and the real script is a contract bug to report,
not something these tests should silently adapt to.

  identify_candidates <repo_path> <min_age_days>
    Echoes newline-separated worktree paths (excluding the main worktree)
    whose most-recent file mtime -- excluding .git/, node_modules/, venv/,
    __pycache__ -- is older than min_age_days days.

  redact_url <url>
    Strips embedded credentials from a git remote URL.

  classify_candidate <uncommitted_count> <untracked_present:0|1>
      <push_status> <pr_state> <ahead_count> <has_merge_base:0|1>
    Echoes exactly one line `SAFE|<reason>` or `NEEDS-REVIEW|<reason>`,
    evaluated in priority order (first match wins):
      SAFE|zero-ahead        -- ahead==0 AND uncommitted==0 AND untracked==0
      SAFE|merged-pr-clean   -- pr_state==merged AND uncommitted==0 AND untracked==0
      NEEDS-REVIEW|open-pr             -- pr_state==open
      NEEDS-REVIEW|detached-unpushed   -- push_status==rejected-nonff
      NEEDS-REVIEW|untracked           -- untracked==1
      NEEDS-REVIEW|large-diff          -- uncommitted>50
      NEEDS-REVIEW|no-merge-base       -- has_merge_base==0
      NEEDS-REVIEW|unpushed-ahead      -- ahead>0 AND push_status in {no-remote, skipped}
      NEEDS-REVIEW|dirty               -- fallback when uncommitted>0

Safety note: as of this writing scripts/worktree_hygiene.sh has NOT yet
added the BASH_SOURCE guard, and its unguarded main body defaults to
scanning $HOME/projects (real git push / gh pr list calls). Every
subprocess call in this file that sources the script therefore runs with
an isolated, throwaway $HOME so sourcing it can never touch real repos or
the network, regardless of whether the guard has landed yet.
"""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "worktree_hygiene.sh"
GIT = shutil.which("git") or "/usr/bin/git"
EXCLUDED_DIRNAMES = ("node_modules", "venv", "__pycache__")


def _git(repo, *args, check=True):
    result = subprocess.run(
        [GIT, "-C", str(repo), *args], capture_output=True, text=True
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"git -C {repo} {args} failed: {result.stdout}{result.stderr}"
        )
    return result


def _call(func_name, *args, timeout=15):
    """Source SCRIPT with an isolated $HOME, then invoke func_name with args
    passed as positional shell parameters (avoids shell-quoting injection
    for paths/URLs containing spaces or special characters)."""
    positional = " ".join(f'"${i + 1}"' for i in range(len(args)))
    body = f'source "{SCRIPT}"; {func_name} {positional}'
    cmd = ["bash", "-c", body, "call"] + [str(a) for a in args]
    with tempfile.TemporaryDirectory() as home:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home}
        return subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=timeout
        )


def _classify(uncommitted, untracked, push_status, pr_state, ahead, has_merge_base):
    return _call(
        "classify_candidate",
        uncommitted,
        untracked,
        push_status,
        pr_state,
        ahead,
        has_merge_base,
    )


def _init_repo(parent, dirname="main-repo"):
    repo = parent / dirname
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "fixture@users.noreply.github.com")
    _git(repo, "config", "user.name", "Fixture User")
    (repo / "README.md").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-q", "-m", "base")
    return repo


def _set_mtime(path, days_ago):
    ts = time.time() - days_ago * 86400
    os.utime(path, (ts, ts))


def _age_tree(root, days_ago, skip_dirnames=(".git",)):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip_dirnames]
        for name in filenames:
            _set_mtime(Path(dirpath) / name, days_ago)
        _set_mtime(Path(dirpath), days_ago)


class IdentifyCandidatesTest(unittest.TestCase):
    """(a) IDENTIFY age-filter correctness."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # Resolve once: on macOS $TMPDIR lives under /var/folders, which is a
        # symlink to /private/var/folders. `git worktree list --porcelain`
        # canonicalizes paths, so comparing against the raw tempfile path
        # would spuriously fail even when the script is correct.
        self.tmp = Path(self._tmp.name).resolve()

    def tearDown(self):
        self._tmp.cleanup()

    def test_age_filter_includes_old_excludes_young_and_excludes_main_worktree(self):
        repo = _init_repo(self.tmp)

        old_wt = self.tmp / "wt-old"
        _git(repo, "worktree", "add", "-B", "wt-old", str(old_wt), "main")
        _age_tree(old_wt, 30)

        young_wt = self.tmp / "wt-young"
        _git(repo, "worktree", "add", "-B", "wt-young", str(young_wt), "main")
        _age_tree(young_wt, 3)

        result = _call("identify_candidates", str(repo), "14")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = [line for line in result.stdout.splitlines() if line.strip()]

        self.assertIn(str(old_wt), candidates)
        self.assertNotIn(str(young_wt), candidates)
        self.assertNotIn(str(repo), candidates)

    def test_excluded_dirs_do_not_count_as_recent_activity(self):
        # Only a node_modules/venv/__pycache__ file is recently touched;
        # every real (non-excluded) file is 30 days stale. True content-mtime
        # scanning must still flag this worktree as a stale candidate.
        repo = _init_repo(self.tmp)
        wt = self.tmp / "wt-excluded-dirs-only-recent"
        _git(repo, "worktree", "add", "-B", "wt-excluded-only-recent", str(wt), "main")
        _age_tree(wt, 30)

        for excluded in EXCLUDED_DIRNAMES:
            nested = wt / excluded / "nested"
            nested.mkdir(parents=True)
            fresh_file = nested / "recent.txt"
            fresh_file.write_text("fresh\n", encoding="utf-8")
            _set_mtime(fresh_file, 0.1)
            _set_mtime(nested, 0.1)
            _set_mtime(wt / excluded, 0.1)

        result = _call("identify_candidates", str(repo), "14")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = [line for line in result.stdout.splitlines() if line.strip()]
        self.assertIn(str(wt), candidates)


class RedactUrlTest(unittest.TestCase):
    """(c) redact_url credential stripping."""

    def _redact(self, url):
        result = _call("redact_url", url)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_strips_user_colon_token_credentials(self):
        self.assertEqual(
            self._redact("https://oauth2:ghp_abc123@github.com/org/repo.git"),
            "https://github.com/org/repo.git",
        )

    def test_strips_token_only_no_colon_credentials(self):
        self.assertEqual(
            self._redact("https://ghp_TOKEN123@github.com/org/repo.git"),
            "https://github.com/org/repo.git",
        )

    def test_url_without_credentials_passes_through_unchanged(self):
        self.assertEqual(
            self._redact("https://github.com/org/repo.git"),
            "https://github.com/org/repo.git",
        )


class ClassifyCandidateTest(unittest.TestCase):
    """(b) CLASSIFY priority-ordered decision matrix -- one case per rule,
    plus explicit ordering proofs."""

    def _assert(self, args, expected):
        result = _classify(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)

    def test_zero_ahead_clean_is_safe_zero_ahead(self):
        # push_status=rejected-nonff and pr_state=open would both trigger
        # NEEDS-REVIEW reasons on their own -- zero-ahead must still win
        # because it is the first rule evaluated.
        self._assert((0, 0, "rejected-nonff", "open", 0, 1), "SAFE|zero-ahead")

    def test_merged_pr_clean_is_safe_merged_pr_clean(self):
        self._assert((0, 0, "ok", "merged", 3, 1), "SAFE|merged-pr-clean")

    def test_open_pr_is_needs_review_open_pr(self):
        self._assert((0, 0, "ok", "open", 2, 1), "NEEDS-REVIEW|open-pr")

    def test_rejected_push_is_needs_review_detached_unpushed(self):
        self._assert((0, 0, "rejected-nonff", "none", 1, 1), "NEEDS-REVIEW|detached-unpushed")

    def test_untracked_present_is_needs_review_untracked(self):
        self._assert((0, 1, "ok", "none", 0, 1), "NEEDS-REVIEW|untracked")

    def test_large_diff_is_needs_review_large_diff(self):
        self._assert((60, 0, "ok", "none", 0, 1), "NEEDS-REVIEW|large-diff")

    def test_no_merge_base_is_needs_review_no_merge_base(self):
        self._assert((5, 0, "ok", "none", 0, 0), "NEEDS-REVIEW|no-merge-base")

    def test_unpushed_ahead_no_remote_is_needs_review_unpushed_ahead(self):
        self._assert((0, 0, "no-remote", "none", 2, 1), "NEEDS-REVIEW|unpushed-ahead")

    def test_unpushed_ahead_skipped_is_needs_review_unpushed_ahead(self):
        self._assert((0, 0, "skipped", "none", 2, 1), "NEEDS-REVIEW|unpushed-ahead")

    def test_dirty_fallback_is_needs_review_dirty(self):
        self._assert((3, 0, "ok", "none", 0, 1), "NEEDS-REVIEW|dirty")

    def test_ordering_untracked_wins_over_large_diff(self):
        # untracked=1 AND uncommitted=60: untracked is evaluated before
        # large-diff in priority order, so it must win.
        self._assert((60, 1, "ok", "none", 0, 1), "NEEDS-REVIEW|untracked")


class IntegrationRealGitRepoTest(unittest.TestCase):
    """(d) End-to-end against a real local git repo (no network)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # See IdentifyCandidatesTest.setUp: resolve to match git's
        # canonicalized /private/var/folders paths on macOS.
        self.tmp = Path(self._tmp.name).resolve()

    def tearDown(self):
        self._tmp.cleanup()

    @staticmethod
    def _gather(worktree, main_branch="main"):
        status_lines = _git(worktree, "status", "--porcelain").stdout.splitlines()
        uncommitted = len(status_lines)
        untracked = 1 if any(line.startswith("??") for line in status_lines) else 0
        ahead = int(
            _git(worktree, "rev-list", "--count", f"{main_branch}..HEAD").stdout.strip()
        )
        merge_base = _git(worktree, "merge-base", main_branch, "HEAD", check=False)
        has_merge_base = 1 if merge_base.returncode == 0 else 0
        return uncommitted, untracked, ahead, has_merge_base

    def test_clean_zero_ahead_worktree_end_to_end_is_safe(self):
        repo = _init_repo(self.tmp)
        wt = self.tmp / "wt-clean"
        _git(repo, "worktree", "add", "-B", "wt-clean", str(wt), "main")
        _age_tree(wt, 30)

        identify = _call("identify_candidates", str(repo), "14")
        self.assertEqual(identify.returncode, 0, identify.stderr)
        candidates = [line for line in identify.stdout.splitlines() if line.strip()]
        self.assertIn(str(wt), candidates)

        uncommitted, untracked, ahead, has_merge_base = self._gather(wt)
        self.assertEqual((uncommitted, untracked, ahead), (0, 0, 0))

        result = _classify(uncommitted, untracked, "skipped", "none", ahead, has_merge_base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "SAFE|zero-ahead")

    def test_detached_ahead_with_untracked_file_is_needs_review_untracked(self):
        repo = _init_repo(self.tmp)
        wt = self.tmp / "wt-untracked-ahead"
        _git(repo, "worktree", "add", "-B", "wt-untracked-ahead", str(wt), "main")

        (wt / "extra.txt").write_text("committed change\n", encoding="utf-8")
        _git(wt, "add", "extra.txt")
        _git(wt, "commit", "-q", "-m", "ahead commit")
        _git(wt, "checkout", "--detach", "-q")

        (wt / "stray.txt").write_text("untracked stray file\n", encoding="utf-8")

        uncommitted, untracked, ahead, has_merge_base = self._gather(wt)
        self.assertEqual(untracked, 1)
        self.assertGreaterEqual(ahead, 1)
        self.assertEqual(has_merge_base, 1)

        result = _classify(uncommitted, untracked, "no-remote", "none", ahead, has_merge_base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "NEEDS-REVIEW|untracked")


class ExecuteFlagCliTest(unittest.TestCase):
    """End-to-end CLI proof (bead jleechan-ue9w "Standing rules": read-only/
    dry-run by default, actual delete step requires an explicit flag).
    Complements ClassifyCandidateTest/IntegrationRealGitRepoTest, which
    prove *what* gets classified SAFE but not that only --execute +
    WORKTREE_APPROVED=1 can turn a SAFE verdict into a real deletion."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name).resolve()

    def tearDown(self):
        self._tmp.cleanup()

    def _safe_fixture(self):
        repo = _init_repo(self.tmp)
        wt = self.tmp / "wt-safe"
        _git(repo, "worktree", "add", "-B", "wt-safe", str(wt), "main")
        _age_tree(wt, 30)
        return repo, wt

    def _run(self, repo, extra_args=(), extra_env=None):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.tmp / "home")}
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [
                "bash", str(SCRIPT), "--repos", str(repo), "--min-age", "1",
                "--skip-push", "--skip-gh", *extra_args,
            ],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def test_default_dry_run_never_deletes_the_worktree(self):
        repo, wt = self._safe_fixture()
        self._run(repo)
        self.assertTrue(wt.exists())
        listing = _git(repo, "worktree", "list", "--porcelain").stdout
        self.assertIn(str(wt), listing)

    def test_execute_without_approval_env_var_refuses_to_delete(self):
        repo, wt = self._safe_fixture()
        result = self._run(repo, extra_args=["--execute"])
        self.assertTrue(wt.exists(), "--execute without WORKTREE_APPROVED=1 must not delete")
        self.assertIn("WORKTREE_APPROVED", result.stdout + result.stderr)

    def test_execute_with_approval_deletes_the_safe_worktree(self):
        repo, wt = self._safe_fixture()
        self._run(repo, extra_args=["--execute"], extra_env={"WORKTREE_APPROVED": "1"})
        self.assertFalse(wt.exists(), "--execute + WORKTREE_APPROVED=1 on SAFE should delete")
        listing = _git(repo, "worktree", "list", "--porcelain").stdout
        self.assertNotIn(str(wt), listing)


if __name__ == "__main__":
    unittest.main()

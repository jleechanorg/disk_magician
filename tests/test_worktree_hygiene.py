#!/usr/bin/env python3
"""RED/GREEN contract for scripts/worktree_hygiene.sh (bead jleechan-ue9w).

Algorithm under test (roadmap/2026-07-16 sidekick STATE.md + bead
jleechan-ue9w -- written against the spec before the script existed, see
lane-tests report for RED/GREEN verification status against the real file):

  IDENTIFY -- discover registered worktrees under --repos, filter by TRUE
    last-modified-FILE mtime (find + stat, excluding .git/node_modules/
    venv/__pycache__), not directory creation time and not bare `.git`
    mtime alone (which lags real edits). Default cutoff --min-age 14 days.
  TRIAGE   -- per candidate: `git status --porcelain` (uncommitted count),
    `git push origin HEAD:<branch>` (no --force), `gh pr list --head
    <branch> --state all --json number,state,title`. Any remote URL is
    redacted before ever being printed.
  CLASSIFY -- SAFE only if (0 commits ahead of main) OR (merged/closed PR
    with no unique content vs main), AND uncommitted diff is trivial/zero.
    NEEDS-REVIEW if: open PR exists; detached HEAD with unpushed commits;
    untracked files present; uncommitted diff >~50 files; no merge-base
    with main.
  DELETE   -- `git worktree remove --force` (metadata-safe, never raw
    `rm -rf`), gated behind an explicit --execute flag; default is
    dry-run / no deletion, matching this repo's cleanup_*.sh convention.

Every fixture here is a fully local, offline git repo (bare "origin" on
disk, no github.com network calls) plus a PATH-stubbed `gh` CLI. No real
network or real git remotes are touched.
"""

import json
import os
import stat
import subprocess
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "worktree_hygiene.sh"

# Fake `gh` CLI: reads canned `gh pr list` JSON from $GH_STUB_RESPONSE_FILE
# so each test can control the "open PR" / "merged PR" / "no PR" response
# without touching the network.
GH_STUB = """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  if [[ -n "${GH_STUB_RESPONSE_FILE:-}" && -f "${GH_STUB_RESPONSE_FILE}" ]]; then
    cat "${GH_STUB_RESPONSE_FILE}"
  else
    echo "[]"
  fi
  exit 0
fi
echo "gh-stub: unsupported invocation: $*" >&2
exit 1
"""


def _git(repo, *args, check=True):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git -C {repo} {args} failed: {result.stderr}")
    return result


def _make_gh_stub(bin_dir: Path) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    gh_path = bin_dir / "gh"
    gh_path.write_text(GH_STUB, encoding="utf-8")
    gh_path.chmod(gh_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return gh_path


def _write_gh_response(tmp_path: Path, payload) -> Path:
    response_file = tmp_path / "gh_response.json"
    response_file.write_text(json.dumps(payload), encoding="utf-8")
    return response_file


def _init_bare_origin(tmp_path: Path, name: str = "origin.git") -> Path:
    bare = tmp_path / name
    subprocess.run(["git", "init", "--bare", "-q", str(bare)], check=True)
    return bare


def _init_main_repo(tmp_path: Path, origin: Path, dirname: str = "main-repo") -> Path:
    repo = tmp_path / dirname
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "fixture@users.noreply.github.com")
    _git(repo, "config", "user.name", "Fixture User")
    (repo / "README.md").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-q", "-m", "base")
    _git(repo, "remote", "add", "origin", str(origin))
    _git(repo, "push", "-q", "origin", "main")
    return repo


def _set_mtime(path: Path, days_ago: float) -> None:
    ts = time.time() - days_ago * 86400
    os.utime(path, (ts, ts))


def _age_all_files(root: Path, days_ago: float) -> None:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            _set_mtime(Path(dirpath) / name, days_ago)
        _set_mtime(Path(dirpath), days_ago)


def _run_script(args, extra_path=None, extra_env=None, timeout=30):
    env = dict(os.environ)
    if extra_path:
        env["PATH"] = f"{extra_path}:{env.get('PATH', '')}"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class WorktreeHygieneIdentifyTest(unittest.TestCase):
    """IDENTIFY: true last-modified-FILE scan, not .git mtime / creation time."""

    def test_stale_git_dir_but_recently_edited_file_is_not_flagged_as_stale(self):
        # .git mtime is old (>14d) but a real file was edited yesterday --
        # the spec requires TRUE last-modified-file scanning, so this
        # worktree must NOT be treated as stale/eligible.
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-fresh-content"
            _git(main_repo, "worktree", "add", "-B", "wt-fresh-content", str(wt), "main")
            _age_all_files(wt, days_ago=30)
            recent_file = wt / "recent.txt"
            recent_file.write_text("edited recently\n", encoding="utf-8")
            _set_mtime(recent_file, days_ago=1)
            _set_mtime(wt / ".git", days_ago=30)

            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)
            result = _run_script(
                ["--repos", str(main_repo), "--min-age", "14"],
                extra_path=str(bin_dir),
            )

            self.assertNotIn(str(wt), result.stdout + result.stderr)

    def test_old_git_dir_mtime_with_stale_content_is_flagged_as_stale(self):
        # Inverse of the above: .git dir was touched recently (e.g. by an
        # unrelated `git fetch`) but every real file is untouched for 30
        # days -- true content-mtime scan must still flag this as stale.
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-stale-content"
            _git(main_repo, "worktree", "add", "-B", "wt-stale-content", str(wt), "main")
            _age_all_files(wt, days_ago=30)
            _set_mtime(wt / ".git", days_ago=0.1)

            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)
            result = _run_script(
                ["--repos", str(main_repo), "--min-age", "14"],
                extra_path=str(bin_dir),
            )

            self.assertIn(str(wt), result.stdout + result.stderr)

    def test_worktree_younger_than_cutoff_is_excluded(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-young"
            _git(main_repo, "worktree", "add", "-B", "wt-young", str(wt), "main")
            _age_all_files(wt, days_ago=3)

            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)
            result = _run_script(
                ["--repos", str(main_repo), "--min-age", "14"],
                extra_path=str(bin_dir),
            )

            self.assertNotIn(str(wt), result.stdout + result.stderr)


class WorktreeHygieneClassifyTest(unittest.TestCase):
    """CLASSIFY: SAFE vs NEEDS-REVIEW decision matrix, per bead jleechan-ue9w."""

    def _run_classify(self, tmp, main_repo, gh_payload=None, min_age="1"):
        bin_dir = tmp / "bin"
        _make_gh_stub(bin_dir)
        extra_env = {}
        if gh_payload is not None:
            extra_env["GH_STUB_RESPONSE_FILE"] = str(_write_gh_response(tmp, gh_payload))
        return _run_script(
            ["--repos", str(main_repo), "--min-age", min_age],
            extra_path=str(bin_dir),
            extra_env=extra_env,
        )

    def _assert_label(self, output, wt_path, label):
        lines = [ln for ln in output.splitlines() if str(wt_path) in ln]
        self.assertTrue(lines, f"no output line mentions {wt_path}:\n{output}")
        self.assertTrue(
            any(label.lower() in ln.lower() for ln in lines),
            f"expected a line with {wt_path!r} to contain {label!r}, got:\n"
            + "\n".join(lines),
        )

    def test_zero_commits_ahead_is_safe(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-zero-ahead"
            _git(main_repo, "worktree", "add", "-B", "wt-zero-ahead", str(wt), "main")
            _age_all_files(wt, days_ago=30)

            result = self._run_classify(tmp, main_repo, gh_payload=[])
            self._assert_label(result.stdout + result.stderr, wt, "SAFE")

    def test_squash_merged_pr_with_no_unique_content_is_safe(self):
        # Branch is 1 commit "ahead" by raw rev-list (squash-merge left it
        # unreachable from main) but its net content is already on main and
        # gh reports the PR as MERGED -- must classify SAFE per spec
        # clause (b), not just clause (a)'s zero-ahead shortcut.
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)

            _git(main_repo, "checkout", "-q", "-b", "feature-squashed")
            (main_repo / "feature.txt").write_text("squashed content\n", encoding="utf-8")
            _git(main_repo, "add", "feature.txt")
            _git(main_repo, "commit", "-q", "-m", "feature work")
            _git(main_repo, "checkout", "-q", "main")
            # Simulate the squash-merge landing on main as a *different*
            # commit with identical net content.
            (main_repo / "feature.txt").write_text("squashed content\n", encoding="utf-8")
            _git(main_repo, "add", "feature.txt")
            _git(main_repo, "commit", "-q", "-m", "feature work (squashed)")
            _git(main_repo, "push", "-q", "origin", "main")

            wt = main_repo / "worktrees" / "wt-squash-merged"
            _git(main_repo, "worktree", "add", str(wt), "feature-squashed")
            _age_all_files(wt, days_ago=30)

            gh_payload = [{"number": 101, "state": "MERGED", "title": "feature work"}]
            result = self._run_classify(tmp, main_repo, gh_payload=gh_payload)
            self._assert_label(result.stdout + result.stderr, wt, "SAFE")

    def test_open_pr_is_needs_review(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)

            _git(main_repo, "checkout", "-q", "-b", "feature-open-pr")
            (main_repo / "feature.txt").write_text("in review\n", encoding="utf-8")
            _git(main_repo, "add", "feature.txt")
            _git(main_repo, "commit", "-q", "-m", "in-review work")
            _git(main_repo, "checkout", "-q", "main")

            wt = main_repo / "worktrees" / "wt-open-pr"
            _git(main_repo, "worktree", "add", str(wt), "feature-open-pr")
            _age_all_files(wt, days_ago=30)

            gh_payload = [{"number": 202, "state": "OPEN", "title": "in-review work"}]
            result = self._run_classify(tmp, main_repo, gh_payload=gh_payload)
            self._assert_label(result.stdout + result.stderr, wt, "NEEDS-REVIEW")

    def test_detached_head_with_unpushed_commit_is_needs_review(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            base_sha = _git(main_repo, "rev-parse", "HEAD").stdout.strip()

            wt = main_repo / "worktrees" / "wt-detached"
            _git(main_repo, "worktree", "add", "--detach", str(wt), base_sha)
            (wt / "local_only.txt").write_text("never pushed\n", encoding="utf-8")
            _git(wt, "add", "local_only.txt")
            _git(wt, "commit", "-q", "-m", "detached local work")
            _age_all_files(wt, days_ago=30)
            _set_mtime(wt / "local_only.txt", days_ago=30)

            result = self._run_classify(tmp, main_repo, gh_payload=[])
            self._assert_label(result.stdout + result.stderr, wt, "NEEDS-REVIEW")

    def test_untracked_files_present_is_needs_review(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-untracked"
            _git(main_repo, "worktree", "add", "-B", "wt-untracked", str(wt), "main")
            (wt / "stray.txt").write_text("untracked, git push cannot capture this\n", encoding="utf-8")
            _age_all_files(wt, days_ago=30)

            result = self._run_classify(tmp, main_repo, gh_payload=[])
            self._assert_label(result.stdout + result.stderr, wt, "NEEDS-REVIEW")

    def test_large_uncommitted_diff_is_needs_review(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-big-diff"
            _git(main_repo, "worktree", "add", "-B", "wt-big-diff", str(wt), "main")
            for i in range(55):
                (wt / f"file_{i}.txt").write_text(f"change {i}\n", encoding="utf-8")
            _age_all_files(wt, days_ago=30)

            result = self._run_classify(tmp, main_repo, gh_payload=[])
            self._assert_label(result.stdout + result.stderr, wt, "NEEDS-REVIEW")

    def test_no_merge_base_with_main_is_needs_review(self):
        with _tmp() as tmp:
            origin = _init_bare_origin(tmp)
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-orphan"
            _git(main_repo, "worktree", "add", "--detach", str(wt), "main")
            _git(wt, "checkout", "-q", "--orphan", "orphan-branch")
            _git(wt, "rm", "-rf", "--quiet", ".")
            (wt / "unrelated.txt").write_text("no shared history\n", encoding="utf-8")
            _git(wt, "add", "unrelated.txt")
            _git(wt, "commit", "-q", "-m", "orphan root commit")
            _age_all_files(wt, days_ago=30)

            result = self._run_classify(tmp, main_repo, gh_payload=[])
            self._assert_label(result.stdout + result.stderr, wt, "NEEDS-REVIEW")


class WorktreeHygieneCredentialRedactionTest(unittest.TestCase):
    def test_embedded_token_in_remote_url_never_appears_in_output(self):
        token = "ghp_FAKEfixtureTOKEN1234567890abcdef"
        with _tmp() as tmp:
            # A fully offline local "remote" whose path embeds a
            # token-shaped string, mirroring the live PAT-in-.git/config
            # incident this bead's spec calls out. No network is used --
            # git treats this as a normal local path remote.
            origin = _init_bare_origin(tmp, name=f"{token}-origin.git")
            main_repo = _init_main_repo(tmp, origin)
            wt = main_repo / "worktrees" / "wt-zero-ahead"
            _git(main_repo, "worktree", "add", "-B", "wt-zero-ahead", str(wt), "main")
            _age_all_files(wt, days_ago=30)

            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)
            result = _run_script(
                ["--repos", str(main_repo), "--min-age", "1"],
                extra_path=str(bin_dir),
            )

            combined = result.stdout + result.stderr
            self.assertNotIn(token, combined, "raw token leaked into script output")


class WorktreeHygieneDryRunTest(unittest.TestCase):
    def _safe_fixture(self, tmp):
        origin = _init_bare_origin(tmp)
        main_repo = _init_main_repo(tmp, origin)
        wt = main_repo / "worktrees" / "wt-zero-ahead"
        _git(main_repo, "worktree", "add", "-B", "wt-zero-ahead", str(wt), "main")
        _age_all_files(wt, days_ago=30)
        return main_repo, wt

    def test_default_invocation_never_removes_a_worktree(self):
        with _tmp() as tmp:
            main_repo, wt = self._safe_fixture(tmp)
            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)

            result = _run_script(
                ["--repos", str(main_repo), "--min-age", "1"],
                extra_path=str(bin_dir),
            )

            self.assertTrue(wt.exists(), "dry-run must not delete the worktree directory")
            listing = _git(main_repo, "worktree", "list", "--porcelain").stdout
            self.assertIn(str(wt), listing, "dry-run must not deregister the worktree")
            self.assertNotEqual(result.returncode, None)

    def test_explicit_dry_run_flag_never_removes_a_worktree(self):
        with _tmp() as tmp:
            main_repo, wt = self._safe_fixture(tmp)
            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)

            _run_script(
                ["--repos", str(main_repo), "--min-age", "1", "--dry-run"],
                extra_path=str(bin_dir),
            )

            self.assertTrue(wt.exists())

    def test_execute_flag_removes_a_confirmed_safe_worktree(self):
        with _tmp() as tmp:
            main_repo, wt = self._safe_fixture(tmp)
            bin_dir = tmp / "bin"
            _make_gh_stub(bin_dir)

            _run_script(
                ["--repos", str(main_repo), "--min-age", "1", "--execute"],
                extra_path=str(bin_dir),
                extra_env={"WORKTREE_APPROVED": "1"},
            )

            self.assertFalse(wt.exists(), "--execute on a SAFE candidate should delete it")
            listing = _git(main_repo, "worktree", "list", "--porcelain").stdout
            self.assertNotIn(str(wt), listing)


class _tmp:
    """Thin wrapper so fixture helpers can `with _tmp() as tmp:` like tempfile."""

    def __enter__(self):
        import tempfile

        self._td = tempfile.TemporaryDirectory()
        return Path(self._td.name)

    def __exit__(self, exc_type, exc, tb):
        self._td.cleanup()


if __name__ == "__main__":
    unittest.main()

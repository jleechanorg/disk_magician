#!/usr/bin/env python3
"""test_worktree_guard.py — PreToolUse guard for `git worktree add` placement.

Feeds Claude Code / Codex PreToolUse JSON to scripts/worktree_guard.py under a
temp HOME and asserts allow (exit 0, empty stdout) vs deny (spec D3 schema).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO_ROOT, "scripts", "worktree_guard.py")


class TestWorktreeGuard(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="wtguard_home_")
        os.makedirs(os.path.join(self.home, ".worktrees", "r"))
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("STANDARD_WORKTREE_ROOT", "DISK_MAGICIAN_WORKTREE_GUARD")}
        self.env["HOME"] = self.home
        self.log = os.path.join(self.home, ".disk_magician_state", "worktree_guard.log")

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def run_raw(self, raw, env=None):
        return subprocess.run([sys.executable, GUARD], input=raw, capture_output=True,
                              text=True, env=env or self.env, timeout=10)

    def run_cmd(self, command, tool="Bash", cwd="/r", workdir=None, env=None):
        payload = {"hook_event_name": "PreToolUse", "tool_name": tool,
                   "tool_input": {"command": command}, "cwd": cwd}
        if workdir:
            payload["tool_input"]["workdir"] = workdir
        return self.run_raw(json.dumps(payload), env=env)

    def assertAllow(self, res):
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout, "")

    def assertDeny(self, res):
        self.assertEqual(res.returncode, 0, res.stderr)
        out = json.loads(res.stdout)
        hso = out["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        self.assertEqual(hso["permissionDecision"], "deny")
        self.assertIn("diskm worktree-new", hso["permissionDecisionReason"])
        self.assertIn("~/.worktrees/<repo>/<name>", hso["permissionDecisionReason"])

    # --- deny reason names the concrete destination ----------------------------
    def _git_repo(self, name):
        repo = os.path.join(self.home, "src", name)
        os.makedirs(repo)
        subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
        return os.path.realpath(repo)

    def reason(self, res):
        self.assertDeny(res)
        return json.loads(res.stdout)["hookSpecificOutput"]["permissionDecisionReason"]

    def test_reason_names_concrete_path_and_command(self):
        repo = self._git_repo("myrepo")
        r = self.reason(self.run_cmd("git worktree add -b feat/x /tmp/feat-x", cwd=repo))
        dest = os.path.join(self.home, ".worktrees", "myrepo", "feat-x")
        self.assertIn(dest, r)
        self.assertIn("diskm worktree-new %s feat/x --name feat-x" % repo, r)
        self.assertIn("git worktree add -b feat/x %s" % dest, r)

    def test_reason_from_linked_worktree_cwd_uses_main_repo_name(self):
        repo = self._git_repo("mainrepo")
        subprocess.run(["git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "i"], check=True,
                       env=dict(self.env, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))
        linked = os.path.join(self.home, ".worktrees", "mainrepo", "l1")
        subprocess.run(["git", "-C", repo, "worktree", "add", "-q", linked], check=True)
        r = self.reason(self.run_cmd("git worktree add ../../../projects/wt2", cwd=linked))
        self.assertIn(os.path.join(self.home, ".worktrees", "mainrepo", "wt2"), r)

    def test_reason_strips_mktemp_suffix(self):
        repo = self._git_repo("mk")
        r = self.reason(self.run_cmd(
            'WT=$(mktemp -d /tmp/worktree_fix_XXXXXXXX) && git worktree add "$WT" -b t/fix', cwd=repo))
        self.assertIn(os.path.join(self.home, ".worktrees", "mk", "worktree_fix"), r)
        self.assertIn("diskm worktree-new %s t/fix --name worktree_fix" % repo, r)

    def test_reason_without_branch_uses_placeholder(self):
        repo = self._git_repo("nb")
        r = self.reason(self.run_cmd("git worktree add /tmp/nb-wt", cwd=repo))
        self.assertIn("diskm worktree-new %s <branch> --name nb-wt" % repo, r)

    def test_reason_generic_when_repo_unknown(self):
        r = self.reason(self.run_cmd("git worktree add /tmp/zz", cwd=os.path.join(self.home, "nope")))
        self.assertIn("~/.worktrees/<repo>/<name>", r)

    # --- fast paths / non-matching -------------------------------------------
    def test_non_bash_tool_allows(self):
        payload = {"tool_name": "Edit", "tool_input": {"file_path": "/tmp/worktree"}}
        self.assertAllow(self.run_raw(json.dumps(payload)))

    def test_command_without_worktree_allows(self):
        self.assertAllow(self.run_cmd("ls -la /tmp"))

    def test_malformed_stdin_allows(self):
        self.assertAllow(self.run_raw("{not json worktree"))

    def test_list_remove_prune_allow(self):
        for c in ("git worktree list", "git worktree remove /tmp/x", "git worktree prune"):
            self.assertAllow(self.run_cmd(c))

    def test_env_off_allows(self):
        env = dict(self.env, DISK_MAGICIAN_WORKTREE_GUARD="off")
        self.assertAllow(self.run_cmd("git worktree add /tmp/x -b b", env=env))

    # --- literal targets ------------------------------------------------------
    def test_tmp_target_denied(self):
        self.assertDeny(self.run_cmd("git worktree add /tmp/x -b b"))

    def test_option_values_skipped(self):
        self.assertDeny(self.run_cmd("git worktree add -b /home/x --reason r /tmp/x"))

    def test_git_C_relative_resolves_and_denies(self):
        self.assertDeny(self.run_cmd("git -C /r worktree add ../wt", cwd="/r"))

    def test_cd_into_root_then_relative_allows(self):
        self.assertAllow(self.run_cmd("cd ~/.worktrees/r && git worktree add ./n"))

    def test_home_and_tilde_targets_allow(self):
        self.assertAllow(self.run_cmd('git worktree add "$HOME/.worktrees/r/n"'))
        self.assertAllow(self.run_cmd("git worktree add ~/.worktrees/r/n -b b"))

    def test_chained_add_denied(self):
        self.assertDeny(self.run_cmd("echo a && git worktree add /tmp/y"))

    # --- in-command variable / mktemp resolution ------------------------------
    def test_mktemp_tmp_denied(self):
        self.assertDeny(self.run_cmd('WT=$(mktemp -d /tmp/x_XXXX) && git worktree add "$WT"'))

    def test_mktemp_under_root_allows(self):
        self.assertAllow(self.run_cmd(
            'WT=$(mktemp -d $HOME/.worktrees/r/x_XXXX) && git worktree add "$WT"'))

    def test_literal_assignment_denied(self):
        self.assertDeny(self.run_cmd("WT=/tmp/y; git worktree add $WT"))

    def test_unresolvable_allows_and_logs(self):
        self.assertAllow(self.run_cmd('git worktree add "$WT"'))
        self.assertAllow(self.run_cmd('git worktree add "$(mktemp -d)"'))
        with open(self.log) as f:
            lines = f.read().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("unresolvable", lines[0])

    def test_log_failure_never_fails(self):
        # state dir path occupied by a file -> mkdir fails; guard still allows
        open(os.path.join(self.home, ".disk_magician_state"), "w").close()
        self.assertAllow(self.run_cmd('git worktree add "$WT"'))

    # --- Codex payload shapes -------------------------------------------------
    def test_codex_list_command_with_workdir_denied(self):
        payload = {"tool_name": "exec_command",
                   "tool_input": {"command": ["bash", "-lc", "git worktree add ../wt -b b"],
                                  "workdir": "/r"}}
        self.assertDeny(self.run_raw(json.dumps(payload)))

    def test_codex_shell_tool_under_root_allows(self):
        payload = {"tool_name": "shell", "cwd": os.path.join(self.home, ".worktrees", "r"),
                   "tool_input": {"command": ["bash", "-lc", "git worktree add n"]}}
        self.assertAllow(self.run_raw(json.dumps(payload)))

    def test_lowercase_bash_tool_denied(self):
        self.assertDeny(self.run_cmd("git worktree add /tmp/z", tool="bash"))


if __name__ == "__main__":
    unittest.main()

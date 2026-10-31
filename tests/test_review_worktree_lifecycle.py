#!/usr/bin/env python3
"""PR184 review regressions. Every mutation is confined to a temporary fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorktreeReviewTests(unittest.TestCase):
    def setUp(self):
        scratch = os.environ.get("CLAUDE_CODE_TMPDIR") or os.environ.get("DISKM_SCRATCH") or os.environ.get("RUNNER_TEMP")
        if not scratch or not Path(scratch).is_dir():
            raise RuntimeError("configured Scratch or RUNNER_TEMP directory required")
        self.temp = tempfile.TemporaryDirectory(prefix="review_worktree_", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "DISK_MAGICIAN_", "C14_", "ACT_", "STANDARD_WORKTREE_"))}
        self.env.update(HOME=str(self.home), DISK_MAGICIAN_STATE_DIR=str(self.state),
                        GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="fixture",
                        GIT_AUTHOR_EMAIL="fixture@localhost", GIT_COMMITTER_NAME="fixture",
                        GIT_COMMITTER_EMAIL="fixture@localhost", DISK_MAGICIAN_ADMIT_RETRY_S="0")
        self.repo = self.root / "repo"
        if os.uname().sysname != "Darwin":
            # GNU stat emits filesystem text for BSD -f before failing. Keep
            # this macOS-targeted lease test on its existing GNU fallback.
            bindir = self.root / "bin"
            bindir.mkdir()
            stat = bindir / "stat"
            stat.write_text('#!/bin/sh\n[ "$1" != -f ] || exit 1\nexec ' + shutil.which("stat") + ' "$@"\n')
            stat.chmod(0o755)
            self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]

    def run_cmd(self, *args, check=True, env=None):
        result = subprocess.run(args, cwd=self.root, env=env or self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def make_repo(self):
        self.run_cmd("git", "init", "-q", "--bare", "-b", "main", str(self.root / "origin.git"))
        self.run_cmd("git", "clone", "-q", str(self.root / "origin.git"), str(self.repo))
        (self.repo / "file").write_text("base\n")
        self.run_cmd("git", "-C", str(self.repo), "add", "file")
        self.run_cmd("git", "-C", str(self.repo), "commit", "-qm", "base")
        self.run_cmd("git", "-C", str(self.repo), "push", "-q", "origin", "main")
        self.wt = self.home / ".worktrees" / "repo" / "old"
        self.run_cmd("git", "-C", str(self.repo), "worktree", "add", "-qb", "old", str(self.wt), "origin/main")

    def receipt(self, job):
        return json.loads((self.state / "receipts" / (job + ".json")).read_text())

    def test_expired_claim_passes_real_c14_and_keeps_exact_owner_scope(self):
        self.make_repo()
        claude = self.root / "claude"
        claude.symlink_to(shutil.which("bash"))
        result = self.run_cmd(str(claude), "-c", r'''
source "$1/scripts/worktree_new.sh"
lease_write "$2" "$3" old review
file="$(lease_path_for "$2")"
python3 - "$file" "$2" <<'EOF'
import json, os, sys, time
p, wt = sys.argv[1:]
d = json.load(open(p)); d['created_epoch'] = int(time.time()) - 172800
d['released_at'] = '2020-01-01T00:00:00+00:00'
json.dump(d, open(p, 'w'))
for base, dirs, files in os.walk(wt):
    for name in dirs + files: os.utime(os.path.join(base, name), (1, 1))
os.utime(wt, (1, 1))
EOF
owner="$(lease_resolve_owner)"
hash="$(shasum -a 256 "$file" | awk '{print $1}')"
lease_claim_reuse "$file" "$hash" old "$(git -C "$2" rev-parse HEAD)" "$owner" || exit 1
printf 'BASE=%s\n' "$(lease_owner_state "$file")"
printf 'OWN=%s\n' "$(lease_owner_state_for "$file" "$owner" "$2")"
printf 'OTHER=%s\n' "$(lease_owner_state_for "$file" $'1\t1\tother' "$2")"
printf 'ANCESTOR=%s\n' "$(lease_owner_state_for "$file" "$owner" "${2%/*}")"
printf 'C14=%s\n' "$(artifact_removal_verdict "$2" --own-reuse-claim "$file")"
printf 'UNCLAIMED_C14=%s\n' "$(artifact_removal_verdict "$2")"
python3 - "$file" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['reuse'].pop('previous_lease'); json.dump(d,open(p,'w'))
EOF
printf 'NO_PROOF=%s\n' "$(lease_owner_state_for "$file" "$owner" "$2")"
''', "_", str(ROOT), str(self.wt), str(self.repo))
        rows = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        self.assertEqual(rows, {"BASE": "alive-expired", "OWN": "own-live",
                              "OTHER": "alive-expired", "ANCESTOR": "alive-expired",
                              "C14": "remove", "UNCLAIMED_C14": "kept:live-owner",
                              "NO_PROOF": "alive-expired"}, result.stdout + result.stderr)

    def rollback_case(self, scenario):
        self.make_repo()
        other = self.root / "other"
        result = self.run_cmd("bash", "-c", r'''
source "$1/scripts/worktree_new.sh"
lease_write "$2" "$3" old review
lease_owner_state() { echo dead; }
worktree_is_recently_active_minutes() { return 1; }
artifact_removal_verdict() { [[ "${1:-}" != --self-test ]] && echo remove || echo ok; }
git() {
    if [[ "$REVIEW_SCENARIO" == unknown && -e "$REVIEW_OTHER" && "$*" == *"worktree list"* ]]; then return 1; fi
    command git "$@"; local rc=$?
    if [[ "$rc" == 0 && "$*" == "-C $REVIEW_WT switch --no-overwrite-ignore old" ]]; then
        case "$REVIEW_SCENARIO" in
            occupied) command git -C "$REVIEW_REPO" worktree add -q "$REVIEW_OTHER" new || return 1 ;;
            moved)
                tip="$(command git -C "$REVIEW_REPO" rev-parse new)"
                moved="$(command git -C "$REVIEW_REPO" commit-tree "$tip^{tree}" -p "$tip" -m advanced)"
                command git -C "$REVIEW_REPO" update-ref refs/heads/new "$moved" "$tip" || return 1 ;;
            unknown) touch "$REVIEW_OTHER" ;;
        esac
    fi
    return "$rc"
}
export DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE=1
wtn_reuse "$3" new origin/main
rc=$?
printf 'REUSE_RC=%s\n' "$rc"
printf 'OLD=%s\n' "$(command git -C "$2" symbolic-ref --short HEAD)"
if [[ "$REVIEW_SCENARIO" == occupied ]]; then
    printf 'OTHER=%s\n' "$(command git -C "$4" symbolic-ref --short HEAD)"
    command git -C "$4" rev-parse --verify HEAD >/dev/null || exit 11
elif [[ "$REVIEW_SCENARIO" == moved ]]; then
    [[ "$(command git -C "$3" rev-parse new)" != "$(command git -C "$3" rev-parse origin/main)" ]] || exit 14
fi
command git -C "$3" rev-parse --verify refs/heads/new >/dev/null || exit 12
file="$(lease_path_for "$2")"
[[ "$(_lease_get "$file" branch)" == old && -z "$(_lease_get "$file" reuse)" ]] || exit 13
''', "_", str(ROOT), str(self.wt), str(self.repo), str(other), check=False,
            env=dict(self.env, REVIEW_WT=str(self.wt), REVIEW_REPO=str(self.repo), REVIEW_OTHER=str(other), REVIEW_SCENARIO=scenario))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REUSE_RC=1", result.stdout)
        self.assertIn("OLD=old", result.stdout)
        if scenario == "occupied":
            self.assertIn("OTHER=new", result.stdout)

    def test_reuse_rollback_preserves_new_branch_claimed_after_vacating(self):
        self.rollback_case("occupied")

    def test_reuse_rollback_preserves_moved_new_branch(self):
        self.rollback_case("moved")

    def test_reuse_rollback_preserves_branch_when_occupancy_unreadable(self):
        self.rollback_case("unknown")

    def test_failed_rollback_preserves_ignored_user_bytes(self):
        self.make_repo()
        (self.wt / "ignored-target.txt").write_text("original-tracked\n")
        self.run_cmd("git", "-C", str(self.wt), "add", "ignored-target.txt")
        self.run_cmd("git", "-C", str(self.wt), "commit", "-qm", "old tracked path")
        self.run_cmd("git", "-C", str(self.wt), "push", "-q", "origin", "old")
        excludes = self.root / "excludes"
        excludes.write_text("ignored-target.txt\n")
        self.run_cmd("git", "-C", str(self.repo), "config", "core.excludesFile", str(excludes))
        hook = self.root / "after-switch"
        hook.write_text('#!/bin/sh\nprintf "keep-user-bytes\\n" > "$3/ignored-target.txt"\n')
        hook.chmod(0o755)
        result = self.run_cmd("bash", "-c", r'''
source "$1/scripts/worktree_new.sh"
lease_write "$2" "$3" old review
lease_owner_state() { echo dead; }
worktree_is_recently_active_minutes() { return 1; }
artifact_removal_verdict() { [[ "${1:-}" != --self-test ]] && echo remove || echo ok; }
wtn_reuse "$3" new origin/main
[[ "$?" == 1 ]] || exit 11
[[ "$(cat "$2/ignored-target.txt")" == keep-user-bytes ]] || exit 12
[[ "$(git -C "$2" symbolic-ref --short HEAD)" == new ]] || exit 13
[[ "$(git -C "$3" rev-parse old)" == "$(git -C "$3" rev-parse origin/old)" ]] || exit 14
python3 - "$(lease_path_for "$2")" <<'EOF'
import json,sys
assert json.load(open(sys.argv[1]))['reuse']['state'] == 'reuse_incomplete'
EOF
''', "_", str(ROOT), str(self.wt), str(self.repo),
            env=dict(self.env, DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE="1",
                     DISK_MAGICIAN_TEST_AFTER_BRANCH_SWITCH=str(hook)))
        self.assertIn("would be overwritten", result.stderr)

    def test_cleanup_stopped_repo_function_succeeds_under_errexit(self):
        self.make_repo()
        source = (ROOT / "scripts/cleanup_worktrees.sh").read_text()
        function = source[source.index("process_repo_local_worktrees() {"):source.index("# Standard root (spec D6)")]
        function = "source " + repr(str(ROOT / "scripts/lib/worktree_lease.sh")) + "\n" + function
        result = self.run_cmd("bash", "-euc", function + '\nACT_STOP=1\nprocess_repo_local_worktrees "$1"\necho STOPPED_OK\n',
                              "_", str(self.repo), check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("STOPPED_OK", result.stdout)

    def test_cleanup_expired_deadline_returns_partial_success(self):
        self.make_repo()
        cursor = self.root / "cleanup-cursor.json"
        result = self.run_cmd("bash", str(ROOT / "scripts/cleanup_worktrees.sh"), "--repos", str(self.repo),
                              "--deadline-at", "1", "--cursor", str(cursor), check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt("cleanup_worktrees")
        self.assertEqual(receipt["active"], [])
        self.assertEqual(receipt["last_terminal"]["outcome"], "partial")
        self.assertEqual(receipt["last_terminal"]["reason"], "deadline_before_candidate")
        self.assertEqual(receipt["last_terminal"]["candidates"]["removed_count"], 0)
        self.assertEqual(json.loads(cursor.read_text())["next_index"], 0)
        self.assertTrue(self.wt.exists())

    def reap_error(self, source, cursor, reason):
        result = self.run_cmd("bash", str(source / "worktree_reap.sh"), "--cursor", str(cursor), check=False)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        receipt = self.receipt("worktree_reap")
        self.assertEqual(receipt["active"], [], result.stdout + result.stderr)
        self.assertEqual(len(receipt["completed"]), 1)
        self.assertEqual(receipt["last_terminal"]["outcome"], "error")
        self.assertEqual(receipt["last_terminal"]["reason"], reason)
        self.assertEqual(receipt["last_terminal"]["candidates"]["removed_count"], 0)
        self.assertFalse((self.state / "worktree_reap.lock").exists())

    def test_reap_invalid_cursor_terminalizes_receipt(self):
        cursor = self.root / "cursor.json"
        cursor.write_text("{broken")
        self.reap_error(ROOT / "scripts", cursor, "cursor-invalid")

    def test_reap_initial_cursor_save_failure_terminalizes_receipt(self):
        scripts = self.root / "scripts"
        shutil.copytree(ROOT / "scripts", scripts)
        with (scripts / "lib/actuator_deadline.sh").open("a") as output:
            output.write("\nact_cursor_save() { return 1; }\n")
        self.reap_error(scripts, self.root / "cursor.json", "cursor-save-failed")

    def test_reap_later_cursor_failure_stays_nonzero_and_preserves_lease(self):
        scripts = self.root / "scripts"
        shutil.copytree(ROOT / "scripts", scripts)
        with (scripts / "lib/actuator_deadline.sh").open("a") as output:
            output.write("\neval \"$(declare -f act_cursor_save | sed '1s/act_cursor_save/review_save/')\"\n"
                         "act_cursor_save() { [[ \"$4\" == 0 ]] || return 1; review_save \"$@\"; }\n")
        leases = self.state / "worktree_leases"
        leases.mkdir(parents=True)
        lease = leases / "missing.json"
        lease.write_text(json.dumps({"path": str(self.root / "missing")}))
        self.reap_error(scripts, self.root / "cursor.json", "cursor-save-failed")
        self.assertTrue(lease.exists(), "checkpoint failure must stop later lease pruning")

    def test_reap_terminal_write_failure_is_nonzero_and_not_retried(self):
        scripts = self.root / "scripts"
        shutil.copytree(ROOT / "scripts", scripts)
        calls = self.root / "finish-calls"
        with (scripts / "job_receipt.py").open("a") as output:
            output.write("\n_review_main = main\ndef main():\n"
                         "    if len(sys.argv) > 1 and sys.argv[1] == 'finish':\n"
                         "        with open(" + repr(str(calls)) + ", 'a') as f: f.write('finish\\n')\n"
                         "        return 7\n    return _review_main()\n")
        result = self.run_cmd("bash", str(scripts / "worktree_reap.sh"), check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["finish"])
        receipt = self.receipt("worktree_reap")
        self.assertEqual(receipt["completed"], [])
        self.assertEqual(len(receipt["active"]), 1)
        self.assertFalse((self.state / "worktree_reap.lock").exists())

    def test_reap_success_terminalizes_once(self):
        self.run_cmd("bash", str(ROOT / "scripts/worktree_reap.sh"))
        receipt = self.receipt("worktree_reap")
        self.assertEqual(receipt["active"], [])
        self.assertEqual(len(receipt["completed"]), 1)
        self.assertEqual(receipt["last_terminal"]["outcome"], "success")


if __name__ == "__main__":
    unittest.main(verbosity=2)

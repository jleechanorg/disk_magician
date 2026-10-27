"""Real creator -> admission confirmation -> birth audit, using only /tmp fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GIB = 1 << 30


class AdmissionBirthPipelineTest(unittest.TestCase):
    def test_real_creators_use_frozen_estimates_and_confirm_the_created_generation(self):
        with tempfile.TemporaryDirectory(prefix="dm-admission-pipeline-", dir="/tmp") as tmp:
            root = Path(tmp).resolve()
            home, state, repo = root / "home", root / "state", root / "repo"
            for p in (home, state / "admission", repo, root / "private-tmp", root / "user-tmp"):
                p.mkdir(parents=True)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("GIT_", "DISK_MAGICIAN_", "C14_"))}
            env.update(HOME=str(home), PATH=os.defpath, TMPDIR=str(root / "user-tmp"),
                       DISK_MAGICIAN_STATE_DIR=str(state),
                       DISK_MAGICIAN_CONFIG=str(ROOT / "config.json.template"),
                       DISK_MAGICIAN_POLICY_FILE=str(root / "no-policy.json"),
                       DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE=str(root / "private-tmp"),
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                       GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                       GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
            df = root / "df"
            df.write_text("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\necho '/dev/x 999999999 1 209715200 1% /'\n")
            df.chmod(0o755)
            env["DISK_MAGICIAN_DF_BIN"] = str(df)
            estimates = state / "admission" / "estimates.json"
            estimates.write_text(json.dumps({"worktree-new": 4, "scratch-new": 3, "hook:git-clone": 3.75}))
            frozen = estimates.read_bytes()

            def run(args, input=None):
                result = subprocess.run(args, cwd=root, env=env, input=input, text=True,
                                        capture_output=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result.stdout.strip()

            run(["git", "-C", str(repo), "init", "-q", "-b", "main"])
            run(["git", "-C", str(repo), "commit", "-q", "--allow-empty", "-m", "fixture"])
            worktree = run(["bash", str(ROOT / "disk_magician.sh"), "worktree-new", str(repo), "created"])
            scratch = run(["bash", str(ROOT / "disk_magician.sh"), "scratch-new", str(repo), "scratch"])
            self.assertTrue(Path(worktree).is_dir())
            self.assertTrue(Path(scratch).is_dir())
            admit = root / "admit"
            admit.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "scripts/disk_budget.py"}" "$@"\n')
            admit.chmod(0o755)
            env["DISK_MAGICIAN_ADMIT_BIN"] = str(admit)
            dest = home / ".worktrees" / "repo" / "hook-clone"
            command = f"git clone {repo} {dest}"
            event = {"hook_event_name": "PreToolUse", "tool_use_id": "pipeline-hook",
                     "cwd": str(root), "tool_input": {"command": command}}
            run(["bash", str(ROOT / "hooks/disk-admission.sh")], json.dumps(event))
            run(["git", "clone", "-q", str(repo), str(dest)])
            event.update(hook_event_name="PostToolUse", tool_response={"exit_code": 0})
            run(["bash", str(ROOT / "hooks/disk-admission.sh")], json.dumps(event))
            run([sys.executable, str(ROOT / "scripts/birth_audit.py"), str(root / "private-tmp"),
                 str(root / "user-tmp"), str(home / "Documents/Codex"), str(home / ".worktrees")])
            rows = [json.loads(line) for line in (state / "admission/events.jsonl").read_text().splitlines()]
            admits = [row for row in rows if row.get("event") == "admit"]
            confirms = [row for row in rows if row.get("event") == "admit_confirm"]
            self.assertEqual(sorted(row["est_bytes"] for row in admits), [3 * GIB, int(3.75 * GIB), 4 * GIB])
            self.assertEqual({row["admit_id"] for row in admits}, {row["admit_id"] for row in confirms})
            births = json.loads((state / "admission/births.json").read_text())["gens"]
            self.assertEqual(len(births), 3)
            self.assertTrue(all(row["status"] == "admitted" for row in births.values()), births)
            self.assertEqual(estimates.read_bytes(), frozen)


if __name__ == "__main__":
    unittest.main()

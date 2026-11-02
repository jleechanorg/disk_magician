#!/usr/bin/env python3
"""Interrupt each real outer lease-lock call site in an isolated state root."""

import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
from typing import Optional
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "scripts/lib/worktree_lease.sh"
SCRATCH_BUDGET = ROOT / "scripts/lib/scratch_budget.sh"
CALLERS = {
    "worktree-new": (ROOT / "scripts/worktree_new.sh", "wtn_reuse", "_wtn_reuse"),
    "worktree-reap": (ROOT / "scripts/worktree_reap.sh", "process_lease", "_process_lease"),
    "worktree-remove-hook": (ROOT / "scripts/worktree_remove_hook.sh", "wrh_main", "_wrh_main"),
    "task-scratch": (ROOT / "scripts/cleanup_task_scratch.sh", None, "task_scratch_run"),
    "cleanup-worktrees": (ROOT / "scripts/cleanup_worktrees.sh", "process_repo_local_worktrees", "_process_repo_local_worktrees"),
    "cleanup-codex-documents": (ROOT / "scripts/cleanup_codex_documents.sh", "process_task", "_process_task"),
}


def outer_call(path: Path, public: Optional[str], inner: str) -> str:
    source = path.read_text()
    if public is None:
        assert re.search(r"^_lease_lock_scope release task_scratch_run$", source, re.M), path
        return "_lease_lock_scope release task_scratch_run"
    match = re.search(
        rf"^{re.escape(public)}\(\) \{{ _lease_lock_scope release "
        rf"{re.escape(inner)} \"\$@\"; \}}$",
        source,
        re.M,
    )
    assert match, f"outer lock scope missing from {path}:{public}"
    return match.group(0) + "\n" + public


class OuterCallerInterruptionTest(unittest.TestCase):
    def test_quarantine_subshell_records_live_holder_after_parent_kill(self):
        scratch = os.environ.get("CLAUDE_CODE_TMPDIR") or os.environ.get("DISKM_SCRATCH") or os.environ.get("RUNNER_TEMP")
        self.assertTrue(scratch and Path(scratch).is_dir(), "configured Scratch directory required")
        with tempfile.TemporaryDirectory(prefix="lease-quarantine-", dir=scratch) as tmp:
            work = Path(tmp)
            state = work / "state"
            state.mkdir()
            (work / "candidate").mkdir()
            ready, go = work / "ready", work / "go"
            script = work / "case.sh"
            script.write_text(
                'set -euo pipefail\n'
                f'source "{SCRATCH_BUDGET}"\n'
                'unset ACT_CURSOR ACT_DEADLINE_AT\n'
                'artifact_removal_verdict() {\n'
                '  : > "$READY"\n'
                '  while [[ ! -e "$GO" ]]; do sleep .02; done\n'
                '  echo kept:fixture\n'
                '}\n'
                'result="$(scratch_budget_quarantine_remove "$HOME/candidate")"\n'
                '[[ "$result" == kept:fixture ]]\n'
            )
            env = {**os.environ, "HOME": str(work), "DISK_MAGICIAN_STATE_DIR": str(state),
                   "DISK_MAGICIAN_CONFIG": str(work / "config.json"),
                   "READY": str(ready), "GO": str(go), "BASH_ENV": ""}
            proc = subprocess.Popen(["bash", str(script)], env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 8
                while not ready.exists() and proc.poll() is None:
                    self.assertLess(time.monotonic(), deadline, "quarantine did not reach verdict")
                    time.sleep(.01)
                self.assertTrue(ready.exists(), "quarantine exited before verdict")
                lock = state / "worktree_leases/.owner-mutation.reuse-lock"
                holder = int((lock / "pid").read_text())
                self.assertNotEqual(holder, proc.pid, "subshell lock named its parent")
                os.kill(holder, 0)
                proc.kill()
                proc.wait(timeout=5)
                self.assertTrue(lock.is_dir(), "child lock disappeared with parent")
                os.kill(holder, 0)
                contender = ["bash", "-c", 'source "$1"; lease_write "$2" --kind scratch',
                             "bash", str(LIBRARY), str(work / "other")]
                busy = subprocess.run(contender, env=env, capture_output=True, text=True, timeout=4)
                self.assertNotEqual(busy.returncode, 0, "contender crossed live child lock")
                go.touch()
                proc.communicate(timeout=6)
                self.assertFalse(lock.exists(), "subshell did not release lock after verdict")
                acquired = subprocess.run(contender, env=env, capture_output=True, text=True, timeout=4)
                self.assertEqual(acquired.returncode, 0, acquired.stderr)
            finally:
                go.touch()
                if proc.poll() is None:
                    proc.kill()
                proc.communicate(timeout=6)

    def test_outer_callers_release_on_term_and_exit(self):
        scratch = os.environ.get("CLAUDE_CODE_TMPDIR") or os.environ.get("DISKM_SCRATCH") or os.environ.get("RUNNER_TEMP")
        self.assertTrue(scratch and Path(scratch).is_dir(), "configured Scratch directory required")
        for label, (path, public, inner) in CALLERS.items():
            for mode in ("term", "exit"):
                with self.subTest(caller=label, interruption=mode):
                    with tempfile.TemporaryDirectory(prefix="lease-outer-", dir=scratch) as tmp:
                        work = Path(tmp)
                        state = work / "state"
                        state.mkdir()
                        ready = work / "ready"
                        go = work / "go"
                        script = work / "case.sh"
                        call = outer_call(path, public, inner)
                        script.write_text(
                            'set -euo pipefail\n'
                            f'source "{LIBRARY}"\n'
                            + (call.split("\n")[0] + "\n" if public else "")
                            + f'{inner}() {{\n'
                            '  lease_registry_mutation_lock_enter || return 1\n'
                            '  : > "$READY"\n'
                            '  while [[ ! -e "$GO" ]]; do sleep .02; done\n'
                            '  if [[ "$MODE" == exit ]]; then exit 7; fi\n'
                            '}\n'
                            + (public if public else call) + '\n'
                        )
                        env = {
                            **os.environ,
                            "DISK_MAGICIAN_STATE_DIR": str(state),
                            "READY": str(ready),
                            "GO": str(go),
                            "MODE": mode,
                            "BASH_ENV": "",
                        }
                        proc = subprocess.Popen(
                            ["bash", str(script)], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                        )
                        try:
                            deadline = time.monotonic() + 5
                            while not ready.exists() and proc.poll() is None:
                                self.assertLess(time.monotonic(), deadline, f"{label} never acquired lock")
                                time.sleep(.01)
                            self.assertTrue(ready.exists(), f"{label}: process exited before lock acquisition")
                            lock = state / "worktree_leases/.owner-mutation.reuse-lock"
                            self.assertTrue(lock.is_dir(), f"{label}: lock not held at interruption")
                            contender = [
                                "bash", "-c",
                                'source "$1"; lease_write "$2" --kind scratch',
                                "bash", str(LIBRARY), str(work / "other"),
                            ]
                            busy = subprocess.run(
                                contender, env=env, capture_output=True, text=True, timeout=4
                            )
                            self.assertNotEqual(busy.returncode, 0, f"{label}: contender did not observe held lock")
                            if mode == "term":
                                os.kill(proc.pid, signal.SIGTERM)
                            go.touch()
                            out, err = proc.communicate(timeout=6)
                            self.assertEqual(proc.returncode, 7 if mode == "exit" else -signal.SIGTERM,
                                             (label, mode, out, err))
                            self.assertFalse(lock.exists(), f"{label}: lock survived {mode}")
                            acquired = subprocess.run(
                                contender, env=env, capture_output=True, text=True, timeout=4
                            )
                            self.assertEqual(acquired.returncode, 0, (label, mode, acquired.stderr))
                        finally:
                            if proc.poll() is None:
                                proc.kill()
                                proc.communicate(timeout=2)


if __name__ == "__main__":
    unittest.main()

"""Bounded C14 probes/git calls, intent cap headroom, and setup flag strictness."""
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "c14_probe.py"
VERDICT_SH = ROOT / "scripts" / "lib" / "artifact_verdict.sh"
QUARANTINE = ROOT / "scripts" / "quarantine_rename.py"


class TestBoundedProbes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp", prefix="dm-c14-hyg-")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(os.path.realpath(self.tmp.name))

    def test_probe_on_blocking_fifo_times_out_as_check_failed(self):
        fifo = self.dir / "inv.fifo"
        os.mkfifo(fifo)
        env = {**os.environ, "C14_PROBE_TIMEOUT": "1"}
        t0 = time.monotonic()
        r = subprocess.run(["python3", str(PROBE), "repos", str(fifo)], env=env,
                           capture_output=True, text=True, timeout=20)
        self.assertLess(time.monotonic() - t0, 10)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("kept:check-failed", r.stdout + r.stderr)

    def test_slow_git_in_verdict_path_is_check_failed(self):
        repo = self.dir / "repo"
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        subprocess.run(["git", "init", "-q", str(repo)], check=True, env=env)
        real_git = subprocess.run(["which", "git"], capture_output=True, text=True).stdout.strip()
        stub = self.dir / "bin"
        stub.mkdir()
        g = stub / "git"
        # status is the slow call; everything else is the real git.
        g.write_text(f'#!/bin/bash\nfor a in "$@"; do [ "$a" = status ] && exec sleep 30; done\nexec {real_git} "$@"\n')
        g.chmod(0o755)
        env.update(C14_GIT_TIMEOUT="1")
        t0 = time.monotonic()
        r = subprocess.run(["bash", "-c", f'source "{VERDICT_SH}"; PATH="{stub}:$PATH"; c14_repo_content_ok "{repo}"'],
                           env=env, capture_output=True, text=True, timeout=25)
        self.assertLess(time.monotonic() - t0, 15)
        self.assertEqual(r.stdout.strip(), "kept:check-failed", r.stderr)


class TestIntentCap(unittest.TestCase):
    def test_cap_leaves_room_for_150k_entry_inventories(self):
        line = next(l for l in QUARANTINE.read_text().splitlines() if l.startswith("MAX_INTENT_BYTES"))
        ns = {}
        exec(line, ns)
        self.assertEqual(ns["MAX_INTENT_BYTES"], 256 * 1024 * 1024)


class TestSetupFlags(unittest.TestCase):
    def test_unknown_setup_flag_is_rejected_before_any_work(self):
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="dm-setup-") as home:
            stub = Path(home) / "bin"
            stub.mkdir()
            log = Path(home) / "launchctl.log"
            ctl = stub / "launchctl"
            ctl.write_text(f'#!/bin/bash\necho "$@" >> {log}\n')
            ctl.chmod(0o755)
            env = {**os.environ, "HOME": home, "PATH": f"{stub}:{os.environ['PATH']}"}
            r = subprocess.run(["bash", str(ROOT / "disk_magician.sh"), "setup", "--dryrun"],
                               env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn("--dryrun", r.stderr)
            self.assertNotIn("Setting up Disk Magician", r.stdout)
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()

"""Regression tests for c14_probe.py lsremote local remote alternates and commondir validation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "c14_probe.py"
VERDICT_SH = ROOT / "scripts" / "lib" / "artifact_verdict.sh"
LEASE_SH = ROOT / "scripts" / "lib" / "worktree_lease.sh"


class TestC14ProbeRemoteAlternates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp", prefix="dm-c14-alt-")
        self.addCleanup(self.tmp.cleanup)
        self.tmproot = Path(os.path.realpath(self.tmp.name))
        self.home = self.tmproot / "home"
        self.state = self.tmproot / "state"
        self.ptmp = self.tmproot / "ptmp"
        self.home.mkdir()
        self.state.mkdir()
        self.ptmp.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "DISK_MAGICIAN_STATE_DIR": str(self.state),
            "DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE": str(self.ptmp),
            "DISK_MAGICIAN_TMP_ROOT_OVERRIDE": str(self.ptmp),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        for k in list(self.env):
            if k.startswith("GIT_") and k not in (
                "GIT_CONFIG_NOSYSTEM",
                "GIT_CONFIG_GLOBAL",
                "GIT_AUTHOR_NAME",
                "GIT_AUTHOR_EMAIL",
                "GIT_COMMITTER_NAME",
                "GIT_COMMITTER_EMAIL",
            ):
                del self.env[k]

    def _git(self, repo: Path, *args: str) -> str:
        res = subprocess.run(
            ["git", "-C", str(repo), *args],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        )
        return res.stdout.strip()

    def _init_seed_repo(self, path: Path) -> str:
        path.mkdir(parents=True, exist_ok=True)
        self._git(path, "init", "-q", "-b", "main")
        (path / "tracked.txt").write_text("tracked content\n", encoding="utf-8")
        self._git(path, "add", "tracked.txt")
        self._git(path, "commit", "-qm", "initial commit")
        return self._git(path, "rev-parse", "HEAD")

    def _write_lease_baseline(self, repo: Path) -> None:
        gitdir = self._git(repo, "rev-parse", "--absolute-git-dir")
        meta_out = subprocess.run(
            [sys.executable, str(PROBE), "gitmeta", gitdir],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        lease_path = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1" && lease_path_for "$2"',
                "lease",
                str(LEASE_SH),
                str(repo),
            ],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        Path(lease_path).parent.mkdir(parents=True, exist_ok=True)
        Path(lease_path).write_text(
            json.dumps(
                {
                    "path": str(repo),
                    "owner": {"pid": 1},
                    "released_at": "2026-10-01T00:00:00Z",
                    "git_meta": json.loads(meta_out),
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def _age_tree(self, path: Path, epoch: int = 1700000000) -> None:
        for root, dirs, files in os.walk(path, followlinks=False):
            for name in list(dirs) + list(files):
                p = os.path.join(root, name)
                try:
                    os.utime(p, (epoch, epoch), follow_symlinks=False)
                except OSError:
                    pass
        os.utime(path, (epoch, epoch), follow_symlinks=False)

    def _verdict(self, func_call: str, *args: str) -> str:
        res = subprocess.run(
            [
                "/bin/bash",
                "-c",
                f'source "$1" && {func_call}',
                "verdict",
                str(VERDICT_SH),
                *args,
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )
        return res.stdout.strip()

    def test_standalone_bare_remote_outside_root_passes(self):
        remote = self.tmproot / "remotes" / "standalone.git"
        remote.mkdir(parents=True)
        self._git(remote, "init", "-q", "--bare", "-b", "main")

        cand_root = self.ptmp / "cand-standalone"
        repo = cand_root / "repo"
        self._init_seed_repo(repo)
        self._git(repo, "remote", "add", "origin", str(remote))
        self._git(repo, "push", "-q", "origin", "main")
        self._write_lease_baseline(repo)
        self._age_tree(cand_root)

        ls = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(ls.returncode, 0)
        self.assertEqual(
            self._verdict('c14_repo_pushed_ok "$2" "$3"', str(repo), str(cand_root)),
            "ok",
        )
        self.assertEqual(
            self._verdict('artifact_removal_verdict "$2"', str(repo)),
            "remove",
        )

    def test_bare_remote_outside_root_with_direct_alternates_into_root_rejected(self):
        cand_root = self.ptmp / "cand-direct-alt"
        repo = cand_root / "repo"
        sha = self._init_seed_repo(repo)

        # Bare remote outside cand_root that borrows objects from repo inside cand_root.
        remote = self.tmproot / "remotes" / "direct-alt.git"
        remote.mkdir(parents=True)
        self._git(remote, "init", "-q", "--bare", "-b", "main")
        alt_file = remote / "objects" / "info" / "alternates"
        alt_file.write_text(str(repo / ".git" / "objects") + "\n", encoding="utf-8")
        self._git(remote, "update-ref", "refs/heads/main", sha)

        self._git(repo, "remote", "add", "origin", str(remote))
        self._write_lease_baseline(repo)
        self._age_tree(cand_root)

        ls = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(ls.returncode, 0)
        self.assertEqual(
            self._verdict('c14_repo_pushed_ok "$2" "$3"', str(repo), str(cand_root)),
            "kept:remote-unverified",
        )
        self.assertEqual(
            self._verdict('artifact_removal_verdict "$2"', str(repo)),
            "kept:remote-unverified",
        )

    def test_bare_remote_outside_root_with_transitive_relative_alternates_into_root_rejected(self):
        cand_root = self.ptmp / "cand-trans-alt"
        repo = cand_root / "repo"
        sha = self._init_seed_repo(repo)

        mid_remote = self.tmproot / "remotes" / "mid-alt.git"
        mid_remote.mkdir(parents=True)
        self._git(mid_remote, "init", "-q", "--bare", "-b", "main")
        rel_to_inner = os.path.relpath(repo / ".git" / "objects", mid_remote / "objects")
        (mid_remote / "objects" / "info" / "alternates").write_text(
            "# comment line\n\n" + rel_to_inner + "\n",
            encoding="utf-8",
        )

        top_remote = self.tmproot / "remotes" / "top-alt.git"
        top_remote.mkdir(parents=True)
        self._git(top_remote, "init", "-q", "--bare", "-b", "main")
        rel_to_mid = os.path.relpath(mid_remote / "objects", top_remote / "objects")
        (top_remote / "objects" / "info" / "alternates").write_text(
            rel_to_mid + "\n",
            encoding="utf-8",
        )
        self._git(top_remote, "update-ref", "refs/heads/main", sha)

        self._git(repo, "remote", "add", "origin", str(top_remote))
        self._write_lease_baseline(repo)
        self._age_tree(cand_root)

        ls = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(top_remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(ls.returncode, 0)
        self.assertEqual(
            self._verdict('c14_repo_pushed_ok "$2" "$3"', str(repo), str(cand_root)),
            "kept:remote-unverified",
        )

    def test_linked_worktree_remote_outside_root_with_commondir_inside_root_rejected(self):
        cand_root = self.ptmp / "cand-wt-remote"
        host_repo = cand_root / "host"
        self._init_seed_repo(host_repo)

        ext_wt = self.tmproot / "ext-worktree"
        self._git(host_repo, "worktree", "add", "-q", str(ext_wt), "-b", "ext-branch")

        # Separate repo inside cand_root that points its remote at ext_wt outside cand_root.
        clone_repo = cand_root / "clone"
        subprocess.run(
            ["git", "clone", "-q", str(ext_wt), str(clone_repo)],
            env=self.env,
            check=True,
        )
        self._write_lease_baseline(clone_repo)
        self._age_tree(cand_root)

        ls = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(ext_wt), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(ls.returncode, 0)
        self.assertEqual(
            self._verdict('c14_repo_pushed_ok "$2" "$3"', str(clone_repo), str(cand_root)),
            "kept:remote-unverified",
        )

    def test_bare_remote_outside_root_with_commondir_file_pointing_inside_root_rejected(self):
        cand_root = self.ptmp / "cand-commondir-file"
        repo = cand_root / "repo"
        sha = self._init_seed_repo(repo)

        remote = self.tmproot / "remotes" / "commondir-borrow.git"
        remote.mkdir(parents=True)
        self._git(remote, "init", "-q", "--bare", "-b", "main")
        (remote / "commondir").write_text(str(repo / ".git") + "\n", encoding="utf-8")
        (remote / "refs" / "heads").mkdir(parents=True, exist_ok=True)
        (remote / "refs" / "heads" / "main").write_text(sha + "\n", encoding="utf-8")

        self._git(repo, "remote", "add", "origin", str(remote))
        self._write_lease_baseline(repo)

        ls = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(ls.returncode, 0)
        self.assertEqual(
            self._verdict('c14_repo_pushed_ok "$2" "$3"', str(repo), str(cand_root)),
            "kept:remote-unverified",
        )

    def test_broken_alternates_fails_closed_and_cycle_terminates(self):
        cand_root = self.ptmp / "cand-edge"
        repo = cand_root / "repo"
        sha = self._init_seed_repo(repo)

        broken_remote = self.tmproot / "remotes" / "broken-alt.git"
        broken_remote.mkdir(parents=True)
        self._git(broken_remote, "init", "-q", "--bare", "-b", "main")
        (broken_remote / "refs" / "heads").mkdir(parents=True, exist_ok=True)
        (broken_remote / "refs" / "heads" / "main").write_text(sha + "\n", encoding="utf-8")
        (broken_remote / "objects" / "info" / "alternates").write_text(
            str(self.tmproot / "nonexistent-objects") + "\n",
            encoding="utf-8",
        )
        ls_broken = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(broken_remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(ls_broken.returncode, 0)

        # Mutual alternates cycle between two external remotes should terminate cleanly.
        a_remote = self.tmproot / "remotes" / "cycle-a.git"
        b_remote = self.tmproot / "remotes" / "cycle-b.git"
        a_remote.mkdir(parents=True)
        b_remote.mkdir(parents=True)
        self._git(a_remote, "init", "-q", "--bare", "-b", "main")
        self._git(b_remote, "init", "-q", "--bare", "-b", "main")
        self._git(repo, "push", "-q", str(a_remote), "main")
        (a_remote / "objects" / "info" / "alternates").write_text(
            str(b_remote / "objects") + "\n", encoding="utf-8"
        )
        (b_remote / "objects" / "info" / "alternates").write_text(
            str(a_remote / "objects") + "\n", encoding="utf-8"
        )
        ls_cycle = subprocess.run(
            [sys.executable, str(PROBE), "lsremote", str(a_remote), str(cand_root)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(ls_cycle.returncode, 0)


if __name__ == "__main__":
    unittest.main()

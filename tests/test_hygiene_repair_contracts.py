"""Behavioral repair contracts using private Git and filesystem fixtures."""

import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


class RepairContracts(unittest.TestCase):
    def test_combined_warning_and_invalid_coverage_do_not_publish(self):
        source = (ROOT / "scripts/disk_snapshot.sh").read_text()
        start = source.index("    # Same convention as the frontier ledger")
        end = source.index("    print(json.dumps(data", start)
        code = source[start:end]
        for coverage, expected in [
            (67.0, False),
            (69.9, False),
            (70.0, True),
            (100.0, True),
            (101.0, False),
            (-1.0, False),
            (float("nan"), False),
        ]:
            with self.subTest(coverage=coverage):
                data = {"coverage_effective_pct": coverage}
                env = {"data": data, "os": os, "math": math}
                with mock.patch.dict(
                    os.environ, {"SNAP_WARNING": "low_coverage+stale_previous_snapshot"}
                ):
                    exec(textwrap.dedent(code), env)
                self.assertEqual(data["canonical"], expected)

    def test_dependency_secret_names_excluded_but_user_secret_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            wt = Path(tmp) / "wt"
            wt.mkdir()
            subprocess.run(["git", "init", "-q", str(wt)], check=True)
            (wt / ".gitignore").write_text("node_modules/\n.env\n")
            (wt / "node_modules/pkg").mkdir(parents=True)
            (wt / "node_modules/pkg/credentials.js").write_text("dependency source")
            script = 'source "$1"; worktree_has_live_cwd(){ return 1; }; worktree_has_live_tmux_pane(){ return 1; }; preserve_wip_blocker "$2" "$2" || true'
            subprocess.run(["git", "-C", str(wt), "add", ".gitignore"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(wt),
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "base",
                ],
                check=True,
            )
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(wt),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.stdout.strip(), "")
            (wt / ".env").write_text("synthetic fixture")
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(wt),
                ],
                capture_output=True,
                text=True,
            )
            self.assertIn("ignored-secret:.env", r.stdout)

    def test_no_push_preserves_worktree_and_normal_push_verifies_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            wt = root / "wt"
            remote = root / "remote.git"

            def git(*args):
                return subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        *map(str, args),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            git("init", "-q", "-b", "main", repo)
            (repo / "file").write_text("base")
            git("-C", repo, "add", ".")
            git("-C", repo, "commit", "-qm", "base")
            git("init", "-q", "--bare", remote)
            git("-C", repo, "remote", "add", "origin", remote)
            git("-C", repo, "worktree", "add", "-qb", "feature", wt)
            (wt / "file").write_text("wip")
            script = (
                'source "$1"; SKIP_PUSH=true; preserve_wip_and_remove "$2" "$3" || true'
            )
            env = {
                **os.environ,
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
            }
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                    str(wt),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertTrue(wt.exists(), r.stdout)
            self.assertIn("WIP-KEPT", r.stdout)
            script = 'source "$1"; PUSH_WIP=true; preserve_wip_and_remove "$2" "$3"'
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                    str(wt),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertFalse(wt.exists())
            self.assertIn("VERIFIED-WIP", r.stdout)
            self.assertIn("wip/worktree-hygiene", git("--git-dir", remote, "show-ref"))

    def test_packaged_cli_no_push_reports_local_preservation_without_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            wt = root / "wt"
            home = root / "home"
            home.mkdir()

            def git(*args):
                return subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        *map(str, args),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )

            git("init", "-qb", "main", repo)
            (repo / "file").write_text("base")
            git("-C", repo, "add", ".")
            git("-C", repo, "commit", "-qm", "base")
            git("-C", repo, "worktree", "add", "-qb", "feature", wt)
            (wt / "file").write_text("work in progress")
            old = time.time() - 30 * 86400
            os.utime(wt / "file", (old, old))
            env = {
                **os.environ,
                "HOME": str(home),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
                "PYTHONPATH": str(ROOT / "src"),
                "WORKTREE_APPROVED": "1",
            }
            r = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "disk_magician.cli",
                    "worktree-hygiene",
                    "--repos",
                    "repo",
                    "--execute",
                    "--preserve-wip",
                    "--push-wip",
                    "--no-push",
                    "--skip-gh",
                ],
                env=env,
                cwd=root,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertTrue(wt.exists())
            state = json.loads(
                (root / "state/worktree_hygiene_summary.json").read_text()
            )
            self.assertEqual(state["locally_preserved_wip_count"], 1)
            self.assertEqual(state["counters"]["removed"], 0)
            self.assertEqual(state["pushed_refs_count"], 0)
            self.assertEqual(state["scanned_repos"], [str(repo.resolve())])
            self.assertEqual(state["discovered_repos"], [str(repo.resolve())])
            self.assertEqual(state["skipped_repos"], [])

    def test_genuine_non_fast_forward_uses_verified_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            wt = root / "wt"
            remote = root / "remote.git"

            def git(*args):
                return subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        *map(str, args),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            git("init", "-qb", "main", repo)
            (repo / "file").write_text("base")
            git("-C", repo, "add", ".")
            git("-C", repo, "commit", "-qm", "base")
            git("init", "-q", "--bare", remote)
            git("-C", repo, "remote", "add", "origin", remote)
            git("-C", repo, "push", "-q", "origin", "main")
            git("-C", repo, "worktree", "add", "-qb", "feature", wt)
            ahead = git(
                "--git-dir",
                remote,
                "commit-tree",
                "main^{tree}",
                "-p",
                "main",
                "-m",
                "ahead",
            )
            day = subprocess.check_output(["date", "+%Y%m%d"], text=True).strip()
            ref = "wip/worktree-hygiene/" + day + "/wt"
            git("--git-dir", remote, "update-ref", "refs/heads/" + ref, ahead)
            (wt / "file").write_text("wip")
            env = {
                **os.environ,
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
            }
            script = 'source "$1"; PUSH_WIP=true; preserve_wip_and_remove "$2" "$3"'
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                    str(wt),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertFalse(wt.exists())
            self.assertIn("VERIFIED-WIP", r.stdout)
            self.assertEqual(git("--git-dir", remote, "rev-parse", ref), ahead)
            self.assertEqual(
                git("--git-dir", remote, "rev-parse", "backup/" + ref + "-" + day),
                git("-C", repo, "rev-parse", ref),
            )

    def test_secret_scan_failure_keeps_wip_without_remote_ref(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            wt = root / "wt"
            remote = root / "remote.git"

            def git(*args):
                return subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        *map(str, args),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()

            git("init", "-qb", "main", repo)
            (repo / "file").write_text("base")
            git("-C", repo, "add", ".")
            git("-C", repo, "commit", "-qm", "base")
            git("init", "-q", "--bare", remote)
            git("-C", repo, "remote", "add", "origin", remote)
            git("-C", repo, "worktree", "add", "-qb", "feature", wt)
            (wt / "config.txt").write_text(
                'api_key = "'
                + hashlib.sha256(b"synthetic noncredential fixture").hexdigest()
                + '"\n'
            )
            env = {
                **os.environ,
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
            }
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; PUSH_WIP=true; preserve_wip_and_remove "$2" "$3"',
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                    str(wt),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertTrue(wt.exists())
            self.assertIn("WIP-KEPT", r.stdout)
            self.assertEqual(
                subprocess.run(
                    ["git", "--git-dir", str(remote), "show-ref"],
                    capture_output=True,
                    text=True,
                ).stdout,
                "",
            )

    def test_ignored_evidence_is_listed_for_decision_and_retained(self):
        with tempfile.TemporaryDirectory() as tmp:
            wt = Path(tmp)
            subprocess.run(["git", "init", "-q", str(wt)], check=True)
            (wt / ".gitignore").write_text("evidence/\n")
            (wt / "evidence").mkdir()
            evidence = wt / "evidence/checksums.sha256"
            evidence.write_text("fixture evidence")
            subprocess.run(["git", "-C", str(wt), "add", ".gitignore"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(wt),
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "base",
                ],
                check=True,
            )
            script = 'source "$1"; worktree_has_live_cwd(){ return 1; }; worktree_has_live_tmux_pane(){ return 1; }; preserve_wip_blocker "$2" "$2" || true'
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(wt),
                ],
                capture_output=True,
                text=True,
            )
            self.assertIn("ignored-evidence:evidence/", r.stdout)
            self.assertEqual(evidence.read_text(), "fixture evidence")

    def test_interrupted_main_writes_partial_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            script = 'source "$1"; discover_worktree_repos(){ echo "$2"; }; identify_candidates(){ kill -TERM "$$"; sleep 1; }; main --repos "$2" --skip-push --skip-gh'
            env = {
                **os.environ,
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
            }
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(r.returncode, 0)
            state = root / "state/worktree_hygiene_summary.json"
            self.assertTrue(state.exists(), r.stdout + r.stderr)
            result = json.loads(state.read_text())
            self.assertEqual(result["status"], "interrupted")
            self.assertTrue(result["partial"])
            self.assertEqual(result["skipped_repos"], [str(repo.resolve())])
            self.assertEqual(result["scanned_repos"], [])


if __name__ == "__main__":
    unittest.main()

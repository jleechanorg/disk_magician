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


def _complete_lsof_env():
    """Return a PATH whose `lsof` reports one complete, resolved cwd observation.

    The live-cwd gate is block-always: on a host where unprivileged lsof cannot
    read every live cwd (sshd, sd-pam, setuid sandboxes) the gate refuses, which
    is correct but makes these contracts depend on the host. They are about
    preservation logic, so they inject a complete observation instead.
    """
    d = Path(tempfile.mkdtemp(prefix="dm-fakelsof-"))
    p = d / "lsof"
    p.write_text('#!/bin/sh\nprintf "p1\\nn/\\n"\n')
    p.chmod(0o755)
    return str(d) + os.pathsep + os.environ.get("PATH", "")


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
            old = time.time() - 30 * 86400
            os.utime(wt / "file", (old, old))
            script = (
                'source "$1"; SKIP_PUSH=true; preserve_wip_and_remove "$2" "$3" || true'
            )
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
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
                "PATH": _complete_lsof_env(),
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
            old = time.time() - 30 * 86400
            os.utime(wt / "file", (old, old))
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
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
                "PATH": _complete_lsof_env(),
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

    def test_publication_hook_mutation_keeps_worktree(self):
        for mutation in (
            "ignored-secret",
            "tracked-edit",
            "head-change",
            "lock",
            "recent-touch",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
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
                (repo / ".gitignore").write_text(".env\n")
                git("-C", repo, "add", ".")
                git("-C", repo, "commit", "-qm", "base")
                git("init", "-q", "--bare", remote)
                git("-C", repo, "remote", "add", "origin", remote)
                git("-C", repo, "worktree", "add", "-qb", "feature", wt)
                (wt / "file").write_text("wip")
                old = time.time() - 30 * 86400
                for file in (wt / "file", wt / ".gitignore"):
                    os.utime(file, (old, old))
                hook = repo / ".git/hooks/pre-push"
                commands = {
                    "ignored-secret": 'printf "synthetic fixture" > "$FIXTURE_WT/.env"',
                    "tracked-edit": 'printf "hook edit" >> "$FIXTURE_WT/file"',
                    "head-change": 'git -C "$FIXTURE_WT" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm "hook commit"',
                    "lock": 'git -C "$FIXTURE_REPO" worktree lock "$FIXTURE_WT"',
                    "recent-touch": 'touch "$FIXTURE_WT/file"',
                }
                hook.write_text("#!/bin/sh\n" + commands[mutation] + "\n")
                hook.chmod(0o755)
                env = {
                    **os.environ,
                "PATH": _complete_lsof_env(),
                    "HOME": str(root),
                    "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
                    "FIXTURE_WT": str(wt),
                    "FIXTURE_REPO": str(repo),
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
                    timeout=30,
                )
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertTrue(wt.exists())
                self.assertIn("WIP-KEPT", r.stdout)
                if mutation == "ignored-secret":
                    self.assertEqual((wt / ".env").read_text(), "synthetic fixture")
                elif mutation == "tracked-edit":
                    self.assertIn("hook edit", (wt / "file").read_text())
                elif mutation == "head-change":
                    self.assertEqual(
                        git("-C", wt, "log", "-1", "--format=%s"), "hook commit"
                    )
                elif mutation == "lock":
                    self.assertIn("locked", r.stdout)
                else:
                    self.assertIn("recently-active", r.stdout)

    def test_publication_sends_only_the_scanned_immutable_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            repo = root / "repo"
            remote = root / "remote.git"
            fakebin = root / "bin"
            fakebin.mkdir()

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
            (repo / "file").write_text("scanned")
            git("-C", repo, "add", ".")
            git("-C", repo, "commit", "-qm", "scanned")
            scanned = git("-C", repo, "rev-parse", "HEAD")
            git("init", "-q", "--bare", remote)
            git("-C", repo, "remote", "add", "origin", remote)
            scanner = fakebin / "gitleaks"
            scanner.write_text(
                '#!/bin/sh\nprintf "new unscanned content" > "$FIXTURE_REPO/file"\ngit -C "$FIXTURE_REPO" add file\ngit -C "$FIXTURE_REPO" -c user.name=test -c user.email=test@example.com commit -qm unscanned\n'
            )
            scanner.chmod(0o755)
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
                "HOME": str(root),
                "PATH": str(fakebin) + ":" + os.environ["PATH"],
                "FIXTURE_REPO": str(repo),
            }
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; publish_wip_ref "$2" backup-test',
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                    str(repo),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(
                git("--git-dir", remote, "rev-parse", "refs/heads/backup-test"), scanned
            )
            self.assertNotEqual(git("-C", repo, "rev-parse", "HEAD"), scanned)
            moved = git("-C", repo, "rev-parse", "HEAD")
            self.assertNotEqual(
                subprocess.run(
                    ["git", "--git-dir", str(remote), "cat-file", "-e", moved],
                    capture_output=True,
                ).returncode,
                0,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_interrupted_summary_survives_unwritable_state_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            repo = root / "repo"
            repo.mkdir()
            state = root / "blocked-state"
            state.write_text("owned regular file blocks a state directory")
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(state),
            }
            script = 'source "$1"; identify_candidates(){ kill -TERM "$$"; sleep 1; }; main --repos "$2" --skip-push --skip-gh'
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
            self.assertEqual(r.returncode, 143, r.stdout + r.stderr)
            self.assertIn("partial", r.stdout)
            self.assertIn("Worktree-hygiene status: interrupted", r.stdout)
            self.assertIn("failed to persist", r.stderr)
            self.assertIn("preserved=0", r.stdout)
            self.assertIn("pushed=0", r.stdout)
            self.assertIn("unfinished-repo=" + str(repo), r.stdout)
            self.assertEqual(
                state.read_text(), "owned regular file blocks a state directory"
            )

    def test_preservation_without_push_wip_does_not_publish_clean_ahead_branch(self):
        for preserve, expected in ((True, False), (False, True)):
            with self.subTest(preserve=preserve), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                repo = root / "repo"
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
                git("-C", repo, "checkout", "-qb", "feature")
                (repo / "file").write_text("ahead")
                git("-C", repo, "add", ".")
                git("-C", repo, "commit", "-qm", "ahead")
                script = 'source "$1"; EXECUTE=true; SKIP_GH=true; PRESERVE_WIP="$3"; triage_candidate "$2" "$2" feature'
                env = {**os.environ, "HOME": str(root)}
                r = subprocess.run(
                    [
                        "bash",
                        "-c",
                        script,
                        "fixture",
                        str(ROOT / "scripts/worktree_hygiene.sh"),
                        str(repo),
                        str(preserve).lower(),
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                refs = git("--git-dir", remote, "show-ref")
                self.assertEqual("refs/heads/feature" in refs, expected)

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

    def test_failed_persistence_fallback_retains_all_actual_counters(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            state = root / "state"
            state.write_text("owned regular file")
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(state),
            }
            script = 'source "$1"; HYGIENE_STATUS=interrupted; safe_count=1; review_count=2; preserved_count=3; wip_count=4; removed_count=5; failed_count=6; pushed_count=7; local_wip_count=8; HYGIENE_CURRENT=fixture; HYGIENE_COMPLETED=fixture; HYGIENE_ALL_REPOS=/fixture/repo; HYGIENE_SCANNED_REPOS=""; HYGIENE_REPO=/fixture/repo; hygiene_finish 143'
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(r.returncode, 143, r.stdout + r.stderr)
            for field in (
                "safe=1",
                "needs-review=2",
                "preserved=3",
                "wip-actions=4",
                "removed=5",
                "failed=6",
                "pushed=7",
                "local-wip=8",
                "unfinished-repo=/fixture/repo",
            ):
                self.assertIn(field, r.stdout)
            self.assertEqual(r.stdout.count("Worktree-hygiene status: interrupted"), 1)
            self.assertIn("failed to persist", r.stderr)
            self.assertEqual(state.read_text(), "owned regular file")

    def test_term_during_discovery_records_partial_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
                "HOME": str(root),
                "DISK_MAGICIAN_STATE_DIR": str(root / "state"),
            }
            script = 'source "$1"; discover_worktree_repos(){ kill -TERM "$$"; sleep 1; }; main --skip-push --skip-gh'
            r = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "fixture",
                    str(ROOT / "scripts/worktree_hygiene.sh"),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(r.returncode, 143, r.stdout + r.stderr)
            self.assertIn("Worktree-hygiene status: interrupted", r.stdout)
            state = root / "state/worktree_hygiene_summary.json"
            self.assertTrue(state.exists(), r.stdout + r.stderr)
            data = json.loads(state.read_text())
            self.assertTrue(data["partial"])
            self.assertEqual(data["phase"], "discovery")

    def test_interrupted_main_writes_partial_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            script = 'source "$1"; discover_worktree_repos(){ echo "$2"; }; identify_candidates(){ kill -TERM "$$"; sleep 1; }; main --repos "$2" --skip-push --skip-gh'
            env = {
                **os.environ,
                "PATH": _complete_lsof_env(),
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

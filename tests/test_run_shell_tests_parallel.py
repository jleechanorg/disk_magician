#!/usr/bin/env python3
"""Unit tests for scripts/run_shell_tests_parallel.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_PATH = REPO_ROOT / "scripts" / "run_shell_tests_parallel.py"


def _load_runner_module():
    spec = importlib.util.spec_from_file_location("run_shell_tests_parallel", RUNNER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class TestRunShellTestsParallel(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = _load_runner_module()

    def _write_script(self, directory: Path, name: str, body: str) -> Path:
        path = directory / name
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_concurrent_execution_and_speedup(self) -> None:
        """Concurrent execution of synthetic shell scripts proves max_concurrent >= 2 and wall_s < serial_sum_s."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            scripts = [
                self._write_script(
                    tmp_dir,
                    f"test_sleep_{i}.sh",
                    f"""\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    sleep 0.4
                    echo "ok-{i}"
                    """,
                )
                for i in range(4)
            ]
            proc = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--jobs",
                    "4",
                    "--repo-root",
                    str(tmp_dir),
                    *[str(s) for s in scripts],
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
            match = re.search(
                r"parallel-shell-tests: total=(\d+) passed=(\d+) failed=(\d+) "
                r"max_concurrent=(\d+) wall_s=([0-9.]+) serial_sum_s=([0-9.]+) speedup=([0-9.]+)x",
                proc.stdout,
            )
            self.assertIsNotNone(match, msg=f"Missing summary line in:\n{proc.stdout}")
            assert match is not None
            total = int(match.group(1))
            passed = int(match.group(2))
            failed = int(match.group(3))
            max_conc = int(match.group(4))
            wall_s = float(match.group(5))
            serial_sum_s = float(match.group(6))

            self.assertEqual(total, 4)
            self.assertEqual(passed, 4)
            self.assertEqual(failed, 0)
            self.assertGreaterEqual(max_conc, 2)
            self.assertLess(wall_s, serial_sum_s)

    def test_isolated_tmpdir_per_test(self) -> None:
        """Each concurrent test gets a distinct TMPDIR under /tmp/dm-ci-shard-* and it is cleaned up afterward."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            record_dir = tmp_dir / "records"
            record_dir.mkdir()
            scripts = []
            for i in range(3):
                scripts.append(
                    self._write_script(
                        tmp_dir,
                        f"test_tmpdir_{i}.sh",
                        f"""\
                        #!/usr/bin/env bash
                        set -euo pipefail
                        # Write to an identically named file inside $TMPDIR; if shared, they would collide.
                        echo "owner-{i}" > "$TMPDIR/collision_probe.txt"
                        sleep 0.25
                        [[ "$(cat "$TMPDIR/collision_probe.txt")" == "owner-{i}" ]]
                        echo "$TMPDIR" > "{record_dir}/tmpdir_{i}.txt"
                        """,
                    )
                )

            proc = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--jobs",
                    "3",
                    "--repo-root",
                    str(tmp_dir),
                    *[str(s) for s in scripts],
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)

            observed_tmpdirs = [
                (record_dir / f"tmpdir_{i}.txt").read_text(encoding="utf-8").strip()
                for i in range(3)
            ]
            self.assertEqual(len(set(observed_tmpdirs)), 3, msg=f"TMPDIRs collided: {observed_tmpdirs}")
            for d in observed_tmpdirs:
                self.assertIn("/tmp/dm-ci-shard-", d)
                self.assertFalse(Path(d).exists(), msg=f"Per-test TMPDIR was not cleaned up: {d}")

    def test_failing_and_timed_out_scripts_exit_nonzero_and_name_script(self) -> None:
        """A failing script or timed-out script exits non-zero and names the failed script."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            ok_script = self._write_script(
                tmp_dir,
                "test_pass.sh",
                """\
                #!/usr/bin/env bash
                echo "all good"
                exit 0
                """,
            )
            fail_script = self._write_script(
                tmp_dir,
                "test_intentional_fail.sh",
                """\
                #!/usr/bin/env bash
                echo "something broke" >&2
                exit 7
                """,
            )
            proc_fail = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--jobs",
                    "2",
                    "--repo-root",
                    str(tmp_dir),
                    str(ok_script),
                    str(fail_script),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_fail.returncode, 0)
            self.assertIn("test_intentional_fail.sh", proc_fail.stdout)
            self.assertIn("failed=1", proc_fail.stdout)

            timeout_script = self._write_script(
                tmp_dir,
                "test_hang_forever.sh",
                """\
                #!/usr/bin/env bash
                sleep 30
                """,
            )
            proc_timeout = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--jobs",
                    "2",
                    "--timeout",
                    "0.4",
                    "--repo-root",
                    str(tmp_dir),
                    str(ok_script),
                    str(timeout_script),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_timeout.returncode, 0)
            self.assertIn("test_hang_forever.sh", proc_timeout.stdout)
            self.assertIn("rc=124", proc_timeout.stdout)
            self.assertIn("failed=1", proc_timeout.stdout)

    def test_heavy_first_ordering_schedules_priority_tests_first(self) -> None:
        """build_test_specs orders HEAVY_PRIORITY tests ahead of regular tests in exact priority order."""
        inputs = [
            "tests/test_zebra.sh",
            "tests/test_alpha.sh",
            "tests/test_artifact_verdict.sh",
            "tests/test_worktree_new.sh",
            "tests/test_worktree_reap.sh",
            "tests/test_worktree_remove_hook.sh",
        ]
        specs = self.runner.build_test_specs(inputs, repo_root=REPO_ROOT)
        ordered_names = [s.display_name for s in specs]
        self.assertEqual(
            ordered_names,
            [
                "tests/test_worktree_new.sh",
                "tests/test_worktree_reap.sh",
                "tests/test_artifact_verdict.sh",
                "tests/test_worktree_remove_hook.sh",
                "tests/test_alpha.sh",
                "tests/test_zebra.sh",
            ],
        )
        self.assertEqual(specs[0].timeout_s, 1500.0)
        self.assertEqual(specs[1].timeout_s, 600.0)
        self.assertEqual(specs[2].timeout_s, 900.0)
        self.assertEqual(specs[3].timeout_s, 300.0)
        self.assertEqual(specs[4].timeout_s, 300.0)

    def test_disk_magician_test_shell_dispatch(self) -> None:
        """disk_magician.sh test-shell dispatches to run_shell_tests_parallel.py."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            s1 = self._write_script(
                tmp_dir,
                "test_cli_dispatch.sh",
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "dispatched-ok"
                """,
            )
            proc = subprocess.run(
                [
                    "/bin/bash",
                    str(REPO_ROOT / "disk_magician.sh"),
                    "test-shell",
                    "--jobs",
                    "2",
                    "--repo-root",
                    str(tmp_dir),
                    str(s1),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
            self.assertIn("dispatched-ok", proc.stdout)
            self.assertIn("parallel-shell-tests: total=1 passed=1 failed=0", proc.stdout)

    def test_empty_test_list_exits_nonzero(self) -> None:
        """When discovery finds zero test scripts, the runner fails closed (rc != 0)."""
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--repo-root",
                    str(tmp),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no test scripts matched", proc.stderr)

    def test_disk_magician_deploy_checkout_resolution(self) -> None:
        """disk_magician.sh deploy works from an installed wheel path when run inside a git checkout and fails closed outside a checkout."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            wheel_dir = tmp_dir / "installed_wheel"
            (wheel_dir / "tools").mkdir(parents=True)
            installed_dm = wheel_dir / "disk_magician.sh"
            installed_dm.write_text(
                (REPO_ROOT / "disk_magician.sh").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            installed_dm.chmod(0o755)
            installed_deploy = wheel_dir / "tools" / "deploy_uv_tool.sh"
            installed_deploy.write_text(
                (REPO_ROOT / "tools" / "deploy_uv_tool.sh").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            installed_deploy.chmod(0o755)

            outside_dir = tmp_dir / "outside"
            outside_dir.mkdir()
            proc_outside = subprocess.run(
                ["/bin/bash", str(installed_dm), "deploy", "--check"],
                cwd=str(outside_dir),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(proc_outside.returncode, 0)
            self.assertIn("must be run from a disk_magician git checkout", proc_outside.stderr)


if __name__ == "__main__":
    unittest.main()

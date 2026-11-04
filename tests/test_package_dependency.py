from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackageDependencyTests(unittest.TestCase):
    def test_isolated_wheel_install_supplies_yaml_to_packaged_launcher(self) -> None:
        """The packaged Python must parse AO YAML without system/Ruby fallback."""
        with tempfile.TemporaryDirectory(prefix="disk-magician-package-dependency-") as tmp:
            root = Path(tmp)
            fixture = root / "fixture"
            fixture.mkdir()
            for filename in ("pyproject.toml", "setup.py", "README.md"):
                shutil.copy2(ROOT / filename, fixture / filename)
            for filename in ("__init__.py", "cli.py", "python_bin/python3"):
                destination = fixture / "src" / "disk_magician" / filename
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / "src" / "disk_magician" / filename, destination)
            parser_source = fixture / "scripts" / "lib" / "ao_worktree_config.sh"
            parser_source.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts" / "lib" / "ao_worktree_config.sh", parser_source)

            dist = root / "dist"
            dist.mkdir()
            built = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "pip",
                    "wheel",
                    "--no-deps",
                    "--no-build-isolation",
                    "--wheel-dir",
                    str(dist),
                    str(fixture),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            wheels = list(dist.glob("*.whl"))
            self.assertEqual(len(wheels), 1)

            venv = root / "venv"
            subprocess.run(
                [sys.executable, "-m", "venv", str(venv)],
                check=True,
                capture_output=True,
                text=True,
                timeout=60,
            )
            python = venv / "bin" / "python"
            installed = subprocess.run(
                [
                    str(python),
                    "-m",
                    "pip",
                    "install",
                    "--disable-pip-version-check",
                    "--no-input",
                    "--only-binary=:all:",
                    str(wheels[0]),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)

            package_root = Path(
                subprocess.check_output(
                    [str(python), "-c", "import disk_magician; print(disk_magician.__path__[0])"],
                    text=True,
                    timeout=10,
                ).strip()
            )
            package_python_bin = package_root / "python_bin"
            parser = package_root / "scripts" / "lib" / "ao_worktree_config.sh"
            self.assertTrue((package_python_bin / "python3").is_file())
            self.assertTrue(parser.is_file())

            launcher_env = json.loads(
                subprocess.check_output(
                    [
                        str(python),
                        "-c",
                        "import json, os; from disk_magician.cli import _build_orchestrator_env; print(json.dumps(_build_orchestrator_env({'PATH': os.environ['PATH']}, 'linux')))",
                    ],
                    env={"PATH": str(package_python_bin)},
                    text=True,
                    timeout=10,
                )
            )

            valid = root / "valid.yaml"
            valid.write_text(
                "projects:\n  demo:\n    worktreeDir: /ao/worktrees/demo\n",
                encoding="utf-8",
            )
            malformed = root / "malformed.yaml"
            malformed.write_text("projects:\n  demo: {}\n  demo: {}\n", encoding="utf-8")
            # This is intentionally the packaged wrapper only.  If the wheel
            # omitted PyYAML, neither system Python nor Ruby can satisfy the
            # parser branch in this environment.
            env = launcher_env

            def parse(config: Path) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        'source "$1"; ao_worktree_dirs "$2"',
                        "disk-magician-package-test",
                        str(parser),
                        str(config),
                    ],
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )

            parsed = parse(valid)
            self.assertEqual(parsed.returncode, 0, parsed.stderr)
            self.assertEqual(parsed.stdout, "P /ao/worktrees/demo\n")

            rejected = parse(malformed)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(rejected.stdout, "")


if __name__ == "__main__":
    unittest.main()

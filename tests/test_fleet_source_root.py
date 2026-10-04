#!/usr/bin/env python3
"""Public fleet CLI regression for package-root versus deployed source-root routing."""

import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
import shutil


ROOT = Path(__file__).resolve().parents[1]


class FleetSourceRootTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.package_root = self.root / "package-root"
        self.source_root = self.root / "manifest-source-root"
        self.other_root = self.root / "other-root"
        self.agents = self.root / "agents"
        self.fakebin = self.root / "bin"
        (self.package_root / "launchd").mkdir(parents=True)
        self.source_root.mkdir()
        self.other_root.mkdir()
        self.agents.mkdir()
        self.fakebin.mkdir()
        (self.package_root / "disk_magician.sh").write_text("#!/bin/sh\n")
        template = {
            "Label": "com.example.repo-helper",
            "ProgramArguments": ["/bin/bash", "@REPO_ROOT@/scripts/helper.sh"],
            "RunAtLoad": True,
        }
        (self.package_root / "launchd" / "com.example.repo-helper.plist.template").write_bytes(
            plistlib.dumps(template)
        )
        self.helper_plist = self.agents / "com.example.repo-helper.plist"
        self.primary_plist = self.agents / "com.jleechanorg.disk-magician.plist"
        self._write_installed(self.source_root)
        self.fake_launchctl = self.fakebin / "launchctl"
        self.fake_launchctl.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = print ]; then printf '%s = {\\n' \"$2\"; exit 0; fi\n"
            "exit 2\n"
        )
        self.fake_launchctl.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _write_installed(self, helper_root: Path):
        helper = {
            "Label": "com.example.repo-helper",
            "ProgramArguments": ["/bin/bash", str((helper_root / "scripts/helper.sh").resolve())],
            "RunAtLoad": True,
        }
        self.helper_plist.write_bytes(plistlib.dumps(helper))
        primary = {
            "Label": "com.jleechanorg.disk-magician",
            "ProgramArguments": ["/tmp/home/.local/bin/diskm", "snapshot"],
            "StartInterval": 1800,
        }
        self.primary_plist.write_bytes(plistlib.dumps(primary))

    def _run_fleet(self):
        env = {
            **os.environ,
            "HOME": "/tmp/home",
            "PATH": f"{self.fakebin}:{os.environ.get('PATH', '')}",
            "DISK_MAGICIAN_OSTYPE": "darwin-test",
            "DISK_MAGICIAN_LAUNCHCTL_UID": "501",
            "DISK_MAGICIAN_LAUNCHAGENTS_DIR": str(self.agents),
            "DISK_MAGICIAN_EXPECTED_SOURCE_ROOT": str(self.source_root),
        }
        return subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/job_inventory.py"),
                "--repo-root",
                str(self.package_root),
                "--expected-source-root",
                str(self.source_root),
                "--json",
            ],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def _prepare_status_tree(self):
        scripts = self.package_root / "scripts"
        scripts.mkdir()
        for name in (
            "disk_status.py",
            "history_diff.py",
            "job_receipt.py",
            "resolve_config.py",
            "resolve_state_repo_path.py",
            "check_launchd_fleet.sh",
            "job_inventory.py",
        ):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        (scripts / "check_launchd_fleet.sh").chmod(0o755)
        state_dir = self.root / "status-state"
        state_dir.mkdir()
        state_repo = self.root / "status-repo"
        state_repo.mkdir()
        return state_dir, state_repo

    def _run_public_status(self, state_dir: Path, state_repo: Path):
        env = {
            **os.environ,
            "HOME": "/tmp/home",
            "PATH": f"{self.fakebin}:{os.environ.get('PATH', '')}",
            "DISK_MAGICIAN_OSTYPE": "darwin-test",
            "DISK_MAGICIAN_LAUNCHCTL_UID": "501",
            "DISK_MAGICIAN_LAUNCHAGENTS_DIR": str(self.agents),
            # This simulates a stale caller-provided value.  A valid manifest
            # may replace it; an invalid or missing manifest must clear it.
            "DISK_MAGICIAN_EXPECTED_SOURCE_ROOT": str(self.source_root),
        }
        return subprocess.run(
            [
                "python3",
                str(self.package_root / "scripts/disk_status.py"),
                "--state-dir",
                str(state_dir),
                "--state-repo",
                str(state_repo),
                "--json",
                "--now",
                "2026-10-04T00:00:00Z",
            ],
            cwd=self.package_root,
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def _write_manifest(self, state_dir: Path, value):
        manifest = state_dir / "deployed.json"
        if value is None:
            manifest.unlink(missing_ok=True)
        elif isinstance(value, str):
            manifest.write_text(value, encoding="utf-8")
        else:
            manifest.write_text(json.dumps(value), encoding="utf-8")

    def test_public_status_binds_fleet_only_to_valid_manifest_source_root(self):
        state_dir, state_repo = self._prepare_status_tree()
        self._write_manifest(state_dir, {"source_root": str(self.source_root)})

        valid = self._run_public_status(state_dir, state_repo)
        self.assertIn(valid.returncode, (0, 1, 2), valid.stderr + valid.stdout)
        valid_status = json.loads(valid.stdout)
        self.assertEqual(valid_status["dimensions"]["fleet"]["status"], "healthy")

        for invalid_manifest in ("not json", None):
            self._write_installed(self.source_root)
            self._write_manifest(state_dir, invalid_manifest)
            result = self._run_public_status(state_dir, state_repo)
            self.assertIn(result.returncode, (0, 1, 2), result.stderr + result.stdout)
            status = json.loads(result.stdout)
            fleet = status["dimensions"]["fleet"]
            self.assertEqual(fleet["status"], "degraded")
            helper = next(record for record in fleet["records"] if record["label"] == "com.example.repo-helper")
            self.assertEqual(helper["expected_execution_root"], str(self.package_root.resolve()))

    def test_public_fleet_cli_uses_manifest_source_root_and_rejects_other_root(self):
        matching = self._run_fleet()
        self.assertEqual(matching.returncode, 0, matching.stderr + matching.stdout)
        healthy = json.loads(matching.stdout)
        helper = next(record for record in healthy["records"] if record["label"] == "com.example.repo-helper")
        self.assertEqual(helper["status"], "healthy")
        self.assertEqual(helper["expected_execution_root"], str(self.source_root.resolve()))

        self._write_installed(self.other_root)
        mismatched = self._run_fleet()
        self.assertEqual(mismatched.returncode, 1, mismatched.stderr)
        degraded = json.loads(mismatched.stdout)
        helper = next(record for record in degraded["records"] if record["label"] == "com.example.repo-helper")
        self.assertEqual(helper["status"], "degraded")
        self.assertIn("execution_root", helper["reason"])


if __name__ == "__main__":
    unittest.main()

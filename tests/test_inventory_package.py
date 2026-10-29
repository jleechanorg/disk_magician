from __future__ import annotations

import shutil
import os
import json
import signal
import time
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
EXPECTED_SYSTEMD = {
    "systemd/disk-magician-routine-clean.service.template",
    "systemd/disk-magician-routine-clean.timer.template",
}
EXPECTED_SCHEDULER = {
    "templates/systemd/disk-magician-inventory-root.service.template",
    "templates/systemd/disk-magician-snapshot.service.template",
    "templates/systemd/disk-magician-snapshot.timer.template",
}
EXPECTED_POLKIT = {"templates/polkit/50-disk-magician-inventory-root.rules.template"}


try:
    import setuptools
except ImportError:
    setuptools = None


class InventoryPackageTests(unittest.TestCase):
    def test_wheel_contains_inventory_and_scheduler_templates_and_shared_dispatcher(self) -> None:
        if setuptools is None:
            self.skipTest("setuptools not available in test environment")
        with tempfile.TemporaryDirectory(prefix="disk-magician-package-test-") as tmp:
            fixture = Path(tmp) / "fixture"
            fixture.mkdir()
            for filename in ("setup.py", "pyproject.toml", "README.md", "disk_magician.sh", "config.json.template", "safety.local.json.template"):
                shutil.copy2(REPO / filename, fixture / filename)
            shutil.copytree(REPO / "src" / "disk_magician", fixture / "src" / "disk_magician", dirs_exist_ok=True)
            for dirname in ("config", "scripts", "launchd", "tools", "hooks", "systemd", "templates"):
                source = REPO / dirname
                if source.is_dir():
                    shutil.copytree(source, fixture / dirname)
            dist = Path(tmp) / "dist"
            dist.mkdir()
            proc = subprocess.run(
                [sys.executable, "-m", "pip", "wheel", "--no-deps", "--no-build-isolation", "--wheel-dir", str(dist), str(fixture)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            wheels = list(dist.glob("*.whl"))
            self.assertEqual(len(wheels), 1)
            with zipfile.ZipFile(wheels[0]) as wheel:
                names = set(wheel.namelist())
                for rel in ("safety.local.json.template", "scripts/native_disposable.py", "systemd/diskm-scratch-reclaim.service.in", "systemd/diskm-scratch-reclaim.timer.in",
                            "scripts/volume_reclaim.sh", "scripts/scratch_pressure.py",
                            "launchd/com.jleechanorg.disk-magician-scratch-pressure.plist.template"):
                    self.assertEqual(wheel.read("disk_magician/" + rel), (REPO / rel).read_bytes(), rel)

                self.assertEqual(wheel.read("disk_magician/cli.py"), (REPO / "src/disk_magician/cli.py").read_bytes())
                self.assertIn("disk_magician/scripts/directory_inventory.py", names)
                expected_wheel_systemd = {f"disk_magician/{rel}" for rel in EXPECTED_SYSTEMD}
                self.assertTrue(expected_wheel_systemd <= names, expected_wheel_systemd - names)
                entry_points_files = [n for n in names if n.endswith("/entry_points.txt")]
                self.assertTrue(entry_points_files, "entry_points.txt not found in wheel")
                entry_points = wheel.read(entry_points_files[0]).decode()
                self.assertIn("disk-magician = disk_magician.cli:main", entry_points)
                self.assertIn("diskm = disk_magician.cli:main", entry_points)
                install = Path(tmp) / "install"
                installed = subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--no-deps", "--no-compile", "--target", str(install), str(wheels[0])],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
                self.assertTrue((install / "disk_magician/scripts/directory_inventory.py").is_file())
                self.assertTrue((install / "disk_magician/systemd/disk-magician-routine-clean.service.template").is_file())
                for command in ("diskm", "disk-magician"):
                    wrapper = (install / "bin" / command).read_text()
                    self.assertIn("from disk_magician.cli import main", wrapper)
                # Fresh installed HOME has no machine-local safety file: the
                # canonical safe baseline must ship, never silently allow-all.
                clean_home = Path(tmp) / "clean-home"
                clean_home.mkdir()
                clean_env = {"PATH": os.environ["PATH"], "HOME": str(clean_home),
                             "PYTHONPATH": str(install), "XDG_CONFIG_HOME": str(clean_home / ".config"),
                             "XDG_STATE_HOME": str(clean_home / ".local/state")}
                plan = subprocess.run([str(install / "bin/diskm"), "disposable", "init",
                                       "--root", "/not-created-native-package-fixture"],
                                      env=clean_env, text=True, capture_output=True)
                if sys.platform.startswith("linux"):
                    self.assertEqual(plan.returncode, 0, plan.stderr)
                    self.assertEqual(json.loads(plan.stdout)["status"], "plan-only")
                    self.assertFalse(Path("/not-created-native-package-fixture").exists())
                else:
                    self.assertNotEqual(plan.returncode, 0)  # Linux-only contract
                timeout = shutil.which("timeout") or shutil.which("gtimeout")
                if timeout:
                    sandbox = Path(tmp) / "signal-fixture"
                    sandbox.mkdir()
                    fake = sandbox / "blocked-diskm"
                    fake.write_text("#!/bin/bash\nsleep 4\n")
                    fake.chmod(0o700)
                    binary = sandbox / "bin"
                    binary.mkdir()
                    wrapper = binary / "timeout"
                    wrapper.write_text('#!/bin/bash\nexec ' + timeout + ' --signal=TERM --kill-after=0.1s 2s "${@:4}"\n')
                    wrapper.chmod(0o700)
                    state = sandbox / "state"
                    env = dict(os.environ, HOME=str(sandbox), DISK_MAGICIAN_STATE_DIR=str(state),
                               DISK_MAGICIAN_DISKM_BIN=str(fake), PYTHONPATH=str(install),
                               PATH=str(binary) + os.pathsep + os.environ["PATH"])
                    process = subprocess.Popen([str(install / "bin/diskm"), "volume", "reclaim", "--available-floor", "--clean"],
                                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               start_new_session=True)
                    receipt_path = state / "receipts/volume_reclaim.json"
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline and not receipt_path.exists():
                        time.sleep(.02)
                    self.assertTrue(receipt_path.exists())
                    process.send_signal(signal.SIGTERM)
                    output, error = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, 143, error.decode())
                    receipt = json.loads(receipt_path.read_text())
                    self.assertEqual(receipt["active"], [])
                    self.assertEqual(receipt["last_terminal"]["reason"], "scheduler-interrupted")
                expected_templates = {f"disk_magician/{rel}" for rel in EXPECTED_SCHEDULER | EXPECTED_POLKIT}
                self.assertTrue(expected_templates <= names, expected_templates - names)
                for rel in EXPECTED_SCHEDULER | EXPECTED_POLKIT:
                    self.assertTrue((install / ("disk_magician/" + rel)).is_file(), rel)

    def test_sync_stage_contains_inventory_and_scheduler_templates(self) -> None:
        with tempfile.TemporaryDirectory(prefix="disk-magician-stage-test-") as tmp:
            stage = Path(tmp) / "stage"
            subprocess.run(["bash", str(REPO / "scripts" / "sync_package_tree.sh"), "--stage", str(stage)], check=True)
            self.assertTrue((stage / "scripts" / "directory_inventory.py").is_file())
            for rel in EXPECTED_SYSTEMD:
                self.assertTrue((stage / rel).is_file(), rel)
            for rel in EXPECTED_SCHEDULER | EXPECTED_POLKIT:
                self.assertTrue((stage / rel).is_file(), rel)


if __name__ == "__main__":
    unittest.main()

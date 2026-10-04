import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DISPATCH = {
    "status": "disk_status.py",
    "growth-top10": "growth_top10.py",
    "frontier-nightly": "disk_frontier_scan.sh",
    "pressure-sweep": "pressure_sweep.sh",
    "tmp-scratch-sweep": "tmp_scratch_sweep.sh",
    "cleanup-claude-state": "cleanup_claude_state.sh",
    "codex-vacuum": "cleanup_codex_db.sh",
}


class ReliabilityDispatchTests(unittest.TestCase):
    def test_dispatch_preserves_arguments_environment_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "disk_magician.sh", root)
            for command, helper in DISPATCH.items():
                path = root / "scripts" / helper
                program = (
                    "import json,os,sys\n"
                    "print(json.dumps({'args':sys.argv[1:],"
                    "'state':os.environ['DISK_MAGICIAN_STATE_DIR']}))\n"
                    "sys.exit(17)\n"
                )
                if helper.endswith(".sh"):
                    program = "#!/bin/bash\nexec python3 - \"$@\" <<'PY'\n" + program + "PY\n"
                path.write_text(program)
                path.chmod(0o755)
                env = dict(
                    os.environ, HOME=str(root), DISK_MAGICIAN_STATE_DIR="state with spaces",
                    DISK_MAGICIAN_TEST_CONTEXT="cli-dispatch-fixture",
                    DISK_MAGICIAN_TEST_SANDBOX=str(root),
                )
                env["PATH"] = "/bin:/usr/bin:" + os.environ.get("PATH", "")
                with self.subTest(command=command):
                    result = subprocess.run(
                        ["/bin/bash", str(root / "disk_magician.sh"), command,
                         "--json", "argument with spaces", "--dry-run"],
                        env=env, capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 17, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {
                        "args": ["--json", "argument with spaces", "--dry-run"],
                        "state": "state with spaces",
                    })

    def test_console_names_share_one_entrypoint_and_include_registry(self):
        source = (ROOT / "pyproject.toml").read_text()
        for name in ("diskm", "disk-magician"):
            self.assertRegex(source, rf'(?m)^{name} = "disk_magician\.cli:main"$')
        self.assertIn('"config/*.txt"', source)

    def test_snapshot_setup_uses_installed_command_and_preserves_schedule(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy2(ROOT / "disk_magician.sh", root)
            bin_dir = root / ".local" / "bin"
            bin_dir.mkdir(parents=True)
            for name in ("git", "launchctl", "gh"):
                stub = bin_dir / name
                stub.write_text("#!/bin/bash\nexit " + ("1" if name == "gh" else "0") + "\n")
                stub.chmod(0o755)
            env = dict(os.environ, HOME=str(root), PATH=str(bin_dir) + ":/bin:/usr/bin")
            command = ["/bin/bash", "-c", 'OSTYPE=darwin-test; source "$1" setup',
                       "fixture", str(root / "disk_magician.sh")]
            missing = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("Install the packaged diskm", missing.stderr)
            self.assertFalse((root / ".disk_magician_backup").exists())
            binary = bin_dir / "diskm"
            binary.write_text("#!/bin/bash\nexit 0\n")
            binary.chmod(0o755)
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            plist = root / "Library/LaunchAgents/com.jleechanorg.disk-magician.plist"
            data = plistlib.loads(plist.read_bytes())
            self.assertEqual(data["ProgramArguments"], [str(binary), "snapshot"])
            self.assertEqual(data["StartInterval"], 1800)
            self.assertTrue(data["RunAtLoad"])

            crontab = bin_dir / "crontab"
            crontab.write_text(
                '#!/bin/bash\nif [[ "$1" == "-l" ]]; then\n'
                'cat "$HOME/crontab"\nelse\ncat > "$HOME/crontab"\nfi\n'
            )
            crontab.chmod(0o755)
            command[2] = 'OSTYPE=linux-test; source "$1" setup'
            for _ in range(2):
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            entries = (root / "crontab").read_text().splitlines()
            self.assertEqual(sum(str(binary) in line for line in entries), 1)
            self.assertTrue(any(line.startswith("*/30 ") for line in entries))

    def test_scoped_templates_use_packaged_dispatch_without_argument_changes(self):
        templates = {
            "com.jleechanorg.disk-magician-frontier-nightly":
                ["frontier-nightly", "--granularity-gib", "5", "--wall-clock-cap", "43200", "--output-default"],
            "com.jleechanorg.disk-magician-pressure-sweep": ["pressure-sweep"],
            "com.jleechanorg.disk-magician-tmp-scratch": ["tmp-scratch-sweep", "--clean"],
            "com.disk-magician.claude-state": ["cleanup-claude-state", "--dry-run"],
            "com.disk-magician.codex-vacuum": ["codex-vacuum", "--clean"],
        }
        for label, args in templates.items():
            with self.subTest(label=label):
                raw = (ROOT / "launchd" / (label + ".plist.template")).read_text()
                data = plistlib.loads(re.sub(r"<!--.*?-->", "", raw, flags=re.S).encode())
                self.assertEqual(data["Label"], label)
                self.assertEqual(data["ProgramArguments"], ["@HOME@/.local/bin/diskm"] + args)


if __name__ == "__main__":
    unittest.main()

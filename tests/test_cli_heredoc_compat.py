import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from disk_magician import cli


PAYLOAD = "x" * 600 + "\n"


def make_heredoc_script(path):
    probe = (
        "import hashlib,json,os,stat,sys; data=sys.stdin.buffer.read(); "
        "print(json.dumps({'bash_compat':os.environ.get('BASH_COMPAT'), "
        "'stdin_regular':stat.S_ISREG(os.fstat(0).st_mode), "
        "'length':len(data), 'sha256':hashlib.sha256(data).hexdigest()}))"
    )
    path.write_text(
        shlex.quote(sys.executable) + " -c " + shlex.quote(probe)
        + " <<'PAYLOAD'\n" + PAYLOAD + "PAYLOAD\n"
    )
    return path


class CliHeredocCompatTests(unittest.TestCase):
    def run_cli(self, script, platform, caller_compat):
        completed = []
        real_run = subprocess.run

        def capture_run(*args, **kwargs):
            result = real_run(*args, capture_output=True, text=True, timeout=10, **kwargs)
            completed.append(result)
            return result

        with mock.patch.dict(os.environ, {"BASH_COMPAT": caller_compat}):
            with mock.patch.object(cli.sys, "platform", platform), \
                 mock.patch.object(cli.sys, "argv", ["disk-magician"]), \
                 mock.patch.object(cli, "get_orchestrator_path", return_value=script), \
                 mock.patch.object(cli.subprocess, "run", side_effect=capture_run):
                with self.assertRaises(SystemExit) as raised:
                    cli.main()
            self.assertEqual(os.environ["BASH_COMPAT"], caller_compat)

        self.assertEqual(raised.exception.code, 0)
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0].returncode, 0, completed[0].stderr)
        return json.loads(completed[0].stdout)

    def test_darwin_cli_uses_compat_mode_for_regular_file_heredoc(self):
        if sys.platform != "darwin":
            self.skipTest("Darwin Bash heredoc delivery is platform-specific")
        version = subprocess.run(
            ["bash", "-c", "printf %s \"$BASH_VERSION\""],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout
        match = re.match(r"^(\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) < (5, 2):
            self.skipTest(f"Bash {version!r} predates pipe-backed heredocs")

        with tempfile.TemporaryDirectory() as directory:
            script = make_heredoc_script(Path(directory) / "orchestrator.sh")
            baseline_env = os.environ.copy()
            baseline_env.pop("BASH_COMPAT", None)
            baseline = subprocess.run(
                ["bash", str(script)], env=baseline_env,
                capture_output=True, text=True, check=True, timeout=10,
            )
            self.assertFalse(json.loads(baseline.stdout)["stdin_regular"])

            result = self.run_cli(script, "darwin", "4.4")

        self.assertEqual(result["bash_compat"], "5.0")
        self.assertTrue(result["stdin_regular"])
        self.assertEqual(result["length"], len(PAYLOAD.encode()))
        self.assertEqual(result["sha256"], hashlib.sha256(PAYLOAD.encode()).hexdigest())

        with tempfile.TemporaryDirectory() as directory:
            script = make_heredoc_script(Path(directory) / "orchestrator.sh")
            system_path = "/bin:/usr/bin"
            self.assertEqual(shutil.which("bash", path=system_path), "/bin/bash")
            with mock.patch.dict(os.environ, {"PATH": system_path}):
                system_bash_result = self.run_cli(script, "darwin", "4.4")
        self.assertEqual(system_bash_result["length"], len(PAYLOAD.encode()))
        self.assertEqual(
            system_bash_result["sha256"], hashlib.sha256(PAYLOAD.encode()).hexdigest()
        )

    def test_non_darwin_cli_preserves_caller_compat_value(self):
        with tempfile.TemporaryDirectory() as directory:
            script = make_heredoc_script(Path(directory) / "orchestrator.sh")
            result = self.run_cli(script, "linux", "4.4")

        self.assertEqual(result["bash_compat"], "4.4")
        self.assertEqual(result["length"], len(PAYLOAD.encode()))
        self.assertEqual(result["sha256"], hashlib.sha256(PAYLOAD.encode()).hexdigest())

    def test_environment_builder_copies_and_only_overrides_darwin_child(self):
        source = {"BASH_COMPAT": "4.4", "KEEP": "yes"}
        darwin = cli._build_orchestrator_env(source, "darwin")
        linux = cli._build_orchestrator_env(source, "linux")

        self.assertEqual(darwin, {"BASH_COMPAT": "5.0", "KEEP": "yes"})
        self.assertEqual(linux, source)
        self.assertEqual(source["BASH_COMPAT"], "4.4")
        self.assertIsNot(darwin, source)
        self.assertIsNot(linux, source)


if __name__ == "__main__":
    unittest.main()

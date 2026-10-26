import errno
import os
import pathlib
import pty
import select
import subprocess
import time
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAC = ROOT / "tools/create_mac_scratch.sh"
LINUX = ROOT / "tools/authenticate_linux_scratch.sh"
CANDIDATE_REL = pathlib.Path(
    ".local/share/disk-magician/candidates/5793451d927a944ba2d013244aa7aa42db881dcd/venv/bin/diskm"
)


class ScratchSetupScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.candidate = self.home / CANDIDATE_REL
        self.candidate.parent.mkdir(parents=True)
        self.config = self.home / ".config/disk-magician"
        self.config.mkdir(parents=True)
        for name in ("linux-scratch.json", "mac-scratch.json"):
            path = self.config / name
            path.write_text("{}\n")
            path.chmod(0o600)
        self.calls = self.home / "calls"

    def fake_cli(self, script):
        self.candidate.write_text("#!/usr/bin/env bash\n" + script)
        self.candidate.chmod(0o700)
        source = self.candidate.parents[1] / "lib/python3.12/site-packages/disk_magician/scripts/volume.py"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes((ROOT / "scripts/volume.py").read_bytes())

    def fake_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(0o700)

    def env(self, extra=None):
        env = dict(os.environ)
        env.update({"HOME": str(self.home), "PATH": str(self.bin) + ":" + env["PATH"], "CALLS": str(self.calls)})
        env.update(extra or {})
        return env

    def run_pty(self, script, env):
        master, slave = pty.openpty()
        process = None
        output = bytearray()
        deadline = time.monotonic() + 20
        try:
            process = subprocess.Popen(["bash", str(script)], stdin=slave, stdout=slave,
                                       stderr=slave, env=env, close_fds=True)
            os.close(slave)
            slave = -1
            while True:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                elif process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("fake-CLI PTY run exceeded 20 seconds")
            return subprocess.CompletedProcess(["bash", str(script)], process.wait(),
                                                bytes(output), b"")
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            if slave >= 0:
                os.close(slave)
            os.close(master)

    def test_linux_authenticates_and_requires_active_cli_identity(self):
        self.fake_command("sudo", '[[ "$1" == -v ]] && echo sudo >> "$CALLS"')
        self.fake_command("uname", 'echo Linux')
        self.fake_cli('''printf '%s\\n' "$*" >> "$CALLS"
if [[ "$1 $2" == "volume status" ]]; then echo '{"alarms":[],"volumes":[{"class":"scratch","status":"active"}]}'
elif [[ "$1 $2" == "volume path" ]]; then echo /home/example/Scratch
else exit 2; fi''')
        result = self.run_pty(LINUX, self.env())
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        lines = self.calls.read_text().splitlines()
        self.assertEqual(lines, ["sudo", "volume status --json", "volume path scratch"])
        self.assertIn(b"Authentication ready", result.stdout)
        self.assertNotIn(b"migrate", self.calls.read_bytes())

    def test_linux_fails_closed_when_candidate_identity_check_fails(self):
        self.fake_command("sudo", '[[ "$1" == -v ]]')
        self.fake_command("uname", 'echo Linux')
        self.fake_cli("""if [[ "$1 $2" == "volume status" ]]; then echo '{"alarms":[],"volumes":[]}'


elif [[ "$1 $2" == "volume path" ]]; then exit 75
else exit 2; fi""")
        result = self.run_pty(LINUX, self.env())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"Authentication ready", result.stdout)

    def test_mac_create_uses_cli_preview_execute_and_final_identity_check(self):
        self.fake_command("uname", 'echo Darwin')
        self.fake_command("stat", '[[ "$1" == -f && "$2" == %Lp ]] && echo 600')
        self.fake_cli('''printf '%s\\n' "$*" >> "$CALLS"
if [[ "$1 $2" == "volume status" ]]; then echo '{"alarms":[],"volumes":[]}'
elif [[ "$1 $2" == "volume path" ]]; then [[ -f "$CALLS.active" ]] && echo /Volumes/diskm-scratch || exit 1
elif [[ "$1 $2" == "volume create" ]]; then
  [[ "${4:-}" == "--execute" ]] && { : > "$CALLS.active"; exit 0; }
  echo '{"fits":true,"quota_gb":70}'
else exit 2; fi''')
        result = self.run_pty(MAC, self.env())
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        self.assertEqual(self.calls.read_text().splitlines(), [
            "volume status --json", "volume path scratch", "volume create scratch", "volume create scratch --execute",
            "volume status --json", "volume path scratch",
        ])

    def test_mac_existing_active_volume_is_idempotent(self):
        self.fake_command("uname", 'echo Darwin')
        self.fake_command("stat", '[[ "$1" == -f && "$2" == %Lp ]] && echo 600')
        self.fake_cli('''printf '%s\\n' "$*" >> "$CALLS"
if [[ "$1 $2" == "volume status" ]]; then echo '{"alarms":[],"volumes":[]}'
elif [[ "$1 $2" == "volume path" ]]; then echo /Volumes/diskm-scratch
else exit 2; fi''')
        result = self.run_pty(MAC, self.env())
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        self.assertEqual(self.calls.read_text().splitlines(), ["volume status --json", "volume path scratch"])


if __name__ == "__main__":
    unittest.main()

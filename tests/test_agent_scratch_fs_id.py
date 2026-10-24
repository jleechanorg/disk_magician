"""Offline filesystem-identity portability tests; all paths are owned fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/lib/agent_scratch.sh'


class ScratchIdentity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / 'leaf'
        self.target.mkdir()

    def identity(self, env=None):
        return subprocess.run(['bash', '-c', 'source "$1"; _agent_scratch_fs_id "$2"',
                               'test', str(HELPER), str(self.target)],
                              env=env, text=True, capture_output=True, check=False)

    def fake_stat(self, body):
        bin_dir = self.root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        stat = bin_dir / 'stat'
        stat.write_text('#!/bin/bash\n' + body)
        stat.chmod(0o755)
        return dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'])

    def test_native_identity_is_exact_and_stable_after_child_write(self):
        expected = f'{self.target.stat().st_dev}:{self.target.stat().st_ino}\n'
        self.assertEqual((0, expected), (self.identity().returncode, self.identity().stdout))
        (self.target / 'child').write_bytes(b'x' * 65536)
        self.assertEqual(expected, self.identity().stdout)

    def test_bsd_command_fixture_discards_failed_gnu_output(self):
        env = self.fake_stat('if [[ "$1" == -c ]]; then echo BAD_GNU_OUTPUT; exit 1; fi\n'
                             'if [[ "$1" == -f && "$2" == "%d:%i" ]]; then echo 12:34; exit 0; fi\nexit 2\n')
        result = self.identity(env)
        self.assertEqual((0, '12:34\n'), (result.returncode, result.stdout))

    def test_failed_native_commands_do_not_pollute_python_fallback(self):
        env = self.fake_stat('echo BAD_NATIVE_OUTPUT; exit 1\n')
        result = self.identity(env)
        self.assertEqual(0, result.returncode)
        self.assertEqual(f'{self.target.stat().st_dev}:{self.target.stat().st_ino}\n', result.stdout)

    def test_missing_path_fails_closed_without_identity(self):
        self.target.rmdir()
        result = self.identity()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('', result.stdout)


if __name__ == '__main__':
    unittest.main()

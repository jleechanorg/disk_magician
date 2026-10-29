"""Isolated policy tests: no host cleanup or scheduler installation."""
import importlib.util
import pathlib
import plistlib
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ScratchPressureTests(unittest.TestCase):
    def policy(self):
        spec = importlib.util.spec_from_file_location('scratch_pressure', ROOT / 'scripts/scratch_pressure.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_available_not_total_free_or_quota(self):
        policy = self.policy()
        with patch.object(policy.os, 'statvfs', return_value=SimpleNamespace(f_bavail=7, f_frsize=4096, f_bfree=99999)) as stat:
            self.assertEqual(policy.available_bytes('/verified/scratch'), 7 * 4096)
            stat.assert_called_once_with('/verified/scratch')

    def test_exact_boundary(self):
        policy = self.policy()
        self.assertTrue(policy.needs_reclaim(50 * 2**30 - 1))
        self.assertFalse(policy.needs_reclaim(50 * 2**30))
        self.assertFalse(policy.needs_reclaim(50 * 2**30 + 1))

    def test_invalid_measurement_fails_closed(self):
        policy = self.policy()
        for value in (-1, None, True):
            with self.assertRaises(ValueError):
                policy.needs_reclaim(value)
        with patch.object(policy.os, 'statvfs', side_effect=OSError('unavailable')):
            with self.assertRaises(OSError):
                policy.available_bytes('/unavailable')

    def test_schedules_only_scratch_pressure(self):
        path = ROOT / 'launchd/com.jleechanorg.disk-magician-scratch-pressure.plist.template'
        plist = plistlib.loads(path.read_bytes())
        self.assertEqual(plist['StartInterval'], 1200)
        self.assertEqual(plist['ProgramArguments'][1:], ['volume', 'reclaim', '--available-floor', '--clean'])
        service = (ROOT / 'systemd/diskm-scratch-reclaim.service.in').read_text()
        self.assertIn('volume reclaim --available-floor --clean', service)
        self.assertIn('OnCalendar=*:0/20', (ROOT / 'scripts/volume.py').read_text())
        legacy = plistlib.loads((ROOT / 'launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template').read_bytes())
        self.assertEqual(legacy['StartInterval'], 3600)
        self.assertIn('volume_args=(volume reclaim --available-floor)', (ROOT / 'scripts/tmp_scratch_sweep.sh').read_text())


class ScratchPressureIntegrationTests(unittest.TestCase):
    def test_real_entrypoint_pressure_gate_and_mount_failure(self):
        import os
        import subprocess
        import tempfile
        import time
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            scratch = root / 'scratch'
            candidate = scratch / 'repo/build/old'
            candidate.mkdir(parents=True)
            old = time.time() - 72 * 3600
            (candidate / "artifact").write_text("fixture")
            os.utime(candidate / "artifact", (old, old))
            os.utime(candidate, (old, old))
            diskm = root / 'diskm'
            diskm.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
 'volume path scratch --for-reclaim') echo "$SCRATCH";;
 'volume verify-mount '*) exit "${MOUNT_RC:-0}";;
 'volume ballast recover scratch') exit 0;;
 'volume status --json --snapshot') echo '{"volumes":[{"class":"scratch","allocated_bytes":1,"quota_bytes":1000,"available":true}]}' ;;
 *) exit 99;;
esac
''')
            diskm.chmod(0o700)
            python = root / 'python3'
            import sys
            python.write_text('#!/bin/bash\nif [[ "$1" == */scratch_pressure.py ]]; then\n [[ "$FREE" == invalid ]] && exit 75\n if [[ -n "${FAIL_AFTER_FIRST:-}" ]]; then\n  [[ -f "$CALLS.probed" ]] && exit 75\n  touch "$CALLS.probed"\n fi\n echo "$FREE"; exit 0\nfi\nexec ' + sys.executable + ' "$@"\n')
            python.chmod(0o700)
            calls = root / 'calls'
            env = {**os.environ, 'HOME': str(root), 'PATH': str(root) + ':' + os.environ['PATH'], 'DISK_MAGICIAN_DISKM_BIN': str(diskm), 'SCRATCH': str(scratch), 'CALLS': str(calls), 'DISK_MAGICIAN_STATE_DIR': str(root / 'state')}
            command = ['bash', str(ROOT / 'scripts/volume_reclaim.sh')]
            for free in (50 * 2**30, 50 * 2**30 + 1):
                result = subprocess.run(command + ['--available-floor', '--clean'], env={**env, 'FREE': str(free)}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('skipped:available-floor:', result.stdout)
                self.assertNotIn('status', calls.read_text())
                self.assertNotIn('ballast ensure', calls.read_text())
                self.assertNotIn('ballast release', calls.read_text())
                self.assertNotIn('trim', calls.read_text())
            result = subprocess.run(command + ['--available-floor'], env={**env, 'FREE': str(50 * 2**30 - 1)}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('would_check:' + str(candidate), result.stdout)
            result = subprocess.run(command + ['--available-floor'], env={**env, 'FREE': '1', 'FAIL_AFTER_FIRST': '1'}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(candidate.is_dir())
            for extra in ({'FREE': 'invalid'}, {'FREE': '1', 'MOUNT_RC': '75'}):
                result = subprocess.run(command + ['--available-floor', '--clean'], env={**env, **extra}, capture_output=True, text=True)
                self.assertNotIn('would_check:', result.stdout)
                self.assertTrue(candidate.is_dir())
                self.assertNotEqual(result.returncode, 0)
                import json
                receipt = json.loads((root / 'state/receipts/volume_reclaim.json').read_text())
                self.assertEqual(receipt['last_terminal']['outcome'], 'error')

if __name__ == '__main__':
    unittest.main()

import unittest
import os
import sys
import json
import subprocess
import tempfile
from pathlib import Path

class TestSnapshot(unittest.TestCase):
    def setUp(self):
        self.script_dir = Path(__file__).parent.parent / 'scripts'
        self.snapshot_script = self.script_dir / 'disk_snapshot.sh'
        self.config_template = Path(__file__).parent.parent / 'config.json.template'

    def test_scripts_exist(self):
        self.assertTrue(self.snapshot_script.exists())
        self.assertTrue(self.config_template.exists())

    def test_sparse_file_measurement(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sparse_file = Path(tmpdir) / 'test_sparse.raw'
            
            # Create a sparse file using truncate (supported on macOS and Linux)
            try:
                subprocess.run(['truncate', '-s', '10M', str(sparse_file)], check=True)
            except (subprocess.CalledProcessError, FileNotFoundError):
                self.skipTest('truncate command not available')

            # apparent size (stat) vs allocated size (du)
            res_apparent = subprocess.run(['stat', '-f', '%z', str(sparse_file)], capture_output=True, text=True)
            if res_apparent.returncode != 0:
                # Fallback to stat -c %s for Linux
                res_apparent = subprocess.run(['stat', '-c', '%s', str(sparse_file)], capture_output=True, text=True)
                
            apparent_bytes = int(res_apparent.stdout.strip()) if res_apparent.returncode == 0 else 10 * 1024 * 1024

            res_allocated = subprocess.run(['du', '-sk', str(sparse_file)], capture_output=True, text=True)
            allocated_kb = int(res_allocated.stdout.split()[0])

            # du -sk should report 0 (or very close to 0) blocks allocated,
            # while apparent bytes should be exactly 10MB (10485760 bytes).
            self.assertLess(allocated_kb, 500)
            self.assertEqual(apparent_bytes, 10 * 1024 * 1024)

    def test_timeout_sentinel(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / 'test_config.json'
            test_target = Path(tmpdir) / 'test_target'
            test_target.mkdir()
            
            config_data = {
                "monitored_dirs": [
                    { "key": "test_target", "path": str(test_target), "timeout": 5 }
                ],
                "monitored_file_globs": [],
                "monitored_globs": []
            }
            with open(config_path, 'w') as f:
                json.dump(config_data, f)
                
            env = os.environ.copy()
            env['DISK_MAGICIAN_CONFIG'] = str(config_path)
            res = subprocess.run([str(self.snapshot_script), '--dry-run'], env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)
            try:
                data = json.loads(res.stdout)
                self.assertTrue('snapshot_coverage_pct' in data)
                self.assertTrue('directories' in data)
                self.assertIn('test_target', data['directories'])
            except json.JSONDecodeError:
                self.fail(f'Output of disk_snapshot.sh is not valid JSON. Output: {res.stdout}, Error: {res.stderr}')

    def test_timeout_sentinel_null(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_timeout = Path(tmpdir) / 'timeout'
            with open(mock_timeout, 'w') as f:
                f.write('#!/usr/bin/env bash\nexit 124\n')
            mock_timeout.chmod(0o755)

            config_path = Path(tmpdir) / 'test_config.json'
            test_target = Path(tmpdir) / 'test_target'
            test_target.mkdir()

            config_data = {
                "monitored_dirs": [
                    { "key": "timeout_target", "path": str(test_target), "timeout": 1 }
                ],
                "monitored_file_globs": [],
                "monitored_globs": []
            }
            with open(config_path, 'w') as f:
                json.dump(config_data, f)

            env = os.environ.copy()
            env['DISK_MAGICIAN_CONFIG'] = str(config_path)
            env['PATH'] = f"{tmpdir}{os.path.pathsep}{env.get('PATH', '')}"

            res = subprocess.run([str(self.snapshot_script), '--dry-run'], env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)
            try:
                data = json.loads(res.stdout)
                self.assertIn('timeout_keys', data)
                self.assertIn('timeout_target', data['timeout_keys'])
                self.assertIsNone(data['directories']['timeout_target'])
            except json.JSONDecodeError:
                self.fail(f'Output of disk_snapshot.sh is not valid JSON. Output: {res.stdout}, Error: {res.stderr}')

if __name__ == '__main__':
    unittest.main()

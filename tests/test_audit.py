import unittest
import os
import sys
from pathlib import Path

class TestAudit(unittest.TestCase):
    def setUp(self):
        self.script_dir = Path(__file__).parent.parent / 'scripts'
        self.cleanup_scripts = [
            self.script_dir / 'cleanup_dev_caches.sh',
            self.script_dir / 'cleanup_sessions.sh',
            self.script_dir / 'cleanup_tmp.sh',
            self.script_dir / 'cleanup_worktrees.sh',
            self.script_dir / 'cleanup_docker.sh',
            self.script_dir / 'cleanup_antigravity_brain.sh',
            self.script_dir / 'cleanup_apfs_snapshots.sh',
            self.script_dir / 'cleanup_llm_inspector.sh',
            self.script_dir / 'cleanup_agent_artifacts.sh'
        ]

    def test_scripts_exist_and_executable(self):
        for script in self.cleanup_scripts:
            self.assertTrue(script.exists(), f'{script} does not exist')
            self.assertTrue(os.access(script, os.X_OK), f'{script} is not executable')

    def test_dry_run_by_default(self):
        # To guarantee safety under any setup, we read each script content
        # and verify that it contains DRY_RUN=true by default.
        for script in self.cleanup_scripts:
            with open(script) as f:
                content = f.read()
            # Check for DRY_RUN=true definition
            has_dry_run_default = 'DRY_RUN=true' in content
            self.assertTrue(has_dry_run_default, f'{script.name} does not define DRY_RUN=true by default')

if __name__ == '__main__':
    unittest.main()

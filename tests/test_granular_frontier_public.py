"""Same public CLI fixture runs against source-only baseline and working tree."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(os.environ.get('GRANULAR_TEST_REPO', pathlib.Path(__file__).resolve().parents[1]))
class PublicFrontier(unittest.TestCase):
    def test_metadata_descent_and_rerun(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            repo = root/'tree'; (repo/'.git'/'objects').mkdir(parents=True)
            payload = repo/'.git'/'objects'/'payload'
            # Real allocated exactly-100MiB file: no sparse-allocation ambiguity.
            with payload.open('wb') as f:
                for _ in range(100): f.write(b'x'*(1024*1024))
            os.link(payload, repo/'alias')
            os.symlink(repo, root/'symlink')
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            def run(*extra):
                proc = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier', '--root', d,
                    '--no-sibling-volumes', '--no-purgeable', '--workers', '1', '--max-depth', '20',
                    '--wall-clock-cap', '20', *extra], env=env, text=True, capture_output=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                return json.loads(proc.stdout)
            partial = run('--max-nodes', '1')
            self.assertTrue(partial['frontier_unfinished'])
            complete = run('--max-nodes', '1000')
            self.assertEqual(complete['config']['granularity_gib'], 100/1024)
            measured = complete['measured']
            self.assertTrue(str(payload) in measured or str(repo/'alias') in measured, measured)
            self.assertNotIn(str(repo), measured)
            self.assertFalse(complete['frontier_unfinished'], complete['frontier_unfinished'])
            self.assertEqual(complete['measured_total_kb'], 100*1024 + sum(complete['directory_metadata_kb'].values()))
            self.assertFalse(any('/symlink/' in path for path in measured))
            self.assertTrue(all(b.get('kind') != 'direct_allocation_segment' for b in complete['granularity_buckets']))

    def test_symlink_root_with_trailing_slash_is_not_walked(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); target = root/'target'; target.mkdir()
            (target/'payload').write_text('do not follow')
            link = root/'link'; link.symlink_to(target)
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            proc = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier',
                '--root', str(link)+'/', '--no-sibling-volumes', '--no-purgeable'],
                env=env, text=True, capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertEqual(set(report['measured']), {str(link)})

    def test_permission_and_deadline_are_partial_then_rerun(self):
        if os.geteuid() == 0:
            self.skipTest('mode000 permission fixture requires non-root')
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            blocked = root/'blocked'; blocked.mkdir()
            (blocked/'payload').write_text('metadata')
            blocked.chmod(0)
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            def run(cap):
                p = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier',
                    '--root', d, '--no-sibling-volumes', '--no-purgeable',
                    '--wall-clock-cap', str(cap)], env=env, text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                return json.loads(p.stdout)
            try:
                denied = run(10)
                self.assertEqual(denied['mode'], 'partial')
                self.assertTrue(denied['frontier_unfinished'])
            finally:
                blocked.chmod(0o700)
            expired = run(0)
            self.assertEqual(expired['mode'], 'partial')
            self.assertTrue(expired['frontier_unfinished'])
            resumed = run(10)
            self.assertFalse(resumed['frontier_unfinished'])
            self.assertEqual(resumed['mode'], 'complete')

if __name__ == '__main__': unittest.main()

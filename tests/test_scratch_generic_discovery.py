"""Deletion discovery boundaries, separate from read-only metadata traversal."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/lib/scratch_budget_artifact_children.py'
spec = importlib.util.spec_from_file_location('discovery', SCRIPT)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


class GenericDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def directory(self, name):
        path = self.root / name
        path.mkdir(parents=True, exist_ok=True)
        return path

    def test_scope_never_crosses_git_or_symlink(self):
        for name in ('file', 'directory', 'dangling', 'bare'):
            parent = self.directory(name)
            child = self.directory(name + '/ordinary/deep')
            if name == 'file':
                (parent / '.git').write_text('gitdir: missing')
            elif name == 'directory':
                (parent / '.git').mkdir()
            elif name == 'dangling':
                (parent / '.git').symlink_to(self.root / 'absent')
            else:
                (parent / 'HEAD').write_text('ref: refs/heads/main')
                (parent / 'objects').mkdir()
                (parent / 'refs').mkdir()
            self.assertTrue(discovery.generic_scope(str(self.root), str(parent)))
            self.assertFalse(discovery.generic_scope(str(self.root), str(child)))
        self.assertEqual(len(discovery.discover_generic(str(self.root), None)), 4)
        (self.root / 'alias').symlink_to(self.root / 'file', target_is_directory=True)
        self.assertFalse(discovery.generic_scope(str(self.root), str(self.root / 'alias/ordinary')))

    def test_scope_rejects_hidden_excluded_and_outside(self):
        for name in ('.hidden/child', 'system-owned/child', '_disk_magician_archive/child'):
            path = self.directory(name)
            self.assertFalse(discovery.generic_scope(str(self.root), str(path)))
        self.assertFalse(discovery.generic_scope(str(self.root), str(self.root.parent)))

    def test_deep_generic_batch_and_expired_all_or_nothing(self):
        leaf = self.directory('a/b/c/d/e/ordinary')
        command = [sys.executable, str(SCRIPT), 'batch-generic', '3', '']
        output = subprocess.check_output(command, input=str(self.root).encode() + b'\0')
        self.assertIn(str(leaf).encode() + b'\0', output)
        command[-1] = str(time.monotonic() - 1)
        result = subprocess.run(command, input=str(self.root).encode() + b'\0', capture_output=True)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stdout, b'')

    def test_stream_emits_disjoint_lexical_leaves(self):
        self.directory('z/leaf')
        self.directory('a/leaf')
        (self.root / 'link').symlink_to(self.root / 'a', target_is_directory=True)
        output = subprocess.check_output([sys.executable, str(SCRIPT), 'stream-generic-leaves', str(self.root), ''])
        self.assertEqual(output.split(b'\0')[:-1], [str(self.root / p).encode() for p in ('a/leaf', 'z/leaf')])


if __name__ == '__main__':
    unittest.main()

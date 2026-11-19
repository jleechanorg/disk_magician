"""Deletion discovery boundaries, separate from read-only metadata traversal."""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

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

    def test_batch_and_batch_generic_isolate_unreadable_candidate_with_blocked_out(self):
        if os.geteuid() == 0:
            self.skipTest('root ignores chmod 000')
        cand_a = self.directory('cand-a-blocked')
        self.directory('cand-a-blocked/build/ok-before-unreadable')
        unreadable = self.directory('cand-a-blocked/work/residual')
        cand_b = self.directory('cand-b-healthy')
        healthy_child = self.directory('cand-b-healthy/dist')
        blocked_out = self.root / 'blocked.bin'
        os.chmod(unreadable, 0o000)
        self.addCleanup(lambda: os.chmod(unreadable, 0o700))
        payload = b'\0'.join([str(cand_a).encode(), str(cand_b).encode()]) + b'\0'

        for mode in ('batch', 'batch-generic'):
            # Without --blocked-out: preserves fail-closed exit 1 with empty stdout.
            no_flag = subprocess.run(
                [sys.executable, str(SCRIPT), mode, '3', ''],
                input=payload,
                capture_output=True,
            )
            self.assertEqual(no_flag.returncode, 1)
            self.assertEqual(no_flag.stdout, b'')

            # With --blocked-out: isolates blocked candidate and returns healthy children.
            if blocked_out.exists():
                blocked_out.unlink()
            res = subprocess.run(
                [sys.executable, str(SCRIPT), mode, '3', '', '--blocked-out', str(blocked_out)],
                input=payload,
                capture_output=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(blocked_out.read_bytes(), str(cand_a).encode() + b'\0')
            fields = res.stdout.split(b'\0')
            self.assertEqual(fields[0], discovery.MARKER)
            pairs = [(fields[i], fields[i + 1]) for i in range(2, len(fields) - 1, 2)]
            self.assertEqual(int(fields[1]), len(pairs))
            self.assertNotIn(str(cand_a).encode(), [p[0] for p in pairs])
            self.assertIn((str(cand_b).encode(), str(healthy_child).encode()), pairs)

        # TimeoutError still returns 124 with empty stdout even when --blocked-out is given.
        if blocked_out.exists():
            blocked_out.unlink()
        expired = subprocess.run(
            [sys.executable, str(SCRIPT), 'batch-generic', '3', str(time.monotonic() - 1), '--blocked-out', str(blocked_out)],
            input=payload,
            capture_output=True,
        )
        self.assertEqual(expired.returncode, 124)
        self.assertEqual(expired.stdout, b'')

        # Malformed stdin still returns 1 with empty stdout when --blocked-out is given.
        bad_stdin = subprocess.run(
            [sys.executable, str(SCRIPT), 'batch-generic', '3', '', '--blocked-out', str(blocked_out)],
            input=str(cand_b).encode(),
            capture_output=True,
        )
        self.assertEqual(bad_stdin.returncode, 1)
        self.assertEqual(bad_stdin.stdout, b'')

    def test_stream_generic_leaves_continues_past_unreadable_subtree_and_returns_1(self):
        if os.geteuid() == 0:
            self.skipTest('root ignores chmod 000')
        self.directory('ez-gh-actions/ok-sibling')
        unreadable = self.directory('ez-gh-actions/work/residual')
        only_bad_parent = self.directory('fz-only-bad')
        self.directory('zz-after/leaf')
        os.chmod(unreadable, 0o000)
        self.addCleanup(lambda: os.chmod(unreadable, 0o700))
        os.chmod(only_bad_parent, 0o000)
        self.addCleanup(lambda: os.chmod(only_bad_parent, 0o700))

        res = subprocess.run(
            [sys.executable, str(SCRIPT), 'stream-generic-leaves', str(self.root), ''],
            capture_output=True,
        )
        self.assertEqual(res.returncode, 1)
        emitted = res.stdout.split(b'\0')[:-1]
        self.assertIn(str(self.root / 'ez-gh-actions/ok-sibling').encode(), emitted)
        self.assertIn(str(self.root / 'zz-after/leaf').encode(), emitted)
        self.assertNotIn(str(unreadable).encode(), emitted)
        self.assertNotIn(str(self.root / 'ez-gh-actions/work').encode(), emitted)
        self.assertNotIn(str(only_bad_parent).encode(), emitted)

    def test_stream_generic_leaves_taints_parent_on_scandir_entry_oserror(self):
        tainted_parent = self.directory('a-tainted')
        self.directory('b-healthy/leaf')
        real_scandir = discovery.os.scandir

        class _FakeEntry:
            def __init__(self, path):
                self.path = path
                self.name = os.path.basename(path)

            def stat(self, *, follow_symlinks):
                raise PermissionError('simulated entry stat error')

        class _FakeScandirCtx:
            def __enter__(self):
                return iter([_FakeEntry(str(tainted_parent / 'hidden-unreadable'))])

            def __exit__(self, *args):
                return False

        def fake_scandir(path):
            if path == str(tainted_parent):
                return _FakeScandirCtx()
            return real_scandir(path)

        with patch.object(discovery.os, 'scandir', fake_scandir):
            buf = []
            real_stdout = sys.stdout

            class _BufStdout:
                class buffer:
                    @staticmethod
                    def write(data):
                        buf.append(data)

                    @staticmethod
                    def flush():
                        pass

            with patch.object(sys, 'stdout', _BufStdout()):
                rc = discovery.stream_generic_leaves(str(self.root), None)
        self.assertEqual(rc, 1)
        emitted = b''.join(buf).split(b'\0')[:-1]
        self.assertEqual(emitted, [str(self.root / 'b-healthy/leaf').encode()])


if __name__ == '__main__':
    unittest.main()

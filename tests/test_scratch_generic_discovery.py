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

    def test_atomic_dep_dirs_stop_descent_in_stream_and_batch_generic(self):
        nm_deep = self.directory('app/node_modules/@firebase/auth/dist/src/core/user')
        (nm_deep / 'index.js').write_text('export {};\n')
        venv_deep = self.directory('app/venv/lib/python3.12/site-packages/pkg')
        (venv_deep / 'mod.py').write_text('x = 1\n')
        pycache_deep = self.directory('app/__pycache__/sub')
        (pycache_deep / 'mod.pyc').write_bytes(b'pyc')
        src_leaf = self.directory('app/src/deep/leaf')
        (src_leaf / 'main.ts').write_text('console.log(1);\n')
        build_leaf = self.directory('ordinary/build/nested')
        (build_leaf / 'out.bin').write_bytes(b'bin')

        stream_out = subprocess.check_output(
            [sys.executable, str(SCRIPT), 'stream-generic-leaves', str(self.root), '']
        )
        stream_leaves = stream_out.split(b'\0')[:-1]
        expected_stream = [
            str(self.root / 'app/__pycache__').encode(),
            str(self.root / 'app/node_modules').encode(),
            str(self.root / 'app/src/deep/leaf').encode(),
            str(self.root / 'app/venv').encode(),
            str(self.root / 'ordinary/build/nested').encode(),
        ]
        self.assertEqual(stream_leaves, expected_stream)

        batch_out = subprocess.check_output(
            [sys.executable, str(SCRIPT), 'batch-generic', '3', ''],
            input=str(self.root).encode() + b'\0',
        )
        fields = batch_out.split(b'\0')
        self.assertEqual(fields[0], discovery.MARKER)
        pairs = [(fields[i], fields[i + 1]) for i in range(2, len(fields) - 1, 2)]
        self.assertEqual(int(fields[1]), len(pairs))
        batch_children = [child for _, child in pairs]
        for expected in (
            'app', 'app/__pycache__', 'app/node_modules', 'app/venv',
            'app/src', 'app/src/deep', 'app/src/deep/leaf',
            'ordinary', 'ordinary/build', 'ordinary/build/nested',
        ):
            self.assertIn(str(self.root / expected).encode(), batch_children)
        for forbidden in (
            'app/node_modules/@firebase',
            'app/node_modules/@firebase/auth/dist/src/core/user',
            'app/venv/lib',
            'app/venv/lib/python3.12/site-packages/pkg',
            'app/__pycache__/sub',
        ):
            self.assertNotIn(str(self.root / forbidden).encode(), batch_children)

    def test_atomic_dep_dirs_preserve_unreadable_and_symlink_safety(self):
        if os.geteuid() == 0:
            self.skipTest('root ignores chmod 000/311')
        real_outside = self.directory('outside-target')
        (real_outside / 'keep.txt').write_text('keep')
        app = self.directory('app')
        (app / 'node_modules').symlink_to(real_outside, target_is_directory=True)
        (self.directory('app/src/leaf') / 'ok.txt').write_text('ok')

        bad_nm = self.directory('bad-app/node_modules/pkg')
        (bad_nm / 'file.js').write_text('x')
        os.chmod(self.root / 'bad-app/node_modules', 0o000)
        self.addCleanup(lambda: os.chmod(self.root / 'bad-app/node_modules', 0o700))

        exec_only_venv = self.directory('exec-app/venv/lib')
        (exec_only_venv / 'file.py').write_text('x')
        os.chmod(self.root / 'exec-app/venv', 0o311)
        self.addCleanup(lambda: os.chmod(self.root / 'exec-app/venv', 0o700))

        res = subprocess.run(
            [sys.executable, str(SCRIPT), 'stream-generic-leaves', str(self.root), ''],
            capture_output=True,
        )
        self.assertEqual(res.returncode, 1)
        emitted = res.stdout.split(b'\0')[:-1]
        self.assertIn(str(self.root / 'app/src/leaf').encode(), emitted)
        self.assertNotIn(str(self.root / 'app/node_modules').encode(), emitted)
        self.assertNotIn(str(self.root / 'bad-app/node_modules').encode(), emitted)
        self.assertNotIn(str(self.root / 'exec-app/venv').encode(), emitted)

        blocked_out = self.root / 'blocked.bin'
        payload = b'\0'.join([
            str(self.root / 'bad-app').encode(),
            str(self.root / 'exec-app').encode(),
            str(self.root / 'app').encode(),
        ]) + b'\0'
        batch_res = subprocess.run(
            [sys.executable, str(SCRIPT), 'batch-generic', '3', '', '--blocked-out', str(blocked_out)],
            input=payload,
            capture_output=True,
        )
        self.assertEqual(batch_res.returncode, 0, batch_res.stderr)
        blocked = blocked_out.read_bytes().split(b'\0')[:-1]
        self.assertEqual(set(blocked), {
            str(self.root / 'bad-app').encode(),
            str(self.root / 'exec-app').encode(),
        })

    def test_atomic_dep_dir_c14_preserves_recent_secret_git_and_unreadable_subtrees(self):
        repo_root = pathlib.Path(__file__).resolve().parents[1]
        verdict_lib = repo_root / 'scripts/lib/artifact_verdict.sh'
        old_epoch = time.time() - (72 * 3600)

        def age_tree(path):
            for dirpath, dirnames, filenames in os.walk(path):
                for name in filenames:
                    os.utime(os.path.join(dirpath, name), (old_epoch, old_epoch), follow_symlinks=False)
                for name in dirnames:
                    os.utime(os.path.join(dirpath, name), (old_epoch, old_epoch), follow_symlinks=False)
            os.utime(path, (old_epoch, old_epoch), follow_symlinks=False)

        def run_verdict(target, state_tag):
            state_dir = self.root / f'state-{state_tag}'
            config_dir = self.root / 'config'
            state_dir.mkdir(parents=True, exist_ok=True)
            config_dir.mkdir(parents=True, exist_ok=True)
            env = os.environ.copy()
            env.update({
                'DISK_MAGICIAN_CONFIG_DIR': str(config_dir),
                'DISK_MAGICIAN_STATE_DIR': str(state_dir),
                'DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE': str(self.root),
                'DISK_MAGICIAN_TMP_ROOT_OVERRIDE': str(self.root),
                'DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE': str(self.root / 'utmp'),
            })
            for key in ('C14_INVENTORY_OUT', 'C14_INVENTORY_FILE', 'DISK_MAGICIAN_C14_LEDGER', 'DISK_MAGICIAN_PROTECTED_TMP_ROOTS'):
                env.pop(key, None)
            (self.root / 'utmp').mkdir(exist_ok=True)
            cmd = f'source "{verdict_lib}" && artifact_removal_verdict "{target}" --kind ephemeral'
            out = subprocess.check_output(['bash', '-c', cmd], env=env, text=True).strip()
            return out

        # 1. Old, clean, ordinary node_modules -> emitted as 1 leaf, C14 verdict == remove
        clean_nm = self.directory('case-clean/app/node_modules/pkg/a/b/c')
        (clean_nm / 'index.js').write_text('module.exports = 1;\n')
        age_tree(self.root / 'case-clean')

        # 2. Recent file (<48h) buried deep inside node_modules -> C14 keeps as recent-activity
        recent_nm = self.directory('case-recent/app/node_modules/pkg/a/b/c')
        (recent_nm / 'old.js').write_text('old\n')
        age_tree(self.root / 'case-recent')
        (recent_nm / 'fresh.js').write_text('fresh\n')

        # 3. Secret-like file buried deep inside node_modules -> C14 keeps as secret-like
        secret_nm = self.directory('case-secret/app/node_modules/pkg/a/b/c')
        (secret_nm / '.env').write_text('TOKEN=abc\n')
        age_tree(self.root / 'case-secret')

        # 4. Dirty nested git repo inside node_modules -> C14 keeps (never remove)
        git_nm = self.directory('case-git/app/node_modules/git-dep')
        subprocess.check_call(['git', 'init', '-q', str(git_nm)])
        (git_nm / 'dirty.txt').write_text('uncommitted\n')
        age_tree(self.root / 'case-git')

        stream_out = subprocess.check_output(
            [sys.executable, str(SCRIPT), 'stream-generic-leaves', str(self.root), '']
        ).split(b'\0')[:-1]
        for case_name in ('case-clean', 'case-recent', 'case-secret', 'case-git'):
            nm = self.root / case_name / 'app/node_modules'
            self.assertIn(str(nm).encode(), stream_out)

        self.assertEqual(run_verdict(self.root / 'case-clean/app/node_modules', 'clean'), 'remove')
        self.assertEqual(run_verdict(self.root / 'case-recent/app/node_modules', 'recent'), 'kept:recent-activity')
        self.assertEqual(run_verdict(self.root / 'case-secret/app/node_modules', 'secret'), 'kept:secret-like')
        git_verdict = run_verdict(self.root / 'case-git/app/node_modules', 'git')
        self.assertTrue(git_verdict.startswith('kept:'), git_verdict)

        if os.geteuid() != 0:
            unreadable_nm = self.directory('case-unreadable/app/node_modules/pkg/a/b/c')
            (unreadable_nm / 'blob.js').write_text('x\n')
            age_tree(self.root / 'case-unreadable')
            os.chmod(unreadable_nm, 0o000)
            self.addCleanup(lambda: os.chmod(unreadable_nm, 0o700))
            self.assertEqual(
                run_verdict(self.root / 'case-unreadable/app/node_modules', 'unreadable'),
                'kept:check-failed',
            )


if __name__ == '__main__':
    unittest.main()

"""Tiny isolated fetched-backup verification contracts; no cloud access."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('restore_verify', ROOT / 'scripts/worktree_restore_verify.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RestoreVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='diskm-verify-test-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo, self.wt, self.store = [self.base / p for p in ('repo', 'linked', 'store')]
        self.store.mkdir()
        self.git('init', '-q', str(self.repo))
        self.git('-C', str(self.repo), 'config', 'user.name', 'Fixture')
        self.git('-C', str(self.repo), 'config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'file').write_text('saved\n')
        (self.repo / 'executable').write_text('executable\n')
        (self.repo / 'executable').chmod(0o755)
        self.git('-C', str(self.repo), 'add', '.')
        self.git('-C', str(self.repo), 'commit', '-qm', 'fixture')
        self.git('-C', str(self.repo), 'worktree', 'add', '-qb', 'candidate', str(self.wt))
        remote = self.base / 'remote.git'
        self.git('init', '--bare', '-q', str(remote))
        self.git('-C', str(self.wt), 'remote', 'add', 'origin', str(remote))
        self.git('-C', str(self.wt), 'push', '-qu', 'origin', 'candidate')
        self.meta = {k: module.git(self.wt, *args).decode().strip() for k, args in {
            'head': ('rev-parse', 'HEAD'), 'ref': ('symbolic-ref', 'HEAD'),
            'tree': ('rev-parse', 'HEAD^{tree}')}.items()}
        self.meta.update(worktree=str(self.wt), format='disk-magician-worktree-backup-v1',
                         status='verified', capture_stable=True, bundle='recovery.bundle',
                         archive='tree.tar', tree_manifest='tree.manifest', file_manifest='files.after.manifest')
        self.capture()
        self.reserve = patch.object(module.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(10**12, 0, 10**12))
        self.reserve.start()
        self.addCleanup(self.reserve.stop)

    def git(self, *args):
        return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', *args],
                              check=True, capture_output=True).stdout

    def capture(self):
        self.git('-C', str(self.wt), 'bundle', 'create', str(self.store / 'recovery.bundle.1'), 'candidate')
        (self.store / 'tree.tar.1').write_bytes(self.git('-C', str(self.wt), 'archive', '--format=tar', 'HEAD'))
        (self.store / 'tree.manifest.1').write_bytes(module.git(self.wt, 'ls-tree', '-r', '--full-tree', 'HEAD'))
        (self.store / 'metadata.json.1').write_text(json.dumps(self.meta))
        for name in ('files.before.manifest', 'files.after.manifest'):
            (self.store / (name + '.1')).write_bytes(module.helper('preservation_file_manifest', self.wt))
        self.rehash()

    def rehash(self):
        self.rows = [dict(path=name, object=module.PREFIX + 'fixture/' + name,
                          generation='1', size=(self.store / (name + '.1')).stat().st_size,
                          sha256=module.digest(self.store / (name + '.1'))) for name in sorted(module.FILES)]
        self.manifest = self.base / 'upload.json'
        self.manifest.write_text(json.dumps(self.rows))

    def verify(self):
        return module.verify(self.wt, self.manifest, self.base / 'receipts', self.store)

    def refused(self, reason=None):
        with self.assertRaises((ValueError, subprocess.SubprocessError)) as error:
            self.verify()
        if reason:
            self.assertIn(reason, str(error.exception))
        self.assertFalse(list(self.base.glob('receipts/**/restore-receipt.json')))

    def change_tar(self, name, kind=None):
        path = self.store / 'tree.tar.1'
        with tarfile.open(path, 'a') as archive:
            member = tarfile.TarInfo(name)
            if kind == 'symlink':
                member.type = tarfile.SYMTYPE
                member.linkname = '/tmp/wrong'
                archive.addfile(member)
            else:
                member.size = 1
                archive.addfile(member, io.BytesIO(b'x'))
        self.rehash()

    def test_verified_receipt_and_source_unchanged(self):
        before = module.identity(self.wt)
        receipt = self.verify()
        row = json.loads(receipt.read_text())
        self.assertEqual(row['restore']['file_count'], 2)
        self.assertEqual(row['durable_backup']['objects'], self.rows)
        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
        self.assertEqual(before, module.identity(self.wt))

    def test_tampered_object(self):
        (self.store / 'tree.tar.1').write_bytes(b'corrupt')
        self.refused()

    def test_bad_generation(self):
        self.rows[0]['generation'] = '2'
        self.manifest.write_text(json.dumps(self.rows))
        self.refused()

    def test_traversal_manifest(self):
        self.rows[0]['path'] = '../escape'
        self.manifest.write_text(json.dumps(self.rows))
        self.refused()

    def test_missing_object(self):
        self.manifest.write_text(json.dumps(self.rows[:-1]))
        self.refused()

    def test_extra_archive(self):
        self.change_tar('extra')
        self.refused('extra or duplicate')

    def test_traversal_archive(self):
        self.change_tar('../escape')
        self.refused('unsafe path')

    def test_symlink_archive(self):
        self.change_tar('extra-link', 'symlink')
        self.refused('extra or duplicate')

    def test_missing_archive_file(self):
        (self.store / 'tree.tar.1').write_bytes(self.git('-C', str(self.wt), 'archive', '--format=tar', 'HEAD', 'file'))
        self.rehash()
        self.refused()

    def test_live_identity_change(self):
        original = module.restore
        def changed(*args):
            count = original(*args)
            self.git('-C', str(self.wt), 'checkout', '-qb', 'changed')
            self.git('-C', str(self.wt), 'config', 'branch.changed.remote', 'origin')
            self.git('-C', str(self.wt), 'config', 'branch.changed.merge', 'refs/heads/candidate')
            return count
        with patch.object(module, 'restore', side_effect=changed):
            self.refused('live identity or payload changed')

    def test_live_manifest_change(self):
        original = module.restore
        def changed(*args):
            count = original(*args)
            path = self.wt / 'file'
            info = path.stat()
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000000))
            return count
        with patch.object(module, 'restore', side_effect=changed):
            self.refused('live identity or payload changed')

    def test_committed_symlink_restore(self):
        os.symlink('file', self.wt / 'link')
        self.git('-C', str(self.wt), 'add', 'link')
        self.git('-C', str(self.wt), 'commit', '-qm', 'symlink')
        self.git('-C', str(self.wt), 'push', '-q')
        for key, value in (('head', 'HEAD'), ('tree', 'HEAD^{tree}')):
            self.meta[key] = module.git(self.wt, 'rev-parse', value).decode().strip()
        self.capture()
        self.assertEqual(json.loads(self.verify().read_text())['restore']['file_count'], 3)

    def test_protected_name_before_payload(self):
        (self.wt / '.env.example').write_text('fixture\n')
        with patch.object(module, 'fetch', side_effect=AssertionError('must not fetch')):
            self.refused()

    def test_reserve(self):
        with patch.object(module.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(0, 0, 0)):
            self.refused()

    def test_dispatch_help(self):
        result = subprocess.run(['bash', str(ROOT / 'disk_magician.sh'), 'worktree-restore-verify', '--help'], capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'--upload-manifest', result.stdout)

    def test_fixture_requires_sandbox(self):
        env = dict(os.environ, DISK_MAGICIAN_RESTORE_FIXTURE_DIR=str(self.store))
        env.pop('DISK_MAGICIAN_TEST_SANDBOX', None)
        result = subprocess.run(['python3', str(ROOT / 'scripts/worktree_restore_verify.py'),
                                 '--worktree', str(self.wt), '--upload-manifest', str(self.manifest),
                                 '--receipt-dir', str(self.base / 'receipts')], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'explicit test sandbox', result.stderr)


if __name__ == '__main__':
    unittest.main()

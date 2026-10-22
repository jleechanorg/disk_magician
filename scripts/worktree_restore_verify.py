#!/usr/bin/env python3
"""Fetch pinned worktree backups and verify restoration without changing the source."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
FILES = {'metadata.json', 'recovery.bundle', 'tree.tar', 'tree.manifest',
         'files.before.manifest', 'files.after.manifest'}
PREFIX = 'gs://wa-test-evidence/agent-evidence/disk_magician/'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=120,
                          env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1")).stdout


def git(repo, *args):
    return run('git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
               '-C', str(repo), *args)


def helper(name, wt, *args, work_tree=None):
    prefix = ["env", "GIT_WORK_TREE=" + str(work_tree)] if work_tree else []
    return run(*prefix, 'bash', '-c', 'source "$1"; "$2" "${@:3}"', '_',
               str(ROOT / 'worktree_hygiene.sh'), name, str(wt), *args)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def safe_path(name):
    p = PurePosixPath(name)
    require(isinstance(name, str) and name and not p.is_absolute()
            and '..' not in p.parts and '.' not in p.parts
            and str(p) == name and '\\' not in name, 'unsafe path')
    return p


def identity(wt):
    helper('preservation_no_lfs', wt, 'HEAD')  # Names guard runs before any payload reads.
    head = git(wt, 'rev-parse', 'HEAD').decode().strip()
    ref = git(wt, 'symbolic-ref', 'HEAD').decode().strip()
    require(ref.startswith('refs/heads/'), 'attached branch required')
    require(not git(wt, 'status', '--porcelain', '--untracked-files=all',
                    '--ignore-submodules=none'), 'worktree is not clean')
    require(not helper('preserve_wip_raw_bytes_dirty', wt).strip(), 'payload differs from HEAD')
    branch = ref[len('refs/heads/'):]
    remote = git(wt, 'config', '--get', 'branch.' + branch + '.remote').decode().strip()
    remote_ref = git(wt, 'config', '--get', 'branch.' + branch + '.merge').decode().strip()
    require(remote and remote != '.' and remote_ref.startswith('refs/heads/'), 'upstream required')
    url = git(wt, 'remote', 'get-url', remote).decode().strip()
    require(git(wt, 'ls-remote', '--heads', url, remote_ref).decode().splitlines()
            == [head + '\t' + remote_ref], 'live upstream does not equal HEAD')
    return {'worktree': str(wt), 'head': head, 'ref': ref,
            'tree': git(wt, 'rev-parse', 'HEAD^{tree}').decode().strip(),
            'remote': {'url': url, 'ref': remote_ref, 'sha': head}}


def fetch(rows, destination, fixture=None):
    client = None
    if fixture is None:
        from google.cloud import storage
        client = storage.Client()
    for row in rows:
        target = destination / row['path']
        if fixture is not None:
            # A generation-specific filename makes a missing generation fail closed.
            source = fixture / (row['path'] + '.' + str(row['generation']))
            require(source.is_file() and not source.is_symlink(), 'fixture generation missing')
            shutil.copyfile(source, target)
        else:
            bucket, _, name = row['object'][5:].partition('/')
            generation = int(row['generation'])
            client.bucket(bucket).blob(name, generation=generation).download_to_filename(
                str(target), if_generation_match=generation, timeout=120)
        require(target.is_file() and not target.is_symlink()
                and target.stat().st_size == row['size']
                and digest(target) == row['sha256'], 'fetched object hash or size mismatch')


def restore(fetched, meta, scratch):
    mirror = scratch / 'mirror.git'
    run('git', '-c', 'core.hooksPath=/dev/null', 'clone', '--mirror',
        str(fetched / 'recovery.bundle'), str(mirror))
    names_tree = scratch / 'names-only-tree'
    names_tree.mkdir(mode=0o700)
    helper('preservation_no_lfs', mirror, meta['head'], work_tree=names_tree)
    git(mirror, 'fsck', '--full', '--strict')
    require(git(mirror, 'rev-parse', meta['ref']).decode().strip() == meta['head'], 'bundle ref mismatch')
    require(git(mirror, 'rev-parse', meta['head'] + '^{tree}').decode().strip()
            == meta['tree'], 'bundle tree mismatch')
    require(git(mirror, 'ls-tree', '-r', '--full-tree', meta['head'])
            == (fetched / 'tree.manifest').read_bytes(), 'tree manifest mismatch')
    expected = {}
    for record in git(mirror, 'ls-tree', '-r', '-z', meta['head']).split(b'\0'):
        if not record:
            continue
        attrs, name = record.split(b'\t', 1)
        mode, kind, oid = attrs.decode().split()
        name = os.fsdecode(name)
        safe_path(name)
        require(kind == 'blob' and mode in ('100644', '100755', '120000'), 'unsupported Git entry')
        expected[name] = (mode, oid)
    restored = scratch / 'restored-tree'
    restored.mkdir(mode=0o700)
    seen, directories = set(), set()
    with tarfile.open(fetched / 'tree.tar') as archive:
        for member in archive:
            name = member.name.rstrip('/') if member.isdir() else member.name
            safe_path(name)
            dst = restored / name
            require(all(not p.is_symlink() for p in dst.parents), 'archive symlink ancestor')
            if member.isdir():
                require(name not in directories and any(p.startswith(name + '/') for p in expected), 'extra directory')
                directories.add(name)
                dst.mkdir(parents=True, exist_ok=True)
                continue
            require(name in expected and name not in seen, 'extra or duplicate archive file')
            seen.add(name)
            mode, oid = expected[name]
            blob = git(mirror, 'cat-file', 'blob', oid)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if mode == '120000':
                require(member.issym() and os.fsencode(member.linkname) == blob, 'symlink mismatch')
                os.symlink(member.linkname, dst)
            else:
                require(member.isfile() and bool(member.mode & 0o111) == (mode == '100755'), 'file type or mode mismatch')
                stream = archive.extractfile(member)
                require(member.size == len(blob) and stream.read() == blob, 'archive blob mismatch')
                dst.write_bytes(blob)
                dst.chmod(0o755 if mode == '100755' else 0o644)
    require(seen == set(expected), 'missing archive file')
    for name, (mode, oid) in expected.items():
        path = restored / name
        actual = os.fsencode(os.readlink(path)) if mode == '120000' else path.read_bytes()
        require(actual == git(mirror, 'cat-file', 'blob', oid), 'restored blob mismatch')
        require(mode == '120000' or bool(path.stat().st_mode & 0o111) == (mode == '100755'), 'restored mode mismatch')
    return len(expected)


def verify(wt, manifest, receipt_dir, fixture=None):
    require(not wt.is_symlink() and wt.is_dir(), 'worktree must be a real directory')
    wt = wt.resolve()
    require(not manifest.is_symlink() and manifest.is_file(), 'manifest must be a regular file')
    rows = json.loads(manifest.read_text())
    require(isinstance(rows, list) and len(rows) == len(FILES), 'unexpected object count')
    require(all(isinstance(r, dict) for r in rows), 'invalid object row')
    require({r.get('path') for r in rows} == FILES, 'unexpected or missing objects')
    for row in rows:
        safe_path(row['path'])
        require(isinstance(row.get('object'), str) and row['object'].startswith(PREFIX), 'unexpected storage root')
        safe_path(row['object'][len(PREFIX):])
        require(row['object'].endswith('/' + row['path']), 'object path mismatch')
        require(re.fullmatch(r'[1-9][0-9]*', str(row.get('generation', ''))) is not None, 'invalid generation')
        require(type(row.get('size')) is int and 0 <= row['size'], 'invalid size')
        require(re.fullmatch(r'[0-9a-f]{64}', str(row.get('sha256', ''))) is not None, 'invalid hash')
    require(len({r['object'].rsplit('/', 1)[0] for r in rows}) == 1, 'mixed backup roots')
    # Include fetched files, unpacked Git objects, and restored tree; retain 40 GiB.
    require(shutil.disk_usage('/tmp').free >= 40 * 1024**3 + sum(r['size'] for r in rows) * 8,
            'insufficient capacity for restore plus 40 GiB reserve')
    before = identity(wt)
    objects = git(wt, 'rev-list', '--objects', '--no-object-names', before['head'])
    sizes = subprocess.run(['git', '-C', str(wt), 'cat-file',
                            '--batch-check=%(objectsize)'], input=objects,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120).stdout
    expanded = sum(int(size) + 4096 for size in sizes.splitlines())
    require(shutil.disk_usage('/tmp').free >= 40 * 1024**3
            + sum(r['size'] for r in rows) + expanded * 4,
            'insufficient capacity for uncompressed restore plus reserve')
    files_before = helper('preservation_file_manifest', wt)
    with tempfile.TemporaryDirectory(prefix='diskm-restore-', dir='/tmp') as temporary:
        scratch = Path(temporary)
        fetched = scratch / 'fetched'
        fetched.mkdir(mode=0o700)
        fetch(rows, fetched, fixture)
        meta = json.loads((fetched / 'metadata.json').read_text())
        require(meta.get('format') == 'disk-magician-worktree-backup-v1'
                and meta.get('status') == 'verified' and meta.get('capture_stable') is True, 'unverified capture')
        require(all(meta.get(k) == before[k] for k in ('worktree', 'head', 'ref', 'tree')), 'capture identity mismatch')
        require([meta.get(k) for k in ('bundle', 'archive', 'tree_manifest', 'file_manifest')]
                == ['recovery.bundle', 'tree.tar', 'tree.manifest', 'files.after.manifest'], 'unexpected capture paths')
        require((fetched / 'files.before.manifest').read_bytes()
                == (fetched / 'files.after.manifest').read_bytes(), 'capture was unstable')
        count = restore(fetched, meta, scratch)
        require(identity(wt) == before and helper('preservation_file_manifest', wt) == files_before,
                'live identity or payload changed during restore verification')
        receipt = dict(before, format='disk-magician-worktree-restore-v1', status='verified',
                       verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       verifier={'command': 'diskm worktree-restore-verify', 'method': 'pinned fetched-only fsck and complete tar/blob/mode/symlink restore'},
                       durable_backup={'status': 'verified', 'fetched': True, 'head': before['head'],
                                       'tree': before['tree'], 'objects': rows},
                       restore={'status': 'verified', 'head': before['head'], 'tree': before['tree'],
                                'file_count': count, 'fsck': 'passed --full --strict', 'no_extra_files': True,
                                'lfs': 'absent-in-selected-tree-and-reachable-history'})
        require(Path('/tmp') in receipt_dir.resolve().parents, 'receipt directory must be under /tmp')
        require(not any(p.is_symlink() for p in [receipt_dir, *receipt_dir.parents]), 'symlink receipt directory')
        leaf = re.sub(r'[^A-Za-z0-9._-]', '_', wt.name)
        output = receipt_dir / (leaf + '-' + before['head'])
        output.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(not output.is_symlink(), 'symlink receipt target')
        fd, temporary_receipt = tempfile.mkstemp(prefix='.receipt-', dir=output)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(receipt, stream, indent=2, sort_keys=True)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_receipt, output / 'restore-receipt.json')
        finally:
            if os.path.exists(temporary_receipt):
                os.unlink(temporary_receipt)
    return output / 'restore-receipt.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', required=True, type=Path)
    parser.add_argument('--upload-manifest', required=True, type=Path)
    parser.add_argument('--receipt-dir', required=True, type=Path)
    args = parser.parse_args()
    fixture = os.environ.get('DISK_MAGICIAN_RESTORE_FIXTURE_DIR')
    if fixture and os.environ.get('DISK_MAGICIAN_TEST_SANDBOX') != '1':
        parser.error('fixture storage requires explicit test sandbox')
    try:
        print(verify(args.worktree, args.upload_manifest, args.receipt_dir,
                     Path(fixture) if fixture else None))
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        parser.exit(1, 'restore verification refused: ' + type(error).__name__ + '\n')


if __name__ == '__main__':
    main()

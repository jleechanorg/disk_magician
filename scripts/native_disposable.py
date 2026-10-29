#!/usr/bin/env python3
"""Opt-in cooperative disposable namespace; never a legacy Scratch/C14 remover."""
from __future__ import annotations
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

CONTRACT = 'disposable-cooperative-flock-v1'
NOFOLLOW = os.O_NOFOLLOW
DIRFLAGS = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW
MAX_ENTRIES = 10000


def protection_rules(root, config, config_path, context=None):
    """Reuse shared sandbox/root resolution and cross-validated safety matcher.

    The reporting tool's permissive loader is deliberately NOT used: deletion
    must reject missing explicit rules, unreadable files, and malformed schemas.
    """
    explicit = os.environ.get('DISK_MAGICIAN_SAFETY_FILE')
    if explicit and not Path(explicit).is_file():
        raise ValueError('explicit safety file unavailable')
    names = config.get('protected_tmp_roots')
    if names is not None and (not isinstance(names, list) or any(not isinstance(n, str) or not n for n in names)):
        raise ValueError('invalid protected_tmp_roots rules')
    env = dict(os.environ)
    for name in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS'): env.pop(name, None)
    script = ('source "$1/safety_lib.sh"; sandbox_guard_roots "$2"; '
              'safety_file_in_use || exit 75; source "$1/lib/scratch_roots.sh"; '
              'scratch_roots_protected_paths "$3"')
    result = subprocess.run(['bash', '--noprofile', '--norc', '-c', script, 'native-policy',
                             str(Path(__file__).resolve().parent), str(root), str(config_path)],
                            env=env, text=True, capture_output=True, timeout=5, check=False)
    if result.returncode:
        raise ValueError('shared safety/sandbox unavailable: ' + result.stderr[:1000])
    lines = result.stdout.splitlines()
    if not lines: raise ValueError('safety file unavailable')
    source = Path(lines[0])
    text = source.read_text()
    if len(text) > 1024 * 1024: raise ValueError('safety rules exceed bound')
    document = json.loads(text)
    if not isinstance(document, dict): raise ValueError('invalid safety rules')
    from check_uncovered_roots import SAFETY_SECTIONS
    rules = {}
    for section in SAFETY_SECTIONS:
        items = document.get(section, [])
        if not isinstance(items, list): raise ValueError('invalid safety section')
        rules[section] = []
        for item in items:
            raw = item.get('path') if isinstance(item, dict) else item
            if not isinstance(raw, str) or not raw: raise ValueError('invalid safety path')
            if any(variable not in ('HOME', '{HOME}') for variable in re.findall(r'\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)', raw)):
                raise ValueError('unsupported safety path environment expansion')
            # Shared Linux matching retains safety_lib's private/tmp aliases.
            raw = os.path.normpath(os.path.expandvars(os.path.expanduser(raw)))
            for alias in ('/private/tmp', '/private/var', '/private/etc'):
                if raw == alias or raw.startswith(alias + '/'):
                    raw = raw[len('/private'):]; break
            rules[section].append((raw, 'shared safety rule'))
    rules['protected_tmp_roots'] = [(str(Path(p).resolve()), 'shared protected tmp root') for p in lines[1:]]
    assert_unprotected(root, rules)
    if context is not None: context.update(safety_file=str(source.resolve()), document=document)
    return rules


def assert_unprotected(path, rules):
    from check_uncovered_roots import classify_path_protection
    direct, descendants = classify_path_protection(str(path), rules, str(Path.home()))
    root_holds, _ = classify_path_protection('/', rules, str(Path.home()))
    if root_holds or direct or descendants: raise ValueError('protected namespace/payload: ' + str(path))


def repository(path):
    return (path / '.git').exists() or ((path / 'HEAD').is_file() and (path / 'objects').is_dir() and (path / 'refs').is_dir())


def mount_targets():
    if not sys.platform.startswith('linux'): raise ValueError('disposable namespace is Linux only')
    targets = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        if len(fields) < 6: raise ValueError('mount inventory unavailable')
        targets.append(Path(re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), fields[4])))
    return targets


def canonical(path):
    path = Path(path)
    if not path.is_absolute() or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(path)):
        raise ValueError('explicit absolute ASCII namespace path required (no whitespace/specifiers)')
    if '..' in path.parts or path.resolve() != path:
        raise ValueError('namespace and ancestors must not be symlinks')
    if path == Path('/') or path == Path.home() or path in (Path('/tmp'), Path('/var/tmp')):
        raise ValueError('not a dedicated namespace')
    for ancestor in [path, *path.parents]:
        if repository(ancestor):
            raise ValueError('namespace cannot be inside a repository')
    # This namespace is deliberately separate from worktrees and existing Scratch.
    excluded = [Path.home() / 'Scratch', Path.home() / '.worktrees', Path('/Volumes/diskm-scratch')]
    # Honor the existing config resolver, including env/state-repo precedence.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import resolve_config
    source = resolve_config.resolve()
    if not source: raise ValueError('configuration unavailable')
    config = json.loads(Path(source).read_text())
    mount = config.get('volumes', {}).get('classes', {}).get('scratch', {}).get('mountpoint')
    if mount: excluded.append(Path(mount).expanduser())
    registry_path = Path(os.environ.get('DISK_MAGICIAN_STATE_DIR', Path.home() / '.disk_magician_state')) / 'volumes/registry.json'
    if registry_path.exists():
        registry = json.loads(registry_path.read_text())
        if registry.get('schema_version') != 1 or not isinstance(registry.get('volumes'), dict):
            raise ValueError('invalid existing volume registry')
        for volume in registry['volumes'].values():
            if not isinstance(volume, dict): raise ValueError('invalid registered volume')
            if volume.get('mountpoint'): excluded.append(Path(volume['mountpoint']).expanduser())
    excluded = [item.resolve() for item in excluded]
    if any(path == item or item in path.parents or path in item.parents for item in excluded):
        raise ValueError('namespace overlaps Scratch/worktree domain')
    protection_rules(path, config, source)
    if any(path == target or path in target.parents for target in mount_targets()):
        raise ValueError('nested mount or mounted namespace refused')
    return path


def ancestor_identities(root):
    result = {}
    for path in root.parents:
        details = path.lstat()
        if not stat.S_ISDIR(details.st_mode) or details.st_uid not in (0, os.getuid()):
            raise ValueError('untrusted ancestor ownership/type')
        if details.st_mode & 0o022 and not details.st_mode & stat.S_ISVTX:
            raise ValueError('writable non-sticky ancestor')
        result[str(path)] = identity(details)
    return result


def identity(details):
    return {'dev': details.st_dev, 'ino': details.st_ino}


def owned(details, directory=False):
    if details.st_uid != os.getuid() or (directory and not stat.S_ISDIR(details.st_mode)):
        raise ValueError('ownership/type mismatch')
    if stat.S_IMODE(details.st_mode) != (0o700 if directory else 0o600):
        raise ValueError('private namespace/control mode required')
    if not directory and (not stat.S_ISREG(details.st_mode) or details.st_nlink != 1):
        raise ValueError('unsafe control file')


def read_json(path):
    fd = os.open(path, os.O_RDONLY | NOFOLLOW)
    with os.fdopen(fd) as stream:
        owned(os.fstat(stream.fileno()))
        data = stream.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('control record exceeds bound')
    return json.loads(data)


def atomic_json(path, value):
    # Control-only metadata, never a data removal path.
    data = (json.dumps(value, sort_keys=True) + '\n').encode()
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('control record exceeds bound')
    fd, temporary = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)
    dfd = os.open(path.parent, DIRFLAGS)
    try: os.fsync(dfd)
    finally: os.close(dfd)


def audit(root, event):
    fd = os.open(root / 'control/audit.jsonl', os.O_RDWR | os.O_APPEND | NOFOLLOW)
    try:
        owned(os.fstat(fd))
        fcntl.flock(fd, fcntl.LOCK_EX)
        existing = os.read(fd, 16 * 1024 * 1024 + 1)
        if len(existing) > 16 * 1024 * 1024 or (existing and not existing.endswith(b'\n')):
            raise ValueError('audit history truncated or exceeds bound')
        for line in existing.splitlines(): json.loads(line)
        data = (json.dumps(dict(event, at=time.time()), sort_keys=True) + '\n').encode()
        if os.write(fd, data) != len(data): raise OSError('short audit write')
        os.fsync(fd)
    finally: os.close(fd)


def initialize(root):
    root = canonical(root)
    if os.path.lexists(root): raise ValueError('existing namespace will not be adopted')
    if not root.parent.is_dir(): raise ValueError('explicit existing parent required')
    root.mkdir(mode=0o700)
    for sub in ('control', 'data', 'control/jobs', 'control/runs'):
        (root / sub).mkdir(mode=0o700)
    for sub in ('control/gate.lock', 'control/audit.jsonl'):
        fd = os.open(root / sub, os.O_CREAT | os.O_EXCL | os.O_WRONLY | NOFOLLOW, 0o600)
        try: os.fsync(fd)
        finally: os.close(fd)
    for path in (root/'control/jobs', root/'control/runs', root/'control', root/'data', root, root.parent):
        fd = os.open(path, DIRFLAGS)
        try: os.fsync(fd)
        finally: os.close(fd)
    record = {'contract': CONTRACT, 'uid': os.getuid(), 'root': identity(root.stat()),
              'control': identity((root / 'control').stat()), 'data': identity((root / 'data').stat()),
              'jobs': identity((root / 'control/jobs').stat()), 'runs': identity((root / 'control/runs').stat()), 'gate': identity((root / 'control/gate.lock').stat()),
              'audit': identity((root / 'control/audit.jsonl').stat()), 'ancestors': ancestor_identities(root)}
    atomic_json(root / 'control/identity.json', record)
    atomic_json(root / 'control/pending.json', {'phase': 'idle'})
    audit(root, {'event': 'initialized', 'identity': record})
    return record


def validate(root):
    root = canonical(root)
    record = read_json(root / 'control/identity.json')
    if record.get('contract') != CONTRACT or record.get('uid') != os.getuid():
        raise ValueError('unknown namespace contract')
    for key, path in (('root', root), ('control', root / 'control'), ('data', root / 'data'), ('jobs', root / 'control/jobs'), ('runs', root / 'control/runs')):
        st = path.lstat(); owned(st, directory=True)
        if identity(st) != record.get(key) or st.st_dev != record['root']['dev']:
            raise ValueError('namespace identity/capacity domain changed')
    if ancestor_identities(root) != record.get('ancestors'):
        raise ValueError('namespace ancestors changed')
    for key in ('gate', 'audit'):
        path = root / 'control' / ('gate.lock' if key == 'gate' else 'audit.jsonl')
        details = path.lstat(); owned(details)
        if identity(details) != record.get(key): raise ValueError(key + ' identity changed')
    return root, record


@contextmanager
def gate(root, exclusive):
    root, record = validate(root)
    fd = os.open(root / 'control/gate.lock', os.O_RDWR | NOFOLLOW)
    try:
        owned(os.fstat(fd))
        if identity(os.fstat(fd)) != record['gate']: raise ValueError('admission lock identity changed')
        fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        validate(root)
        if identity((root / 'control/gate.lock').lstat()) != record['gate']: raise ValueError('admission lock replaced')
        yield root, record, fd
    finally: os.close(fd)


def require_idle(root):
    if read_json(root / 'control/pending.json').get('phase') != 'idle':
        raise ValueError('incomplete native attempt requires explicit audit reconciliation')


def producer(root, command):
    if not command: raise ValueError('producer command required')
    with gate(root, False) as (root, record, gate_fd):
        require_idle(root)
        job = uuid.uuid4().hex
        directory = root / 'data' / job
        directory.mkdir(mode=0o700)
        fd = os.open(directory, DIRFLAGS)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH)
            atomic_json(root / 'control/jobs' / (job + '.json'), identity(os.fstat(fd)))
            audit(root, {'event': 'producer-start', 'job': job, 'identity': identity(os.fstat(fd))})
            env = dict(os.environ, DISKM_DISPOSABLE_DIR=str(directory),
                       DISKM_DISPOSABLE_LOCK_FD=str(fd), DISKM_DISPOSABLE_GATE_FD=str(gate_fd))
            # The wrapper and child both hold FDs. Detached descendants MUST retain
            # them or acquire their own registration; this is a cooperative API.
            result = subprocess.run(command, cwd=directory, env=env, pass_fds=(fd, gate_fd), check=False)
            audit(root, {'event': 'producer-exit', 'job': job, 'returncode': result.returncode})
            return result.returncode
        finally: os.close(fd)


def entries(path):
    # Audit enumeration must not refresh atime and defeat native 3-day aging.
    fd = os.open(path, DIRFLAGS | os.O_NOATIME)
    try:
        with os.scandir(fd) as items: return [path / item.name for item in items]
    finally: os.close(fd)


def snapshot(root):
    records = {}
    data = root / 'data'
    import resolve_config
    config_path = resolve_config.resolve()
    if not config_path: raise ValueError('configuration unavailable')
    rules = protection_rules(root, json.loads(Path(config_path).read_text()), config_path)
    device = data.stat().st_dev
    for job in sorted(entries(data)):
        if not re.fullmatch(r'[0-9a-f]{32}', job.name): raise ValueError('unregistered data entry')
        st = job.lstat(); owned(st, directory=True)
        if identity(st) != read_json(root / 'control/jobs' / (job.name + '.json')):
            raise ValueError('job identity changed')
        stack = [job]
        while stack:
            path = stack.pop(); st = path.lstat()
            assert_unprotected(path, rules)
            if st.st_dev != device or st.st_uid != os.getuid() or path.name == '.git':
                raise ValueError('foreign mount/owner/repository data')
            if stat.S_ISDIR(st.st_mode):
                if repository(path): raise ValueError('repository payload refused')
                stack.extend(entries(path))
            elif not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise ValueError('symlink/hardlink/special data refused')
            records[str(path.relative_to(data))] = dict(identity(st), size=st.st_size, mode=st.st_mode,
                                                       mtime_ns=st.st_mtime_ns, ctime_ns=st.st_ctime_ns)
            if len(records) > MAX_ENTRIES: raise ValueError('manifest enumeration limit')
    return records


def native_env():
    # In particular, v255 unconditionally reads CREDENTIALS_DIRECTORY/tmpfiles.extra.
    return {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C'}


def clean(root, binary, execute=False):
    if not sys.platform.startswith('linux'): raise ValueError('native disposable cleanup is Linux only')
    with gate(root, True) as (root, record, gate_fd):
        require_idle(root)
        before = snapshot(root)
        if not execute:
            return {'status': 'plan-only', 'entries': len(before), 'age': '3d', 'device': record['root']['dev']}
        binary = Path(binary)
        if not binary.is_absolute() or binary.resolve() != binary or not binary.is_file():
            raise ValueError('explicit trusted absolute native tmpfiles executable required')
        version = subprocess.run([str(binary), '--version'], env=native_env(), text=True, capture_output=True, timeout=5, check=True)
        match = re.match(r'systemd (\d+)\b', version.stdout)
        if not match or int(match.group(1)) < 255: raise ValueError('systemd255 or newer required')
        run = uuid.uuid4().hex
        intent = {'phase': 'pending', 'id': run, 'identity': record, 'before': before, 'age': '3d'}
        atomic_json(root / 'control/runs' / (run + '.before.json'), intent)
        atomic_json(root / 'control/pending.json', intent)
        audit(root, {'event': 'native-intent', 'id': run, 'manifest_sha256': hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(), 'entries': len(before)})
        data_fd = os.open(root / 'data', DIRFLAGS)
        try:
            if identity(os.fstat(data_fd)) != record['data']: raise ValueError('data identity changed')
            # FD-bound root prevents root rename/substitution from widening scope.
            # v255 does NOT honor flock on configured root; producer job children
            # each hold compatible BSD locks in addition to our admission gate.
            with tempfile.NamedTemporaryFile('w', dir=root / 'control', prefix='.native-') as conf:
                conf.write('e / - - - 3d -\n'); conf.flush(); os.fsync(conf.fileno())
                validate(root)
                try:
                    result = subprocess.run([str(binary), '--root=/proc/self/fd/' + str(data_fd), '--clean', conf.name],
                                            env=native_env(), pass_fds=(data_fd, gate_fd), text=True, capture_output=True, timeout=30, check=False)
                    rc = result.returncode
                    diagnostics = result.stderr[:4096]
                except subprocess.TimeoutExpired:
                    rc = 'timeout'
                    diagnostics = 'native process exceeded 30-second bound; terminated before observation'
            validate(root)
            after = snapshot(root)
            changed = [path for path in before.keys() & after.keys() if before[path] != after[path]]
            anomalies = [path for path in changed if any(before[path][key] != after[path][key] for key in ('dev', 'ino', 'mode')) or not stat.S_ISDIR(before[path]['mode'])]
            added = sorted(after.keys() - before.keys())
            removed = sorted(before.keys() - after.keys())
            # Directory metadata legitimately changes when children are removed;
            # report observations, never infer success just from native exit0.
            observation = {'event': 'native-observation', 'id': run, 'native_returncode': rc,
                           'removed': removed, 'remaining': len(after), 'changed': changed, 'added': added, 'anomalies': anomalies,
                           'status': 'observed' if rc == 0 and not added and not anomalies else 'incomplete', 'diagnostics': diagnostics}
            atomic_json(root / 'control/runs' / (run + '.after.json'), {'observation': observation, 'after': after})
            audit(root, observation)
            if rc == 0 and not added and not anomalies:
                atomic_json(root / 'control/pending.json', {'phase': 'idle', 'last': run})
            return observation
        finally: os.close(data_fd)


def reconcile(root):
    with gate(root, True) as (root, _, _fd):
        pending = read_json(root / 'control/pending.json')
        if pending.get('phase') == 'idle': return {'status': 'idle'}
        after = snapshot(root)
        event = {'event': 'interrupted-observation', 'id': pending['id'], 'status': 'unknown-attribution',
                 'missing_since_intent': sorted(set(pending['before']) - set(after)), 'remaining': len(after)}
        atomic_json(root / 'control/runs' / (pending['id'] + '.reconciled.json'), {'observation':event, 'after':after})
        audit(root, event)
        atomic_json(root / 'control/pending.json', {'phase': 'idle', 'last': pending['id']})
        return event


def unit_quote(value):
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError('unit argument contains a control character')
    # systemd performs specifier and environment expansion even inside quotes.
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def environment_quote(value):
    # Environment= does not perform shell/environment expansion; only specifiers.
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('unsupported environment control character')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def schedule_context(root):
    """Bind authoritative policy sources, never caller-dependent fallback rules."""
    import resolve_config
    source = resolve_config.resolve()
    if not source: raise ValueError('configuration unavailable')
    source = str(Path(source).resolve())
    metadata = {}
    config = json.loads(Path(source).read_text())
    protection_rules(root, config, source, metadata)
    names = ('DISK_MAGICIAN_PROTECTED_TMP_ROOTS', 'DISK_MAGICIAN_TMP_ROOT_OVERRIDE',
             'DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE', 'DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES',
             'DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE', 'DISK_MAGICIAN_TEST_CONTEXT',
             'DISK_MAGICIAN_TEST_SANDBOX')
    context = {name: os.environ.get(name, '') for name in names}
    for name, value in context.items():
        if not value or name in ('DISK_MAGICIAN_TEST_CONTEXT', 'DISK_MAGICIAN_PROTECTED_TMP_ROOTS'): continue
        paths = value.split() if name == 'DISK_MAGICIAN_PROTECTED_TMP_ROOTS' else value.split(':')
        if any(not Path(path).is_absolute() for path in paths):
            raise ValueError('schedule requires absolute policy override paths')
    context.update(HOME=str(Path.home()), DISK_MAGICIAN_CONFIG=source,
                   DISK_MAGICIAN_SAFETY_FILE=metadata['safety_file'],
                   DISK_MAGICIAN_STATE_DIR=str(Path(os.environ.get('DISK_MAGICIAN_STATE_DIR', Path.home()/'.disk_magician_state')).resolve()),
                   BASH_ENV='', ENV='')
    return context


def render_schedule(root, binary):
    """Return reviewable user-unit text only; never install/enable/start it."""
    with gate(root, False) as (root, record, _):
        require_idle(root)
        if not binary or not Path(binary).is_absolute():
            raise ValueError('explicit absolute installed diskm launcher required')
        if not re.fullmatch(r'/[A-Za-z0-9_./ -]+', str(binary)):
            raise ValueError('unsupported launcher characters')
        binary = Path(binary).resolve()
        if not re.fullmatch(r'/[A-Za-z0-9_./ -]+', str(binary)):
            raise ValueError('unsupported resolved launcher characters')
        fd = os.open(binary, os.O_RDONLY | NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            details = os.fstat(stream.fileno())
            if (not stat.S_ISREG(details.st_mode) or details.st_uid not in (0, os.getuid())
                    or details.st_mode & 0o022 or not os.access(binary, os.X_OK)):
                raise ValueError('unsafe installed launcher')
            data = stream.read(128 * 1024 + 1)
        if len(data) > 128 * 1024 or b'from disk_magician.cli import main' not in data:
            raise ValueError('expected installed shared diskm CLI launcher')
        name = 'diskm-disposable-' + hashlib.sha256(str(root).encode()).hexdigest()[:16]
        templates = Path(__file__).resolve().parent.parent / 'systemd'
        service = (templates / 'diskm-disposable-clean.service.in').read_text()
        timer = (templates / 'diskm-disposable-clean.timer.in').read_text()
        context = schedule_context(root)
        replacements = {'DISKM_BIN':unit_quote(str(binary)), 'NAMESPACE':unit_quote(str(root)),
                        'POLICY_ENV':'\n'.join('Environment=' + environment_quote(k + '=' + v) for k,v in sorted(context.items()))}
        service = re.sub(r'@(DISKM_BIN|NAMESPACE|POLICY_ENV)@', lambda match: replacements[match.group(1)], service)
        timer = timer.replace('@UNIT_NAME@', name)
        return {'status':'render-only', 'unit':name, 'service':service, 'timer':timer,
                'namespace_identity':record, 'launcher_sha256':hashlib.sha256(data).hexdigest(),
                'activation':'not installed or enabled; operator must verify reviewed launcher and explicitly install user units',
                'policy':'native 3d in separate disposable namespace; not Scratch pressure relief'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('init', 'run', 'clean', 'reconcile', 'schedule'))
    parser.add_argument('--root', required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--diskm-bin')
    parser.add_argument('--tmpfiles-bin', default='/usr/bin/systemd-tmpfiles')
    argv = list(sys.argv[1:] if argv is None else argv)
    command = []
    if '--' in argv:
        separator = argv.index('--'); command = argv[separator + 1:]; argv = argv[:separator]
    args = parser.parse_args(argv)
    try:
        if args.action == 'run': return producer(args.root, command)
        if args.action == 'schedule':
            if args.execute: raise ValueError('schedule is render-only; --execute cannot install units')
            result = render_schedule(args.root, args.diskm_bin)
        elif args.action == 'clean': result = clean(args.root, args.tmpfiles_bin, args.execute)
        elif not args.execute: result = {'status': 'plan-only', 'action': args.action, 'root': str(canonical(args.root))}
        elif args.action == 'init': result = initialize(args.root)
        else: result = reconcile(args.root)
        print(json.dumps(result, sort_keys=True)); return 75 if result.get('status') == 'incomplete' else 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('disposable: refused: ' + str(error), file=sys.stderr); return 75


if __name__ == '__main__':
    raise SystemExit(main())

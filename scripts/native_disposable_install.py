"""Explicit opt-in user-unit installation; no import-time host operations."""
import fcntl
import hashlib
import os
import re
import shlex
from pathlib import Path
import stat
import subprocess
import time
import uuid

SYSTEMCTL = '/usr/bin/systemctl'


def manager_environment():
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid())))
    config = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config')))
    for path in (runtime, config):
        if not path.is_absolute() or path.resolve() != path:
            raise ValueError('unsafe user manager/config path')
    env = dict(os.environ)
    for key in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS'): env.pop(key, None)
    guarded = subprocess.run(['bash','--noprofile','--norc','-c',
        'source "$1/safety_lib.sh"; shift; sandbox_guard_roots "$@"', 'install-sandbox',
        str(Path(__file__).resolve().parent), str(config/'systemd/user'), str(runtime)],
        env=env, text=True, capture_output=True, timeout=5, check=False)
    if guarded.returncode: raise ValueError('installation sandbox refused: ' + guarded.stderr[:1024])
    details = runtime.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) != 0o700:
        raise ValueError('private caller-owned user manager runtime required')
    return {'PATH':'/usr/bin:/bin', 'HOME':str(Path.home()), 'LANG':'C',
            'XDG_RUNTIME_DIR':str(runtime), 'XDG_CONFIG_HOME':str(config)}


def manager(*args, accepted=(0,), inherited=(), deadline=None):
    if deadline is not None and time.monotonic() >= deadline: raise ValueError('installation manager deadline expired')
    env = manager_environment()
    remaining = 8 if deadline is None else min(8, deadline - time.monotonic())
    if remaining <= 0: raise ValueError('installation manager deadline expired')
    result = subprocess.run([SYSTEMCTL, '--user', *args], text=True, env=env,
                            capture_output=True, timeout=remaining, check=False, pass_fds=inherited)
    if result.returncode not in accepted:
        raise ValueError('user manager refused ' + ' '.join(args) + ': ' + result.stderr[:1024])
    return result.stdout.strip()


def private_directory(path, native):
    if not path.is_absolute() or path.resolve() != path or '..' in path.parts:
        raise ValueError('absolute non-symlink user config directory required')
    for part in reversed([path, *path.parents]):
        if not part.exists():
            part.mkdir(mode=0o700)
            fd = os.open(part.parent, native.DIRFLAGS)
            try: os.fsync(fd)
            finally: os.close(fd)
        details = part.lstat()
        if (not stat.S_ISDIR(details.st_mode) or details.st_uid not in (0, os.getuid())
                or (details.st_mode & 0o022 and not details.st_mode & stat.S_ISVTX)):
            raise ValueError('unsafe user config ancestry')
    if path.stat().st_uid != os.getuid(): raise ValueError('user unit directory must be owned by caller')


def unit_bytes(path, native):
    if not os.path.lexists(path): return None
    fd = os.open(path, os.O_RDONLY | native.NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        details = os.fstat(stream.fileno())
        if (not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid()
                or details.st_nlink != 1 or details.st_mode & 0o022):
            raise ValueError('unsafe user unit file')
        data = stream.read(128 * 1024 + 1)
    if len(data) > 128 * 1024: raise ValueError('unit file exceeds bound')
    return data


def sync_directory(path, native):
    fd = os.open(path, native.DIRFLAGS)
    try: os.fsync(fd)
    finally: os.close(fd)


def unit_identity(name, directory, control, required=False, service_text=None):
    for suffix in ('service', 'timer'):
        unit = name + '.' + suffix
        fragment = control('show', '--property=FragmentPath', '--value', unit, accepted=(0, 1))
        if (required or fragment) and fragment != str(directory / unit):
            raise ValueError('manager resolves another unit fragment')
        drops = control('show', '--property=DropInPaths', '--value', unit, accepted=(0, 1))
        if drops: raise ValueError('untrusted unit drop-in refused')
        transient = control('show', '--property=Transient', '--value', unit, accepted=(0, 1))
        if transient not in ('', 'no'): raise ValueError('transient unit refused')
        if fragment and suffix == 'timer':
            associated = control('show', '--property=Unit', '--value', unit)
            if associated != name + '.service': raise ValueError('foreign timer service association')
        if fragment and suffix == 'service':
            if service_text is None: raise ValueError('expected service source unavailable')
            lines = [line.split('=',1)[1] for line in service_text.splitlines() if line.startswith('ExecStart=')]
            if len(lines) != 1: raise ValueError('ambiguous expected ExecStart')
            args = shlex.split(lines[0])
            if any(re.search(r'[^A-Za-z0-9_./-]', arg) for arg in args):
                raise ValueError('install requires simple unexpanded ExecStart arguments')
            effective = control('show', '--property=ExecStart', '--value', unit)
            argv = re.findall(r'argv\[\]=([^;]*?)\s*;', effective)
            paths = re.findall(r'(?:^|[ {])path=([^;]*?)\s*;', effective)
            if argv != [' '.join(args)] or paths != [args[0]]:
                raise ValueError('effective service ExecStart mismatch')
            expected_environment = []
            for line in service_text.splitlines():
                if line.startswith('Environment='):
                    expected_environment.extend(shlex.split(line.split('=',1)[1].replace('%%','%')))
            effective_environment = shlex.split(control('show', '--property=Environment', '--value', unit))
            if sorted(effective_environment) != sorted(expected_environment):
                raise ValueError('effective service Environment mismatch')
            for prop, expected in (('EnvironmentFiles',''), ('PassEnvironment',''), ('UnsetEnvironment',''),
                                   ('NoNewPrivileges','yes'), ('UMask','0077'), ('KillMode','control-group')):
                if control('show', '--property='+prop, '--value', unit) != expected:
                    raise ValueError('effective service security property mismatch: ' + prop)



def states(name, directory, control=manager, require_fragment=False, service_text=None):
    unit_identity(name, directory, control, require_fragment, service_text)
    active = control('is-active', name + '.timer', accepted=(0, 3, 4))
    enabled = control('is-enabled', name + '.timer', accepted=(0, 1, 4))
    service = control('is-active', name + '.service', accepted=(0, 3, 4))
    if active not in ('active', 'inactive', 'unknown') or enabled not in ('enabled', 'disabled', 'not-found'):
        raise ValueError('unsupported existing timer state')
    if service not in ('inactive', 'unknown', 'failed'): raise ValueError('native service must be inactive before installation')
    return {'active': active == 'active', 'enabled': enabled == 'enabled'}


def verify_launcher(expected, native):
    if not isinstance(expected, dict) or not isinstance(expected.get('path'), str):
        raise ValueError('launcher identity missing; operator reconciliation required')
    try:
        actual = native.launcher_record(expected['path'])
    except OSError as error:
        raise ValueError('launcher unavailable or replaced') from error
    if actual != expected: raise ValueError('launcher identity/content changed; operator reconciliation required')


def verify_sources(directory, transaction, native, allow_missing_created=False):
    verify_launcher(transaction.get('launcher'), native)
    for filename, content in transaction['desired'].items():
        path = directory / filename
        data = unit_bytes(path, native)
        if data is None:
            if allow_missing_created and not transaction['original'][filename]: continue
            raise ValueError('expected unit source missing')
        if data != content.encode(): raise ValueError('unit source drift; operator reconciliation required')
        expected = transaction['created'].get(filename) or transaction['original_identity'].get(filename)
        if expected is None: raise ValueError('unbound unit file; operator reconciliation required')
        if native.identity(path.stat()) != expected: raise ValueError('unit source identity changed')


def admission_marker(transaction, phase):
    return {'phase':phase, 'transaction_id':transaction['id'], 'identity':transaction['identity']}


def terminal_marker(root, transaction, native):
    # This operation is AFTER terminal journal fsync. A visible terminal marker
    # therefore proves the earlier journal commit, even if this final fsync
    # fails. Old pending marker after a crash remains conservatively blocking.
    try:
        native.atomic_json(root/'control/schedule-admission.json', admission_marker(transaction, transaction['phase']))
    except OSError as error:
        return {'status':'incomplete', 'committed':True, 'unit':transaction['unit'],
                'detail':'terminal journal durable; admission finalization uncertain: '+str(error)}
    return None


def rollback(root, transaction, native, control=manager):
    directory = Path(transaction['directory']); name = transaction['unit']
    verify_sources(directory, transaction, native, allow_missing_created=True)
    service_text = transaction['desired'][name + '.service']
    unit_identity(name, directory, control, service_text=service_text)
    raw_control = control
    def guarded(*args, **kwargs):
        verify_sources(directory, transaction, native, allow_missing_created=True)
        unit_identity(name, directory, raw_control, service_text=service_text)
        verify_sources(directory, transaction, native, allow_missing_created=True)
        return raw_control(*args, **kwargs)
    control = guarded
    current_state = states(name, directory, raw_control, service_text=service_text)
    if not transaction['before']['active'] and current_state['active']: control('stop', name + '.timer')
    if not transaction['before']['enabled'] and current_state['enabled']: control('disable', name + '.timer')
    verify_sources(directory, transaction, native, allow_missing_created=True)
    for filename, details in transaction['created'].items():
        path = directory / filename
        current = unit_bytes(path, native)
        if current is not None:
            if current != transaction['desired'][filename].encode(): raise ValueError('rollback in-place unit drift')
            if native.identity(path.stat()) != details: raise ValueError('rollback unit identity changed')
            path.unlink()
    sync_directory(directory, native)
    control('daemon-reload')
    if transaction['before']['enabled']: control('enable', name + '.timer')
    if transaction['before']['active']: control('start', name + '.timer')
    after = states(name, directory, raw_control, service_text=service_text)
    verify_sources(directory, transaction, native, allow_missing_created=True)
    if after != transaction['before']: raise ValueError('manager rollback state not verified')
    native.audit(root, {'event':'schedule-rollback', 'unit':name, 'status':'verified'})
    transaction['phase'] = 'rolled-back'
    native.atomic_json(root / 'control/schedule-transaction.json', transaction)
    uncertain = terminal_marker(root, transaction, native)
    return uncertain or {'status':'rolled-back', 'unit':name}


def install(root, binary, accepted, execute, native, recover=False):
    if not accepted: raise ValueError('explicit --accept-cooperative-producers required')
    # Render before claiming exclusive admission; it does not write host state.
    rendered = None if recover else native.render_schedule(root, binary)
    if not recover and re.search(r'[^A-Za-z0-9_./-]', str(Path(binary).resolve())):
        raise ValueError('install requires simple launcher path without whitespace/specifiers')
    if rendered: verify_launcher(rendered.get('launcher'), native)
    directory = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config'))) / 'systemd/user'
    if not directory.is_absolute(): raise ValueError('absolute XDG_CONFIG_HOME required')
    if Path(root) == directory or Path(root) in directory.parents or directory in Path(root).parents:
        raise ValueError('user units must be outside disposable namespace')
    if not execute: return dict(rendered or {}, status='recovery-plan-only' if recover else 'install-plan-only', directory=str(directory))
    with native.gate(root, True) as (root, record, gate_fd):
        native.require_idle(root, allow_install_pending=True)
        native.snapshot(root)  # Unknown payloads/leases never become disposable by installation.
        if rendered and record != rendered['namespace_identity']: raise ValueError('namespace changed since render')
        if rendered: verify_launcher(rendered.get('launcher'), native)
        manager_environment()  # Shared sandbox guard covers config and bus before mkdir or manager calls.
        private_directory(directory, native)
        lock = directory / '.diskm-disposable-install.lock'
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | native.NOFOLLOW, 0o600)
        try:
            native.owned(os.fstat(fd))
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if native.identity(os.fstat(fd)) != native.identity(lock.stat()): raise ValueError('install lock replaced')
            deadline = time.monotonic() + 120
            control = lambda *args, **kwargs: manager(*args, inherited=(gate_fd, fd), deadline=deadline, **kwargs)
            journal = root / 'control/schedule-transaction.json'
            if journal.exists():
                previous = native.read_json(journal)
                if previous.get('phase') == 'pending' or recover:
                    if not recover: raise ValueError('incomplete installation; explicit schedule-recover required')
                    if previous.get('phase') not in ('pending','installed','rolled-back') or not re.fullmatch(r'[a-f0-9]{32}', str(previous.get('id',''))):
                        raise ValueError('invalid installation transaction phase/id')
                    verify_launcher(previous.get('launcher'), native)
                    marker_path = root/'control/schedule-admission.json'
                    marker = native.read_json(marker_path) if marker_path.exists() else None
                    if marker and (marker.get('transaction_id') != previous['id'] or marker.get('identity') != record):
                        if (previous['phase']=='pending' and not previous.get('created')
                                and marker==previous.get('predecessor_marker')
                                and marker.get('phase') in ('installed','rolled-back')
                                and marker.get('identity')==record):
                            # Crash between new intent and advancing old terminal marker:
                            # no new file or manager mutation is permitted before this advance.
                            native.atomic_json(marker_path, admission_marker(previous, 'pending'))
                            marker = admission_marker(previous, 'pending')
                        else:
                            raise ValueError('installation admission marker mismatch')
                    if previous.get('directory') != str(directory) or previous.get('identity') != record:
                        raise ValueError('installation recovery identity/context mismatch')
                    expected = 'diskm-disposable-' + hashlib.sha256(str(root).encode()).hexdigest()[:16]
                    keys = {expected+'.service', expected+'.timer'}
                    if (previous.get('unit') != expected or set(previous.get('desired', {})) != keys
                            or set(previous.get('original', {})) != keys or not set(previous.get('created', {})) <= keys
                            or set(previous.get('original_identity', {})) != {k for k,v in previous['original'].items() if v}
                            or any(type(v) is not bool for v in previous['original'].values())
                            or previous.get('before') not in ({'active':a,'enabled':e} for a in (True,False) for e in (True,False))
                            or any(not isinstance(v,str) for v in previous['desired'].values())):
                        raise ValueError('invalid installation recovery record')
                    if marker and marker.get('phase') == previous['phase'] and previous['phase'] in ('installed','rolled-back'):
                        verify_sources(directory, previous, native, allow_missing_created=previous['phase']=='rolled-back')
                        expected_state = {'active':True,'enabled':True} if previous['phase']=='installed' else previous['before']
                        actual_state = states(previous['unit'], directory, control, service_text=previous['desired'][previous['unit']+'.service'])
                        verify_sources(directory, previous, native, allow_missing_created=previous['phase']=='rolled-back')
                        if actual_state != expected_state: raise ValueError('committed installation state drift')
                        native.atomic_json(journal, previous)
                        uncertain = terminal_marker(root, previous, native)
                        return uncertain or {'status':'finalization-verified','phase':previous['phase']}
                    return rollback(root, previous, native, control)
            if recover: return {'status':'no-pending-installation'}
            name = rendered['unit']
            desired = {name+'.'+suffix:rendered[suffix] for suffix in ('service','timer')}
            original = {}; original_identity = {}
            for filename, content in desired.items():
                data = unit_bytes(directory / filename, native)
                if data is not None and data != content.encode(): raise ValueError('existing unit drift; will not overwrite')
                original[filename] = data is not None
                if data is not None: original_identity[filename] = native.identity((directory/filename).stat())
            service_text = desired[name + '.service']
            before = states(name, directory, control, service_text=service_text)
            if (before['active'] or before['enabled']) and not all(original.values()):
                raise ValueError('active/enabled units lack matching owned source files')
            verify_launcher(rendered.get('launcher'), native)
            predecessor_path = root/'control/schedule-admission.json'
            predecessor = native.read_json(predecessor_path) if predecessor_path.exists() else None
            transaction = {'predecessor_marker':predecessor,'id':uuid.uuid4().hex,'phase':'pending','directory':str(directory),'identity':record,'unit':name,
                           'launcher':rendered['launcher'],'desired':desired,'original':original,'original_identity':original_identity,'created':{},'before':before}
            native.atomic_json(journal, transaction)
            native.atomic_json(root/'control/schedule-admission.json', admission_marker(transaction, 'pending'))
            native.audit(root, {'event':'schedule-install-intent','unit':name,'before':before})
            try:
                for filename, content in desired.items():
                    if original[filename]: continue
                    verify_launcher(transaction['launcher'], native)
                    path = directory / filename
                    file_fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | native.NOFOLLOW, 0o600)
                    with os.fdopen(file_fd, 'wb') as stream:
                        stream.write(content.encode()); stream.flush(); os.fsync(stream.fileno())
                        transaction['created'][filename] = native.identity(os.fstat(stream.fileno()))
                        native.atomic_json(journal, transaction)
                    sync_directory(directory, native)
                native.validate(root)
                verify_sources(directory, transaction, native)
                unit_identity(name, directory, control, service_text=service_text)
                verify_sources(directory, transaction, native)
                control('daemon-reload')
                verify_sources(directory, transaction, native)
                unit_identity(name, directory, control, required=True, service_text=service_text)
                verify_sources(directory, transaction, native)
                control('enable', name + '.timer')
                verify_sources(directory, transaction, native)
                unit_identity(name, directory, control, required=True, service_text=service_text)
                verify_sources(directory, transaction, native)
                control('start', name + '.timer')
                verify_sources(directory, transaction, native)
                after = states(name, directory, control, require_fragment=True, service_text=service_text)
                verify_sources(directory, transaction, native)
                if after != {'active':True,'enabled':True}: raise ValueError('timer activation not verified')
                native.audit(root, {'event':'schedule-installed','unit':name,'status':'manager-verified'})
                transaction['phase'] = 'installed'
                native.atomic_json(journal, transaction)
                # No rollback after this durable commit point: only marker finalization remains.
                uncertain = terminal_marker(root, transaction, native)
                return uncertain or {'status':'installed-enabled','unit':name,'directory':str(directory),
                        'scope':'timer only; no claim that cleanup has executed'}
            except (OSError, ValueError, subprocess.SubprocessError) as failure:
                try:
                    recovered = rollback(root, transaction, native, control)
                    if recovered.get('status') == 'incomplete':
                        raise ValueError('rollback committed but admission finalization uncertain')
                except (OSError, ValueError, subprocess.SubprocessError) as recovery:
                    raise ValueError('installation incomplete; recovery required: ' + str(recovery)) from failure
                raise ValueError('installation failed and rolled back: ' + str(failure)) from failure
        finally: os.close(fd)

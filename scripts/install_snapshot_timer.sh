#!/usr/bin/env bash
# Staging/install helper behind `diskm setup --snapshot-timer`.
# Reconciles the existing names only. Never enables, starts or reloads a unit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIR/../templates/systemd" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

source = Path(sys.argv[1])
parser = argparse.ArgumentParser(description="Stage the existing snapshot service/timer without activation")
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--stage-dir', type=Path, help='write a reviewable fixture/staging directory only')
mode.add_argument('--install', action='store_true', help='write the same user unit names; never activate')
mode.add_argument('--dry-run', action='store_true', help='preview only (default)')
args = parser.parse_args(sys.argv[2:])
if os.geteuid() == 0:
    parser.error('user snapshot units must not be installed as root')
target = args.stage_dir or Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'systemd/user'
target = target.expanduser().absolute()
names = ('disk-magician-snapshot.service', 'disk-magician-snapshot.timer')
payloads = {name: (source / (name + '.template')).read_bytes() for name in names}
SYSTEM_SYMLINKS = {Path('/var'), Path('/tmp'), Path('/etc')}
for path in (target, *target.parents):
    if path in SYSTEM_SYMLINKS and path.resolve() == Path('/private') / path.name:
        continue
    if path.is_symlink():
        parser.error(f'refusing symlinked destination: {path}')
for name in (*names, 'disk-magician-snapshot.install.json'):
    if (target / name).is_symlink():
        parser.error(f'refusing symlinked unit: {name}')
if not args.stage_dir and not args.install:
    print(json.dumps({'destination': str(target), 'files': list(names), 'activated': False, 'dry_run': True}))
    raise SystemExit(0)
target.mkdir(parents=True, exist_ok=True)

def publish(name, content):
    fd, tmp = tempfile.mkstemp(prefix='.' + name + '.', dir=target)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o644)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, target / name)
        directory = os.open(target, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

files = {}
for name, content in payloads.items():
    publish(name, content)
    info = (target / name).stat()
    files[name] = {'sha256': hashlib.sha256(content).hexdigest(), 'uid': info.st_uid,
                   'gid': info.st_gid, 'mode': format(info.st_mode & 0o777, '04o')}
receipt = {'schema_version': 1, 'installed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'destination': str(target), 'staged': args.stage_dir is not None, 'activated': False,
           'files': files, 'effective_argv': [str(Path.home() / '.local/bin/diskm'), 'snapshot', '--refresh-inventory-if-stale=24h'],
           'schedule': {'OnCalendar': '*-*-* 00/2:15:00', 'Persistent': True},
           'admission': 'report_only; privileged collector and scheduled receipts not verified'}
publish('disk-magician-snapshot.install.json', (json.dumps(receipt, sort_keys=True, indent=2) + '\n').encode())
print(json.dumps(receipt, sort_keys=True))
PY

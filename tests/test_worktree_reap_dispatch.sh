#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
from datetime import datetime, timezone
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])

def run(args, env, expected=0):
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=45)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result

for tree in [t for t in (root, root / 'src/disk_magician') if (t / 'disk_magician.sh').exists()]:
    with tempfile.TemporaryDirectory(prefix='reap-dispatch-', dir='/tmp') as tmp:
        home = Path(tmp).resolve()
        state = home / '.disk_magician_state'
        bins = home / '.local/bin'
        bins.mkdir(parents=True)
        (home / 'Library/LaunchAgents').mkdir(parents=True)
        env = {**os.environ, 'HOME': str(home), 'STANDARD_WORKTREE_ROOT': str(home / '.worktrees'),
               'DISK_MAGICIAN_STATE_DIR': str(state), 'GIT_CONFIG_NOSYSTEM': '1'}
        cli = ['/bin/bash', str(tree / 'disk_magician.sh')]
        run(cli + ['worktree-reap', '--mode', 'nominate'], env)
        receipt = state / 'receipts/worktree_reap.json'
        assert json.loads(receipt.read_text())['last_terminal']['outcome'] == 'success'
        print('PASS:', tree.name, 'nominate dispatch writes receipt')

        fake_ps = bins / 'ps'
        fake_ps.write_text('''#!/bin/bash
pid= spec=
while [[ $# -gt 0 ]]; do case "$1" in -p) pid="$2"; shift 2;; -o) spec="$2"; shift 2;; *) shift;; esac; done
case "$spec" in
ppid=,comm=) if [[ "$pid" == 400 ]]; then echo '1 claude'; else echo '400 bash'; fi;;
lstart=) echo 'Thu Oct 09 08:53:20 2025';;
args=) echo claude;;
*) exit 1;;
esac
''')
        fake_ps.chmod(0o755)
        env['DISK_MAGICIAN_PS_BIN'] = str(fake_ps)
        leased = home / 'leased'
        leased.mkdir()
        (leased / 'sentinel').write_text('retain me')
        leases = state / 'worktree_leases'
        leases.mkdir(exist_ok=True)
        lease = leases / (hashlib.sha256(str(leased).encode()).hexdigest()[:16] + '.json')
        lease.write_text(json.dumps({'path': str(leased), 'owner': {'pid': 400, 'start_epoch': 1760000000, 'comm': 'claude'}}))
        run(cli + ['worktree-release', str(leased)], env)
        assert json.loads(lease.read_text())['released_at']
        assert (leased / 'sentinel').read_text() == 'retain me'
        result = run(cli + ['worktree-release', str(home / 'unleased')], env, 1)
        assert 'no lease' in result.stderr
        denied = json.loads(lease.read_text())
        denied['owner']['pid'] = 401
        lease.write_text(json.dumps(denied))
        before = lease.read_bytes()
        result = run(cli + ['worktree-release', str(leased)], env, 1)
        assert 'not lease owner' in result.stderr and lease.read_bytes() == before
        print('PASS:', tree.name, 'release updates only own lease without deleting; unleased fails')

        template = tree / 'launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template'
        raw = template.read_text()
        config = plistlib.loads(raw.encode())
        rendered = home / 'reap.plist'
        rendered.write_text(raw.replace('@HOME@', str(home)))
        run(['plutil', '-lint', str(rendered)], env)
        assert 'DISK_MAGICIAN_REAP_MODE' not in run(['plutil', '-p', str(rendered)], env).stdout
        assert config['ProgramArguments'] == ['@HOME@/.local/bin/diskm', 'worktree-reap']
        assert config['StartInterval'] == 1800
        for key in ('StandardOutPath', 'StandardErrorPath'):
            assert config[key] == '@HOME@/Library/Logs/disk-magician-worktree-reap.log'
        scheduled = config['EnvironmentVariables']
        assert '@HOME@/.local/bin' in scheduled['PATH'] and '/opt/homebrew/bin' in scheduled['PATH']
        assert scheduled['GIT_TERMINAL_PROMPT'] == '0'
        assert 'BatchMode=yes' in scheduled['GIT_SSH_COMMAND']
        assert config['Label'] in (tree / 'scripts/check_launchd_fleet.sh').read_text()
        installer = (tree / 'scripts/install_launchd_sweepers.sh').read_text()
        consolidated = installer.split('if [[ "$CONSOLIDATE" == true ]]; then\n  SELECTED=(', 1)[1].split(')', 1)[0]
        assert template.name in consolidated
        print('PASS:', tree.name, 'template lint, nominate default, environment and fleet registration')

        # A released, quiet linked worktree needs the cached merged-PR proof.
        repo = home / 'repo'
        wt = home / '.worktrees/repo/candidate'
        run(['git', 'init', '-q', str(repo)], env)
        (repo / 'file').write_text('fixture\n')
        run(['git', '-C', str(repo), 'add', 'file'], env)
        run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
             'commit', '-q', '--allow-empty', '-m', 'fixture'], env)
        run(['git', '-C', str(repo), 'remote', 'add', 'origin', 'https://github.com/example/repo.git'], env)
        run(['git', '-C', str(repo), 'worktree', 'add', '-qb', 'candidate', str(wt)], env)
        head = run(['git', '-C', str(wt), 'rev-parse', 'HEAD'], env).stdout.strip()
        run(['/bin/bash', '-c', 'source "$1"; lease_write "$2" "$3" candidate test',
             'fixture', str(tree / 'scripts/lib/worktree_lease.sh'), str(wt), str(repo)], env)
        candidate_lease = leases / (hashlib.sha256(str(wt).encode()).hexdigest()[:16] + '.json')
        candidate = json.loads(candidate_lease.read_text())
        candidate['released_at'] = datetime.fromtimestamp(time.time()-4000, timezone.utc).isoformat()
        candidate_lease.write_text(json.dumps(candidate))
        for base, dirs, files in os.walk(wt):
            for name in files:
                os.utime(Path(base) / name, (time.time()-4000,)*2)
        cache = state / 'pr_cache/example/repo.tsv'
        cache.parent.mkdir(parents=True)
        cache.write_text('#epoch %d\ncandidate\t%s\n' % (time.time(), head))
        real_git = shutil.which('git')
        mocks = {
            'git': 'for arg in "$@"; do [[ "$arg" != fetch ]] || exit 0; done\nexec ' + shlex.quote(real_git) + ' "$@"',
            'gh': 'echo unexpected-gh >> "$HOME/gh-called"\nexit 99',
            'timeout': 'echo "$*" >> "$HOME/timeout-called"\nshift\nexec "$@"',
            'lsof': "printf 'p999999\\nfcwd\\nn/\\n'",
        }
        for name, body in mocks.items():
            tool = bins / name
            tool.write_text('#!/bin/bash\n' + body + '\n')
            tool.chmod(0o755)
        launch_env = {key: value.replace('@HOME@', str(home)) for key, value in scheduled.items()}
        launch_env['HOME'] = str(home)
        run(['env', '-i', *[f'{k}={v}' for k,v in launch_env.items()], 'bash', str(tree / 'disk_magician.sh'), 'worktree-reap', '--mode', 'nominate'], env)
        terminal = json.loads(receipt.read_text())['last_terminal']
        assert terminal['candidates']['gh_failed'] == 0, terminal
        assert terminal['candidates']['gh_ok'] == 1, terminal
        assert terminal['candidates']['fetch_ok'] == 1, terminal
        assert 'fetch' in (home / 'timeout-called').read_text()
        assert not (home / 'gh-called').exists()
        assert json.loads(candidate_lease.read_text())['last_verdict'] == 'remove'
        assert wt.is_dir()
        print('PASS:', tree.name, 'clean launchd environment nominates using timeout and cached PR')

        # Shared receipt writer and reader must both accept a bounded partial run.
        helper = ['python3', str(tree / 'scripts/job_receipt.py')]
        run_id = run(helper + ['begin', '--job', 'worktree_reap'], env).stdout.strip()
        run(helper + ['finish', '--job', 'worktree_reap', '--run-id', run_id, '--outcome', 'partial'], env)
        data = json.loads(run(helper + ['read', '--job', 'worktree_reap'], env).stdout)
        assert data['last_terminal']['outcome'] == 'partial'
        assert data['last_success']['outcome'] == 'success'
        health = run(cli + ['sweeper-health', '--no-notify'], env, 1)
        assert 'worktree_reap' in health.stdout and 'partial' in health.stdout, health.stdout
        print('PASS:', tree.name, 'partial terminal accepted and reported by sweeper-health')
PY

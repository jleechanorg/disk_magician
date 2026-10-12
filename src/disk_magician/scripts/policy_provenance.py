#!/usr/bin/env python3
"""Standing-decision record (C11). Recording activates nothing; see removal_activation_ok."""
import glob, hashlib, json, os, pwd, re, subprocess, sys, tempfile, time
IDS = {'worktree_reap_remove': 'D1', 'worktree_cleanup': 'D1b', 'admission_enforcement': 'D2', 'budgets': 'D3',
       'ci_autopause': 'D4', 'colima_selfheal': 'D8', 'claude_state_cleanup': None}
PATH = os.environ.get('DISK_MAGICIAN_POLICY_FILE') or os.path.expanduser('~/.config/disk-magician/standing_decisions.json')
MARK, phrase = 'policy:worktree_reap_remove', 'APPROVE {}'.format  # fixed per id; the caller never chooses it
USAGE = 'usage: diskm policy approve <id> --from-transcript <~/.claude*/projects/**/*.jsonl> | set-amendment <id> <sha> | revoke <id> | list\napprove records only when a typed user message is exactly "APPROVE <id>" (trimmed, case-sensitive); ids: ' + ' '.join(IDS)
git = lambda repo, *a: subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True)

def find_approval(path, want):  # (realpath, line, sha256) of a genuine typed user message equal to want, else None
    real, home = os.path.realpath(path), pwd.getpwuid(os.getuid()).pw_dir  # real home: $HOME cannot move the root
    if not (os.path.isfile(real) and real.endswith('.jsonl') and any(real.startswith(os.path.realpath(r) + os.sep)
            for r in glob.glob(os.path.join(home, '.claude*', 'projects')))): return None
    for n, line in enumerate(open(real, 'rb'), 1):  # wrapped reminders/notifications can never equal the phrase
        m = json.loads(line); c = m.get('message', {}).get('content')
        if m.get('type') != 'user' or any(m.get(k) for k in ('isMeta', 'isSidechain', 'isCompactSummary')): continue
        if isinstance(c, list) and all(b.get('type') == 'text' for b in c): c = ''.join(b.get('text', '') for b in c)
        if isinstance(c, str) and c.strip() == want: return real, n, hashlib.sha256(line.rstrip(b'\n')).hexdigest()

def amendment(sha, repo):  # bounded fetch on every call; a stale local origin/main is never trusted
    p = subprocess.Popen(['git', '-C', repo, 'fetch', '-q', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main'],
                         env=dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false'), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try: ok = p.wait(timeout=float(os.environ.get('DISK_MAGICIAN_POLICY_FETCH_TIMEOUT', 30))) == 0
    except subprocess.TimeoutExpired: os.killpg(p.pid, 9); p.wait(); ok = False
    if not ok: return 'policy_unverified'
    if not sha: return 'amendment_missing'
    if git(repo, 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main').returncode: return 'amendment_not_on_main'
    return None if MARK in git(repo, 'show', 'refs/remotes/origin/main:CLAUDE.md').stdout else 'amendment_reverted'

def main(cmd='', i='', *a):
    d = json.load(open(PATH)) if os.path.exists(PATH) else {}
    live, repo = i in d and d[i]['revoked_at'] is None, os.environ.get('DISK_MAGICIAN_POLICY_REPO') or os.path.dirname(sys.path[0])
    if cmd == 'approve' and a[:1] == ('--from-transcript',) and len(a) == 2 and i in IDS:
        hit = find_approval(a[1], phrase(i))
        if not hit: return print(f'refused: no typed user message equal to {phrase(i)!r} in a ~/.claude*/projects transcript', file=sys.stderr) or 2
        d[i] = dict(zip(('transcript', 'line', 'line_sha256'), hit), id=i, phrase=phrase(i), approved_at=int(time.time()), revoked_at=None)
    elif cmd == 'set-amendment' and live and len(a) == 1:  # full commit sha that edits CLAUDE.md and carries MARK
        if not (re.fullmatch('[0-9a-f]{40}', a[0]) and 'CLAUDE.md' in git(repo, 'diff-tree', '--root', '--name-only', '-r', a[0]).stdout.split()
                and MARK in git(repo, 'show', f'{a[0]}:CLAUDE.md').stdout): return print('refused: not an amendment commit', file=sys.stderr) or 2
        d[i]['amendment_commit'] = a[0]
    elif cmd == 'revoke' and i in d: d[i]['revoked_at'] = int(time.time())
    elif cmd == 'approved': return 0 if live else 1
    elif cmd == 'amendment' and len(a) == 1:  # only reached after decision_approved
        why = amendment(d[i].get('amendment_commit'), a[0]) if live else 'decision_missing'; return print(why, end='') or 1 if why else 0
    elif cmd == 'list': return print(json.dumps({'phrases': {k: phrase(k) for k in IDS}, 'decisions': d}, indent=1, sort_keys=True)) or 0
    else: return print(USAGE, file=sys.stderr) or 2
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH), prefix='.policy-')
    with os.fdopen(fd, 'w') as f: json.dump(d, f, indent=1, sort_keys=True); f.write('\n')
    os.replace(tmp, PATH)
if __name__ == '__main__':
    try: sys.exit(main(*sys.argv[1:]) or 0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e: sys.exit(print(f'policy: {e}', file=sys.stderr) or 2)

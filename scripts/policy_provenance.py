#!/usr/bin/env python3
"""Standing-decision record (C11). Recording activates nothing; see removal_activation_ok."""
import json, os, re, subprocess, sys, tempfile, time
IDS = {'worktree_reap_remove': 'D1', 'worktree_cleanup': 'D1b', 'admission_enforcement': 'D2', 'budgets': 'D3',
       'ci_autopause': 'D4', 'colima_selfheal': 'D8', 'claude_state_cleanup': None}
PATH = os.environ.get('DISK_MAGICIAN_POLICY_FILE') or os.path.expanduser('~/.config/disk-magician/standing_decisions.json')

def user_texts(path):  # live user text only: no tool results, meta injections or sidechains
    for m in map(json.loads, open(path)):
        if m.get('type') == 'user' and not m.get('isMeta') and not m.get('isSidechain'):
            c = m.get('message', {}).get('content')
            yield from [c] if isinstance(c, str) else [b.get('text', '') for b in c if b.get('type') == 'text']

def amendment(sha, repo):  # bounded fetch on every call; a stale local origin/main is never trusted
    git = lambda *a, **k: subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, **k)
    p = subprocess.Popen(['git', '-C', repo, 'fetch', '-q', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main'],
                         env=dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false'), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try: ok = p.wait(timeout=float(os.environ.get('DISK_MAGICIAN_POLICY_FETCH_TIMEOUT', 30))) == 0
    except subprocess.TimeoutExpired: os.killpg(p.pid, 9); p.wait(); ok = False
    if not ok: return 'policy_unverified'
    if not sha: return 'amendment_missing'
    if git('merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main').returncode: return 'amendment_not_on_main'
    return None if 'policy:worktree_reap_remove' in git('show', 'refs/remotes/origin/main:CLAUDE.md').stdout else 'amendment_reverted'

def main(cmd='', i='', *a):
    d = json.load(open(PATH)) if os.path.exists(PATH) else {}
    live = i in d and d[i]['revoked_at'] is None
    if cmd == 'approve' and len(a) == 4 and a[0] == '--phrase' and a[2] == '--from-transcript' and i in IDS:
        names = '|'.join(re.escape(n) for n in (i, IDS[i]) if n)
        if not (a[1].strip() and re.search(r'\b(%s)\b' % names, a[1]) and any(a[1] in t for t in user_texts(a[3]))):
            return print('refused: phrase must name the decision and appear in a live user message', file=sys.stderr) or 2
        d[i] = {'id': i, 'phrase': a[1], 'transcript': a[3], 'approved_at': int(time.time()), 'revoked_at': None}
    elif cmd == 'set-amendment' and live and len(a) == 1: d[i]['amendment_commit'] = a[0]
    elif cmd == 'revoke' and i in d: d[i]['revoked_at'] = int(time.time())
    elif cmd in ('approved', 'amendment') and not live: return 1
    elif cmd == 'approved': return 0
    elif cmd == 'amendment' and len(a) == 1:
        why = amendment(d[i].get('amendment_commit'), a[0]); return print(why, end='') or 1 if why else 0
    elif cmd == 'list': return print(json.dumps(d, indent=1, sort_keys=True)) or 0
    else: return print('usage: diskm policy approve <id> --phrase <text> --from-transcript <jsonl> | set-amendment <id> <sha> | revoke <id> | list', file=sys.stderr) or 2
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH), prefix='.policy-')
    with os.fdopen(fd, 'w') as f: json.dump(d, f, indent=1, sort_keys=True); f.write('\n')
    os.replace(tmp, PATH)
if __name__ == '__main__':
    try: sys.exit(main(*sys.argv[1:]) or 0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e: sys.exit(print(f'policy: {e}', file=sys.stderr) or 2)

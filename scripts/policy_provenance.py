#!/usr/bin/env python3
"""Standing-decision record (C11). Recording activates nothing; see removal_activation_ok."""
import datetime, glob, hashlib, json, os, pwd, re, subprocess, sys, tempfile, time
IDS = {'worktree_reap_remove': 'D1', 'worktree_cleanup': 'D1b', 'admission_enforcement': 'D2', 'budgets': 'D3',
       'ci_autopause': 'D4', 'external_edits': 'D6', 'colima_selfheal': 'D8', 'claude_state_cleanup': None}
PATH = os.environ.get('DISK_MAGICIAN_POLICY_FILE') or os.path.expanduser('~/.config/disk-magician/standing_decisions.json')
MARK, phrase = 'policy:worktree_reap_remove', 'APPROVE {}'.format  # fixed per id; the caller never chooses it
USAGE = 'usage: diskm policy approve <id> --from-transcript <~/.claude*/projects/**/*.jsonl | ~/.codex/sessions/**/*.jsonl> | set-amendment <id> <sha> | revoke <id> | list\napprove records only when a genuine typed user message contains the whole phrase "APPROVE <id>" (case-sensitive; injected wrappers never count; Claude entries without origin.kind=human must equal it); ids: ' + ' '.join(IDS)
git = lambda repo, *a: subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True)
stamp = lambda m: datetime.datetime.fromisoformat(m.get('timestamp') or '1970-01-01T00:00:00+00:00').timestamp()  # after a revoke only newer lines count
def _trusted_root(home, uid):  # fixed OS-home trust: .codex AND .codex/sessions must be real uid-owned dirs
    for p in (os.path.join(home, '.codex'), os.path.join(home, '.codex', 'sessions')):
        try: st = os.lstat(p)
        except OSError: return False
        if os.path.islink(p) or not os.path.isdir(p) or st.st_uid != uid: return False  # symlink/wrong owner never counts
    return True
FLAGS = ('isMeta', 'isSidechain', 'isCompactSummary', 'inherited_user_message')
def _flagged(*objs):  # provenance flags on ANY envelope layer refuse the entry/header
    return any(isinstance(o, dict) and any(o.get(k) for k in FLAGS) for o in objs)
INJECTED = re.compile(r'<(?:teammate-message|task-notification|system-reminder|command-(?:message|name|args)|local-command-\w+|bash-(?:input|stdout|stderr)|agent-message|send_user_message_\w+|environment_context|user_instructions|user_shell_command|turn_aborted|subagent_notification)\b'
                      r'|Another Claude session sent a message|\[SYSTEM NOTIFICATION\]')  # harness-injected wrappers: never a typed approval
AGENT_KEYS = ('agentId', 'sourceToolUseID', 'toolUseResult')  # agent/tool provenance on a Claude user envelope
def _typed_phrase(text, want):  # typed text CONTAINS want as whole tokens; whitespace-normalised so a line wrap still matches
    return not INJECTED.search(text) and re.search(r'(?<![\w-])' + re.escape(want) + r'(?![\w-])', ' '.join(text.split())) is not None
def _codex_header(m):  # session_meta must be the interactive codex-tui CLI; flags on any layer never count
    p = m.get('payload')
    if not isinstance(p, dict): return False
    return (m.get('type') == 'session_meta'
            and not _flagged(m, p, m.get('metadata'), p.get('internal_chat_message_metadata_passthrough'))
            and p.get('source') == 'cli' and p.get('originator') == 'codex-tui')
def _codex_text(m):  # exact observed genuine typed user envelope, else None; unknown future forms refuse
    if m.get('type') != 'response_item': return None
    p = m.get('payload')
    if not isinstance(p, dict): return None
    pt, md = p.get('internal_chat_message_metadata_passthrough'), m.get('metadata')
    if _flagged(m, p, pt, md): return None  # metadata/sidechain/summary/inherited on any layer
    if p.get('type') != 'message' or p.get('role') != 'user': return None
    c = p.get('content')
    if not (isinstance(c, list) and c and all(isinstance(b, dict) and b.get('type') == 'input_text'
            and isinstance(b.get('text'), str) for b in c)): return None  # mixed text/image or tool blocks refuse
    if not (isinstance(pt, dict) and pt.get('content_item_kinds') == ['user.text']): return None
    if not isinstance(md, dict): return None
    if md.get('client_authored') is not False or not isinstance(md.get('mcp_attribution'), dict) \
            or md['mcp_attribution'].get('status') != 'none': return None
    rs = md.get('retained_source')
    if not (isinstance(rs, dict) and rs.get('complete') is True
            and isinstance(rs.get('id'), dict) and rs['id'].get('role') == 'user'): return None
    return ''.join(b['text'] for b in c)
def _codex_approval(real, want, after, uid):  # (realpath, line, sha256) in the trusted OS-home codex root
    if os.stat(real).st_uid != uid: return None  # the transcript file itself must be uid-owned
    with open(real, 'rb') as f:
        head = f.readline()
        try: meta = json.loads(head)
        except ValueError: return None  # missing/unparseable source header: fail closed
        if not _codex_header(meta): return None
        for n, line in enumerate(f, 2):
            try: m = json.loads(line)
            except ValueError: continue
            text = _codex_text(m)
            if text is not None and _typed_phrase(text, want) and stamp(m) > (after or -1):
                return real, n, hashlib.sha256(line.rstrip(b'\n')).hexdigest()
def _claude_approval(real, want, after):  # original fixed-phrase Claude projects scan, semantics unchanged
    for n, line in enumerate(open(real, 'rb'), 1):
        m = json.loads(line); c = m.get('message', {}).get('content')
        if m.get('type') != 'user' or _flagged(m) or any(m.get(k) for k in AGENT_KEYS): continue
        human = isinstance(m.get('origin'), dict) and m['origin'].get('kind') == 'human'  # harness-stamped typed input
        if 'origin' in m and not human: continue  # task-notification etc.
        if isinstance(c, list) and all(b.get('type') == 'text' for b in c): c = ''.join(b.get('text', '') for b in c)
        if isinstance(c, str) and (_typed_phrase(c, want) if human else c.strip() == want) and stamp(m) > (after or -1): return real, n, hashlib.sha256(line.rstrip(b'\n')).hexdigest()
def find_approval(path, want, after):  # (realpath, line, sha256) of a genuine typed user message containing want, else None
    home, uid = pwd.getpwuid(os.getuid()).pw_dir, os.getuid()  # real OS home: $HOME/CODEX_HOME cannot move the root
    real = os.path.realpath(path)
    if not (os.path.isfile(real) and real.endswith('.jsonl')): return None
    croot = os.path.join(home, '.codex', 'sessions')  # observed adapter: fixed root, never a caller-chosen path
    if real.startswith(os.path.realpath(croot) + os.sep):
        return _codex_approval(real, want, after, uid) if _trusted_root(home, uid) and not os.path.islink(path) else None
    if any(real.startswith(os.path.realpath(r) + os.sep) for r in glob.glob(os.path.join(home, '.claude*', 'projects'))):
        return _claude_approval(real, want, after)  # Claude semantics unchanged, incl. in-root symlink acceptance
    return None

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
        hit = find_approval(a[1], phrase(i), d.get(i, {}).get('revoked_at'))
        if not hit: return print(f'refused: no typed user message containing {phrase(i)!r} in a supported Claude projects or Codex sessions transcript', file=sys.stderr) or 2
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
    with os.fdopen(fd, 'w') as f: f.write(json.dumps(d, indent=1, sort_keys=True) + '\n')
    os.replace(tmp, PATH)
if __name__ == '__main__':
    try: sys.exit(main(*sys.argv[1:]) or 0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e: sys.exit(print(f'policy: {e}', file=sys.stderr) or 2)

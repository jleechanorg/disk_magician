#!/usr/bin/env python3
import os
import sys
import subprocess
import time
import re
import argparse
import concurrent.futures
import shutil
import threading

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RECENCY_HELPER = os.path.join(SCRIPT_DIR, 'lib', 'worktree_recency.sh')
REPO_LOCKS = {}
REPO_LOCKS_GUARD = threading.Lock()

def get_repo_lock(repo_path: str):
    with REPO_LOCKS_GUARD:
        if repo_path not in REPO_LOCKS:
            REPO_LOCKS[repo_path] = threading.Lock()
        return REPO_LOCKS[repo_path]

def get_worktree_age_days(wt_path: str) -> int:
    cmd = f'source "{RECENCY_HELPER}" && worktree_age_days "{wt_path}"'
    try:
        res = subprocess.run(['bash', '-c', cmd], capture_output=True, text=True, timeout=15)
        out = res.stdout.strip()
        if out and out.isdigit():
            return int(out)
    except Exception:
        pass
    return 0

def is_worktree_locked_by_process(wt_path: str) -> bool:
    try:
        res = subprocess.run(['lsof', '+D', wt_path], capture_output=True, text=True, timeout=5)
        lines = [l for l in res.stdout.strip().splitlines() if l]
        return len(lines) > 1
    except Exception:
        return False

def discover_worktrees():
    repos = [
        '/Users/jleechan/projects/worldarchitect.ai',
        '/Users/jleechan/projects/dark-factory',
        '/Users/jleechan/projects/merge_train',
        '/Users/jleechan/projects_other/disk_magician',
        '/Users/jleechan/project_worldaiclaw/worldai_claw',
    ]
    for p in ['/Users/jleechan/projects', '/Users/jleechan/projects_other']:
        if os.path.exists(p):
            for d in os.listdir(p):
                full = os.path.join(p, d)
                if os.path.isdir(os.path.join(full, '.git')) and full not in repos:
                    repos.append(full)

    seen = set()
    wt_list = []
    for r in repos:
        try:
            out = subprocess.run(['git', '-C', r, 'worktree', 'list', '--porcelain'], capture_output=True, text=True, timeout=10)
            if out.returncode == 0:
                lines = out.stdout.splitlines()
                cur_wt = None
                cur_branch = None
                for l in lines:
                    if l.startswith('worktree '):
                        cur_wt = l.split(' ', 1)[1]
                    elif l.startswith('branch '):
                        cur_branch = l.split(' ', 1)[1].replace('refs/heads/', '')
                    elif l.startswith('detached'):
                        cur_branch = 'detached'
                    elif l == '':
                        if cur_wt and cur_wt != r and cur_wt not in seen and os.path.exists(cur_wt):
                            seen.add(cur_wt)
                            wt_list.append((r, cur_wt, cur_branch or 'unknown'))
                        cur_wt = None
                        cur_branch = None
                if cur_wt and cur_wt != r and cur_wt not in seen and os.path.exists(cur_wt):
                    seen.add(cur_wt)
                    wt_list.append((r, cur_wt, cur_branch or 'unknown'))
        except Exception:
            pass

    for extra in ['/Users/jleechan/.ao/data/worktrees', '/Users/jleechan/.gemini/antigravity/worktrees', '/Users/jleechan/.worktrees', '/Users/jleechan/worktrees']:
        if os.path.exists(extra):
            for root, dirs, files in os.walk(extra):
                if '.git' in files:
                    wt_path = root
                    if wt_path not in seen and os.path.exists(wt_path):
                        try:
                            with open(os.path.join(wt_path, '.git')) as f:
                                content = f.read()
                            m = re.search(r'gitdir:\s*(.+)', content)
                            if m:
                                gitdir = m.group(1).strip()
                                main_repo = gitdir.split('/.git/worktrees/')[0]
                                if os.path.exists(main_repo):
                                    seen.add(wt_path)
                                    wt_list.append((main_repo, wt_path, 'unknown'))
                        except Exception:
                            pass
    return wt_list

def triage_and_prune(item, min_age_days, execute):
    main_repo, wt_path, branch = item
    age = get_worktree_age_days(wt_path)
    if age < min_age_days:
        return {'status': 'PRESERVE', 'reason': f'young (<{min_age_days}d)', 'age': age, 'path': wt_path, 'repo': main_repo}
    
    if is_worktree_locked_by_process(wt_path):
        return {'status': 'PRESERVE', 'reason': 'active-process-lock', 'age': age, 'path': wt_path, 'repo': main_repo}

    if execute:
        repo_lock = get_repo_lock(main_repo)
        with repo_lock:
            try:
                # If directory still exists on disk
                if os.path.exists(wt_path):
                    st_res = subprocess.run(['git', '-C', wt_path, 'status', '--porcelain'], capture_output=True, text=True, timeout=10)
                    status_out = st_res.stdout.strip()
                    if status_out:
                        bk_branch = f'backup/prune-{branch if branch != "detached" else "detached"}-{int(time.time())}'
                        subprocess.run(['git', '-C', wt_path, 'checkout', '-b', bk_branch], capture_output=True, timeout=10)
                        subprocess.run(['git', '-C', wt_path, 'add', '-A'], capture_output=True, timeout=10)
                        subprocess.run(['git', '-C', wt_path, 'commit', '-m', f'backup before automated worktree prune (age={age}d)'], capture_output=True, timeout=10)
                
                rm_res = subprocess.run(['git', '-C', main_repo, 'worktree', 'remove', '--force', wt_path], capture_output=True, text=True, timeout=20)
                if os.path.exists(wt_path):
                    shutil.rmtree(wt_path, ignore_errors=True)
                    subprocess.run(['git', '-C', main_repo, 'worktree', 'prune'], capture_output=True, timeout=10)
                return {'status': 'PRUNED', 'reason': 'success', 'age': age, 'path': wt_path, 'repo': main_repo}
            except Exception as e:
                return {'status': 'ERROR', 'reason': str(e), 'age': age, 'path': wt_path, 'repo': main_repo}
    else:
        return {'status': 'ELIGIBLE', 'reason': 'candidate', 'age': age, 'path': wt_path, 'repo': main_repo}

def main():
    parser = argparse.ArgumentParser(description='Prune dormant git worktrees with safety preservation.')
    parser.add_argument('--min-age', '--days', dest='min_age', type=int, default=7, help='Minimum age in days (default: 7)')
    parser.add_argument('--clean', '--execute', dest='execute', action='store_true', help='Execute actual deletion')
    parser.add_argument('--dry-run', dest='execute', action='store_false', help='Dry-run mode (default)')
    parser.set_defaults(execute=False)
    args = parser.parse_args()

    if args.execute and os.environ.get('WORKTREE_APPROVED') != '1':
        print('Refusing to delete worktrees: WORKTREE_APPROVED=1 is required in the environment.', file=sys.stderr)
        sys.exit(1)

    print(f'=== WORKTREE PRUNE (min_age >= {args.min_age}d, execute={args.execute}) ===')
    worktrees = discover_worktrees()
    print(f'Discovered {len(worktrees)} worktrees across the system. Evaluating...')

    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        futures = [executor.submit(triage_and_prune, item, args.min_age, args.execute) for item in worktrees]
        results = [f.result() for f in futures]

    pruned = [r for r in results if r['status'] in ('PRUNED', 'ELIGIBLE')]
    preserved = [r for r in results if r['status'] == 'PRESERVE']
    errors = [r for r in results if r['status'] == 'ERROR']

    print('=' * 70)
    print(f'SUMMARY:')
    print(f'  {len(pruned)} worktrees {"PRUNED" if args.execute else "ELIGIBLE FOR PRUNING"} (>= {args.min_age}d)')
    print(f'  {len(preserved)} worktrees PRESERVED (< {args.min_age}d or active process lock)')
    if errors:
        print(f'  {len(errors)} ERRORS')
    print('=' * 70)

    for r in sorted(pruned, key=lambda x: x["age"], reverse=True)[:30]:
        print(f'  {r["status"]} | age={r["age"]}d | {r["path"]}')
    if len(pruned) > 30:
        print(f'  ... and {len(pruned) - 30} more worktrees.')

if __name__ == '__main__':
    main()

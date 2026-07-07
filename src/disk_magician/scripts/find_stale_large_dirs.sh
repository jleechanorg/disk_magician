#!/usr/bin/env bash
# find_stale_large_dirs.sh — large dirs not modified in N days (excludes convos)
set -euo pipefail
DAYS=14; MIN_MB=500
while [[ $# -gt 0 ]]; do case "$1" in --days) DAYS="$2"; shift 2;; --min-mb) MIN_MB="$2"; shift 2;; -h|--help) sed -n '1,8p' "$0"; exit 0;; *) shift;; esac; done
export DAYS MIN_MB
python3 - <<'PY'
import os, subprocess, time
days=int(os.environ["DAYS"]); min_mb=int(os.environ["MIN_MB"]); cutoff=time.time()-days*86400
exclude=("/conversations","/sessions/","/sessions","/chats/","/chats","/convos/")
roots=[os.path.expanduser(p) for p in ["~/.worktrees","~/projects","~/projects_other","~/projects_reference","~/.hermes","~/.gemini","~/.codex","~/.colima"]]
def ex(p): return any(x in p.lower() for x in exclude)
def sz(p):
  try: return int(subprocess.check_output(["du","-sk",p],stderr=subprocess.DEVNULL,timeout=120).split()[0])/1024
  except: return 0
hits=[]
for root in roots:
  if not os.path.isdir(root): continue
  for name in os.listdir(root):
    path=os.path.join(root,name)
    if not os.path.isdir(path) or ex(path): continue
    try:
      if os.path.getmtime(path)>=cutoff: continue
      mb=sz(path)
      if mb>=min_mb: hits.append((mb,time.strftime("%Y-%m-%d",time.localtime(os.path.getmtime(path))),path))
    except OSError: pass
hits.sort(reverse=True)
print(f"Stale >={days}d, >={min_mb}MB — {len(hits)} hits\n")
for mb,mt,p in hits[:40]: print(f"{mb/1024:6.1f}G  {mt}  {p}")
PY

#!/bin/bash
# set_gc_worktree_prune.sh — pin gc.worktreePruneExpire to 7.days.ago for all
# bare git repos in known locations, so `git worktree prune` reaps sleeping
# worktree links automatically. Idempotent. Dry-run by default; --apply to mutate.
#
# Why: default git behavior keeps worktree metadata for 3 months when the
# metadata path is gone, but never reaps existing-but-sleeping worktrees.
# Bounding this to 7 days matches the AO session lifetime and prevents
# ~/projects/* and ~/.worktrees/* from accumulating indefinitely.
#
# Background: observed 265+ sleeping worktree directories in ~/projects since
# the prior session's audit. Each is a directory that AO/AO-worker sessions
# created and abandoned. The kernel does not auto-remove them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DAYS="${DAYS:-7}"
APPLY=false
# arg parsing for --apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    *) shift ;;
  esac
done

REPOS=()
if [[ -n "${DISK_MAGICIAN_GC_REPOS:-}" ]]; then
  IFS=':' read -r -a REPOS <<< "${DISK_MAGICIAN_GC_REPOS}"
elif command -v python3 >/dev/null 2>&1; then
  CONFIG="${DISK_MAGICIAN_CONFIG:-$REPO_ROOT/config.json}"
  [[ -f "$CONFIG" ]] || CONFIG="$REPO_ROOT/config.json.template"
  export CONFIG
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && REPOS+=("$repo")
  done < <(python3 - <<'PYCFG'
import json, os, sys
from pathlib import Path
cfg = Path(os.environ.get("CONFIG", ""))
try:
    data = json.loads(cfg.read_text())
except Exception:
    sys.exit(0)
for p in data.get("gc_worktree_repos") or []:
    print(os.path.expanduser(p))
PYCFG
  )
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "No repos configured. Set DISK_MAGICIAN_GC_REPOS (colon-separated paths)"
  echo "or add gc_worktree_repos to config.json (see config.json.template)."
  exit 0
fi

action="would set"
$APPLY && action="setting"

APPLIED=0
SKIPPED=0
echo "Mode: $([[ "$APPLY" == true ]] && echo APPLY || echo DRY-RUN)"
echo "Target: gc.worktreePruneExpire=${DAYS}.days.ago"
echo

for r in "${REPOS[@]}"; do
  if [[ ! -d "$r/.git" ]]; then
    echo "  SKIP (no .git): $r"
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi
  current=$(git -C "$r" config --get gc.worktreePruneExpire 2>/dev/null || echo "")
  if [[ "$current" == "${DAYS}.days.ago" ]]; then
    echo "  ALREADY-SET: $r  (current=$current)"
    continue
  fi
  echo "  $action gc.worktreePruneExpire=${DAYS}.days.ago in $r  (current=${current:-unset})"
  if $APPLY; then
    git -C "$r" config --local gc.worktreePruneExpire "${DAYS}.days.ago"
    APPLIED=$(( APPLIED + 1 ))
  fi
done

echo
echo "Summary: applied=$APPLIED skipped=$SKIPPED total=${#REPOS[@]}"
$APPLY || echo "(dry-run — no changes written; re-run with --apply to mutate)"

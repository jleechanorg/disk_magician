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

DAYS="${DAYS:-7}"
APPLY=false
# arg parsing for --apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    *) shift ;;
  esac
done

REPOS=(
  "$HOME/projects/worldarchitect.ai"
  "$HOME/jleechanorg/agent-orchestrator"
  "$HOME/llm_wiki"
  "$HOME/projects_other/user_scope"
  "$HOME/projects_other/worldarchitect.ai"
  "$HOME/projects_reference/agent-orchestrator-mirror"
  "$HOME/hermes-agent"
)

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

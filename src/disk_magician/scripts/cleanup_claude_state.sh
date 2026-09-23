#!/usr/bin/env bash
# cleanup_claude_state.sh — Tier-6-style gated sweeper for ~/.claude/state
# per-task work dirs (bead disk_magician-isw).
#
# ~/.claude/state accumulates ad-hoc per-task scratch dirs created by the
# user's own interactive orchestrator sessions (stack-review-*, reward-
# evidence-*, pr-stack-fix-*, rewards-managed-groups.*, ...) dispatching
# codex exec / agy verifier lanes into full git clones/worktrees, each
# carrying node_modules + venvs + evidence/video. Producer-side tracing
# (disk_magician-isw notes, 2026-09-22) found NO owning slash command or
# script -- these are operator-driven work-dir names, not hardcoded
# constants -- so there is no producer fix to make. This script is the
# reclaim-path half of that bead: cleanup_worktrees.sh only walks
# `git worktree list --porcelain` entries registered against a known main
# repo, and these per-task dirs are standalone clones/detached worktrees
# that were never registered that way.
#
# Candidate = direct child dir of --root (default ~/.claude/state).
# Eligible only if ALL of:
#   - not a symlink itself (a symlinked child of the root is REFUSED outright
#     -- never followed, never deleted)
#   - realpath resolves to a path still inside the (canonicalized) root, and
#     not inside ~/.claude/projects (defense in depth; --root can never
#     point there either -- see the hard refusal check below)
#   - content age (scripts/lib/worktree_recency.sh: newest regular-file
#     mtime in the tree, NOT directory mtime) >= --min-age days (default 7,
#     the CLAUDE.md worktree floor -- may only be raised); unmeasurable
#     content fails closed to age 0, i.e. preserved
#   - every git repo/worktree found inside (bounded depth, default
#     --maxdepth 3) is clean (no uncommitted/untracked changes), has no
#     stash, and has no commits ahead of its upstream (or, when no upstream
#     is configured, IS contained in at least one remote-tracking branch)
#     -- any git repo failing this makes the WHOLE candidate NEEDS-REVIEW
#   - no open file handles anywhere under the candidate (`lsof +D`,
#     timeout-bounded); any lsof error, timeout, or unexpected output fails
#     closed to "has open handles" (preserved)
#
# Defaults to dry-run. --clean requires CLAUDE_STATE_APPROVED=1 in the
# environment. Never touches ~/.claude/projects (hard refusal even under a
# --root override) or anything a symlink would otherwise reach outside the
# root.
set -uo pipefail
# Deliberately NOT `set -e`: a single candidate's git/lsof probe erroring
# must not abort the sweep over every other candidate -- each probe's
# failure is handled explicitly and fails closed (preserved), never silently
# skipped by an early exit.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"

DRY_RUN=true
MIN_AGE_DAYS="${CLAUDE_STATE_MIN_AGE_DAYS:-7}"
STATE_ROOT="${CLAUDE_STATE_ROOT:-$HOME/.claude/state}"
LSOF_TIMEOUT_SEC="${CLAUDE_STATE_LSOF_TIMEOUT_SEC:-20}"
GIT_MAXDEPTH="${CLAUDE_STATE_GIT_MAXDEPTH:-3}"

usage() {
  cat <<'EOF'
Usage: cleanup_claude_state.sh [--clean] [--dry-run] [--min-age N] [--root PATH] [-h|--help]

Tier-6-style gated sweeper for ~/.claude/state per-task work dirs (full git
clones/worktrees + node_modules + venvs + evidence/video left behind by
interactive orchestrator sessions -- bead disk_magician-isw).

Options:
  --clean       Actually remove eligible dirs (default: dry-run).
                Requires CLAUDE_STATE_APPROVED=1 in the environment.
  --dry-run     Print actions without touching disk (default).
  --min-age N   Minimum content age in days for eligibility (default: 7).
                Hard floor: may only be raised, never lowered (CLAUDE.md).
  --root PATH   Root directory to scan (default: ~/.claude/state). Tests
                only -- production callers should never override this, and
                ~/.claude/projects (or anything under it) is refused even
                if passed here.
  -h, --help    Show this help.

Environment:
  CLAUDE_STATE_APPROVED=1        Required for --clean deletions.
  CLAUDE_STATE_MIN_AGE_DAYS      Default for --min-age when flag omitted.
  CLAUDE_STATE_ROOT              Default for --root when flag omitted.
  CLAUDE_STATE_LSOF_TIMEOUT_SEC  lsof bound in seconds (default 20).
  CLAUDE_STATE_GIT_MAXDEPTH      find -maxdepth for nested .git discovery
                                 (default 3).
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --min-age|--days)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      MIN_AGE_DAYS="$2"
      shift
      ;;
    --root)
      [[ $# -ge 2 ]] || { echo "--root requires a value" >&2; exit 2; }
      STATE_ROOT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# Hard floor: 7 days, may only be raised, never lowered (CLAUDE.md
# invariant). Normalize via 10# BEFORE clamping -- bash arithmetic parses a
# leading-zero numeral like "08" as invalid octal otherwise.
if [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
else
  MIN_AGE_DAYS=7
fi
[[ "$MIN_AGE_DAYS" -lt 7 ]] && MIN_AGE_DAYS=7

# realpath_or_empty <path> -- portable realpath (python3 is always present
# on this machine; avoids depending on GNU coreutils' realpath -f).
realpath_or_empty() {
  python3 -c 'import os, sys
try:
    print(os.path.realpath(sys.argv[1]))
except Exception:
    pass' "$1" 2>/dev/null
}

size_kb() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
  du -sk "$path" 2>/dev/null | awk '{print $1+0}'
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
      if ($kb >= 1048576)  printf \"%.2fG\", $kb / 1048576
      else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
      else                  printf \"%dK\", $kb
  }"
}

# claude_state_git_repos <candidate_dir> -- print one .git path per line for
# every git repo/worktree found within bounded depth. node_modules/venv/etc
# are pruned from the walk both for performance on these node_modules-heavy
# clones and because `find` never has `-L`, so a symlink is never followed
# during this walk either.
claude_state_git_repos() {
  local candidate="$1"
  find "$candidate" \
    \( -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \) -prune \
    -o -maxdepth "$GIT_MAXDEPTH" -name .git \( -type d -o -type f \) -print \
    2>/dev/null
}

# claude_state_git_check <git_path> -- echoes a one-word reason to stdout,
# returns rc 0 = clean/pushed/no-stash, rc 1 = NEEDS-REVIEW, rc 2 = probe
# itself failed (caller treats identically to rc 1: fail closed).
claude_state_git_check() {
  local git_path="$1" repo_dir
  repo_dir="$(dirname "$git_path")"

  local status
  if ! status="$(git -C "$repo_dir" status --porcelain 2>&1)"; then
    echo "git-status-failed"
    return 2
  fi
  if [[ -n "$status" ]]; then
    echo "dirty"
    return 1
  fi

  local stash
  if ! stash="$(git -C "$repo_dir" stash list 2>&1)"; then
    echo "git-stash-failed"
    return 2
  fi
  if [[ -n "$stash" ]]; then
    echo "stash-present"
    return 1
  fi

  local upstream
  if upstream="$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    local ahead
    ahead="$(git -C "$repo_dir" rev-list --count "${upstream}..HEAD" 2>/dev/null || true)"
    if [[ -z "$ahead" || ! "$ahead" =~ ^[0-9]+$ ]]; then
      echo "ahead-count-failed"
      return 2
    fi
    if (( ahead > 0 )); then
      echo "unpushed-ahead-of-upstream"
      return 1
    fi
  else
    # No upstream configured. Fall back to: is HEAD contained in ANY
    # remote-tracking branch? If not, there is no proof it is pushed
    # anywhere, so it stays NEEDS-REVIEW.
    local contains
    if ! contains="$(git -C "$repo_dir" branch -r --contains HEAD 2>&1)"; then
      echo "contains-check-failed"
      return 2
    fi
    if [[ -z "$contains" ]]; then
      echo "not-on-any-remote-branch"
      return 1
    fi
  fi

  echo "clean"
  return 0
}

# claude_state_has_open_handles <candidate_dir> -- rc 0 = open handles found
# OR the lsof probe was inconclusive (timeout/error/unexpected output) --
# both fail closed to "treat as open" (preserved). rc 1 = lsof confirmed
# zero matches.
claude_state_has_open_handles() {
  local candidate="$1" out rc
  out="$(timeout "$LSOF_TIMEOUT_SEC" lsof +D "$candidate" 2>&1)"
  rc=$?
  if [[ -n "$out" ]]; then
    return 0
  fi
  if [[ $rc -eq 1 ]]; then
    return 1
  fi
  return 0
}

refuse_path() {
  echo "REFUSED  $2  ($1)"
}

if [[ ! -d "$STATE_ROOT" ]]; then
  echo "State root does not exist: $STATE_ROOT"
  exit 0
fi

STATE_ROOT_REAL="$(cd "$STATE_ROOT" 2>/dev/null && pwd -P || true)"
if [[ -z "$STATE_ROOT_REAL" ]]; then
  echo "Cannot resolve state root: $STATE_ROOT -- refusing to proceed" >&2
  exit 1
fi

PROJECTS_DIR_REAL="$(cd "$HOME/.claude/projects" 2>/dev/null && pwd -P || true)"
if [[ -n "$PROJECTS_DIR_REAL" ]] && { [[ "$STATE_ROOT_REAL" == "$PROJECTS_DIR_REAL" ]] || [[ "$STATE_ROOT_REAL" == "$PROJECTS_DIR_REAL"/* ]]; }; then
  echo "REFUSING: resolved root $STATE_ROOT_REAL is ~/.claude/projects or inside it -- hard-banned" >&2
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "=== CLAUDE STATE CLEANUP (DRY-RUN) === root=$STATE_ROOT_REAL min-age=${MIN_AGE_DAYS}d"
else
  echo "=== CLAUDE STATE CLEANUP === root=$STATE_ROOT_REAL min-age=${MIN_AGE_DAYS}d"
  if [[ "${CLAUDE_STATE_APPROVED:-0}" != "1" ]]; then
    echo "Refusing to delete: set CLAUDE_STATE_APPROVED=1 after explicit approval."
    exit 0
  fi
fi

TOTAL_ELIGIBLE_KB=0
ELIGIBLE_COUNT=0
NEEDS_REVIEW_COUNT=0
PRESERVED_YOUNG_COUNT=0
PRESERVED_OPEN_COUNT=0
REFUSED_COUNT=0

shopt -s nullglob
for candidate in "$STATE_ROOT_REAL"/*/; do
  candidate="${candidate%/}"

  if [[ -L "$candidate" ]]; then
    refuse_path "symlink-child-of-state-root" "$candidate"
    REFUSED_COUNT=$((REFUSED_COUNT + 1))
    continue
  fi

  candidate_real="$(realpath_or_empty "$candidate")"
  if [[ -z "$candidate_real" || "$candidate_real" != "$STATE_ROOT_REAL"/* ]]; then
    refuse_path "resolves-outside-state-root" "$candidate"
    REFUSED_COUNT=$((REFUSED_COUNT + 1))
    continue
  fi
  if [[ -n "$PROJECTS_DIR_REAL" ]] && { [[ "$candidate_real" == "$PROJECTS_DIR_REAL" ]] || [[ "$candidate_real" == "$PROJECTS_DIR_REAL"/* ]]; }; then
    refuse_path "resolves-into-claude-projects" "$candidate"
    REFUSED_COUNT=$((REFUSED_COUNT + 1))
    continue
  fi

  age_days="$(worktree_age_days "$candidate")"
  if (( age_days < MIN_AGE_DAYS )); then
    echo "PRESERVE $candidate  (age ${age_days}d < ${MIN_AGE_DAYS}d floor)"
    PRESERVED_YOUNG_COUNT=$((PRESERVED_YOUNG_COUNT + 1))
    continue
  fi

  needs_review=false
  review_reason=""
  while IFS= read -r git_path; do
    [[ -n "$git_path" ]] || continue
    reason="$(claude_state_git_check "$git_path")"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      needs_review=true
      review_reason="$reason ($git_path)"
      break
    fi
  done < <(claude_state_git_repos "$candidate")

  if [[ "$needs_review" == true ]]; then
    echo "NEEDS-REVIEW $candidate  ($review_reason)"
    NEEDS_REVIEW_COUNT=$((NEEDS_REVIEW_COUNT + 1))
    continue
  fi

  if claude_state_has_open_handles "$candidate"; then
    echo "PRESERVE $candidate  (open file handles or lsof probe inconclusive)"
    PRESERVED_OPEN_COUNT=$((PRESERVED_OPEN_COUNT + 1))
    continue
  fi

  size_kb_val="$(size_kb "$candidate")"
  TOTAL_ELIGIBLE_KB=$((TOTAL_ELIGIBLE_KB + size_kb_val))
  ELIGIBLE_COUNT=$((ELIGIBLE_COUNT + 1))

  if [[ "$DRY_RUN" == true ]]; then
    echo "ELIGIBLE $candidate  (age ${age_days}d, $(fmt_kb "$size_kb_val"))"
  else
    echo "DELETING $candidate  (age ${age_days}d, $(fmt_kb "$size_kb_val"))"
    rm -rf -- "$candidate"
  fi
done

echo
echo "=== Summary ==="
echo "Eligible: $ELIGIBLE_COUNT dirs, $(fmt_kb "$TOTAL_ELIGIBLE_KB")"
echo "NEEDS-REVIEW (preserved): $NEEDS_REVIEW_COUNT"
echo "Preserved (young, <${MIN_AGE_DAYS}d): $PRESERVED_YOUNG_COUNT"
echo "Preserved (open handles / lsof inconclusive): $PRESERVED_OPEN_COUNT"
echo "Refused (symlink escape / outside root): $REFUSED_COUNT"

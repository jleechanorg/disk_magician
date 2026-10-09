#!/usr/bin/env bash
# cleanup_worktree_deps.sh — Strip rebuildable dependency dirs from dormant worktrees.
#
# Removes node_modules, Rust target/ (only beside a Cargo.toml) and .mypy_cache
# from linked git worktrees (a `.git` FILE pointer) whose content saw no activity
# within the worktree floor (safety_worktree_floor_days, default 3). The worktree
# source and .git are preserved; reinstall with npm ci / cargo build.
#
# Defaults to dry-run. --clean requires WORKTREE_APPROVED=1.
#
# Safety: fail-closed recency via worktree_is_recently_active; skips symlinked
# dirs, base repos (.git directory), AO-owned worktrees, and any worktree that
# contains a process cwd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"

DRY_RUN=true
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-}"
if [[ -n "${DISK_MAGICIAN_WORKTREE_ROOTS:-}" ]]; then
  IFS=',' read -r -a ROOTS <<< "$DISK_MAGICIAN_WORKTREE_ROOTS"
else
  ROOTS=("$HOME/projects" "$HOME/.worktrees" "$HOME/project_worldaiclaw" "$HOME/projects_other")
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --min-age|--days) MIN_AGE_DAYS="$2"; shift 2 ;;
    --roots) IFS=',' read -r -a ROOTS <<< "$2"; shift 2 ;;
    -h|--help)
      echo "Usage: cleanup_worktree_deps.sh [--clean] [--dry-run] [--min-age N] [--roots A,B]"
      echo "Strips node_modules, target (with Cargo.toml) and .mypy_cache from worktrees idle >= floor days."
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

floor=$(safety_worktree_floor_days 2>/dev/null || echo 3)
[[ "$floor" =~ ^[0-9]+$ ]] || floor=3
floor=$((10#$floor))
[[ "$floor" -lt 3 ]] && floor=3
[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || MIN_AGE_DAYS="$floor"
MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
[[ "$MIN_AGE_DAYS" -lt "$floor" ]] && MIN_AGE_DAYS="$floor"

if [[ "$DRY_RUN" == true ]]; then
  echo "=== WORKTREE DEPS CLEANUP (DRY-RUN) — floor ${MIN_AGE_DAYS}d ==="
else
  echo "=== WORKTREE DEPS CLEANUP — floor ${MIN_AGE_DAYS}d ==="
  if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
    echo "Refusing to delete: set WORKTREE_APPROVED=1."
    exit 0
  fi
fi

LIVE_CWDS="$(lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
now="$(date +%s)"
total_kb=0
count=0

is_live() {
  local wt="$1" c
  while IFS= read -r c; do
    [[ -n "$c" && ( "$c" == "$wt" || "$c" == "$wt"/* ) ]] && return 0
  done <<< "$LIVE_CWDS"
  return 1
}

strip_dir() {
  local wt="$1" dir="$2" kb
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  if [[ "$DRY_RUN" == true ]]; then
    echo "  WOULD-STRIP ${kb}KB $dir"
  else
    rm -rf -- "$dir" && echo "  STRIPPED   ${kb}KB $dir" || { echo "  FAILED $dir"; return 0; }
  fi
  total_kb=$((total_kb + kb))
  count=$((count + 1))
}

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  for wt in "$root"/* "$root"/*/*; do
    [[ -f "$wt/.git" && ! -L "$wt" ]] || continue
    [[ "$wt" == *"ao/data/worktrees/"* ]] && continue
    [[ -e "$wt/node_modules" || -e "$wt/target" || -e "$wt/.mypy_cache" ]] || continue
    if worktree_is_recently_active "$wt" "$MIN_AGE_DAYS" "$now"; then continue; fi
    if is_live "$wt"; then continue; fi
    strip_dir "$wt" "$wt/node_modules"
    [[ -f "$wt/Cargo.toml" ]] && strip_dir "$wt" "$wt/target"
    strip_dir "$wt" "$wt/.mypy_cache"
  done
done

echo "=== Summary ==="
echo "Dirs: $count  Total: $((total_kb / 1024)) MB ($total_kb KB)"

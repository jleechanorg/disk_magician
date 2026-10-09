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
# Safety: fail-closed recency via worktree_is_recently_active; fail-closed live-cwd
# (lsof failure aborts the run); skips symlinked dirs, base repos (.git
# directory), AO-owned worktrees (path or AO config worktreeDir), and anything
# machine-local safety rules protect (safety_gate).
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

# Live-cwd evidence must be complete; otherwise refuse to delete anything.
lsof_bin="$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)"
[[ -x "$lsof_bin" ]] || { echo "lsof unavailable: cwd unknown, refusing."; exit 0; }
lsof_err="$(mktemp)"
lsof_rc=0
LIVE_CWDS_RAW="$("$lsof_bin" -d cwd -Fn 2>"$lsof_err")" || lsof_rc=$?
lsof_msg="$(cat "$lsof_err" 2>/dev/null || true)"; rm -f "$lsof_err"
if [[ "$lsof_rc" -ne 0 || -z "$LIVE_CWDS_RAW" ]] \
    || grep -qiE 'warning|permission denied|cannot|error' <<<"$lsof_msg"; then
  echo "lsof output incomplete: cwd unknown, refusing."; exit 0
fi
LIVE_CWDS="$(sed -n 's/^n\(\/.*\)$/\1/p' <<<"$LIVE_CWDS_RAW")"

# AO-owned worktrees: any directory named by worktreeDir in the AO config.
AO_DIRS=()
ao_cfg="${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml}"
if [[ -e "$ao_cfg" ]]; then
  [[ -r "$ao_cfg" ]] || { echo "AO config unreadable: refusing."; exit 0; }
  while IFS= read -r d; do
    d="${d//\"/}"; d="${d//\'/}"; d="${d/#\~/$HOME}"; d="${d//\$HOME/$HOME}"; d="${d%/}"
    [[ -n "$d" ]] && AO_DIRS+=("$d")
  done < <(sed -n 's/^[[:space:]]*worktreeDir:[[:space:]]*//p' "$ao_cfg")
fi
is_ao_owned() {
  local wt="$1" d
  [[ "$wt" == *"ao/data/worktrees/"* ]] && return 0
  for d in ${AO_DIRS[@]+"${AO_DIRS[@]}"}; do
    [[ "$wt" == "$d"/* ]] && return 0
  done
  return 1
}
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
  if ! _reason="$(safety_gate "$dir" 2>/dev/null)"; then
    echo "  SAFETY-SKIP $dir ($_reason)"
    return 0
  fi
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
    is_ao_owned "$wt" && continue
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

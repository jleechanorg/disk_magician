#!/usr/bin/env bash
# cleanup_worktree_deps.sh — Strip rebuildable dependency dirs from dormant worktrees.
#
# Removes node_modules, Rust target/ (only beside a Cargo.toml) and .mypy_cache
# from linked git worktrees (a `.git` FILE pointer) whose content saw no activity
# within the worktree floor (safety_worktree_floor_days, default 3). Nested build
# caches (e.g. daemon/target in a multi-crate tree) are stripped only when the
# dir that owns them holds the manifest that produces them. The worktree source
# and .git are preserved; reinstall with npm ci / cargo build.
#
# Defaults to dry-run. --clean requires WORKTREE_APPROVED=1.
#
# Safety: fail-closed recency via worktree_is_recently_active; fail-closed live-cwd
# (lsof failure aborts the run); skips symlinked dirs (find never follows a link,
# so a symlinked parent is not traversed), base repos (.git directory), AO-owned
# worktrees (path or AO config worktreeDir), and anything machine-local safety
# rules protect (safety_gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/lsof_linux.sh
source "$SCRIPT_DIR/lib/lsof_linux.sh"
# shellcheck source=scripts/lib/ao_worktree_config.sh
source "$SCRIPT_DIR/lib/ao_worktree_config.sh"

DRY_RUN=true
INCLUDE_REPOS=false
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-}"
if [[ -n "${DISK_MAGICIAN_WORKTREE_ROOTS:-}" ]]; then
  IFS=',' read -r -a ROOTS <<< "$DISK_MAGICIAN_WORKTREE_ROOTS"
else
  ROOTS=("$HOME/projects" "$HOME/.worktrees" "$HOME/.codex-worktrees" "$HOME/project_worldaiclaw" "$HOME/project_worldai_frontend" "$HOME/wc-wt" "$HOME/projects_other" "$HOME/Documents/Codex" "$HOME/worktrees" "$HOME/mirror/projects" "$HOME/agent-f" "$HOME/worldarchitect.ai.worktrees")
  for _wf in "$HOME"/wf_*; do
    [[ -d "$_wf" && ! -L "$_wf" ]] && ROOTS+=("$_wf")
  done
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --min-age|--days) MIN_AGE_DAYS="$2"; shift 2 ;;
    --roots) IFS=',' read -r -a ROOTS <<< "$2"; shift 2 ;;
    --include-repos) INCLUDE_REPOS=true; shift ;;
    -h|--help)
      echo "Usage: cleanup_worktree_deps.sh [--clean] [--dry-run] [--min-age N] [--roots A,B] [--include-repos]"
      echo "Strips node_modules, target (with Cargo.toml) and .mypy_cache from worktrees idle >= floor days."
      echo "Nested caches are stripped only beside the manifest that builds them (Cargo.toml / package.json)."
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
    || lsof_stderr_incomplete "$lsof_msg"; then
  echo "lsof output incomplete: cwd unknown, refusing."; exit 0
fi
LIVE_CWDS_RAW="$(lsof_drop_foreign_denied <<<"$LIVE_CWDS_RAW")"
if grep -qiE '\(readlink:|\(stat:|\(lstat:|permission denied' <<<"$LIVE_CWDS_RAW" \
    || grep -qE '^n[^/]' <<<"$LIVE_CWDS_RAW"; then
  echo "lsof output unparseable: cwd unknown, refusing."; exit 0
fi
LIVE_CWDS="$(sed -n 's/^n\(\/.*\)$/\1/p' <<<"$LIVE_CWDS_RAW")"
[[ -n "$LIVE_CWDS" ]] || { echo "lsof reported no cwd paths: cwd unknown, refusing."; exit 0; }

# AO-owned worktrees: parsed via ao_worktree_dirs (P = project worktreeDir, C = container/default root).
AO_DIRS=()
AO_PARENTS=()
ao_cfg="${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml}"
if [[ -e "$ao_cfg" || -L "$ao_cfg" ]]; then
  if [[ ! -f "$ao_cfg" || ! -r "$ao_cfg" ]] || ! ao_lines="$(ao_worktree_dirs "$ao_cfg" 2>/dev/null)"; then
    echo "AO config unreadable or invalid: refusing."
    exit 0
  fi
  while read -r kind d; do
    [[ -n "$d" ]] || continue
    d="${d/#\~/$HOME}"; d="${d//\$HOME/$HOME}"; d="${d%/}"
    real_d="$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "$d")"
    if [[ "$kind" == "C" ]]; then
      AO_PARENTS+=("$d")
      [[ "$real_d" != "$d" ]] && AO_PARENTS+=("$real_d")
    else
      AO_DIRS+=("$d")
      [[ "$real_d" != "$d" ]] && AO_DIRS+=("$real_d")
    fi
  done <<< "$ao_lines"
fi
is_ao_owned() {
  local wt="$1" real_wt d
  real_wt="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
  [[ "$wt" == *"ao/data/worktrees/"* || "$real_wt" == *"ao/data/worktrees/"* ]] && return 0
  for d in ${AO_DIRS[@]+"${AO_DIRS[@]}"}; do
    [[ "$wt" == "$d" || "$wt" == "$d"/* || "$real_wt" == "$d" || "$real_wt" == "$d"/* ]] && return 0
  done
  for d in ${AO_PARENTS[@]+"${AO_PARENTS[@]}"}; do
    [[ "${wt%/*}" == "$d" || "${real_wt%/*}" == "$d" ]] && return 0
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

stripped_paths="|"
strip_dir() {
  local wt="$1" dir="$2" kb
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  # A worktree can be reached twice (root rules and the nested scan); report once.
  [[ "$stripped_paths" == *"|$dir|"* ]] && return 0
  stripped_paths+="$dir|"
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

has_pkg_node_modules() {
  local wt="$1" pkg_nm pkg_ios
  [[ ! -L "$wt/packages" ]] || return 1
  for pkg_nm in "$wt"/packages/*/node_modules; do
    [[ ! -L "${pkg_nm%/node_modules}" && -e "$pkg_nm" && -f "${pkg_nm%/node_modules}/package.json" ]] && return 0
  done
  for pkg_ios in "$wt"/packages/*/ios; do
    [[ ! -L "${pkg_ios%/ios}" && ! -L "$pkg_ios" && -f "$pkg_ios/Podfile" && ( -d "$pkg_ios/Pods" || -d "$pkg_ios/build" ) ]] && return 0
  done
  return 1
}

# Build output is proven by the manifest, never by the directory name alone:
# cargo writes <crate>/target beside <crate>/Cargo.toml, npm writes
# <pkg>/node_modules beside <pkg>/package.json. Anything else keeps the name but
# is not rebuildable, so it is preserved.
is_build_output_dir() {
  local dir="$1" parent name
  name="${dir##*/}"
  parent="${dir%/*}"
  [[ -d "$dir" && ! -L "$dir" && -n "$parent" ]] || return 1
  case "$name" in
    target) [[ -f "$parent/Cargo.toml" ]] ;;
    node_modules) [[ -f "$parent/package.json" ]] ;;
    *) return 1 ;;
  esac
}

# Every target/ and node_modules/ below <wt>, at any depth. find does not follow
# symlinks and -type d rejects a symlinked leaf, so a linked parent is never
# traversed. Matched dirs are pruned, never descended into.
nested_cache_dirs() {
  find "$1" -maxdepth 4 \( -name .git -o -name venv -o -name .venv -o -name __pycache__ \
    -o -name .pytest_cache -o -name .ruff_cache -o -name .mypy_cache -o -name Pods \
    -o -name DerivedData -o -name .beads -o -name .husky -o -name .next \) -prune -o \
    -type d \( -name node_modules -o -name target \) -prune -print 2>/dev/null
}

for root in "${ROOTS[@]}"; do
  while [[ "$root" == */ && "$root" != / ]]; do root="${root%/}"; done
  [[ -d "$root" && ! -L "$root" ]] || continue
  real_root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
  for wt in "$root" "$root"/* "$root"/*/*; do
    if [[ "$INCLUDE_REPOS" == true ]]; then
      [[ ( -f "$wt/.git" || -d "$wt/.git" ) && ! -L "$wt" ]] || continue
    else
      [[ -f "$wt/.git" && ! -L "$wt" ]] || continue
    fi
    # Resolve only the configured root's aliases; no descendant may redirect us.
    real_wt="$(cd "$wt" 2>/dev/null && pwd -P)" || continue
    if [[ "$wt" == "$root" ]]; then
      [[ "$real_wt" == "$real_root" ]] || continue
    else
      [[ "$real_wt" == "${real_root%/}/${wt#"$root"/}" ]] || continue
    fi
    is_ao_owned "$wt" && continue
    # Nested build caches are only discoverable by walking; skip that walk when
    # root caches already make this worktree a candidate. Only nested caches can
    # make a worktree with no root caches a candidate at all.
    if [[ -e "$wt/node_modules" || -e "$wt/target" || -e "$wt/.mypy_cache" || -e "$wt/.pytest_cache" || -e "$wt/.ruff_cache" || -e "$wt/.next" || -e "$wt/.ci-source-packages" || ( -f "$wt/ios/Podfile" && ( -d "$wt/ios/Pods" || -d "$wt/ios/build" ) ) ]] || has_pkg_node_modules "$wt"; then
      nested_dirs=""
    else
      nested_dirs="$(nested_cache_dirs "$wt")"
      [[ -n "$nested_dirs" ]] || continue
    fi
    if worktree_is_recently_active "$wt" "$MIN_AGE_DAYS" "$now"; then continue; fi
    if is_live "$wt"; then continue; fi
    [[ -n "$nested_dirs" ]] || nested_dirs="$(nested_cache_dirs "$wt")"
    strip_dir "$wt" "$wt/node_modules"
    for pkg_nm in "$wt"/packages/*/node_modules; do
      # A real node_modules leaf may still escape through a symlinked ancestor.
      [[ ! -L "$wt/packages" && ! -L "${pkg_nm%/node_modules}" && -f "${pkg_nm%/node_modules}/package.json" ]] && strip_dir "$wt" "$pkg_nm"
    done
    for pkg_ios in "$wt"/packages/*/ios; do
      if [[ ! -L "$wt/packages" && ! -L "${pkg_ios%/ios}" && ! -L "$pkg_ios" && -f "$pkg_ios/Podfile" ]]; then
        strip_dir "$wt" "$pkg_ios/Pods"
        strip_dir "$wt" "$pkg_ios/build"
      fi
    done
    [[ -f "$wt/Cargo.toml" ]] && strip_dir "$wt" "$wt/target"
    [[ -f "$wt/package.json" ]] && strip_dir "$wt" "$wt/.next"
    [[ -d "$wt/.ci-source-packages" ]] && strip_dir "$wt" "$wt/.ci-source-packages"
    if [[ ! -L "$wt/ios" && -f "$wt/ios/Podfile" ]]; then
      strip_dir "$wt" "$wt/ios/Pods"
      strip_dir "$wt" "$wt/ios/build"
    fi
    strip_dir "$wt" "$wt/.mypy_cache"
    strip_dir "$wt" "$wt/.pytest_cache"
    strip_dir "$wt" "$wt/.ruff_cache"
    while IFS= read -r nested; do
      [[ -n "$nested" ]] && is_build_output_dir "$nested" && strip_dir "$wt" "$nested"
    done <<< "$nested_dirs"
  done
done

echo "=== Summary ==="
echo "Dirs: $count  Total: $((total_kb / 1024)) MB ($total_kb KB)"

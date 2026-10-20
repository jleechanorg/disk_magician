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
# DISK_MAGICIAN_DEPS_IDLE_MINUTES (integer >= 60) replaces the day floor for a
# worktree that is clean, whose HEAD is contained in a refs/remotes/* ref, that is
# not locked/AO-owned/live-cwd, and that was quiet for that many minutes. Then
# the same dirs plus ios/Pods, ios/build, build, android/build, android/app/build,
# .gradle, .venv, venv, .next and nested __pycache__ are stripped, each only when
# gitignored and untracked, and never when it holds secret-like files. Unset,
# non-numeric or < 60 keeps the day floor. Dirs only: the worktree, .env* and git
# state are untouched.
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
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-}"
if [[ -n "${DISK_MAGICIAN_WORKTREE_ROOTS:-}" ]]; then
  IFS=',' read -r -a ROOTS <<< "$DISK_MAGICIAN_WORKTREE_ROOTS"
else
  ROOTS=("$HOME/projects" "$HOME/.worktrees" "$HOME/project_worldaiclaw" "$HOME/wc-wt" "$HOME/projects_other")
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

IDLE_MIN=0
if [[ -n "${DISK_MAGICIAN_DEPS_IDLE_MINUTES:-}" ]]; then
  if [[ "$DISK_MAGICIAN_DEPS_IDLE_MINUTES" =~ ^[0-9]{1,7}$ && "$((10#$DISK_MAGICIAN_DEPS_IDLE_MINUTES))" -ge 60 ]]; then
    IDLE_MIN=$((10#$DISK_MAGICIAN_DEPS_IDLE_MINUTES))
  else
    echo "DISK_MAGICIAN_DEPS_IDLE_MINUTES=${DISK_MAGICIAN_DEPS_IDLE_MINUTES} ignored (need integer >= 60); day floor applies."
  fi
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "=== WORKTREE DEPS CLEANUP (DRY-RUN) — floor ${MIN_AGE_DAYS}d, idle override ${IDLE_MIN}m ==="
else
  echo "=== WORKTREE DEPS CLEANUP — floor ${MIN_AGE_DAYS}d, idle override ${IDLE_MIN}m ==="
  if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
    echo "Refusing to delete: set WORKTREE_APPROVED=1."
    exit 0
  fi
fi

# Live-cwd evidence must be complete; otherwise refuse to delete anything. The
# shared strict parser is the only place that interprets lsof output.
if ! lsof_snapshot_cwds; then
  echo "lsof output incomplete ($LSOF_CWD_REASON): cwd unknown, refusing."; exit 0
fi
LIVE_CWDS="$LSOF_CWDS"

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

# Idle-override extras beyond the day-floor set (which keeps its own manifest rules).
IDLE_EXTRA_RELS=(ios/Pods ios/build build android/build android/app/build .gradle .venv venv .next)

# idle_override_eligible <wt>: quiet for IDLE_MIN minutes, not locked, HEAD on a
# remote ref, clean tree. Any unknown fails closed.
idle_override_eligible() {
  local wt="$1" admin st
  worktree_is_recently_active_minutes "$wt" "$IDLE_MIN" && return 1
  admin="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)" || return 1
  [[ "$admin" == /* ]] || admin="$wt/$admin"
  [[ -e "$admin/locked" ]] && return 1
  [[ -n "$(git -C "$wt" for-each-ref --count=1 --contains HEAD refs/remotes/ 2>/dev/null)" ]] || return 1
  st="$(git --no-optional-locks -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null)" || return 1
  [[ -z "$st" ]]
}

# Extra dirs present in <wt>; find never follows symlinks.
idle_candidate_dirs() {
  local wt="$1" rel
  for rel in "${IDLE_EXTRA_RELS[@]}"; do
    [[ -d "$wt/$rel" && ! -L "$wt/$rel" ]] && echo "$wt/$rel"
  done
  find "$wt" \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name Pods -o -name build \) -prune -o \
    -type d -name __pycache__ -prune -print 2>/dev/null
}

# idle_dir_ok <wt> <dir>: override-mode guard for one dir.
idle_dir_ok() {
  local wt="$1" dir="$2" rel part acc hit real_wt real_dir
  rel="${dir#"$wt"/}"
  [[ "$rel" != "$dir" && "$rel" != /* && "$rel" != *..* ]] || return 1
  acc="$wt"
  while [[ -n "$rel" ]]; do
    part="${rel%%/*}"; acc="$acc/$part"
    [[ ! -L "$acc" ]] || { echo "  IDLE-SKIP $dir (symlinked path component)"; return 1; }
    [[ "$rel" == */* ]] && rel="${rel#*/}" || rel=""
  done
  rel="${dir#"$wt"/}"
  real_wt="$(cd "$wt" && pwd -P)"; real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$real_dir" == "$real_wt"/* ]] || { echo "  IDLE-SKIP $dir (outside worktree)"; return 1; }
  git -C "$wt" check-ignore -q -- "$rel" 2>/dev/null || { echo "  IDLE-SKIP $dir (not gitignored)"; return 1; }
  [[ -z "$(git -C "$wt" ls-files -- "$rel" 2>/dev/null)" ]] || { echo "  IDLE-SKIP $dir (tracked files)"; return 1; }
  hit="$(find "$dir" \( -name '.env*' -o -name '.xcode.env.local' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
    -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' -o -name 'id_dsa*' -o -name '.npmrc' -o -name '.netrc' \
    -o -iname '*credentials*' -o -iname 'secrets*' \) -print -quit 2>/dev/null)"
  [[ -z "$hit" ]] || { echo "  SECRET-SKIP $dir (holds $hit)"; return 1; }
  return 0
}

stripped_paths="|"
strip_dir() {
  local wt="$1" dir="$2" kb
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  # A worktree can be reached twice (root rules and the nested scan); report once.
  [[ "$stripped_paths" == *"|$dir|"* ]] && return 0
  stripped_paths+="$dir|"
  if [[ "$mode" == idle ]]; then idle_dir_ok "$wt" "$dir" || return 0; fi
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
  local wt="$1" pkg_nm
  [[ ! -L "$wt/packages" ]] || return 1
  for pkg_nm in "$wt"/packages/*/node_modules; do
    [[ ! -L "${pkg_nm%/node_modules}" && -e "$pkg_nm" && -f "${pkg_nm%/node_modules}/package.json" ]] && return 0
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
  find "$1" \( -name .git -o -name venv -o -name .venv -o -name __pycache__ \
    -o -name .pytest_cache -o -name .ruff_cache \) -prune -o \
    -type d \( -name node_modules -o -name target \) -prune -print 2>/dev/null
}

for root in "${ROOTS[@]}"; do
  while [[ "$root" == */ && "$root" != / ]]; do root="${root%/}"; done
  [[ -d "$root" && ! -L "$root" ]] || continue
  real_root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
  for wt in "$root"/* "$root"/*/*; do
    [[ -f "$wt/.git" && ! -L "$wt" ]] || continue
    # Resolve only the configured root's aliases; no descendant may redirect us.
    real_wt="$(cd "$wt" 2>/dev/null && pwd -P)" || continue
    [[ "$real_wt" == "${real_root%/}/${wt#"$root"/}" ]] || continue
    is_ao_owned "$wt" && continue
    # Nested build caches are only discoverable by walking; skip that walk when
    # root caches already make this worktree a candidate. Only nested caches can
    # make a worktree with no root caches a candidate at all.
    has_day_caches=1
    if [[ -e "$wt/node_modules" || -e "$wt/target" || -e "$wt/.mypy_cache" ]] || has_pkg_node_modules "$wt"; then
      nested_dirs=""
    else
      nested_dirs="$(nested_cache_dirs "$wt")"
      [[ -n "$nested_dirs" ]] || has_day_caches=0
    fi
    idle_dirs=""
    [[ "$IDLE_MIN" -gt 0 ]] && idle_dirs="$(idle_candidate_dirs "$wt")"
    [[ "$has_day_caches" -eq 1 || -n "$idle_dirs" ]] || continue
    mode=""
    if [[ "$IDLE_MIN" -gt 0 ]] && idle_override_eligible "$wt"; then
      mode=idle
    elif [[ "$has_day_caches" -eq 1 ]] && ! worktree_is_recently_active "$wt" "$MIN_AGE_DAYS" "$now"; then
      mode=day
    else
      continue
    fi
    if is_live "$wt"; then continue; fi
    [[ -n "$nested_dirs" ]] || nested_dirs="$(nested_cache_dirs "$wt")"
    strip_dir "$wt" "$wt/node_modules"
    for pkg_nm in "$wt"/packages/*/node_modules; do
      # A real node_modules leaf may still escape through a symlinked ancestor.
      [[ ! -L "$wt/packages" && ! -L "${pkg_nm%/node_modules}" && -f "${pkg_nm%/node_modules}/package.json" ]] && strip_dir "$wt" "$pkg_nm"
    done
    [[ -f "$wt/Cargo.toml" ]] && strip_dir "$wt" "$wt/target"
    strip_dir "$wt" "$wt/.mypy_cache"
    while IFS= read -r nested; do
      [[ -n "$nested" ]] && is_build_output_dir "$nested" && strip_dir "$wt" "$nested"
    done <<< "$nested_dirs"
    if [[ "$mode" == idle ]]; then
      while IFS= read -r nested; do
        [[ -n "$nested" ]] && strip_dir "$wt" "$nested"
      done <<< "$idle_dirs"
    fi
  done
done

echo "=== Summary ==="
echo "Dirs: $count  Total: $((total_kb / 1024)) MB ($total_kb KB)"

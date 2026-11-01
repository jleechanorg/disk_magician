#!/usr/bin/env bash
# slim_worktree_checkouts.sh — shrink dormant linked worktrees without touching
# git history, by excluding heavy tracked directories from the checkout with
# git sparse-checkout.
#
# WHY
# ---
# worldarchitect.ai carries 156.8 MB of tracked docs per checkout (91.9 MB of
# it docs/user-stories-ui: 134 PNG screenshots), so each of 289 worktrees pays
# ~162 MiB for documentation nobody reopened. Measured on jeff-ubuntu
# 2026-10-22: excluding docs/ reclaims 46.8 GiB across the tree, 39% of the
# 119.5 GiB worktree total. Nothing is deleted from git — `git sparse-checkout
# disable` (or `git checkout -- docs`) restores the files.
#
# SAFETY
# ------
#   * Activated worktrees are never touched: the canonical recency helper
#     (lib/worktree_recency.sh) must report the worktree inactive for --min-age
#     days (default 3, the repo's worktree floor).
#   * Live-cwd and safety_gate-protected worktrees are skipped.
#   * A worktree with local modifications under an excluded path is skipped —
#     excluding it would hide uncommitted work.
#   * Defaults to dry-run. --clean also requires WORKTREE_APPROVED=1.
#   * Sparse-checkout is written per worktree (extensions.worktreeConfig), so
#     one worktree's exclusion never leaks to its siblings or the main repo.
#
# USAGE
#   slim_worktree_checkouts.sh [--clean] [--dry-run] [--min-age N]
#                              [--roots A,B] [--exclude docs,evidence]
#                              [--include-ao]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=lib/ao_worktree_config.sh
source "$SCRIPT_DIR/lib/ao_worktree_config.sh" 2>/dev/null || true

DRY_RUN=true
MIN_AGE_DAYS="${SLIM_MIN_AGE_DAYS:-3}"
EXCLUDE="docs"
INCLUDE_AO=0
ROOTS=("$HOME/.worktrees" "$HOME/projects" "$HOME/.ao/data/worktrees")

usage() { echo "Usage: $(basename "$0") [--clean] [--dry-run] [--min-age N] [--roots A,B] [--exclude docs,evidence] [--include-ao]"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --min-age) MIN_AGE_DAYS="$2"; shift 2 ;;
    --roots) IFS=',' read -r -a ROOTS <<< "$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --include-ao) INCLUDE_AO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || { echo "min-age must be an integer" >&2; exit 2; }
IFS=',' read -r -a EXCLUDES <<< "$EXCLUDE"

if [[ "$DRY_RUN" == false && "${WORKTREE_APPROVED:-0}" != "1" ]]; then
  echo "Refusing to slim: set WORKTREE_APPROVED=1." >&2
  exit 1
fi

# Live-cwd evidence: a worktree a shell or agent is sitting in must not lose
# files under its own feet. /proc is authoritative on Linux; sysctl/lsof is the
# macOS path used by the rest of this repo.
live_cwds() {
  if [[ -d /proc ]]; then
    for p in /proc/[0-9]*/cwd; do
      readlink "$p" 2>/dev/null || true
    done
  else
    lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
  fi
}
LIVE_CWDS="$(live_cwds)"

is_live() {
  local wt="$1" c
  while IFS= read -r c; do
    [[ -n "$c" && ( "$c" == "$wt" || "$c" == "$wt"/* ) ]] && return 0
  done <<< "$LIVE_CWDS"
  return 1
}

is_ao_owned() {
  local wt="$1" d real_wt
  # The live AO worktree roots are <container>/.ao/data/worktrees/<project>/<wt>;
  # the leading dot matters, so match the exact component, not "/ao/..." (a
  # wrong pattern here silently slimmed live AO agent checkouts in a dry run on
  # 2026-10-22).
  real_wt="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
  case "$wt$real_wt" in
    */.ao/data/worktrees/*|*/ao/data/worktrees/*) return 0 ;;
  esac
  # Also honour worktreeDir entries from the AO config when it is readable.
  local cfg="${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml}"
  if [[ -r "$cfg" ]] && command -v ao_worktree_dirs >/dev/null 2>&1; then
    while read -r _kind d; do
      [[ -n "$d" ]] || continue
      d="${d/#\~/$HOME}"; d="${d//\$HOME/$HOME}"; d="${d%/}"
      if [[ "$_kind" == "C" ]]; then
        [[ "${wt%/*}" == "$d" || "${real_wt%/*}" == "$d" ]] && return 0
      else
        [[ "$wt" == "$d" || "$wt" == "$d"/* || "$real_wt" == "$d" || "$real_wt" == "$d"/* ]] && return 0
      fi
    done < <(ao_worktree_dirs "$cfg" 2>/dev/null)
  fi
  return 1
}

gitdir_of() { git -C "$1" rev-parse --git-dir 2>/dev/null; }
is_sparse() { local d; d="$(gitdir_of "$1")"; [[ -n "$d" && -f "$d/info/sparse-checkout" ]]; }

now="$(date +%s)"
total_kb=0
count=0
skipped_recent=0
skipped_live=0
skipped_ao=0
skipped_dirty=0
skipped_sparse=0
skipped_safety=0
seen="|"

mode="DRY-RUN"; [[ "$DRY_RUN" == false ]] && mode="APPLY"
echo "=== WORKTREE CHECKOUT SLIM ($mode) — floor ${MIN_AGE_DAYS}d, exclude=${EXCLUDE} ==="

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  for wt in "$root"/* "$root"/*/*; do
    [[ -f "$wt/.git" && ! -L "$wt" ]] || continue
    [[ "$seen" == *"|$wt|"* ]] && continue
    seen+="$wt|"

    if [[ "$INCLUDE_AO" != 1 ]] && is_ao_owned "$wt"; then skipped_ao=$((skipped_ao+1)); continue; fi
    if is_sparse "$wt"; then skipped_sparse=$((skipped_sparse+1)); continue; fi
    if worktree_is_recently_active "$wt" "$MIN_AGE_DAYS" "$now"; then skipped_recent=$((skipped_recent+1)); continue; fi
    if is_live "$wt"; then skipped_live=$((skipped_live+1)); continue; fi
    if ! _reason="$(safety_gate "$wt" 2>/dev/null)"; then skipped_safety=$((skipped_safety+1)); echo "  SAFETY-SKIP $wt ($_reason)"; continue; fi

    # Any locally modified file under an excluded path means the exclusion would
    # hide uncommitted work. Untracked files are unaffected by sparse-checkout.
    dirty_hit=""
    for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
      if git -C "$wt" status --porcelain --untracked-files=no -- "$ex" 2>/dev/null | grep -q .; then
        dirty_hit="$ex"
        break
      fi
    done
    if [[ -n "$dirty_hit" ]]; then skipped_dirty=$((skipped_dirty+1)); echo "  DIRTY-SKIP $wt (local changes under $dirty_hit)"; continue; fi

    kb=0
    for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
      e=$(du -sk "$wt/$ex" 2>/dev/null | awk '{print $1}')
      [[ "$e" =~ ^[0-9]+$ ]] && kb=$((kb + e))
    done
    [[ "$kb" -gt 0 ]] || continue

    if [[ "$DRY_RUN" == true ]]; then
      echo "  WOULD-SLIM ${kb}KB $wt"
    else
      patterns=("/*")
      for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do patterns+=("!/$ex/"); done
      if git -C "$wt" sparse-checkout set --no-cone "${patterns[@]}" >/dev/null 2>&1; then
        echo "  SLIMMED    ${kb}KB $wt"
        deletion_log "$(basename "$0")" slim "$kb" "$wt"
      else
        echo "  FAILED     $wt"; continue
      fi
    fi
    total_kb=$((total_kb + kb))
    count=$((count + 1))
  done
done

echo "=== Summary ==="
echo "  Worktrees slimmed:      $count"
echo "  Reclaimable/Reclaimed:  $((total_kb / 1024)) MB ($total_kb KB)"
echo "  Skipped (too young):    $skipped_recent"
echo "  Skipped (live cwd):     $skipped_live"
echo "  Skipped (ao-owned):     $skipped_ao"
echo "  Skipped (already sparse): $skipped_sparse"
echo "  Skipped (local changes): $skipped_dirty"
echo "  Skipped (safety gate):  $skipped_safety"
if [[ "$DRY_RUN" == true ]]; then
  echo "  DRY-RUN: re-run with WORKTREE_APPROVED=1 $(basename "$0") --clean to apply"
fi

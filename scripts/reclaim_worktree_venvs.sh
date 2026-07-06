#!/bin/bash
# reclaim_worktree_venvs.sh — Convert worldarchitect.ai worktree venvs from
# duplicate directories to symlinks pointing to the main checkout's venv.
# Per PR #7522 (jleechanorg/worldarchitect.ai#7522, merged 2026-06-13).
#
# Background: each worldarchitect.ai git worktree was creating its own
# 700 MB Python venv, wasting ~18 GB across the 25 worktrees that have
# one. PR #7522 makes fresh worktrees symlink to the main venv, but
# existing worktrees keep their real venvs until setup-dev-env.sh is
# re-run. This script walks those existing worktrees and converts them.
#
# Usage:
#   ./reclaim_worktree_venvs.sh           # dry-run by default
#   DRY_RUN=0 ./reclaim_worktree_venvs.sh # actually convert
#
# Honors escape hatches (set on a worktree to skip it):
#   VENV_NO_SYMLINK=1   — skip this worktree
#   GITHUB_ACTIONS=true — skip this worktree
#
# What it does per worktree (matches setup_venv() in venv_utils.sh):
#   1. Detect if cwd is a linked git worktree (not main checkout)
#   2. Resolve main project root
#   3. Validate main checkout has a working venv
#   4. rm -rf worktree/venv (the duplicate)
#   5. ln -sfn main/venv worktree/venv (create symlink)

set -uo pipefail

DRY_RUN="${DRY_RUN:-1}"
MAIN_CHECKOUT="${WORLDARCHITECT_MAIN:-$HOME/projects/worldarchitect.ai}"
MIN_VENV_MB="${MIN_VENV_MB:-50}"
ROOTS=(
  "$HOME/projects"
  "$HOME/.worktrees"
  "$HOME/worktrees"
  "$HOME/projects_other"
)

if [ ! -d "$MAIN_CHECKOUT" ]; then
  echo "ERROR: main checkout not found at $MAIN_CHECKOUT" >&2
  echo "Set WORLDARCHITECT_MAIN to the correct path." >&2
  exit 1
fi

if [ ! -d "$MAIN_CHECKOUT/venv" ]; then
  echo "ERROR: $MAIN_CHECKOUT/venv does not exist." >&2
  echo "Create the main venv first (e.g. cd $MAIN_CHECKOUT && scripts/setup-dev-env.sh)" >&2
  exit 1
fi

# Source venv_utils.sh for validate_existing_venv + is_git_worktree + get_git_main_project_root
# shellcheck disable=SC1091
source "$MAIN_CHECKOUT/scripts/venv_utils.sh"

# Counters
total_scanned=0
already_symlinks=0
already_symlinks_bytes=0
would_convert=0
would_convert_bytes=0
skipped_main_invalid=0
skipped_too_small=0
skipped_no_venv=0
skipped_escape=0
skipped_not_worktree=0
converted=0
converted_bytes=0
failed=0

for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r -d '' wt; do
    [ -d "$wt" ] || continue
    [ "$wt" = "$MAIN_CHECKOUT" ] && continue
    total_scanned=$((total_scanned + 1))

    venv="$wt/venv"

    # Already a symlink → counted, skipped
    if [ -L "$venv" ]; then
      target_kb=$(du -sk "$venv" 2>/dev/null | awk '{print $1}')
      already_symlinks=$((already_symlinks + 1))
      already_symlinks_bytes=$((already_symlinks_bytes + target_kb))
      continue
    fi

    # No venv dir at all
    if [ ! -d "$venv" ]; then
      skipped_no_venv=$((skipped_no_venv + 1))
      continue
    fi

    # Escape hatch
    if [ -n "${VENV_NO_SYMLINK:-}" ]; then
      skipped_escape=$((skipped_escape + 1))
      continue
    fi

    # Is this actually a worktree?
    if ! (cd "$wt" && is_git_worktree 2>/dev/null); then
      skipped_not_worktree=$((skipped_not_worktree + 1))
      continue
    fi

    # Check venv size
    size_kb=$(du -sk "$venv" 2>/dev/null | awk '{print $1}')
    size_mb=$((size_kb / 1024))
    if [ "$size_mb" -lt "$MIN_VENV_MB" ]; then
      skipped_too_small=$((skipped_too_small + 1))
      continue
    fi

    # Get the main project root from this worktree
    main_root=$(cd "$wt" && get_git_main_project_root 2>/dev/null || echo "")
    main_venv="$main_root/venv"

    # Validate main venv (must be 3.10-3.12, have pip)
    if [ -z "$main_root" ] || ! validate_existing_venv "$main_venv" 2>/dev/null; then
      skipped_main_invalid=$((skipped_main_invalid + 1))
      echo "  SKIP (main venv invalid at $main_venv): $wt"
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "  WOULD CONVERT: $wt (${size_mb} MB → symlink to $main_venv)"
      would_convert=$((would_convert + 1))
      would_convert_bytes=$((would_convert_bytes + size_kb))
    else
      # Match the repo safety convention used by symlink-shared-venvs.sh:
      # rename to .bak.<timestamp> instead of rm -rf, so a bad conversion
      # is always reversible.
      bak="${venv}.bak.$(date +%Y%m%d-%H%M%S)"
      if mv "$venv" "$bak" 2>/dev/null && ln -sfn "$main_venv" "$venv" 2>/dev/null; then
        echo "  CONVERTED: $wt (${size_mb} MB → symlink, backup: $bak)"
        converted=$((converted + 1))
        converted_bytes=$((converted_bytes + size_kb))
      else
        echo "  FAILED: $wt"
        failed=$((failed + 1))
      fi
    fi
  done < <(find "$root" -maxdepth 2 -type d \( -name "worktree_*" -o -name "wt-*" \) -print0 2>/dev/null)
done

echo
echo "=== Summary ==="
echo "Worktrees scanned:       $total_scanned"
echo "Already symlinks:         $already_symlinks ($((already_symlinks_bytes / 1024)) MB shared)"
echo "No venv dir:              $skipped_no_venv"
echo "Not a worktree:           $skipped_not_worktree"
echo "Too small (<${MIN_VENV_MB}MB):     $skipped_too_small"
echo "Main venv invalid:        $skipped_main_invalid"
echo "Escape hatch set:         $skipped_escape"
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY-RUN] Would convert:  $would_convert ($((would_convert_bytes / 1024)) MB would be reclaimed)"
  echo "Re-run with DRY_RUN=0 to apply."
else
  echo "Converted:                $converted ($((converted_bytes / 1024)) MB reclaimed)"
  echo "Failed:                   $failed"
fi

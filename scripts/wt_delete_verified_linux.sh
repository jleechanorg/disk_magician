#!/bin/bash
# Remove worktrees from a HAND-VERIFIED "likely-safe" list (>7d, clean, HEAD
# contained in a remote ref, unlocked, no live cwd).
#
# ALWAYS use `git worktree remove`, never `rm -rf`, for a LINKED worktree:
# plain removal leaves stale entries in the main repo's .git/worktrees/ admin
# directory, which later makes `git worktree list` lie about what exists.
#
# A worktree whose git admin dir is GONE (main checkout lived under /tmp and
# was cleaned) cannot be handled by `git worktree remove` at all; those fall
# back to directory removal after chmod u+w, because there is no object store
# left to consult and nothing left to push.
#
# Safety: refuses unless WT_DELETE_APPROVED=1, and re-verifies every property
# per path immediately before acting (a stale list must not become a licence).
set -uo pipefail

LIST="${1:-}"
[[ "${WT_DELETE_APPROVED:-0}" == "1" ]] || { echo "Refusing: set WT_DELETE_APPROVED=1" >&2; exit 2; }
[[ -n "$LIST" && -f "$LIST" ]] || { echo "usage: $0 <list-file>  (TSV: gib<TAB>relative-worktree-path)" >&2; exit 2; }

WT_ROOT="${WORKTREE_ROOT:-$HOME/.worktrees}"
PSDUMP="$(mktemp "${TMPDIR:-/tmp}/wtd.XXXXXX")" || exit 1
ps -Ao pid,command > "$PSDUMP" 2>/dev/null || true

ok=0; skip=0; fail=0; kb_total=0

while IFS=$'\t' read -r _gib rel; do
  [[ -n "${rel:-}" ]] || continue
  wt="$WT_ROOT/$rel"
  [[ -d "$wt" ]] || { echo "SKIP not-a-dir: $rel"; skip=$((skip+1)); continue; }
  [[ -L "$wt" ]] && { echo "SKIP symlink: $rel"; skip=$((skip+1)); continue; }

  kb=$(du -x -P -sk "$wt" 2>/dev/null | awk '{print $1}')
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0

  if timeout 30 git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
    # Linked (or standalone) repo: re-verify the safety properties.
    dirty=$(GIT_OPTIONAL_LOCKS=0 timeout 60 git -C "$wt" status --porcelain 2>/dev/null | wc -l)
    dirty=${dirty//[!0-9]/}
    [[ "$dirty" == "0" ]] || { echo "SKIP dirty=$dirty: $rel"; skip=$((skip+1)); continue; }

    if [[ -z "$(timeout 30 git -C "$wt" for-each-ref --count=1 --contains HEAD refs/remotes 2>/dev/null)" ]]; then
      echo "SKIP head-not-on-remote: $rel"; skip=$((skip+1)); continue
    fi

    gd=$(timeout 30 git -C "$wt" rev-parse --git-dir 2>/dev/null)
    case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
    [[ -f "$gd/locked" ]] && { echo "SKIP locked: $rel"; skip=$((skip+1)); continue; }

    grep -Fq -- "$wt" "$PSDUMP" 2>/dev/null && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }

    main_repo=$(timeout 30 git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    main_repo="${main_repo%/.git}"
    if timeout 300 git -C "${main_repo:-$wt}" worktree remove "$wt" 2>/dev/null && [[ ! -e "$wt" ]]; then
      ok=$((ok+1)); kb_total=$((kb_total+kb))
      printf 'REMOVED(lw)     %6.2f GiB  %s\n' "$(awk -v k="$kb" 'BEGIN{print k/1048576}')" "$rel"
    else
      echo "FAILED(lw): $rel"; fail=$((fail+1))
    fi
  else
    # Orphaned: admin dir gone, so this is just a directory now.
    grep -Fq -- "$wt" "$PSDUMP" 2>/dev/null && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
    find "$wt" -type d -exec chmod u+w {} + 2>/dev/null || true
    if rm -rf -- "$wt" 2>/dev/null && [[ ! -e "$wt" ]]; then
      ok=$((ok+1)); kb_total=$((kb_total+kb))
      printf 'REMOVED(orphan) %6.2f GiB  %s\n' "$(awk -v k="$kb" 'BEGIN{print k/1048576}')" "$rel"
    else
      echo "FAILED(orphan): $rel"; fail=$((fail+1))
    fi
  fi
done < "$LIST"

rm -f "$PSDUMP" 2>/dev/null || true
printf '\n=== removed=%d (%.2f GiB) skipped=%d failed=%d ===\n' \
  "$ok" "$(awk -v k=$kb_total 'BEGIN{print k/1048576}')" "$skip" "$fail"
(( fail == 0 )) || exit 1
exit 0

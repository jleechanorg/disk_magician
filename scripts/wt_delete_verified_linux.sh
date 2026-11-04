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

# in_live_use <path> -- rc 0 when a live process actually holds this path.
#
# A one-time `ps` command-line snapshot is NOT sufficient: a shell's argv keeps
# the cwd it was launched from, so `cd`-ing into a directory never appears in
# argv at all, and a process that started after the snapshot is invisible. That
# is exactly how active work gets deleted. Check the real cwd via lsof (macOS)
# or /proc/*/cwd (Linux), and treat argv as an extra signal only.
in_live_use() {
  local p=$1 pid cwd
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -F n 2>/dev/null | grep -Fq -- "$p" && return 0
  fi
  if [[ -d /proc ]]; then
    for pid in /proc/[0-9]*; do
      cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
      case "$cwd" in "$p"|"$p"/*) return 0 ;; esac
    done
  fi
  grep -Fq -- "$p" "$PSDUMP" 2>/dev/null && return 0
  return 1
}

ok=0; skip=0; fail=0; kb_total=0

while IFS=$'\t' read -r _gib rel; do
  [[ -n "${rel:-}" ]] || continue

  # Validate the relative path BEFORE concatenation. An unchecked `rel` can
  # contain `..` segments, an absolute path, or a leading dash, any of which
  # escapes $WT_ROOT and turns a worktree cleanup into an arbitrary recursive
  # delete. Reject rather than normalise: a list that needs repairing should be
  # repaired, not silently reinterpreted.
  case "$rel" in
    /*|*..*|-*) echo "SKIP unsafe-relpath: $rel"; skip=$((skip+1)); continue ;;
  esac
  wt="$WT_ROOT/$rel"

  # Containment check on the resolved parent: the worktree directory itself may
  # be a symlink target, so compare the realpath of its containing directory.
  real_parent=$(cd "$WT_ROOT/$(dirname "$rel")" 2>/dev/null && pwd -P) || {
    echo "SKIP unresolvable-parent: $rel"; skip=$((skip+1)); continue; }
  case "$real_parent" in
    "$WT_ROOT"|"$WT_ROOT"/*) ;;
    *) echo "SKIP escapes-root: $rel"; skip=$((skip+1)); continue ;;
  esac

  [[ -d "$wt" ]] || { echo "SKIP not-a-dir: $rel"; skip=$((skip+1)); continue; }
  [[ -L "$wt" ]] && { echo "SKIP symlink: $rel"; skip=$((skip+1)); continue; }

  kb=$(du -x -P -sk "$wt" 2>/dev/null | awk '{print $1}')
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0

  # THREE-way probe, not two. A failed/timed-out `rev-parse` is UNKNOWN, and
  # unknown must preserve -- treating it as "orphaned" is a fail-open delete of
  # an arbitrary directory whenever git is merely slow, locked, or the timeout
  # fires. Only a probe that positively reports "not a git repository" may
  # qualify for the orphan path.
  probe_err="$(timeout 30 git -C "$wt" rev-parse HEAD 2>&1 >/dev/null)"
  probe_rc=$?

  if (( probe_rc == 0 )); then
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

    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }

    main_repo=$(timeout 30 git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    main_repo="${main_repo%/.git}"
    if timeout 300 git -C "${main_repo:-$wt}" worktree remove "$wt" 2>/dev/null && [[ ! -e "$wt" ]]; then
      ok=$((ok+1)); kb_total=$((kb_total+kb))
      printf 'REMOVED(lw)     %6.2f GiB  %s\n' "$(awk -v k="$kb" 'BEGIN{print k/1048576}')" "$rel"
    else
      echo "FAILED(lw): $rel"; fail=$((fail+1))
    fi
  else
    # Orphaned path is allowed ONLY on git's own positive "not a repository"
    # verdict. Any other failure (timeout/rc 124, permission, lock, corrupt
    # object store) is unknown and therefore preserved.
    if (( probe_rc != 128 )) || ! grep -qiE 'not a git repository|not a work tree' <<<"$probe_err"; then
      echo "SKIP unverified-git-state (rc=$probe_rc): $rel"
      skip=$((skip+1))
      continue
    fi
    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
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

#!/bin/bash
# Read-only worktree residency check (Linux / Jeff-Ubuntu, and macOS).
#
# Enumerates every real git worktree under ~/.worktrees and reports:
#   age_days (canonical content-mtime recency), size, dirty count, remotes,
#   whether HEAD is contained in a remote ref, locked state, live-cwd state.
#
# WHY THIS EXISTS
# ---------------
# A first pass at "how many worktrees are older than 7 days?" counted the
# CONTAINER directories one level up (`~/.worktrees/worldarchitect.ai/`), not
# the worktrees inside them, and reported "33 >7d". The real answer on that
# host was 154 of 597. Real worktrees are `.git` children at depth <= 3.
#
# Age comes from the canonical scripts/lib/worktree_recency.sh helper, never
# `stat .git` (creation age) and never `stat <dir>` (top-level mtime only) --
# both are measured-wrong proxies documented in that file.
#
# Read-only: no deletion, no move, no git write. `git status` runs with
# GIT_OPTIONAL_LOCKS=0 so it cannot refresh the index and perturb the very
# recency signal this script reports.
set -uo pipefail

REC="${DISK_MAGICIAN_RECENCY_LIB:-}"
if [[ -z "$REC" ]]; then
  for cand in \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.13/site-packages/disk_magician/scripts/lib/worktree_recency.sh" \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.12/site-packages/disk_magician/scripts/lib/worktree_recency.sh"
  do
    [[ -f "$cand" ]] && { REC="$cand"; break; }
  done
fi
[[ -f "$REC" ]] || { echo "FATAL: canonical worktree_recency.sh not found (set DISK_MAGICIAN_RECENCY_LIB)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$REC"

# bounded <seconds> <cmd...> -- cap the wall clock when `timeout` exists, else
# run the command alone. `timeout` is coreutils and absent from base images; an
# unguarded call exits 127, and this probe then reports a healthy worktree as
# dirty=0 / onremote=noborn -- a WRONG ANSWER rather than a missing one, which
# is worse than failing because it feeds the cleanup assessment directly.
if command -v timeout >/dev/null 2>&1; then
  bounded() { timeout "$@"; }
else
  bounded() { local _secs=$1; shift; "$@"; }
fi

ROOT="${WORKTREE_ROOT:-$HOME/.worktrees}"
[[ -d "$ROOT" ]] || { echo "FATAL: worktree root not found: $ROOT" >&2; exit 1; }

LIVE="$(mktemp "${TMPDIR:-/tmp}/wt-live.XXXXXX")" || exit 1
ps -Ao pid,command > "$LIVE" 2>/dev/null || true

printf '%-4s %-8s %-6s %-6s %-7s %-7s %-7s %-5s %s\n' \
  AGE GiB DIRTY REMOTES ONREMOTE LOCKED LIVECWD GITS PATH

while IFS= read -r wt; do
  [[ -n "$wt" ]] || continue
  name="${wt#"$ROOT"/}"

  age="$(worktree_age_days "$wt" 2>/dev/null)" || age="?"
  [[ "$age" =~ ^[0-9]+$ ]] || age="?"

  kb="$(du -x -P -sk "$wt" 2>/dev/null | awk '{print $1}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  gib="$(awk -v k="$kb" 'BEGIN{printf "%.2f", k/1048576}')"

  dirty="$(GIT_OPTIONAL_LOCKS=0 bounded 60 git -C "$wt" status --porcelain 2>/dev/null | wc -l)"
  dirty="${dirty//[!0-9]/}"; [[ -n "$dirty" ]] || dirty="?"

  nrem="$(bounded 30 git -C "$wt" remote 2>/dev/null | wc -l)"
  nrem="${nrem//[!0-9]/}"

  # "noborn" is a distinct state from "not on a remote": it means the git admin
  # directory is GONE (e.g. the main checkout lived under /tmp and was cleaned).
  # Those worktrees cannot be pushed from at all and are safe to reclaim as
  # plain directories -- but they must not be confused with "commits on no
  # remote", which is a real push-before-delete case.
  onremote="no"
  if bounded 30 git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
    if [[ -n "$(bounded 30 git -C "$wt" for-each-ref --count=1 --contains HEAD refs/remotes 2>/dev/null)" ]]; then
      onremote="yes"
    fi
  else
    onremote="noborn"
  fi

  locked="no"
  if bounded 30 git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    gd="$(bounded 30 git -C "$wt" rev-parse --git-dir 2>/dev/null)"
    case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
    [[ -f "$gd/locked" ]] && locked="yes"
  fi

  # Assign both normal match outcomes explicitly.
  if grep -Fq -- "$wt" "$LIVE" 2>/dev/null; then
    livecwd="YES"
  else
    livecwd="no"
  fi

  ngits="$(find "$wt" -xdev -maxdepth 3 -type d -name .git 2>/dev/null | wc -l)"
  ngits="${ngits//[!0-9]/}"

  printf '%-4s %-8s %-6s %-6s %-7s %-7s %-7s %-5s %s\n' \
    "$age" "$gib" "$dirty" "$nrem" "$onremote" "$locked" "$livecwd" "$ngits" "$name"
done < <(
  find "$ROOT" -xdev -maxdepth 3 \( -type d -o -type f \) -name .git -print 2>/dev/null |
    sed 's#/\.git$##' | sort -u
)

rm -f "$LIVE" 2>/dev/null || true

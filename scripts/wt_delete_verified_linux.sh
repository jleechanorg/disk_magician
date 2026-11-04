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

# in_live_use <path> -- rc 0 when a live process MAY hold this path.
#
# FAIL-CLOSED and PIPEFAIL-SAFE by construction:
#  * `producer | grep -q` is unusable under `set -o pipefail`: grep exits on the
#    first match, the producer takes SIGPIPE, and the PIPELINE reports 141 --
#    a real match reads as "not live". Measured 2026-11-04:
#      producer | grep -Fq match   ->  rc=141
#    Capture the output first, then match on the string, never on the pipe.
#  * If lsof exists but fails/times out, that is UNKNOWN, not "not live". Any
#    uncertainty returns 0 (treat as live) so the candidate is preserved.
in_live_use() {
  local p=$1 pid cwd listing
  if command -v lsof >/dev/null 2>&1; then
    if listing="$(timeout 60 lsof -nP -F n 2>/dev/null)"; then
      case "$listing" in *"$p"*) return 0 ;; esac
    else
      return 0
    fi
  fi
  if [[ -d /proc ]]; then
    for pid in /proc/[0-9]*; do
      cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
      case "$cwd" in "$p"|"$p"/*) return 0 ;; esac
    done
  fi
  # Refresh the command-line probe PER CANDIDATE, immediately before deletion.
  # The one-time snapshot taken at startup cannot see a process that started
  # afterwards, and a process may hold the path in argv while its cwd and open
  # descriptors live elsewhere. Ignoring a failed capture is also fail-open.
  local fresh
  if ! fresh="$(timeout 30 ps -Ao pid,command 2>/dev/null)"; then
    return 0   # probe unavailable -> preserve
  fi
  [[ -n "$fresh" ]] || return 0
  case "$fresh" in *"$p"*) return 0 ;; esac
  return 1
}

# reverify_gates <wt> <rel> -- rc 0 only when the candidate STILL satisfies the
# same recency and machine-local protection gates it satisfied when the list was
# produced. A list is a snapshot of past judgement; between snapshot and action
# the checkout can become recent (someone resumed work) or protected (a
# safety.local.json rule added it to never_delete / needs_decision). Re-checking
# is the difference between acting on verified state and acting on a stale note.
reverify_gates() {
  local wt=$1 rel=$2 min_days age newest
  min_days="${WT_MIN_AGE_DAYS:-7}"

  # 1) recency: newest content mtime, via the canonical helper when available.
  if [[ -n "${DISK_MAGICIAN_RECENCY_LIB:-}" && -f "${DISK_MAGICIAN_RECENCY_LIB:-}" ]]; then
    # shellcheck source=/dev/null
    . "$DISK_MAGICIAN_RECENCY_LIB" 2>/dev/null || true
  fi
  if command -v worktree_age_days >/dev/null 2>&1; then
    age="$(worktree_age_days "$wt" 2>/dev/null)" || return 1
  else
    newest="$(find "$wt" -xdev -type f -exec stat -c '%Y' {} + 2>/dev/null \
      | awk '$1+0>m{m=$1+0} END{if(m>0)print m}')"
    [[ "$newest" =~ ^[0-9]+$ ]] || return 1
    age=$(( ( $(date +%s) - newest ) / 86400 ))
  fi
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  (( age >= min_days )) || { echo "SKIP too-recent (age=${age}d): $rel"; return 1; }

  # 2) machine-local protection gates. An UNLOCATABLE safety module is a FAILED
  # gate, not a passed one: silently skipping it means a path covered by a
  # never_delete or needs_decision rule gets removed because the checker could
  # not be found. Absence of the checker must never read as absence of a rule.
  local safety found=0
  for safety in \
    "${WT_SAFETY_CHECK:-}" \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.13/site-packages/disk_magician/scripts/safety_check.sh" \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.12/site-packages/disk_magician/scripts/safety_check.sh"
  do
    [[ -n "$safety" && -f "$safety" ]] || continue
    found=1
    if ! bash "$safety" "$wt" >/dev/null 2>&1; then
      echo "SKIP safety-gate: $rel"; return 1
    fi
    break
  done
  (( found == 1 )) || { echo "SKIP safety-module-missing (fail closed): $rel"; return 1; }
  return 0
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
    # `git status --porcelain` does NOT list ignored files, and
    # `git worktree remove` deletes them anyway. Measured 2026-11-04: a worktree
    # with an ignored, untracked `ignored/data.txt` reported dirty=0 and the
    # remove step destroyed the file. Check ignored content explicitly and
    # preserve -- an ignored path is exactly where build outputs, local config
    # and credentials live.
    dirty=$(GIT_OPTIONAL_LOCKS=0 timeout 60 git -C "$wt" status --porcelain 2>/dev/null | wc -l)
    dirty=${dirty//[!0-9]/}
    [[ "$dirty" == "0" ]] || { echo "SKIP dirty=$dirty: $rel"; skip=$((skip+1)); continue; }

    if ! ignored_list="$(GIT_OPTIONAL_LOCKS=0 timeout 120 git -C "$wt" status --porcelain --ignored=matching --untracked-files=normal 2>/dev/null)"; then
      echo "SKIP ignored-scan-unmeasurable: $rel"; skip=$((skip+1)); continue
    fi
    if grep -qE '^!![[:space:]]' <<<"$ignored_list"; then
      echo "SKIP has-ignored-content (not covered by dirty check): $rel"
      skip=$((skip+1)); continue
    fi

    # Confirm against the LIVE remote, not stale local remote-tracking refs.
    # `for-each-ref refs/remotes` answers from the local ref cache, which keeps
    # a branch that has since been deleted or force-pushed upstream. Measured
    # 2026-11-04: after deleting the remote branch and keeping the local ref,
    # `for-each-ref --contains HEAD refs/remotes` still reports a match -- so a
    # commit that exists nowhere counted as "on remote" and would be deleted.
    # `ls-remote` is the authoritative check; failure or timeout preserves.
    if ! remote_urls="$(timeout 60 git -C "$wt" remote 2>/dev/null)" || [[ -z "$remote_urls" ]]; then
      echo "SKIP no-remote-configured: $rel"; skip=$((skip+1)); continue
    fi
    if ! live_heads="$(timeout 120 git -C "$wt" ls-remote --heads origin 2>/dev/null)"; then
      echo "SKIP remote-unverifiable: $rel"; skip=$((skip+1)); continue
    fi
    head_sha=$(timeout 30 git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [[ -z "$head_sha" ]] || ! grep -q "^${head_sha}[[:space:]]" <<<"$live_heads"; then
      echo "SKIP head-not-on-live-remote: $rel"; skip=$((skip+1)); continue
    fi

    gd=$(timeout 30 git -C "$wt" rev-parse --git-dir 2>/dev/null)
    case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
    [[ -f "$gd/locked" ]] && { echo "SKIP locked: $rel"; skip=$((skip+1)); continue; }

    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
    reverify_gates "$wt" "$rel" || { skip=$((skip+1)); continue; }

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

    # "not a repository" ALSO describes an ordinary directory with no git at
    # all, and a damaged repo whose objects were partly lost -- neither is
    # proven-orphaned worktree state. Require POSITIVE orphan provenance: the
    # worktree must still be declared by its main repo, and that repo's
    # .git/worktrees/<name> admin entry must be the thing that is missing.
    # Without that positive signal we cannot distinguish "orphaned worktree"
    # from "someone's plain folder", so preserve.

    main_repo=$(timeout 30 git -C "$WT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [[ -z "$main_repo" ]]; then
      # Resolve the owning repo from the list's first path component instead.
      repo_key="${rel%%/*}"
      for cand in "$HOME/projects/$repo_key" "$HOME/projects_other/$repo_key" "$HOME/$repo_key"; do
        if timeout 20 git -C "$cand" rev-parse --git-dir >/dev/null 2>&1; then
          main_repo="$(timeout 20 git -C "$cand" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
          break
        fi
      done
    fi
    main_repo="${main_repo%/.git}"
    if [[ -z "$main_repo" ]] || ! timeout 20 git -C "$main_repo" rev-parse --git-dir >/dev/null 2>&1; then
      echo "SKIP no-orphan-provenance (main repo unresolved): $rel"; skip=$((skip+1)); continue
    fi
    # POSITIVE provenance is required, not merely the absence of a Git record.
    # "Not listed by worktree list" and "no admin dir" are NEGATIVE conditions:
    # an ordinary directory that never was a worktree (say
    # ~/.worktrees/<repo>/notes) satisfies both, and would be recursively
    # deleted on a hand-list mistake. Deletion additionally requires a leftover
    # artifact that only a real worktree leaves behind: a `.git` FILE containing
    # a `gitdir:` pointer whose target is now missing. Absent that proof, the
    # candidate is preserved.
    wt_git="$wt/.git"
    proven_orphan=0
    if [[ -f "$wt_git" && ! -L "$wt_git" ]]; then
      gitdir_target="$(sed -n 's/^gitdir:[[:space:]]*//p' "$wt_git" 2>/dev/null | head -1)"
      if [[ -n "$gitdir_target" && ! -e "$gitdir_target" ]]; then
        proven_orphan=1
      fi
    fi
    if (( proven_orphan == 0 )); then
      echo "SKIP no-positive-orphan-provenance (no dangling gitdir pointer): $rel"
      skip=$((skip+1)); continue
    fi
    # A still-listed worktree is not an orphan even with a dangling pointer.
    if timeout 30 git -C "$main_repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
      echo "SKIP still-registered-worktree: $rel"; skip=$((skip+1)); continue
    fi

    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
    reverify_gates "$wt" "$rel" || { skip=$((skip+1)); continue; }
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

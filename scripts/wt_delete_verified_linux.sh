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
# Canonicalize the root once. The per-path containment check compares against
# `pwd -P` of the resolved parent, which returns the PHYSICAL path (macOS
# resolves /var -> /private/var and /tmp similarly). Without this, a root under
# such a path can never match the resolved parent, so every candidate is
# rejected as "escapes-root" -- a fail-closed but total denial of service on
# real cleanup. Measured 2026-11-04 while writing the regression suite.
WT_ROOT="$(cd "$WT_ROOT" 2>/dev/null && pwd -P)" || { echo "Refusing: worktree root does not exist: $WT_ROOT" >&2; exit 2; }

# `timeout` is coreutils, not part of a base macOS or minimal Linux image, and it
# is NOT guaranteed just because the repo's CI installs it. Repo convention
# (cleanup_claude_state.sh, cleanup_colima.sh, ...) is to degrade rather than
# assume. Guarding matters here because an unguarded call exits 127, which the
# git probe then classifies as "unverified" -- every candidate silently
# preserved, a guard suite that fails, and a cleanup that never runs.
# TO=() means "no timeout available": commands run unbounded.
# bounded <seconds> <cmd...> -- run with a wall-clock cap when `timeout` exists,
# otherwise run the command alone. The duration and the command MUST travel
# together: expanding an empty timeout array in front of a literal duration
# leaves `30 git ...` and bash tries to execute "30".
if command -v timeout >/dev/null 2>&1; then
  bounded() { timeout "$@"; }
else
  bounded() { local _secs=$1; shift; "$@"; }
fi
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
    if listing="$(bounded 60 lsof -nP -F n 2>/dev/null)"; then
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
  if ! fresh="$(bounded 30 ps -Ao pid,command 2>/dev/null)"; then
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

  # NOTE: this function's SKIP messages go to STDERR so the caller's
  # `|| { ...; continue; }` cannot swallow them. Written to stdout they were
  # silently discarded, leaving a bare "skipped=1" with no reason in the output
  # -- which made a real guard fire indistinguishable from a no-op.
  # 1) recency: newest content mtime, via the canonical helper when available.
  if [[ -n "${DISK_MAGICIAN_RECENCY_LIB:-}" && -f "${DISK_MAGICIAN_RECENCY_LIB:-}" ]]; then
    # shellcheck source=/dev/null
    . "$DISK_MAGICIAN_RECENCY_LIB" 2>/dev/null || true
  fi
  # Portable stat: BSD (-f %m) on macOS, GNU (-c %Y) on Linux. The Linux-only
  # form silently measured nothing on macOS, so every candidate looked
  # unmeasurable and was preserved -- fail-closed but useless.
  local stat_mtime=(stat -f '%m')
  stat -f '%m' / >/dev/null 2>&1 || stat_mtime=(stat -c '%Y')
  if command -v worktree_age_days >/dev/null 2>&1; then
    if ! age="$(worktree_age_days "$wt" 2>/dev/null)"; then
      echo "SKIP age-unmeasurable: $rel" >&2; return 1
    fi
  else
    newest="$(find "$wt" -xdev -type f -exec "${stat_mtime[@]}" {} + 2>/dev/null \
      | awk '$1+0>m{m=$1+0} END{if(m>0)print m}')"
    if [[ ! "$newest" =~ ^[0-9]+$ ]]; then
      echo "SKIP age-unmeasurable (no file mtimes): $rel" >&2; return 1
    fi
    age=$(( ( $(date +%s) - newest ) / 86400 ))
  fi
  if [[ ! "$age" =~ ^[0-9]+$ ]]; then
    echo "SKIP age-not-numeric ('$age'): $rel" >&2; return 1
  fi
  (( age >= min_days )) || { echo "SKIP too-recent (age=${age}d): $rel" >&2; return 1; }

  # 2) machine-local protection gates. An UNLOCATABLE safety module is a FAILED
  # gate, not a passed one: silently skipping it means a path covered by a
  # never_delete or needs_decision rule gets removed because the checker could
  # not be found. Absence of the checker must never read as absence of a rule.
  # An EXPLICIT WT_SAFETY_CHECK is authoritative: if it is set but missing or
  # non-executable, that is the operator pointing at a checker that is not
  # there, and falling through to an installed default silently substitutes a
  # DIFFERENT policy for the one that was requested. Fail closed instead.
  local safety found=0
  if [[ -n "${WT_SAFETY_CHECK:-}" ]]; then
    if [[ ! -f "$WT_SAFETY_CHECK" || ! -r "$WT_SAFETY_CHECK" ]]; then
      echo "SKIP safety-module-missing (explicit WT_SAFETY_CHECK unreadable: $WT_SAFETY_CHECK): $rel" >&2
      return 1
    fi
    if ! bash "$WT_SAFETY_CHECK" "$wt" >/dev/null 2>&1; then
      echo "SKIP safety-gate: $rel" >&2; return 1
    fi
    # Require the checker to actually EXAMINE this path. The canonical
    # safety_check.sh takes the path positionally and does not implement
    # --check, so a --check-first probe proves nothing: it exits 2 (usage) and
    # the retry below would then accept any checker that returns 0. Instead,
    # require positive evidence in the OUTPUT -- the canonical checker prints
    # "OK <path>" for a permitted path. A checker that prints nothing about the
    # path has not looked at it, and silence is not consent.
    local out rc2
    out="$(bash "$WT_SAFETY_CHECK" "$wt" 2>&1)"; rc2=$?
    if (( rc2 != 0 )); then
      echo "SKIP safety-gate (checker rc=$rc2): $rel" >&2; return 1
    fi
    if ! grep -qE "(^|[[:space:]])OK[[:space:]]+.*${wt//\./\\.}" <<<"$out"; then
      echo "SKIP safety-gate (checker did not report OK for this path): $rel" >&2
      return 1
    fi
    return 0
  fi
  for safety in \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.13/site-packages/disk_magician/scripts/safety_check.sh" \
    "$HOME/.local/share/uv/tools/disk-magician/lib/python3.12/site-packages/disk_magician/scripts/safety_check.sh"
  do
    [[ -n "$safety" && -f "$safety" ]] || continue
    found=1
    if ! bash "$safety" "$wt" >/dev/null 2>&1; then
      echo "SKIP safety-gate: $rel" >&2; return 1
    fi
    break
  done
  (( found == 1 )) || { echo "SKIP safety-module-missing (fail closed): $rel" >&2; return 1; }
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
  # Capture STDERR only. The redirection ORDER matters: duplicating stdout onto
  # fd 2 BEFORE discarding stdout leaves stderr pointing at the terminal, so the
  # capture is EMPTY. That made the "not a git repository" match fail on any git
  # whose message lands on stderr (seen only on the CI runner), so a genuine
  # orphan fell through as unverified-git-state. Discard stdout FIRST, then
  # merge stderr into the capture -- the order used on the line below.
  # Message-free probe. Parsing git's wording was brittle: it varies by version
  # ("not a git repository: <path>" vs "not a git repository (or any of the
  # parent directories)") and the difference decided whether a genuine orphan
  # was reclaimed or silently preserved. Ask a question with a stable contract
  # instead -- does git consider this path part of ANY repository?
  #   --git-dir succeeds -> it IS a repo (healthy OR damaged)  -> not an orphan
  #   --git-dir fails    -> not a repo at all                  -> candidate
  # HEAD resolution then distinguishes healthy from damaged.
  bounded 30 git -C "$wt" rev-parse HEAD >/dev/null 2>&1
  probe_rc=$?
  gitdir_ok=0
  bounded 30 git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 && gitdir_ok=1

  if (( probe_rc == 0 )); then
    # Linked (or standalone) repo: re-verify the safety properties.
    # `git status --porcelain` does NOT list ignored files, and
    # `git worktree remove` deletes them anyway. Measured 2026-11-04: a worktree
    # with an ignored, untracked `ignored/data.txt` reported dirty=0 and the
    # remove step destroyed the file. Check ignored content explicitly and
    # preserve -- an ignored path is exactly where build outputs, local config
    # and credentials live.
    # Capture FIRST, then count. `git status ... | wc -l` hides a failing git:
    # measured 2026-11-04, `git status` returned 128 on a bad repo while the
    # pipeline still printed 0 lines -- a broken/unreadable repo read as clean.
    if ! status_out="$(GIT_OPTIONAL_LOCKS=0 bounded 60 git -C "$wt" status --porcelain 2>/dev/null)"; then
      echo "SKIP git-status-failed: $rel"; skip=$((skip+1)); continue
    fi
    if [[ -n "$status_out" ]]; then
      echo "SKIP dirty: $rel"; skip=$((skip+1)); continue
    fi

    if ! ignored_list="$(GIT_OPTIONAL_LOCKS=0 bounded 120 git -C "$wt" status --porcelain --ignored=matching --untracked-files=normal 2>/dev/null)"; then
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
    if ! remote_urls="$(bounded 60 git -C "$wt" remote 2>/dev/null)" || [[ -z "$remote_urls" ]]; then
      echo "SKIP no-remote-configured: $rel"; skip=$((skip+1)); continue
    fi
    if ! live_heads="$(bounded 120 git -C "$wt" ls-remote --heads origin 2>/dev/null)"; then
      echo "SKIP remote-unverifiable: $rel"; skip=$((skip+1)); continue
    fi
    head_sha=$(bounded 30 git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [[ -z "$head_sha" ]] || ! grep -q "^${head_sha}[[:space:]]" <<<"$live_heads"; then
      echo "SKIP head-not-on-live-remote: $rel"; skip=$((skip+1)); continue
    fi

    gd=$(bounded 30 git -C "$wt" rev-parse --git-dir 2>/dev/null)
    case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
    [[ -f "$gd/locked" ]] && { echo "SKIP locked: $rel"; skip=$((skip+1)); continue; }

    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
    reverify_gates "$wt" "$rel" || { skip=$((skip+1)); continue; }

    main_repo=$(bounded 30 git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    main_repo="${main_repo%/.git}"
    if bounded 300 git -C "${main_repo:-$wt}" worktree remove "$wt" 2>/dev/null && [[ ! -e "$wt" ]]; then
      ok=$((ok+1)); kb_total=$((kb_total+kb))
      printf 'REMOVED(lw)     %6.2f GiB  %s\n' "$(awk -v k="$kb" 'BEGIN{print k/1048576}')" "$rel"
    else
      echo "FAILED(lw): $rel"; fail=$((fail+1))
    fi
  else
    # Orphaned path is allowed ONLY on git's own positive "not a repository"
    # verdict. Any other failure (timeout/rc 124, permission, lock, corrupt
    # object store) is unknown and therefore preserved.
    # Match git's own "this is not a repository" verdict tolerantly: the exact
    # wording varies by version and by whether the path is an invalid .git FILE
    # or a missing admin dir ("not a git repository: <path>" vs "not a git
    # repository (or any of the parent directories)"). Requiring one phrasing
    # made a genuine orphan read as unverified-git-state on git 2.56.
    # Any OTHER fatal message, or a non-128 exit, stays unknown -> preserve.
    # Unknown unless git positively says this path is not in any repository.
    # `gitdir_ok == 1` means it IS a repo (damaged HEAD or unreadable admin
    # dir), which is NOT an orphan. `probe_rc` must also be the
    # repository-not-found status; anything else (timeout 124, permission,
    # lock) is unknown and preserves.
    if (( gitdir_ok == 1 )) || (( probe_rc != 128 )); then
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

    # Resolve the owning repo from the candidate's OWN repo key, never from
    # $WT_ROOT. `git -C "$WT_ROOT"` walks UP the directory tree, so when the
    # worktree root happens to live inside any git repository (a checkout, a
    # nested test sandbox, a parent project) it resolves to THAT repo and never
    # to the candidate's owner -- the wrong answer, silently. Measured
    # 2026-11-04: it returned the enclosing temp sandbox's .git instead of the
    # per-candidate repo.
    main_repo=""
    repo_key="${rel%%/*}"
    for cand in "$HOME/projects/$repo_key" "$HOME/projects_other/$repo_key" \
                "$HOME/.worktrees/$repo_key" "$HOME/$repo_key"; do
      [[ -d "$cand" ]] || continue
      if bounded 20 git -C "$cand" rev-parse --git-dir >/dev/null 2>&1; then
        main_repo="$(bounded 20 git -C "$cand" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        break
      fi
    done
    main_repo="${main_repo%/.git}"
    if [[ -z "$main_repo" ]] || ! bounded 20 git -C "$main_repo" rev-parse --git-dir >/dev/null 2>&1; then
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
      # The dangling pointer must BELONG to the resolved main repo, otherwise an
      # unrelated repo's leftover pointer would authorize deleting a directory
      # this repo never owned. Require the target to sit under <main_repo>/.git/
      # and to name this worktree.
      if [[ -n "$gitdir_target" && ! -e "$gitdir_target" ]]; then
        # Canonicalize the recorded pointer before comparing. git writes the
        # path it was given, which may be a LOGICAL path (e.g. /var/...), while
        # main_repo resolves PHYSICAL (/private/var/...). Comparing raw strings
        # made a correctly-owned orphan look foreign, so it was preserved
        # forever. Measured 2026-11-04. Compare both the recorded and resolved
        # forms so either spelling matches.
        # Resolve the nearest EXISTING ancestor and re-join the tail: the whole
        # point of this branch is that the target is missing, so `cd` on its own
        # dirname always fails and would degrade to "/<basename>".
        gitdir_phys="$gitdir_target"
        probe="$gitdir_target"; tail=""
        while [[ -n "$probe" && "$probe" != "/" ]]; do
          if [[ -d "$probe" ]]; then
            gitdir_phys="$(cd "$probe" 2>/dev/null && pwd -P)${tail}"
            break
          fi
          tail="/${probe##*/}${tail}"
          probe="$(dirname "$probe")"
        done
        case "$gitdir_target:$gitdir_phys" in
          "$main_repo"/.git/worktrees/"${wt##*/}":*|*:"$main_repo"/.git/worktrees/"${wt##*/}"|\
          "$main_repo"/.git/worktrees/"${wt##*/}"/*:*|*:"$main_repo"/.git/worktrees/"${wt##*/}"/*) proven_orphan=1 ;;
          *) echo "SKIP orphan-pointer-not-owned-by-main-repo: $rel"; skip=$((skip+1)); continue ;;
        esac
      fi
    fi
    if (( proven_orphan == 0 )); then
      echo "SKIP no-positive-orphan-provenance (no dangling gitdir pointer): $rel"
      skip=$((skip+1)); continue
    fi
    # A still-listed worktree is not an orphan even with a dangling pointer.
    # If the registration check FAILS or times out, the answer is unknown, and
    # unknown must preserve -- never let a failed `worktree list` read as
    # "not registered".
    if ! wt_list="$(bounded 30 git -C "$main_repo" worktree list --porcelain 2>/dev/null)"; then
      echo "SKIP registration-unverifiable: $rel"; skip=$((skip+1)); continue
    fi
    if [[ -z "$wt_list" ]]; then
      echo "SKIP registration-unverifiable (empty): $rel"; skip=$((skip+1)); continue
    fi
    if grep -qxF "worktree $wt" <<<"$wt_list"; then
      echo "SKIP still-registered-worktree: $rel"; skip=$((skip+1)); continue
    fi

    in_live_use "$wt" && { echo "SKIP live: $rel"; skip=$((skip+1)); continue; }
    reverify_gates "$wt" "$rel" || { skip=$((skip+1)); continue; }

    # CONTENT SAFETY for an orphaned worktree.
    #
    # With the git admin dir gone there is NO way to tell which files were
    # committed and which were never committed: the index and object store that
    # would answer that are exactly what is missing. Any content check I could
    # run here would be a guess, and a guess in the delete direction destroys
    # uncommitted work. So an unverifiable worktree is preserved unless the
    # caller attests, per path, that its content was already accounted for.
    #   WT_ORPHAN_CONTENT_VERIFIED=<path>[,<path>...]  explicit operator attestation
    if [[ -n "${WT_ORPHAN_CONTENT_VERIFIED:-}" ]]; then
      case ",${WT_ORPHAN_CONTENT_VERIFIED}," in
        *",$wt,"*) : ;;
        *) echo "SKIP orphan-content-unverified: $rel"; skip=$((skip+1)); continue ;;
      esac
    else
      echo "SKIP orphan-content-unverified (git admin gone; pass WT_ORPHAN_CONTENT_VERIFIED): $rel"
      skip=$((skip+1)); continue
    fi

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

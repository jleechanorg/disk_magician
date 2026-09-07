# shellcheck shell=bash
# worktree_safety.sh — canonical fail-closed git-safety guard.
#
# Source this file, then call:
#   worktree_has_unsaved_work <path>
#     rc 0 = UNSAFE (uncommitted changes, untracked files, unpushed commits,
#            no upstream, or unparseable/corrupted git metadata -> DO NOT DELETE/ARCHIVE)
#     rc 1 = SAFE (provably clean and pushed worktree, or not a git worktree at all)
#
# WHY THIS EXISTS
# ---------------
# Three cleanup scripts (cleanup_tmp.sh, cleanup_agent_artifacts.sh,
# cleanup_pr_scratch.sh) independently implemented worktree_has_unsaved_work().
# Over repeated review rounds (PR #55, PR #60), copies drifted: fixes for
# dangling .git symlinks (-L) and probe exit code assertions (status_rc, rev_rc)
# were applied to some copies while leaving others failing open.
# Extracting the canonical implementation here resolves beads disk_magician-0jy
# and disk_magician-nv3.
#
# FAIL-CLOSED CONTRACT
# --------------------
# Every ambiguity or error (git binary missing, corrupted repo, dangling .git,
# failed status/rev-list execution, missing upstream) resolves to rc 0 (UNSAFE).
# Only a provably clean repo with valid upstream and zero unpushed commits,
# or a path with genuinely no .git metadata, returns rc 1 (SAFE).

worktree_has_unsaved_work() {
  local wt="$1" git_bin upstream status_out status_rc rev_out rev_rc
  git_bin=$(command -v git 2>/dev/null) || {
    if declare -F log >/dev/null 2>&1; then
      log "git unavailable — cannot prove worktree $wt is clean; treating as unsafe."
    fi
    return 0
  }

  # Not a git worktree at all → no git work to lose here.
  # -e alone follows symlinks, so also check -L: a DANGLING .git symlink is corrupted
  # metadata, not "absent", and must fall through to the fail-closed rev-parse branch below.
  if [[ ! -e "$wt/.git" && ! -L "$wt/.git" ]]; then
    return 1
  fi

  # .git exists (or is a dangling symlink) but rev-parse failed ->
  # corrupted repo / permission error, must fail closed, not read the same as "not a worktree".
  "$git_bin" -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Check the PROBE's own exit code, not just whether it printed anything —
  # empty stdout from a failed `git status`/`git rev-list` must not read the same as "confirmed clean".
  status_out="$("$git_bin" -C "$wt" status --porcelain 2>/dev/null)"; status_rc=$?
  [[ "$status_rc" -ne 0 ]] && return 0
  [[ -n "$status_out" ]] && return 0

  # Unpushed commits, or no upstream to compare against → fail closed.
  upstream=$("$git_bin" -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 0
  [[ -z "$upstream" ]] && return 0

  rev_out="$("$git_bin" -C "$wt" rev-list "${upstream}..HEAD" 2>/dev/null)"; rev_rc=$?
  [[ "$rev_rc" -ne 0 ]] && return 0
  [[ -n "$rev_out" ]] && return 0

  return 1
}

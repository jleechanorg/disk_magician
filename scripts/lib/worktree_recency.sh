# shellcheck shell=bash
# worktree_recency.sh — canonical "when was this worktree last touched?" helper.
#
# Source this file, then call:
#   worktree_last_activity_epoch <path>   prints unix epoch of newest activity
#   worktree_age_days <path>              prints whole days since that activity
#   worktree_is_recently_active <path> <min_days>
#                                         rc 0 = TOO YOUNG, do not delete
#
# WHY THIS EXISTS
# ---------------
# Three scripts independently guessed a worktree's age from a cheap stat, and
# both guesses are provably wrong on this machine:
#
#   a) `stat -f %m <wt>/.git`  — for a LINKED worktree `.git` is a one-line
#      `gitdir:` pointer file written once at `git worktree add` time. Git does
#      not rewrite it on commit/checkout/status, so this measures worktree
#      CREATION age, not last-edit age.
#   b) `stat -f %m <wt>`       — a directory's mtime only changes when entries
#      are added/removed at its top level. Editing mvp_site/foo.py all week
#      leaves the worktree root's mtime untouched.
#
# Measured against the live worldarchitect.ai registry (30 linked worktrees
# sampled 2026-07-27): both proxies reported 20.4 days for two worktrees whose
# newest file was 12.8 days old. Under the 14-day floor those two would have
# been classified deletable while sitting inside the protected window.
#
# FAIL-CLOSED CONTRACT
# --------------------
# Every unknown resolves toward "active". If the tree cannot be walked, if the
# path is unreadable, if the find pipeline returns nothing — this prints
# `now`, i.e. age 0, i.e. protected. A sweeper that cannot prove a worktree is
# old must not delete it. The previous fallback did the opposite: an empty
# `find` result fell through to the directory mtime, which is the most
# stale-biased number available, so the failure mode of the safety check was to
# mark things deletable.

# Directory names pruned from the content walk. `-prune` (not `-not -path`)
# because -not -path still descends into every excluded dir and filters after
# the fact — on a worktree with a venv/ that is tens of thousands of wasted
# stat calls.
_WT_RECENCY_PRUNE_NAMES=(.git node_modules venv .venv __pycache__ .pytest_cache .ruff_cache)

# NOT counted as activity: anything inside the git admin dir.
#
# Tempting, and wrong. `git status --porcelain` rewrites the index to refresh
# its stat cache, and this repo's own worktree_hygiene.sh runs `git status` on
# every candidate during triage. Counting index mtime would mean run N marks a
# worktree a candidate, triage touches its index, and run N+1 sees it as
# "active" — the sweeper would permanently exempt exactly the worktrees it had
# just identified. tests/test_worktree_hygiene.py locks in the same decision
# from the other direction (jleechan-20gm: a fresh `.git` pointer must not mask
# stale content), which is why `.git` is in the prune list below.
#
# Nothing is lost by this: commit, checkout, reset, rebase and stash all
# rewrite working-tree files, so real work always shows up in content mtime.

# worktree_last_activity_epoch <worktree_path>
# Newest mtime among non-pruned regular files in the tree.
# Prints `now` when that cannot be determined (fail closed).
worktree_last_activity_epoch() {
    local wt="${1:-}" now newest=0 candidate
    now="$(date +%s)"
    [[ -n "$wt" && -d "$wt" ]] && [[ -r "$wt" ]] || { printf '%s\n' "$now"; return 0; }

    # awk computes the max in a single pass instead of `sort -rn | head -1`:
    # head closing the pipe early raises SIGPIPE in sort, which under
    # `set -o pipefail` turns a healthy scan into an empty result. awk consumes
    # all of stdin, so the pipe is never closed early.
    local prune_expr=() name first=true
    for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
        if [[ "$first" == true ]]; then
            prune_expr=(-name "$name")
            first=false
        else
            prune_expr+=(-o -name "$name")
        fi
    done
    candidate="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
        -o -type f -exec stat -f '%m' {} + 2>/dev/null \
        | awk '$1+0>m{m=$1+0} END{if (m>0) print m}')" || candidate=""
    [[ -n "$candidate" ]] && (( candidate > newest )) && newest="$candidate"

    # Fail closed: no evidence at all -> treat as active right now.
    if (( newest <= 0 )); then
        printf '%s\n' "$now"
        return 0
    fi
    # A clock skew / future mtime must not read as "very old" either.
    (( newest > now )) && newest="$now"
    printf '%s\n' "$newest"
}

# worktree_age_days <worktree_path> — whole days since last activity.
worktree_age_days() {
    local now last
    now="$(date +%s)"
    last="$(worktree_last_activity_epoch "$1")"
    printf '%s\n' "$(( (now - last) / 86400 ))"
}

# worktree_is_recently_active <worktree_path> <min_days>
# rc 0 = the worktree was touched inside the last <min_days> days; it is
#        PROTECTED and must not be deleted, stripped, or archived.
# rc 1 = older than the floor; eligible for whatever the caller does next.
worktree_is_recently_active() {
    local wt="${1:-}" min_days="${2:-14}" age
    age="$(worktree_age_days "$wt")"
    (( age < min_days ))
}

# shellcheck shell=bash
# worktree_recency.sh — canonical "when was this worktree last touched?" helper.
#
# Source this file, then call:
#   worktree_last_activity_epoch <path>   prints unix epoch of newest activity
#   worktree_age_days <path>              prints whole days since that activity
#   worktree_is_recently_active <path> <min_days> [now]
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

# Fill the caller's local prune_expr array (also supported by macOS Bash 3.2).
_worktree_recency_build_prune_expr() {
    local name first=true
    prune_expr=()
    for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
        if [[ "$first" == true ]]; then
            prune_expr=(-name "$name")
            first=false
        else
            prune_expr+=(-o -name "$name")
        fi
    done
}

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
    local prune_expr=()
    _worktree_recency_build_prune_expr
    # BSD stat (-f '%m') vs GNU stat (-c '%Y'); GNU rejects the BSD form, which
    # previously left every Linux worktree unmeasured and therefore "young".
    local stat_mtime=(stat -f '%m')
    stat -f '%m' / >/dev/null 2>&1 || stat_mtime=(stat -c '%Y')
    # find's own exit status is checked (not left to the caller's pipefail): a
    # partly unreadable tree has unknown recency and must read as active.
    local mtimes
    if mtimes="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
        -o -type f -exec "${stat_mtime[@]}" {} + 2>/dev/null)"; then
        candidate="$(awk '$1+0>m{m=$1+0} END{if (m>0) print m}' <<<"$mtimes")"
    else
        candidate=""
    fi
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

# Keep every fallback on the same validated row clock as the threshold probe.
_worktree_recency_legacy_active() {
    local wt="$1" min_days="$2" now="$3" last age
    last="$(worktree_last_activity_epoch "$wt")"
    age="$(( (now - last) / 86400 ))"
    (( age < min_days ))
}

# worktree_is_recently_active <worktree_path> <min_days> [now]
# rc 0 = the worktree was touched inside the last <min_days> days; it is
#        PROTECTED and must not be deleted, stripped, or archived.
# rc 1 = older than the floor; eligible for whatever the caller does next.
# An optional row clock is accepted only within the preceding 300 seconds.
#
# Legacy find -exec stat cannot stat a regular file whose path exceeds PATH_MAX,
# so it reads that tree as active. The final byte-length guard preserves this
# intentional protection even though -newer itself can inspect longer paths.
# One accepted residual: a file deleted, modified, or created during the check
# after the final traversal has passed it can be missed here while legacy's
# slightly later batched stat would see it. Both are point-in-time measurements.
worktree_is_recently_active() {
    local wt="${1:-}" min_days="${2:-7}" raw_min_days="${2-7}" supplied_now="${3:-}" now
    now="$(date +%s)" || now=""
    # Bound the supplied decimal's length before Bash arithmetic: arbitrarily
    # long digit strings must not wrap into the accepted 300-second window.
    if [[ "$supplied_now" =~ ^[1-9][0-9]*$ && "$now" =~ ^[1-9][0-9]*$ ]] &&
        (( ${#supplied_now} <= ${#now} )) &&
        (( supplied_now <= now && now - supplied_now <= 300 )); then
        now="$supplied_now"
    fi

    local root="$wt" root_name name wt_physical="" eligible=true
    while [[ "$root" == */ && "$root" != / ]]; do root="${root%/}"; done
    root_name="${root##*/}"
    for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
        [[ "$root_name" == "$name" ]] && eligible=false
    done
    if [[ ! "$raw_min_days" =~ ^(0|[1-9][0-9]{0,4})$ ]] ||
        (( min_days > 36500 )) ||
        [[ "$wt" != /* || ! -d "$wt" || ! -r "$wt" || -L "$root" || "$eligible" == false ]]; then
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi
    wt_physical="$(cd -P -- "$wt" 2>/dev/null && pwd -P)" || wt_physical=""
    while [[ "$wt_physical" == */ && "$wt_physical" != / ]]; do wt_physical="${wt_physical%/}"; done
    if [[ -z "$wt_physical" || "$wt_physical" != "$root" || ! "$now" =~ ^[1-9][0-9]*$ ]]; then
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi

    local cutoff=$(( now - min_days * 86400 )) flavor="" probe
    if (( cutoff <= 1 )); then
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi
    # Detect once; the two reference stamps use only the selected flavour.
    if probe="$(date -r 0 +%s 2>/dev/null)" && [[ "$probe" == 0 ]]; then
        flavor=bsd
    elif probe="$(date -d @0 +%s 2>/dev/null)" && [[ "$probe" == 0 ]]; then
        flavor=gnu
    else
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi

    local ref_dir
    if ! ref_dir="$(mktemp -d 2>/dev/null)" || [[ -z "$ref_dir" ]]; then
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi
    # Expected conservative difference: legacy counts mtime exactly 1 as
    # positive (old), but this epoch-1 reference deliberately excludes it from
    # the -newer probe, so an epoch-0/1-only tree stays active/protected here.
    local cutoff_ref="$ref_dir/cutoff" epoch_ref="$ref_dir/epoch-one"
    local ref_physical="" stamp readback result=2 rc hit any_hit path_max long_pattern
    local prune_expr=()
    _worktree_recency_build_prune_expr
    # result 2 means legacy fallback, always after deleting both references.
    while :; do
        ref_physical="$(cd -P -- "$ref_dir" 2>/dev/null && pwd -P)" || break
        while [[ "$ref_physical" == */ && "$ref_physical" != / ]]; do ref_physical="${ref_physical%/}"; done
        [[ -n "$ref_physical" ]] || break
        if [[ "$wt_physical" == / || "$ref_physical" == "$wt_physical" ||
            "$ref_physical" == "$wt_physical/"* ]]; then
            break
        fi
        if [[ "$flavor" == bsd ]]; then
            stamp="$(TZ=UTC0 date -r "$cutoff" +%Y%m%d%H%M.%S 2>/dev/null)" || break
        else
            stamp="$(TZ=UTC0 date -d "@$cutoff" +%Y%m%d%H%M.%S 2>/dev/null)" || break
        fi
        TZ=UTC0 touch -t "$stamp" "$cutoff_ref" 2>/dev/null || break
        if [[ "$flavor" == bsd ]]; then
            readback="$(stat -f %m "$cutoff_ref" 2>/dev/null)" || break
        else
            readback="$(stat -c %Y "$cutoff_ref" 2>/dev/null)" || break
        fi
        [[ "$readback" == "$cutoff" ]] || break
        if [[ "$flavor" == bsd ]]; then
            stamp="$(TZ=UTC0 date -r 1 +%Y%m%d%H%M.%S 2>/dev/null)" || break
        else
            stamp="$(TZ=UTC0 date -d @1 +%Y%m%d%H%M.%S 2>/dev/null)" || break
        fi
        TZ=UTC0 touch -t "$stamp" "$epoch_ref" 2>/dev/null || break
        if [[ "$flavor" == bsd ]]; then
            readback="$(stat -f %m "$epoch_ref" 2>/dev/null)" || break
        else
            readback="$(stat -c %Y "$epoch_ref" 2>/dev/null)" || break
        fi
        [[ "$readback" == 1 ]] || break

        # Never normalize the find root: its bytes must match the legacy call.
        rc=0
        hit="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
            -o -type f -newer "$cutoff_ref" -print -quit 2>/dev/null)" || rc=$?
        if (( rc != 0 )) || [[ -n "$hit" ]]; then result=0; break; fi
        rc=0
        any_hit="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
            -o -type f -newer "$epoch_ref" -print -quit 2>/dev/null)" || rc=$?
        if (( rc != 0 )) || [[ -z "$any_hit" ]]; then result=0; break; fi
        if [[ "$any_hit" -ef "$cutoff_ref" || "$any_hit" -ef "$epoch_ref" ]]; then break; fi
        rc=0
        hit="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
            -o -type f -newer "$cutoff_ref" -print -quit 2>/dev/null)" || rc=$?
        if (( rc != 0 )) || [[ -n "$hit" ]]; then result=0; break; fi

        path_max="$(getconf PATH_MAX "$wt" 2>/dev/null)" || path_max=""
        [[ "$path_max" =~ ^[0-9]+$ ]] || path_max=1024
        printf -v long_pattern '%*s' "$(( path_max - 1 ))" ''
        long_pattern="${long_pattern// /?}*"
        rc=0
        hit="$(LC_ALL=C find "$wt" \( "${prune_expr[@]}" \) -prune \
            -o -path "$long_pattern" -print -quit 2>/dev/null)" || rc=$?
        if (( rc != 0 )) || [[ -n "$hit" ]]; then result=0; break; fi
        result=1
        break
    done
    # Reference cleanup must precede legacy, especially with TMPDIR in the tree.
    # An unexpected cleanup failure cannot establish that the worktree is old.
    rm -rf -- "$ref_dir" 2>/dev/null || return 0
    if (( result == 2 )); then
        _worktree_recency_legacy_active "$wt" "$min_days" "$now"
        return $?
    fi
    return "$result"
}

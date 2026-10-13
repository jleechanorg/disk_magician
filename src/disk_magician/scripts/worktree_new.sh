#!/usr/bin/env bash
# worktree_new.sh — `diskm worktree-new` (spec D2): create a git worktree at
# $STANDARD_WORKTREE_ROOT/<repo>/<name> and print its absolute path.
#
#   worktree_new.sh <repo-path> <branch> [--base <ref>] [--name <name>]
#
# stdout is exactly the path; all git output goes to stderr. Never fetches.
# Sourced by worktree_create_hook.sh for the shared wtn_* functions.

_WTN_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/lib/layout_standard.sh
source "$_WTN_DIR/lib/layout_standard.sh"
# Lease bookkeeping (plan Task 4): optional on purpose — creation must never
# fail because the lease lib is missing or unreadable.
# shellcheck source=scripts/lib/worktree_lease.sh
[[ -f "$_WTN_DIR/lib/worktree_lease.sh" ]] && source "$_WTN_DIR/lib/worktree_lease.sh"
# shellcheck source=scripts/lib/admit_caller.sh
[[ -f "$_WTN_DIR/lib/admit_caller.sh" ]] && source "$_WTN_DIR/lib/admit_caller.sh"
[[ -f "$_WTN_DIR/lib/worktree_recency.sh" ]] && source "$_WTN_DIR/lib/worktree_recency.sh"
# C14 sources worktree_remove_hook, which sources this file back. Guard that
# source cycle so a missing/incomplete C14 still fails closed without recursion.
if [[ -z "${_WTN_LOADING_C14:-}" && -f "$_WTN_DIR/lib/artifact_verdict.sh" ]]; then
    _WTN_LOADING_C14=1
    source "$_WTN_DIR/lib/artifact_verdict.sh"
    unset _WTN_LOADING_C14
fi

# wtn_main_repo <path> — the repo that owns <path>'s worktrees: the main
# checkout for a linked worktree, the submodule checkout for a submodule
# (core.worktree), or the bare git dir for a bare repo.
wtn_main_repo() {
    local common wt
    common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [[ -n "$common" ]] || return 1
    if wt="$(git --git-dir="$common" config --get core.worktree)"; then
        (CDPATH= cd -- "$common" >/dev/null && CDPATH= cd -- "$wt" >/dev/null && pwd -P)
    elif [[ "$(git --git-dir="$common" config --bool --get core.bare)" == true ]]; then
        printf '%s\n' "$common"
    else
        dirname "$common"
    fi
}

# wtn_repo_name <repo> — basename without a bare repo's .git suffix.
wtn_repo_name() { local b; b="$(basename "$1")"; printf '%s\n' "${b%.git}"; }

# wtn_default_base <repo> — origin/HEAD, else HEAD.
wtn_default_base() {
    if git -C "$1" rev-parse -q --verify 'origin/HEAD^{commit}' >/dev/null 2>&1; then
        echo origin/HEAD
    else
        echo HEAD
    fi
}

wtn_branch_exists() { git -C "$1" show-ref -q --verify "refs/heads/$2"; }
wtn_remote_branch_exists() { git -C "$1" show-ref -q --verify "refs/remotes/origin/$2"; }

# wtn_timeout <secs> <cmd...> — timeout/gtimeout, else a perl alarm that
# signals the whole process group (exit 124 on timeout, like timeout(1)).
wtn_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        perl -e '
            my $t = shift;
            my $p = fork // exit 127;
            if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
            setpgrp($p, $p);
            $SIG{ALRM} = sub { kill "TERM", -$p; sleep 1; kill "KILL", -$p; exit 124 };
            alarm $t;
            waitpid $p, 0;
            exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
        ' "$secs" "$@"
    fi
}

# wtn_checked_out_elsewhere <repo> <branch> <path> — rc 0 if <branch> is
# checked out by any registered worktree other than <path> (or if the list
# cannot be read: fail closed).
wtn_checked_out_elsewhere() {
    local list
    list="$(git -C "$1" worktree list --porcelain)" || return 0
    awk -v b="branch refs/heads/$2" -v p="worktree $3" '
        /^worktree / { wt = $0 } $0 == b && wt != p { f = 1 } END { exit !f }' <<<"$list"
}

# wtn_unclaim <path> — undo this call's claim: rmdir only, so a dir that
# holds anything (another call's checkout, or a partial one) is never deleted.
# git rolls back its own admin entry when `worktree add` fails; this never
# touches .git/worktrees.
wtn_unclaim() {
    rmdir -- "$1" 2>/dev/null || echo "worktree-new: left non-empty $1 in place" >&2
}

# wtn_registered <repo> <path> — rc 0 if <path> is a registered worktree,
# including missing or locked ones (fail closed: unreadable list = taken).
wtn_registered() {
    local list real
    list="$(git -C "$1" worktree list --porcelain)" || return 0
    real="$(CDPATH= cd -- "$(dirname -- "$2")" >/dev/null 2>&1 && pwd -P)/$(basename -- "$2")" || real="$2"
    grep -qxF "worktree $2" <<<"$list" || grep -qxF "worktree $real" <<<"$list"
}

# wtn_create <repo> <branch> <path> <base> [new] — worktree add, git output to
# stderr, ${WTN_ADD_TIMEOUT:-30} s cap; prints <path> on success; a failed
# add leaves git's own rc in WTN_ADD_RC (worktree-new's exit, spec §7.1). Existing
# local branch: checked out as is. Branch only on origin: local branch
# tracking origin/<branch>. Otherwise: new untracked branch from <base>.
# With "new", the branch must be created by this call: an existing local or
# origin branch, or losing the atomic create, is a lost race (rc 3).
# <path> is claimed with an atomic mkdir first (rc 2 if it already exists),
# and a new branch is created atomically by this call before the add (rc 3 if
# someone else created it first), so a concurrent call never cleans up a
# worktree or branch it did not create. On failure, rmdirs this call's empty
# path, and deletes its own new branch only if still at the start commit and
# not checked out by another worktree.
wtn_create() {
    local repo="$1" branch="$2" path="$3" base="$4" need_new="${5:-}" created=0 start=""
    mkdir -p "$(dirname "$path")" || return 1
    if wtn_registered "$repo" "$path"; then
        echo "worktree-new: target registered: $path" >&2
        return 2
    fi
    if ! mkdir "$path" 2>/dev/null; then
        echo "worktree-new: target exists: $path" >&2
        # A writable parent means mkdir lost to an existing or racing entry.
        [[ -w "$(dirname "$path")" ]] && return 2
        return 1
    fi
    if [[ "$need_new" == new ]] &&
        { wtn_branch_exists "$repo" "$branch" || wtn_remote_branch_exists "$repo" "$branch"; }; then
        echo "worktree-new: branch already exists: $branch" >&2
        wtn_unclaim "$path"
        return 3
    fi
    if [[ "$need_new" == new ]] || ! wtn_branch_exists "$repo" "$branch"; then
        local track=--no-track from="$base"
        if wtn_remote_branch_exists "$repo" "$branch"; then track=--track; from="origin/$branch"; fi
        start="$(git -C "$repo" rev-parse -q --verify "$from^{commit}")" &&
            git -C "$repo" branch "$track" "$branch" "$from" >&2 && created=1
        if [[ "$created" != 1 ]]; then
            echo "worktree-new: could not create branch $branch" >&2
            wtn_unclaim "$path"
            wtn_branch_exists "$repo" "$branch" && return 3
            return 1
        fi
    fi
    WTN_ADD_RC=0
    wtn_timeout "${WTN_ADD_TIMEOUT:-30}" git -C "$repo" worktree add "$path" "$branch" >&2 || WTN_ADD_RC=$?
    if [[ "$WTN_ADD_RC" != 0 ]]; then
        echo "worktree-new: git worktree add failed: $path" >&2
        if wtn_registered "$repo" "$path"; then
            # The add got as far as registering (e.g. killed by the timeout
            # mid-checkout): keep worktree and branch together for review.
            echo "worktree-new: left registered worktree $path on $branch in place" >&2
            return 1
        fi
        wtn_unclaim "$path"
        if [[ "$created" == 1 ]] && ! wtn_checked_out_elsewhere "$repo" "$branch" "$path"; then
            git -C "$repo" update-ref -d "refs/heads/$branch" "$start" >&2 2>/dev/null
        fi
        return 1
    fi
    printf '%s\n' "$path"
}

# wtn_free_gb — free GiB on the volume holding the worktree root, or rc 1 when
# it cannot be measured. DISK_MAGICIAN_FREE_GB_OVERRIDE is the deterministic
# test hook (unparseable value exercises the unmeasurable path).
wtn_free_gb() {
    local raw avail p
    if [[ -n "${DISK_MAGICIAN_FREE_GB_OVERRIDE:-}" ]]; then
        raw="$DISK_MAGICIAN_FREE_GB_OVERRIDE"
        [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
        printf '%s\n' "${raw%%.*}"
        return 0
    fi
    for p in "${STANDARD_WORKTREE_ROOT:-}" /System/Volumes/Data /; do
        [[ -n "$p" && -d "$p" ]] || continue
        avail="$(df -kP "$p" 2>/dev/null | awk 'NR==2{print $4}')"
        [[ "$avail" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$((avail / 1024 / 1024))"
        return 0
    done
    return 1
}

# wtn_admit <path> <repo> — admission gate, run before wtn_create so a
# refusal never creates a directory or a branch. First `diskm admit --class
# worktrees` per the caller contract (lib/admit_caller.sh; estimate
# WORKTREE_ADMIT_EST_GB, default 2). Admit is observe-only until D2 is
# recorded, so the legacy floor below stays as the live backstop: warn below
# WORKTREE_ADMIT_WARN_GB (default 25), refuse with rc 75 below
# WORKTREE_ADMIT_MIN_GB (default 10; 0 disables the refusal). Unmeasurable
# free space fails OPEN — the gate must not block work because it cannot read
# df. All output goes to stderr; stdout stays exactly the path.
wtn_admit() {
    local warn="${WORKTREE_ADMIT_WARN_GB:-25}" min="${WORKTREE_ADMIT_MIN_GB:-10}" free
    local est="${WORKTREE_ADMIT_EST_GB:-2}"
    [[ "$est" =~ ^[0-9]+(\.[0-9]+)?$ ]] || est=2
    if ! declare -F admit_gate >/dev/null; then
        echo "admission_degraded:caller admit missing" >&2
    elif ! admit_gate worktrees "$est" "worktree-new:$(wtn_repo_name "$2")" "$1" worktree-new; then
        echo "worktree-new: disk admission refused: reuse an existing worktree" >&2
        return 75
    fi
    [[ "$warn" =~ ^[0-9]+$ ]] || warn=25
    [[ "$min" =~ ^[0-9]+$ ]] || min=10
    if ! free="$(wtn_free_gb)"; then
        echo "worktree-new: free-space unmeasurable; proceeding" >&2
        return 0
    fi
    if [[ "$min" != 0 ]] && (( free < min )); then
        echo "worktree-new: disk low ($free GiB free): reuse an existing worktree" >&2
        echo "disk-admission: refused class=worktrees rc=75" >&2
        return 75
    fi
    if (( free < warn )); then
        echo "worktree-new: low disk ($free GiB free)" >&2
    fi
    return 0
}

# wtn_reuse <repo> <branch> <base> — reuse only a proven, idle, dead/released
# same-repository worktree. Any missing or incomplete guard falls back to fresh.
wtn_reuse_path_is_canonical() {
    local repo="$1" candidate="$2" file="$3" expected_path resolved_candidate resolved_expected expected_lease
    path_is_under_standard_root "$candidate" || return 1
    expected_path="$(standard_worktree_path "$(wtn_repo_name "$repo")" "$(basename -- "$candidate")")" || return 1
    resolved_candidate="$(_layout_resolve "$candidate")" || return 1
    resolved_expected="$(_layout_resolve "$expected_path")" || return 1
    [[ "$resolved_candidate" == "$resolved_expected" ]] || return 1
    expected_lease="$(lease_path_for "$candidate")" || return 1
    [[ "$file" == "$expected_lease" ]]
}

# Return 0 when another linked worktree owns <branch>, 1 when none does, and
# 2 when Git could not enumerate worktrees. Use at the branch-delete boundary
# after the candidate has detached.
wtn_branch_is_checked_out() {
    local repo="$1" branch="$2" worktrees line
    worktrees="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || return 2
    while IFS= read -r line; do
        [[ "$line" == "branch refs/heads/$branch" ]] && return 0
    done <<<"$worktrees"
    return 1
}


wtn_reuse() {
    local repo="$1" branch="$2" base="$3" base_tip file candidate old tip lease_hash owner state verdict remote_tip admin_id admin_birth checkout_dev checkout_ino
    wtn_branch_exists "$repo" "$branch" && return 1
    wtn_remote_branch_exists "$repo" "$branch" && return 1
    base_tip="$(git -C "$repo" rev-parse -q --verify "$base^{commit}" 2>/dev/null)" || return 1
    declare -F lease_claim_reuse >/dev/null && declare -F worktree_is_recently_active_minutes >/dev/null &&
        declare -F artifact_removal_verdict >/dev/null || return 1
    [[ "$(artifact_removal_verdict --self-test 2>/dev/null)" == complete ]] || return 1
    for file in "$(lease_dir)"/*.json; do
        [[ -f "$file" ]] || continue
        # Bind all eligibility checks to the exact lease read before owner
        # liveness is evaluated; the claim rechecks this hash under the lock.
        lease_hash="$(python3 - "$file" <<'PY'
import hashlib,sys
try: print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
except OSError: sys.exit(1)
PY
)" || continue
        [[ "$(_lease_get "$file" repo)" == "$repo" ]] || continue
        candidate="$(_lease_get "$file" path)"
        old="$(_lease_get "$file" branch)"
        admin_id="$(_lease_get "$file" admin_id)"
        admin_birth="$(_lease_get "$file" admin_birth_epoch)"
        checkout_dev="$(_lease_get "$file" checkout_dev)"
        checkout_ino="$(_lease_get "$file" checkout_ino)"
        [[ -n "$candidate" && -n "$old" && -d "$candidate" && "$old" != "$branch" ]] || continue
        # Only recycle leases created under the canonical same-repository
        # worktree directory, and only when the lease filename is the one
        # derived from that exact checkout path.
        wtn_reuse_path_is_canonical "$repo" "$candidate" "$file" || continue
        # A path can be removed and recreated while its old lease survives.
        # Bind eligibility to both the worktree admin dir and checkout inode.
        lease_matches_incarnation "$file" || continue
        [[ "$(wtn_main_repo "$candidate")" == "$repo" ]] || continue
        state="$(lease_owner_state "$file")"
        [[ "$state" == dead || "$state" == released ]] || continue
        worktree_is_recently_active_minutes "$candidate" 120 && continue
        [[ "$(git -C "$candidate" symbolic-ref -q --short HEAD 2>/dev/null)" == "$old" ]] || continue
        wtn_registered "$repo" "$candidate" || continue
        tip="$(git -C "$repo" rev-parse -q --verify "refs/heads/$old^{commit}" 2>/dev/null)" || continue
        git -C "$repo" merge-base --is-ancestor "$tip" origin/main 2>/dev/null || {
            remote_tip="$(wtn_timeout 30 git -C "$repo" ls-remote origin "refs/heads/$old" 2>/dev/null | awk 'NR==1{print $1}')"
            [[ -n "$remote_tip" && "$remote_tip" == "$tip" ]] || continue
        }
        verdict="$(artifact_removal_verdict "$candidate" 2>/dev/null)"
        [[ "$verdict" == remove ]] || continue
        owner="$(lease_resolve_owner)"
        lease_claim_reuse "$file" "$lease_hash" "$old" "$tip" "$owner" \
            "$repo" "$candidate" "$admin_id" "$admin_birth" "$checkout_dev" "$checkout_ino" || continue
        if ! wtn_reuse_path_is_canonical "$repo" "$candidate" "$file" || ! lease_matches_incarnation "$file"; then
            lease_restore_reuse_claim "$file" || lease_mark_reuse_incomplete "$file"
            continue
        fi
        # Claim first, then repeat the final content/removal verdict.
        verdict="$(artifact_removal_verdict "$candidate" 2>/dev/null)"
        if [[ "$verdict" != remove ]]; then lease_restore_reuse_claim "$file"; continue; fi
        if ! git -C "$candidate" switch --detach "$tip" >&2; then
            lease_restore_reuse_claim "$file" || lease_mark_reuse_incomplete "$file"
            continue
        fi
        # Verify the exact checkout incarnation and detached tip after Git
        # has switched the worktree; neither should be accepted from a stale
        # pre-switch observation.
        if ! lease_matches_incarnation "$file" ||
            [[ "$(git -C "$candidate" rev-parse -q --verify HEAD 2>/dev/null)" != "$tip" ]]; then
            git -C "$candidate" switch --no-overwrite-ignore "$old" >&2 || lease_mark_reuse_incomplete "$file"
            lease_restore_reuse_claim "$file" || lease_mark_reuse_incomplete "$file"
            continue
        fi
        if [[ -n "${DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF:-}" ]]; then
            "$DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF" "$repo" "$old" "$candidate" >&2 || true
        fi
        # update-ref does not know whether another worktree has checked out
        # this branch. Preserve and park the candidate if it is now occupied.
        if wtn_branch_is_checked_out "$repo" "$old"; then
            lease_mark_reuse_incomplete "$file"
            continue
        else
            local checkout_rc=$?
            if [[ "$checkout_rc" != 1 ]]; then
                lease_mark_reuse_incomplete "$file"
                continue
            fi
        fi
        # Last C14 check after any external work at the branch-delete boundary.
        if ! lease_matches_incarnation "$file" ||
            [[ "$(git -C "$candidate" rev-parse -q --verify HEAD 2>/dev/null)" != "$tip" ]] ||
            [[ "$(artifact_removal_verdict "$candidate" 2>/dev/null)" != remove ]]; then
            git -C "$candidate" switch --no-overwrite-ignore "$old" >&2 || lease_mark_reuse_incomplete "$file"
            lease_restore_reuse_claim "$file" || lease_mark_reuse_incomplete "$file"
            continue
        fi
        if ! git -C "$repo" update-ref -d "refs/heads/$old" "$tip"; then
            git -C "$candidate" switch --no-overwrite-ignore "$old" >&2 || lease_mark_reuse_incomplete "$file"
            lease_restore_reuse_claim "$file" || lease_mark_reuse_incomplete "$file"
            continue
        fi
        if [[ -n "${DISK_MAGICIAN_TEST_RECREATE_OLD_REF_AFTER_DELETE:-}" ]]; then
            "$DISK_MAGICIAN_TEST_RECREATE_OLD_REF_AFTER_DELETE" "$repo" "$old" "$tip" >&2 || true
        fi
        local switch_rc=0
        if [[ -n "${DISK_MAGICIAN_TEST_FAIL_AFTER_REF_DELETE:-}" ]]; then switch_rc=1
        else
            if [[ -n "${DISK_MAGICIAN_TEST_BEFORE_BRANCH_SWITCH:-}" ]]; then
                "$DISK_MAGICIAN_TEST_BEFORE_BRANCH_SWITCH" "$repo" "$old" "$candidate" "$branch" "$base" >&2 || true
            fi
            git -C "$candidate" checkout -b "$branch" --no-track --no-overwrite-ignore "$base" >&2 || switch_rc=$?
        fi
        if [[ "$switch_rc" == 0 && -n "${DISK_MAGICIAN_TEST_AFTER_BRANCH_SWITCH:-}" ]]; then
            "$DISK_MAGICIAN_TEST_AFTER_BRANCH_SWITCH" "$repo" "$old" "$candidate" "$branch" "$base" >&2 || true
        fi
        local lease_rc=0
        if [[ -n "${DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE:-}" ]]; then lease_rc=1
        elif [[ "$switch_rc" == 0 ]]; then
            lease_write "$candidate" "$repo" "$branch" worktree-new >/dev/null 2>&1 || lease_rc=$?
        fi
        if [[ "$switch_rc" == 0 && "$lease_rc" == 0 ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        # Restore is create-only: a concurrent ref is never overwritten.
        if git -C "$repo" show-ref -q --verify "refs/heads/$old"; then
            lease_mark_reuse_incomplete "$file"
            continue
        fi
        if ! git -C "$repo" update-ref "refs/heads/$old" "$tip" 0000000000000000000000000000000000000000 ||
            ! git -C "$candidate" switch --no-overwrite-ignore "$old" >&2; then
            lease_mark_reuse_incomplete "$file"
            continue
        fi
        if [[ "$switch_rc" == 0 ]] && ! git -C "$repo" update-ref -d "refs/heads/$branch" "$base_tip"; then
            # The branch moved or another worktree claimed it during recovery.
            echo "worktree-new: could not remove failed new branch $branch at $base_tip" >&2
            lease_mark_reuse_incomplete "$file"
            continue
        fi
        if ! lease_restore_reuse_claim "$file"; then
            lease_mark_reuse_incomplete "$file"
        fi
    done
    return 1
}

wtn_main() {
    local repo_arg="" branch="" base="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base="${2:-}"; shift 2 || return 1 ;;
            --base=*) base="${1#--base=}"; shift ;;
            --name) name="${2:-}"; shift 2 || return 1 ;;
            --name=*) name="${1#--name=}"; shift ;;
            -h|--help)
                echo "usage: diskm worktree-new <repo-path> <branch> [--base <ref>] [--name <name>]" >&2
                return 0 ;;
            *)
                if [[ -z "$repo_arg" ]]; then repo_arg="$1"
                elif [[ -z "$branch" ]]; then branch="$1"
                else echo "worktree-new: unexpected argument: $1" >&2; return 1
                fi
                shift ;;
        esac
    done
    if [[ -z "$repo_arg" || -z "$branch" ]]; then
        echo "usage: diskm worktree-new <repo-path> <branch> [--base <ref>] [--name <name>]" >&2
        return 1
    fi
    local repo path
    repo="$(wtn_main_repo "$repo_arg")" || { echo "worktree-new: not a git repo: $repo_arg" >&2; return 1; }
    [[ -n "$name" ]] || name="${branch//\//-}"
    if [[ -n "$base" ]] && wtn_branch_exists "$repo" "$branch"; then
        echo "worktree-new: --base not applicable: branch $branch already exists" >&2
        return 1
    fi
    path="$(standard_worktree_path "$(wtn_repo_name "$repo")" "$name")" || { echo "worktree-new: bad name: $name" >&2; return 1; }
    [[ -n "$base" ]] || base="$(wtn_default_base "$repo")"
    if wtn_reuse "$repo" "$branch" "$base"; then return 0; fi
    wtn_admit "$path" "$repo" || return $?
    WTN_ADD_RC=1
    wtn_create "$repo" "$branch" "$path" "$base" || return "$WTN_ADD_RC"
    # Record the owner lease; a failure is logged but never blocks creation
    # (stdout must stay exactly the path).
    if declare -F lease_write >/dev/null 2>&1; then
        lease_write "$path" "$repo" "$branch" "worktree-new" >/dev/null 2>&1 ||
            echo "worktree-new: lease write failed: $path" >&2
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wtn_main "$@"
    exit $?
fi

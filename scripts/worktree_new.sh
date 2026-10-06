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

# wtn_unclaim <repo> <path> — undo a failed add at <path>, a dir this call
# created with mkdir: drop only the admin entries whose gitdir points at it
# (never a repo-wide prune), then the dir itself.
wtn_unclaim() {
    local repo="$1" path="$2" common real g
    common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    real="$(CDPATH= cd -- "$path" >/dev/null 2>&1 && pwd -P)" || real="$path"
    if [[ -n "$common" && -d "$common/worktrees" ]]; then
        for g in "$common"/worktrees/*/gitdir; do
            [[ -f "$g" && "$(cat "$g")" == "$real/.git" ]] || continue
            g="${g%/gitdir}"
            [[ -n "$g" && "$g" == "$common"/worktrees/?* ]] && rm -rf -- "$g"
        done
    fi
    [[ -n "$path" && "$path" == /?*/?* ]] && rm -rf -- "$path"
}

# wtn_create <repo> <branch> <path> <base> [new] — worktree add, git output to
# stderr, ${WTN_ADD_TIMEOUT:-30} s cap; prints <path> on success. Existing
# local branch: checked out as is. Branch only on origin: local branch
# tracking origin/<branch>. Otherwise: new untracked branch from <base>.
# With "new", the branch must be created by this call: an existing local or
# origin branch, or losing the atomic create, is a lost race (rc 3).
# <path> is claimed with an atomic mkdir first (rc 2 if it already exists),
# and a new branch is created atomically by this call before the add (rc 3 if
# someone else created it first), so a concurrent call never cleans up a
# worktree or branch it did not create. On failure, removes this call's
# path/admin entry, and its own new branch only if still at the start commit
# and not checked out by another worktree.
wtn_create() {
    local repo="$1" branch="$2" path="$3" base="$4" need_new="${5:-}" created=0 start=""
    mkdir -p "$(dirname "$path")" || return 1
    if ! mkdir "$path" 2>/dev/null; then
        echo "worktree-new: target exists: $path" >&2
        [[ -e "$path" || -L "$path" ]] && return 2
        return 1
    fi
    if [[ "$need_new" == new ]] &&
        { wtn_branch_exists "$repo" "$branch" || wtn_remote_branch_exists "$repo" "$branch"; }; then
        echo "worktree-new: branch already exists: $branch" >&2
        wtn_unclaim "$repo" "$path"
        return 3
    fi
    if [[ "$need_new" == new ]] || ! wtn_branch_exists "$repo" "$branch"; then
        local track=--no-track from="$base"
        if wtn_remote_branch_exists "$repo" "$branch"; then track=--track; from="origin/$branch"; fi
        start="$(git -C "$repo" rev-parse -q --verify "$from^{commit}")" &&
            git -C "$repo" branch "$track" "$branch" "$from" >&2 && created=1
        if [[ "$created" != 1 ]]; then
            echo "worktree-new: could not create branch $branch" >&2
            wtn_unclaim "$repo" "$path"
            wtn_branch_exists "$repo" "$branch" && return 3
            return 1
        fi
    fi
    if ! wtn_timeout "${WTN_ADD_TIMEOUT:-30}" git -C "$repo" worktree add "$path" "$branch" >&2; then
        echo "worktree-new: git worktree add failed: $path" >&2
        wtn_unclaim "$repo" "$path"
        if [[ "$created" == 1 ]] && ! wtn_checked_out_elsewhere "$repo" "$branch" "$path"; then
            git -C "$repo" update-ref -d "refs/heads/$branch" "$start" >&2 2>/dev/null
        fi
        return 1
    fi
    printf '%s\n' "$path"
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
    wtn_create "$repo" "$branch" "$path" "$base" || return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wtn_main "$@"
    exit $?
fi

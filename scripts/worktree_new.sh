#!/usr/bin/env bash
# worktree_new.sh — `diskm worktree-new` (spec D2): create a git worktree at
# $STANDARD_WORKTREE_ROOT/<repo>/<name> and print its absolute path.
#
#   worktree_new.sh <repo-path> <branch> [--base <ref>] [--name <name>]
#
# stdout is exactly the path; all git output goes to stderr. Never fetches.
# Sourced by worktree_create_hook.sh for the shared wtn_* functions.

_WTN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/layout_standard.sh
source "$_WTN_DIR/lib/layout_standard.sh"

# wtn_main_repo <path> — top level of the MAIN checkout (maps a path inside a
# linked worktree back to its main repo via --git-common-dir).
wtn_main_repo() {
    local common
    common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [[ -n "$common" ]] || return 1
    dirname "$common"
}

# wtn_default_base <repo> — origin/HEAD, else HEAD.
wtn_default_base() {
    if git -C "$1" rev-parse -q --verify 'origin/HEAD^{commit}' >/dev/null 2>&1; then
        echo origin/HEAD
    else
        echo HEAD
    fi
}

wtn_branch_exists() { git -C "$1" show-ref -q --verify "refs/heads/$2"; }

# wtn_timeout <secs> <cmd...> — timeout/gtimeout, else perl alarm.
wtn_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
    fi
}

# wtn_create <repo> <branch> <path> <base> — worktree add (existing branch:
# no -b), git output to stderr, 30 s cap; prints <path> on success.
wtn_create() {
    local repo="$1" branch="$2" path="$3" base="$4"
    if [[ -e "$path" ]]; then
        echo "worktree-new: target exists: $path" >&2
        return 1
    fi
    mkdir -p "$(dirname "$path")" || return 1
    if wtn_branch_exists "$repo" "$branch"; then
        wtn_timeout 30 git -C "$repo" worktree add "$path" "$branch" >&2 || return 1
    else
        wtn_timeout 30 git -C "$repo" worktree add -b "$branch" "$path" "$base" >&2 || return 1
    fi
    printf '%s\n' "$path"
}

wtn_main() {
    local repo_arg="" branch="" base="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base="${2:-}"; shift 2 || return 1 ;;
            --name) name="${2:-}"; shift 2 || return 1 ;;
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
    path="$(standard_worktree_path "$(basename "$repo")" "$name")" || { echo "worktree-new: bad name: $name" >&2; return 1; }
    [[ -n "$base" ]] || base="$(wtn_default_base "$repo")"
    wtn_create "$repo" "$branch" "$path" "$base"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wtn_main "$@"
    exit $?
fi

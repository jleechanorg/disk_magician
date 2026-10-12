#!/usr/bin/env bash
# artifact_verdict.sh — C14 artifact_removal_verdict (spec §7.2), sourced.
# This part holds repository discovery and the per-repository content checks;
# the verdict keeps every path and the self-test reports `incomplete` until the
# remaining C14 rules land, so removal_activation_ok stays blocked.

_AV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_AV_DIR/worktree_ignored.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$_AV_DIR/../worktree_remove_hook.sh" # has_hidden_state

# c14_discover_repos <root>: print every repository under <root> (itself
# included), NUL-terminated and absolute: a dir holding a `.git` dir or file,
# or a bare repo (HEAD + objects/ + refs/). No -prune, so ignored dirs are
# walked too. rc 1 when the walk is incomplete or a path escapes <root>.
c14_discover_repos() {
    local root p d done=
    root="$(cd "$1" 2>/dev/null && pwd -P)" && [[ "$root" == /* ]] || return 1
    # The OK sentinel can never be a find path, which starts with "/".
    while IFS= read -r -d '' p; do
        [[ "$p" == OK ]] && { done=1; continue; }
        [[ "$p" == "$root"/* ]] || return 1
        d="${p%/*}"
        if [[ "${p##*/}" == .git ]]; then
            printf '%s\0' "$d"
        # A bare repo; git's own internals (.git/modules, .git/worktrees) are
        # covered through the repository that owns them.
        elif [[ -f "$p" && -d "$d/objects" && -d "$d/refs" && "/$d/" != */.git/* ]]; then
            printf '%s\0' "$d"
        fi
    done < <(find "$root" \( -name .git -o -name HEAD \) -print0 2>/dev/null && printf 'OK\0')
    [[ -n "$done" ]]
}

# c14_repo_content_ok <repo>: print `ok` (rc 0) or `kept:<reason>` (rc 1).
# Caller git env is dropped, and git must resolve <repo> itself: a broken
# .git (no HEAD, empty dir) makes git walk up to an ancestor repository.
c14_repo_content_ok() (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    local r=$1 st flags
    case "$(git -C "$r" rev-parse --is-bare-repository 2>/dev/null)" in
        true) [[ "$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" == "$r" ]] && { echo ok; return 0; } ;;
        false) [[ "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" == "$r" ]] ;;
        *) false ;;
    esac || { echo kept:check-failed; return 1; }
    if ! st="$(git -C "$r" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" ||
        ! flags="$(git -C "$r" ls-files -v 2>/dev/null)"; then
        echo kept:check-failed; return 1
    fi
    # Tracked or submodule changes, untracked files, or hidden index flags.
    if [[ -n "$st" ]] || grep -q '^[a-zS]' <<<"$flags"; then
        echo kept:dirty; return 1
    fi
    has_hidden_state "$r" && { echo kept:secret-like; return 1; }
    has_ignored_user_data "$r" && { echo kept:ignored-data; return 1; }
    echo ok
)

# c14_repos_ok <root> [--outer-certificate <receipt>]: discovery plus the
# content checks of every repository found; prints `ok` or the first kept
# reason. The certificate is accepted for advice_own_copy_ok; unused here.
c14_repos_ok() {
    local r v done=
    while IFS= read -r -d '' r; do
        [[ "$r" == OK ]] && { done=1; continue; }
        v="$(c14_repo_content_ok "$r")" || { echo "$v"; return 1; }
    done < <(c14_discover_repos "$1" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 1; }
    echo ok
}

# artifact_removal_verdict <path> [...] | --self-test
artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    echo kept:check-failed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    artifact_removal_verdict "$@"
fi

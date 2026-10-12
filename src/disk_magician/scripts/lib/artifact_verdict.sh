#!/usr/bin/env bash
# artifact_verdict.sh — C14 artifact_removal_verdict (spec §7.2), sourced.
# Discovery and per-repository content checks; the verdict keeps every path and
# the self-test is `incomplete` until the rest of C14 lands (activation blocked).

_AV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_AV_DIR/worktree_ignored.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$_AV_DIR/../worktree_remove_hook.sh" # has_hidden_state

# c14_discover_repos <root>: print every repository under <root> (itself
# included), NUL-terminated and absolute: a dir holding a `.git` dir or file,
# or a bare repo (HEAD + objects/ + refs/). No -prune, so ignored dirs are
# walked too. rc 1 when the walk is incomplete or a path escapes <root>; the
# OK sentinel can never be a find path, which starts with "/".
c14_discover_repos() {
    local root p d done=
    root="$(cd "$1" 2>/dev/null && pwd -P)" && [[ "$root" == /* ]] || return 1
    while IFS= read -r -d '' p; do
        [[ "$p" == OK ]] && { done=1; continue; }
        [[ "$p" == "$root"/* ]] || return 1
        d="${p%/*}"
        if [[ "${p##*/}" == .git ]]; then
            printf '%s\0' "$d"
        # A bare repo; git internals (.git/modules, .git/worktrees) go with their owner.
        elif [[ -f "$p" && -d "$d/objects" && -d "$d/refs" && "/$d/" != */.git/* ]]; then
            printf '%s\0' "$d"
        fi
    done < <(find "$root" \( -name .git -o -name HEAD \) -print0 2>/dev/null && printf 'OK\0')
    [[ -n "$done" ]]
}

# c14_repo_content_ok <repo>: print `ok` (rc 0) or `kept:<reason>` (rc 1).
# Git env dropped; git must resolve <repo> itself, not an ancestor (broken .git).
c14_repo_content_ok() (
    local r=$1 st flags && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
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

# c14_repo_pushed_ok <repo> [<root>]: independent repo (linked worktree: kept for now): all
# commits in the live ls-remote set of remotes outside <root> (default <repo>), no
# unreachable object, .git = lease git_meta.
c14_repo_pushed_ok() (
    local r=$1 root=${2:-$1} gd kv out adv have unp v
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    gd="$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" &&
        [[ "$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "$gd" ]] ||
        { echo kept:check-failed; return 1; }
    while IFS= read -r -d '' kv; do
        out="$(python3 "$_AV_DIR/../c14_probe.py" lsremote "${kv#*$'\n'}" "$root")" || { echo kept:remote-unverified; return 1; }
        adv+="$out"$'\n'
    done < <(git -C "$r" config -z --get-regexp '^remote\..*\.url$' 2>/dev/null)
    # Advertised SHAs present locally become negative tips.
    have="$(cut -f1 <<<"$adv" | git -C "$r" cat-file --batch-check='%(objectname)' 2>/dev/null | grep -v ' missing$' | sed 's/^/^/')"
    unp="$(git -C "$r" rev-list --all --reflog --stdin -n1 <<<"$have" 2>/dev/null)" || { echo kept:check-failed; return 1; }
    [[ -z "$unp" ]] || { echo kept:not-pushed; return 1; }
    out="$(git -C "$r" fsck --connectivity-only --unreachable --no-reflogs --no-progress 2>/dev/null)" ||
        { echo kept:check-failed; return 1; }
    grep -q '^unreachable ' <<<"$out" && { echo kept:unreachable-object; return 1; }
    v="$(python3 "$_AV_DIR/../c14_probe.py" gitmeta "$gd" "$(lease_path_for "$r" 2>/dev/null)")"
    echo "${v:-kept:check-failed}"
    [[ "$v" == ok ]]
)

# c14_repos_ok <root> [--outer-certificate <receipt>]: content and remote checks on every
# repository found; `ok` or the first kept reason. Certificate unused here.
c14_repos_ok() {
    local r v done=
    while IFS= read -r -d '' r; do
        [[ "$r" == OK ]] && { done=1; continue; }
        v="$(c14_repo_content_ok "$r")" || { echo "$v"; return 1; }
        v="$(c14_repo_pushed_ok "$r" "$1")" || { echo "$v"; return 1; }
    done < <(c14_discover_repos "$1" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 1; }
    echo ok
}

# artifact_removal_verdict <path> [...] | --self-test
artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    echo kept:check-failed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then artifact_removal_verdict "$@"; fi

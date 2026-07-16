#!/usr/bin/env bash
# worktree_repo_discovery.sh — shared repo-discovery logic for worktree
# hygiene/cleanup scripts. Source this file, then call:
#
#   discover_worktree_repos "$CLAUDE_WORKTREE_REPOS_OVERRIDE"
#
# Echoes newline-separated, deduped, absolute-ish repo paths. If the
# override arg is non-empty (comma/space separated), it is split and
# returned as-is (no auto-discovery). Otherwise auto-discovers main repos
# that have registered worktrees under:
#   $HOME/.ao/data/worktrees
#   $HOME/.gemini/antigravity/worktrees
#   $HOME/projects/*/.claude/worktrees
# plus always includes $HOME/projects/worldarchitect.ai as a base repo.
#
# Not meant to be executed directly.

discover_worktree_repos() {
    local override="${1:-}"

    if [[ -n "$override" ]]; then
        echo "$override" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
        return 0
    fi

    local discovered_repos_str="$HOME/projects/worldarchitect.ai"

    _dwr_find_repos_from_worktrees() {
        local search_dir="$1"
        [[ -d "$search_dir" ]] || return 0
        while IFS= read -r git_file; do
            local gitdir_line
            gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
            if [[ -n "$gitdir_line" ]]; then
                local git_dir main_repo
                git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                main_repo="${git_dir%/.git/worktrees/*}"
                if [[ -d "$main_repo" ]]; then
                    discovered_repos_str="${discovered_repos_str} ${main_repo}"
                fi
            fi
        done < <(find "$search_dir" -type f -name ".git" 2>/dev/null)
    }

    _dwr_find_repos_from_worktrees "$HOME/.ao/data/worktrees"
    _dwr_find_repos_from_worktrees "$HOME/.gemini/antigravity/worktrees"

    if [[ -d "$HOME/projects" ]]; then
        for repo_dir in "$HOME/projects"/*; do
            [[ -d "$repo_dir" ]] || continue
            local claude_wt_dir="$repo_dir/.claude/worktrees"
            [[ -d "$claude_wt_dir" ]] || continue
            _dwr_find_repos_from_worktrees "$claude_wt_dir"
        done
    fi

    if [[ -n "$discovered_repos_str" ]]; then
        echo "$discovered_repos_str" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u
    fi

    unset -f _dwr_find_repos_from_worktrees
}

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
#   $HOME/.worktrees                     (flat multi-tool worktree pool —
#                                          jleechan-4dtg/jleechan-dqiz: 26 GiB,
#                                          ~70 entries spanning many main
#                                          repos, e.g. agent-orchestrator,
#                                          .hermes, dark-factory, disk_magician
#                                          itself — not just worldarchitect.ai)
#   $HOME/projects/*/.claude/worktrees
# plus always includes $HOME/projects/worldarchitect.ai as a base repo.
#
# NOTE: this only widens which MAIN REPOS get scanned — it does not change
# how a worktree is judged eligible for removal. Each discovered repo still
# goes through worktree_hygiene.sh's own IDENTIFY -> TRIAGE -> CLASSIFY gate
# (age, uncommitted/untracked status, push preservation, PR coverage,
# ahead-count) via `git -C <repo> worktree list --porcelain`, regardless of
# where on disk that repo's worktrees physically live.
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
                # Require an actual .git dir at main_repo, not just any
                # directory. Found live 2026-07-22 (jleechan-dqiz): a stale
                # worktree-pointer file under ~/.worktrees referenced a main
                # repo (~/.openclaw) whose .git had since been removed --
                # the plain `-d "$main_repo"` check let it through, and the
                # downstream `git worktree list` on a non-repo produced an
                # empty result that crashed worktree_hygiene.sh's main loop
                # under bash 3.2 (see that script for the matching fix).
                if [[ -d "$main_repo/.git" ]]; then
                    discovered_repos_str="${discovered_repos_str} ${main_repo}"
                fi
            fi
        done < <(find "$search_dir" -type f -name ".git" 2>/dev/null)
    }

    _dwr_find_repos_from_worktrees "$HOME/.ao/data/worktrees"
    _dwr_find_repos_from_worktrees "$HOME/.gemini/antigravity/worktrees"
    _dwr_find_repos_from_worktrees "$HOME/.worktrees"

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

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
#   $HOME/project_worldaiclaw            (multi-agent worktree clusters)
#   $HOME/wc-wt                          (review/advice/recut worktree clusters)
# plus includes $HOME/projects/worldarchitect.ai and
# $HOME/project_worldaiclaw/worldai_claw if they have a valid .git.
#
# Bounded discovery: searches prune .git dirs and node_modules, and cap depth
# to prevent multi-minute stalls traversing large worktree checkouts. An 8s
# timeout per search root prevents hanging unattended cleanup runs.
#
# Not meant to be executed directly.

discover_worktree_repos() {
    local override="${1:-}"

    if [[ -n "$override" ]]; then
        echo "$override" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
        return 0
    fi

    local discovered_repos_str="$HOME/projects/worldarchitect.ai"

    _dwr_add_main_repo() {
        local repo="$1"
        [[ -z "$repo" ]] && return 0
        # Require an actual .git dir at main_repo, not just any
        # directory. Found live 2026-07-22 (jleechan-dqiz): a stale
        # worktree-pointer file under ~/.worktrees referenced a main
        # repo (~/.openclaw) whose .git had since been removed --
        # the plain `-d "$main_repo"` check let it through, and the
        # downstream `git worktree list` on a non-repo produced an
        # empty result that crashed worktree_hygiene.sh's main loop
        # under bash 3.2.
        if [[ -d "$repo/.git" ]]; then
            discovered_repos_str="${discovered_repos_str} ${repo}"
        fi
    }

    _dwr_find_repos_from_worktrees() {
        local search_dir="$1"
        local max_depth="${2:-3}"
        [[ -d "$search_dir" ]] || return 0

        local find_cmd=(find "$search_dir" -maxdepth "$max_depth" \( -name .git -type d -o -name node_modules \) -prune -o -type f -name ".git" -print)

        local git_files=""
        if command -v python3 >/dev/null 2>&1; then
            git_files=$(python3 -c '
import sys, subprocess
cmd = sys.argv[1:]
try:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=8)
    sys.stdout.write(p.stdout)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout)
    sys.stderr.write(f"worktree_repo_discovery: timeout searching root {cmd[1]}\n")
except Exception:
    pass
' "${find_cmd[@]}" 2>/dev/null || true)
        elif command -v timeout >/dev/null 2>&1; then
            git_files=$(timeout 8 "${find_cmd[@]}" 2>/dev/null || true)
        else
            git_files=$("${find_cmd[@]}" 2>/dev/null || true)
        fi

        while IFS= read -r git_file; do
            [[ -n "$git_file" ]] || continue
            local gitdir_line
            gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
            if [[ -n "$gitdir_line" ]]; then
                local git_dir main_repo
                git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                main_repo="${git_dir%/.git/worktrees/*}"
                _dwr_add_main_repo "$main_repo"
            fi
        done <<<"$git_files"
    }

    _dwr_find_repos_from_worktrees "$HOME/.ao/data/worktrees" 3
    _dwr_find_repos_from_worktrees "$HOME/.gemini/antigravity/worktrees" 3
    _dwr_find_repos_from_worktrees "$HOME/.worktrees" 3

    if [[ -d "$HOME/projects" ]]; then
        for repo_dir in "$HOME/projects"/*; do
            [[ -d "$repo_dir" ]] || continue
            local claude_wt_dir="$repo_dir/.claude/worktrees"
            [[ -d "$claude_wt_dir" ]] || continue
            _dwr_find_repos_from_worktrees "$claude_wt_dir" 2
        done
    fi

    # Include worldai_claw if its main repo .git is present
    _dwr_add_main_repo "$HOME/project_worldaiclaw/worldai_claw"

    # Auto-discover worktrees under sibling agent roots
    _dwr_find_repos_from_worktrees "$HOME/project_worldaiclaw" 3
    _dwr_find_repos_from_worktrees "$HOME/wc-wt" 3

    if [[ -n "$discovered_repos_str" ]]; then
        echo "$discovered_repos_str" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u
    fi

    unset -f _dwr_find_repos_from_worktrees
    unset -f _dwr_add_main_repo
}

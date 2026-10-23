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
#   $HOME/project_agento, project_worldai_frontend, worldarchitect.ai.worktrees,
#   $HOME/llm_wiki.worktrees             (see dwr_agent_roots)
# plus includes $HOME/projects/worldarchitect.ai and
# $HOME/project_worldaiclaw/worldai_claw if they have a valid .git.
#
# Bounded discovery: searches prune .git dirs and node_modules, and cap depth
# to prevent multi-minute stalls traversing large worktree checkouts. An 8s
# timeout per search root prevents hanging unattended cleanup runs.
#
# Not meant to be executed directly.

# Agent worktree roots outside the standard root. Single list shared by repo
# discovery and cleanup_worktrees.sh's repo-local match, so a root added here is
# both discovered and swept (all existing gates still apply).
dwr_agent_roots() {
    printf '%s\n' "$HOME/project_worldaiclaw" "$HOME/wc-wt" "$HOME/project_agento" \
        "$HOME/project_worldai_frontend" "$HOME/worldarchitect.ai.worktrees" "$HOME/llm_wiki.worktrees"
}

dwr_in_agent_root() {
    local p="$1" r
    while IFS= read -r r; do
        [[ "$p" == "$r/"* ]] && return 0
    done < <(dwr_agent_roots)
    return 1
}

discover_worktree_repos() {
    local override="${1:-}"

    if [[ -n "$override" ]]; then
        echo "$override" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
        return 0
    fi

    local discovered_repos_str=""

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

        local timeout_sec="${WORKTREE_DISCOVERY_TIMEOUT:-8}"
        local git_files=""
        if command -v python3 >/dev/null 2>&1; then
            local raw_files
            raw_files=$(python3 -c '
import sys, subprocess
t = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=t)
    sys.stdout.buffer.write(p.stdout or b"")
except subprocess.TimeoutExpired as exc:
    out = exc.stdout or b""
    if isinstance(out, str):
        out = out.encode("utf-8", errors="replace")
    if out:
        last_nl = out.rfind(b"\n")
        if last_nl != -1:
            sys.stdout.buffer.write(out[:last_nl + 1])
    sys.stderr.write(f"worktree_repo_discovery: timeout searching root {cmd[1]}\n")
    sys.stderr.flush()
except Exception:
    pass
' "$timeout_sec" "${find_cmd[@]}"; printf '__DWR_RC__%d' "$?")
            raw_files="${raw_files%__DWR_RC__*}"
            git_files="$raw_files"
        elif command -v timeout >/dev/null 2>&1; then
            local timeout_rc=0
            local raw_files
            raw_files=$(timeout "$timeout_sec" "${find_cmd[@]}" 2>/dev/null; printf '__DWR_RC__%d' "$?")
            timeout_rc="${raw_files##*__DWR_RC__}"
            raw_files="${raw_files%__DWR_RC__*}"
            if [[ $timeout_rc -eq 124 || $timeout_rc -eq 137 || $timeout_rc -eq 143 ]]; then
                echo "worktree_repo_discovery: timeout searching root $search_dir" >&2
            fi
            git_files="$raw_files"
        elif command -v gtimeout >/dev/null 2>&1; then
            local timeout_rc=0
            local raw_files
            raw_files=$(gtimeout "$timeout_sec" "${find_cmd[@]}" 2>/dev/null; printf '__DWR_RC__%d' "$?")
            timeout_rc="${raw_files##*__DWR_RC__}"
            raw_files="${raw_files%__DWR_RC__*}"
            if [[ $timeout_rc -eq 124 || $timeout_rc -eq 137 || $timeout_rc -eq 143 ]]; then
                echo "worktree_repo_discovery: timeout searching root $search_dir" >&2
            fi
            git_files="$raw_files"
        else
            echo "worktree_repo_discovery: skipping root $search_dir (no timeout runner available)" >&2
            return 0
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
        done < <(printf '%s' "$git_files")
    }

    _dwr_find_repos_from_worktrees "$HOME/.ao/data/worktrees" 3
    _dwr_find_repos_from_worktrees "$HOME/.gemini/antigravity/worktrees" 3
    local std_wt_root="${STANDARD_WORKTREE_ROOT:-$HOME/.worktrees}"
    _dwr_find_repos_from_worktrees "$std_wt_root" 3
    if [[ "$std_wt_root" != "$HOME/.worktrees" ]]; then
        _dwr_find_repos_from_worktrees "$HOME/.worktrees" 3
    fi

    if [[ -d "$HOME/projects" ]]; then
        for repo_dir in "$HOME/projects"/*; do
            [[ -d "$repo_dir" ]] || continue
            local claude_wt_dir="$repo_dir/.claude/worktrees"
            [[ -d "$claude_wt_dir" ]] || continue
            _dwr_find_repos_from_worktrees "$claude_wt_dir" 2
        done
    fi

    # Include base repos if their main repo .git is present
    _dwr_add_main_repo "$HOME/projects/worldarchitect.ai"
    _dwr_add_main_repo "$HOME/project_worldaiclaw/worldai_claw"

    # Auto-discover worktrees under sibling agent roots
    local agent_root
    while IFS= read -r agent_root; do
        _dwr_find_repos_from_worktrees "$agent_root" 3
    done < <(dwr_agent_roots)

    if [[ -n "$discovered_repos_str" ]]; then
        echo "$discovered_repos_str" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u
    fi

    unset -f _dwr_find_repos_from_worktrees
    unset -f _dwr_add_main_repo
}

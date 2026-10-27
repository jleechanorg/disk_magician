#!/usr/bin/env bash
# worktree_repo_discovery.sh — shared repo-discovery logic for worktree
# hygiene/cleanup scripts. Source this file, then call:
#
#   discover_worktree_repos [override] [roots-manifest] [strict]
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
    local roots_manifest="${2:-${WORKTREE_DISCOVERY_ROOTS_FILE:-}}"
    local strict="${3:-${WORKTREE_DISCOVERY_STRICT:-0}}"
    local discovery_failed=0
    local machine_report=0
    [[ -n "$roots_manifest" || "$strict" == "1" ]] && machine_report=1

    _dwr_json_string() {
        local value="$1"
        value=${value//\\/\\\\}
        value=${value//\"/\\\"}
        value=${value//$'\n'/\\n}
        value=${value//$'\r'/\\r}
        printf '"%s"' "$value"
    }

    _dwr_report_root() {
        local root="$1" status="$2" found="${3:-0}" detail="${4:-}"
        if [[ "$machine_report" == 1 ]]; then
            printf '{"event":"root_complete","root":%s,"status":%s,"found":%s,"detail":%s}\n' \
                "$(_dwr_json_string "$root")" "$(_dwr_json_string "$status")" \
                "$found" "$(_dwr_json_string "$detail")" >&2
            [[ "$status" == "ok" ]] || discovery_failed=1
        fi
    }

    if [[ -n "$override" ]]; then
        echo "$override" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
        unset -f _dwr_report_root _dwr_json_string
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
        if [[ -d "$repo/.git" || -f "$repo/.git" ]]; then
            discovered_repos_str="${discovered_repos_str} ${repo}"
        fi
    }

    _dwr_find_repos_from_worktrees() {
        local search_dir="$1"
        local max_depth="${2:-3}"
        if [[ ! -d "$search_dir" ]]; then
            _dwr_report_root "$search_dir" missing 0 "root is not a directory"
            return 0
        fi
        if [[ ! -r "$search_dir" || ! -x "$search_dir" ]]; then
            _dwr_report_root "$search_dir" unreadable 0 "root is not readable/searchable"
            return 0
        fi

        local find_cmd
        if [[ "$machine_report" == 1 ]]; then
            find_cmd=(find "$search_dir" -maxdepth "$max_depth" \( -name node_modules -type d -prune \) -o \( -name .git \( -type d -o -type f \) -print -prune \))
        else
            find_cmd=(find "$search_dir" -maxdepth "$max_depth" \( -name .git -type d -o -name node_modules \) -prune -o -type f -name .git -print)
        fi

        local timeout_sec="${WORKTREE_DISCOVERY_TIMEOUT:-8}"
        local git_files="" root_status="ok" root_detail=""
        if command -v python3 >/dev/null 2>&1; then
            local raw_files
            raw_files=$(DWR_MACHINE="$machine_report" python3 -c '
import sys, subprocess, os
t = float(sys.argv[1])
cmd = sys.argv[2:]
machine = os.environ.get("DWR_MACHINE") == "1"
try:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=t)
    sys.stdout.buffer.write(p.stdout or b"")
    if p.returncode:
        sys.stdout.write("\n__DWR_STATUS__error")
except subprocess.TimeoutExpired as exc:
    out = exc.stdout or b""
    if isinstance(out, str):
        out = out.encode("utf-8", errors="replace")
    if out:
        last_nl = out.rfind(b"\n")
        if last_nl != -1:
            sys.stdout.buffer.write(out[:last_nl + 1])
    if not machine:
        sys.stderr.write(f"worktree_repo_discovery: timeout searching root {cmd[1]}\n")
        sys.stderr.flush()
    sys.stdout.write("\n__DWR_STATUS__timeout")
except Exception:
    sys.stdout.write("\n__DWR_STATUS__error")
' "$timeout_sec" "${find_cmd[@]}"; printf '__DWR_RC__%d' "$?")
            if [[ "$raw_files" == *$'\n__DWR_STATUS__timeout'* ]]; then
                root_status=timeout
                root_detail="search exceeded ${timeout_sec}s"
                raw_files="${raw_files%$'\n__DWR_STATUS__timeout'}"
            elif [[ "$raw_files" == *$'\n__DWR_STATUS__error'* ]]; then
                root_status=error
                root_detail="search runner failed"
                raw_files="${raw_files%$'\n__DWR_STATUS__error'}"
            fi
            raw_files="${raw_files%__DWR_RC__*}"
            git_files="$raw_files"
        elif command -v timeout >/dev/null 2>&1; then
            local timeout_rc=0
            local raw_files
            raw_files=$(timeout "$timeout_sec" "${find_cmd[@]}" 2>/dev/null; printf '__DWR_RC__%d' "$?")
            timeout_rc="${raw_files##*__DWR_RC__}"
            raw_files="${raw_files%__DWR_RC__*}"
            if [[ $timeout_rc -eq 124 || $timeout_rc -eq 137 || $timeout_rc -eq 143 ]]; then
                [[ "$machine_report" == 1 ]] || echo "worktree_repo_discovery: timeout searching root $search_dir" >&2
                root_status=timeout
                root_detail="search exceeded ${timeout_sec}s"
            elif [[ $timeout_rc -ne 0 ]]; then
                root_status=error
                root_detail="find exited $timeout_rc"
            fi
            git_files="$raw_files"
        elif command -v gtimeout >/dev/null 2>&1; then
            local timeout_rc=0
            local raw_files
            raw_files=$(gtimeout "$timeout_sec" "${find_cmd[@]}" 2>/dev/null; printf '__DWR_RC__%d' "$?")
            timeout_rc="${raw_files##*__DWR_RC__}"
            raw_files="${raw_files%__DWR_RC__*}"
            if [[ $timeout_rc -eq 124 || $timeout_rc -eq 137 || $timeout_rc -eq 143 ]]; then
                [[ "$machine_report" == 1 ]] || echo "worktree_repo_discovery: timeout searching root $search_dir" >&2
                root_status=timeout
                root_detail="search exceeded ${timeout_sec}s"
            elif [[ $timeout_rc -ne 0 ]]; then
                root_status=error
                root_detail="find exited $timeout_rc"
            fi
            git_files="$raw_files"
        else
            [[ "$machine_report" == 1 ]] || echo "worktree_repo_discovery: skipping root $search_dir (no timeout runner available)" >&2
            _dwr_report_root "$search_dir" error 0 "no timeout runner available"
            return 0
        fi

        local found_count=0
        while IFS= read -r git_file; do
            [[ -n "$git_file" ]] || continue
            found_count=$((found_count + 1))
            local gitdir_line
            gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
            if [[ -n "$gitdir_line" ]]; then
                local git_dir main_repo
                git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                if [[ "$git_dir" == */.git/worktrees/* ]]; then
                    main_repo="${git_dir%/.git/worktrees/*}"
                else
                    main_repo="${git_file%/.git}"
                fi
                _dwr_add_main_repo "$main_repo"
            else
                # A real main checkout has a .git directory; a .git file
                # without a worktrees pointer is still a repository root.
                _dwr_add_main_repo "${git_file%/.git}"
            fi
        done < <(printf '%s' "$git_files")
        _dwr_report_root "$search_dir" "$root_status" "$found_count" "$root_detail"
    }

    if [[ -n "$roots_manifest" ]]; then
        if [[ ! -r "$roots_manifest" ]]; then
            _dwr_report_root "$roots_manifest" unreadable 0 "roots manifest is not readable"
        else
            while IFS= read -r scan_root || [[ -n "$scan_root" ]]; do
                [[ -n "$scan_root" && "$scan_root" != \#* ]] || continue
                _dwr_find_repos_from_worktrees "$scan_root" 4
            done < "$roots_manifest"
        fi
        # Explicit manifests are a closed inventory: do not silently add
        # roots outside the caller's declared coverage boundary.
    else
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
    fi
    if [[ -n "$discovered_repos_str" ]]; then
        echo "$discovered_repos_str" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u
    fi

    unset -f _dwr_find_repos_from_worktrees
    unset -f _dwr_add_main_repo
    unset -f _dwr_report_root _dwr_json_string
    if [[ "$strict" == "1" && "$discovery_failed" -eq 1 ]]; then
        return 1
    fi
    return 0
}

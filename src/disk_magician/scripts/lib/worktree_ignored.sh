#!/usr/bin/env bash
# Shared by cleanup_worktrees.sh and worktree_remove_hook.sh (sourced, not run).

# has_ignored_user_data <wt>: rc 0 when the worktree holds gitignored files that
# are not known-rebuildable (local DBs, data dirs, scratch notes, evidence), or
# the probe fails/times out (fail closed). Removal uses --force --force, so these
# would be lost; every worktree removal path must use this shared classification.
has_ignored_user_data() {
    local out entry comp rest ok t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    # shellcheck disable=SC2086
    out="$($t git -C "$1" ls-files -o -i --exclude-standard --directory 2>/dev/null)" || return 0
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        ok=false
        rest="${entry%/}"
        # Allowed when ANY path component is a known rebuildable dir/file, so
        # nested cache contents (.ruff_cache/0.16.1, venv/.../CACHEDIR.TAG) pass.
        while [[ -n "$rest" ]]; do
            comp="${rest##*/}"
            case "$comp" in
                # Unambiguous tool-generated names only; generic names such as
                # build, dist, env, target, coverage and .cache can hold hand-made
                # files, so they count as user data and preserve the worktree.
                node_modules|venv|.venv|__pycache__|.pytest_cache|.mypy_cache|.ruff_cache|\
                .next|.turbo|.gradle|.tox|.eggs|htmlcov|venv.bak.*|test-results)
                    ok=true; break ;;
                # File-oriented patterns are rebuildable only when the matched
                # path is not a directory containing user data.
                *.pyc|.DS_Store|.coverage|*.tsbuildinfo|*.egg-info|.testmondata)
                    [[ ! -d "$1/$rest" ]] && { ok=true; break; }
                    ;;
            esac
            [[ "$rest" == */* ]] || break
            rest="${rest%/*}"
        done
        [[ "$ok" == true ]] || return 0
    done <<<"$out"
    return 1
}

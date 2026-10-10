#!/usr/bin/env bash
# Shared by cleanup_worktrees.sh and worktree_remove_hook.sh (sourced, not run).

# has_ignored_user_data <wt>: rc 0 when the worktree holds gitignored files that
# are not known-rebuildable (local DBs, data dirs, scratch notes, evidence), or
# the probe fails/times out (fail closed). Removal uses --force --force, so these
# would be lost; used by the pushed-branch path where the worktree is the only
# place such files can live.
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
                # Unambiguous tool-generated DIRECTORY names only; generic
                # names such as build, dist, env, target, coverage and .cache
                # can hold hand-made files, so they count as user data and
                # preserve the worktree.
                node_modules|venv|.venv|__pycache__|.pytest_cache|.mypy_cache|.ruff_cache|\
                .next|.turbo|.gradle|.tox|.eggs|*.egg-info|htmlcov|venv.bak.*|\
                test-results|.testmondata)
                    ok=true; break ;;
                # File-oriented patterns count as rebuildable only when the
                # matching path really is a file. A DIRECTORY named foo.pyc/
                # or .coverage/ is hand-made data and preserves the worktree.
                *.pyc|.DS_Store|.coverage|*.tsbuildinfo)
                    if [[ ! -d "$1/$rest" ]]; then ok=true; break; fi
                    ;;
            esac
            [[ "$rest" == */* ]] || break
            rest="${rest%/*}"
        done
        [[ "$ok" == true ]] || return 0
    done <<<"$out"
    return 1
}

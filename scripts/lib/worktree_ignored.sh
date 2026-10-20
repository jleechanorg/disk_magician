#!/usr/bin/env bash
# Shared by cleanup_worktrees.sh, worktree_remove_hook.sh and cleanup_codex_documents.sh (sourced, not run).

# ignored_entry_rebuildable <wt> <entry>: rc 0 when the ignored entry is a
# known-rebuildable path (any component matches the allowlist below; with a
# non-empty third arg, only the leaf component is considered).
ignored_entry_rebuildable() {
    local rest="${2%/}" comp
    # Allowed when ANY path component is a known rebuildable dir/file, so
    # nested cache contents (.ruff_cache/0.16.1, venv/.../CACHEDIR.TAG) pass.
    while [[ -n "$rest" ]]; do
        comp="${rest##*/}"
        case "$comp" in
            # Unambiguous tool-generated names only; generic names such as
            # build, dist, env, target, coverage and .cache can hold hand-made
            # files, so they count as user data and preserve the worktree.
            node_modules|venv|.venv|__pycache__|.pytest_cache|.mypy_cache|.ruff_cache|\
            .next|.turbo|.gradle|.tox|.eggs|*.egg-info|htmlcov|venv.bak.*|test-results|\
            .beads|.husky|.doctor|.codex-worktrees|Pods|xcuserdata|xcshareddata|project.xcworkspace|.expo|dist-export|\
            .venv_bootstrap.lock|.superpowers|.dark-factory|.tmp|logs|.br_recovery)
                return 0 ;;
            # File-oriented patterns are rebuildable only when the matched
            # path is not a directory containing user data.
            *.pyc|.DS_Store|.coverage|*.tsbuildinfo|.testmondata|.claude.json*|*.log|*.sqlite-shm|*.sqlite-wal|\
            .playwright-cli-*|coverage.json|coverage*.xml|test_output*.txt|pytest*.xml)
                [[ ! -d "$1/$rest" ]] && return 0
                ;;
        esac
        [[ -z "${3:-}" && "$rest" == */* ]] || break
        rest="${rest%/*}"
    done
    return 1
}

# has_ignored_user_data <wt>: rc 0 when the worktree holds gitignored files that
# are not known-rebuildable (local DBs, data dirs, scratch notes, evidence), or
# the probe fails/times out (fail closed). Removal uses --force --force, so these
# would be lost; every worktree removal path must use this shared classification.
has_ignored_user_data() {
    local out entry t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    local git_args=(-C "$1")
    if [[ -f "$1/.git" ]]; then
        local gd_line gd_target
        gd_line=$(grep '^gitdir: ' "$1/.git" 2>/dev/null || true)
        gd_target=$(echo "$gd_line" | cut -d' ' -f2-)
        if [[ -n "$gd_target" && ! -e "$gd_target" ]]; then
            local mr="${gd_target%/.git/worktrees/*}"
            if [[ -d "$mr/.git" ]]; then
                git_args=(--git-dir="$mr/.git" --work-tree="$1")
            else
                if [[ -f "$1/.gitignore" ]]; then
                    if /usr/bin/find "$1" -maxdepth 3 \( -name '.env*' -o -name '*credentials*' -o -name '*secrets*' \) -print -quit 2>/dev/null | grep -q .; then
                        return 0
                    fi
                fi
                return 1
            fi
        fi
    fi
    # shellcheck disable=SC2086
    out="$($t git "${git_args[@]}" ls-files -o -i --exclude-standard --directory 2>/dev/null)" || return 0
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        ignored_entry_rebuildable "$1" "$entry" || return 0
    done <<<"$out"
    return 1
}

# has_hidden_state <wt>: rc 0 when state `git status` cannot see exists
# (assume-unchanged/skip-worktree entries, ignored secret-like files) or a
# probe fails/times out (fail closed).
has_hidden_state() {
    local out flags t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    flags="$(git -C "$1" ls-files -v 2>/dev/null)" || return 0
    grep -q '^[a-zS]' <<<"$flags" && return 0
    # shellcheck disable=SC2086
    out="$($t git -C "$1" ls-files -o -i --exclude-standard -- \
        ':(icase).env*' ':(icase)*/.env*' ':(icase)*.pem' ':(icase)*.key' \
        ':(icase)*.p12' ':(icase)*.pfx' ':(icase)id_rsa*' ':(icase)*/id_rsa*' \
        ':(icase)id_ed25519*' ':(icase)*/id_ed25519*' ':(icase)id_ecdsa*' ':(icase)*/id_ecdsa*' \
        ':(icase)id_dsa*' ':(icase)*/id_dsa*' \
        ':(icase).npmrc' ':(icase)*/.npmrc' ':(icase).netrc' ':(icase)*/.netrc' \
        ':(icase)*credentials*' ':(icase)secrets*' ':(icase)*/secrets*' 2>/dev/null)" || return 0
    # Python bytecode, compiler intermediates (.o, .dia, .swiftdeps), public CA bundles, test logs,
    # and non-secret template/example files (.env.example) are not user secrets.
    out="$(grep -Ev '(^|/)__pycache__/|\.pyc$|\.o$|\.dia$|\.swiftdeps$|\.swiftconstvalues$|\.example$|\.template$|\.sample$|\.test$|\.dist$|(^|/)test-results/.*\.log$' <<<"$out" || true)"
    [[ -n "$out" ]]
}

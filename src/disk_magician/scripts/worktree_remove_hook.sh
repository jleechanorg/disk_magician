#!/usr/bin/env bash
# worktree_remove_hook.sh — `diskm worktree-remove-hook`, Claude Code
# WorktreeRemove hook (spec D3b).
#
# stdin: {"worktree_path": ...}. Removes the worktree (never --force) only if
# it is a registered linked worktree under $STANDARD_WORKTREE_ROOT, clean
# (tracked, untracked, no hidden state or non-rebuildable ignored data), and its
# HEAD is contained in some refs/remotes/*. Then deletes its worktree-* branch
# with `git branch -d` unless checked out elsewhere. Anything else: leave in place,
# log, exit 0 (fail closed).

_WRH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/worktree_new.sh
source "$_WRH_DIR/worktree_new.sh"

wrh_log() {
    local dir="$HOME/.disk_magician_state"
    mkdir -p "$dir" 2>/dev/null &&
        printf '%s worktree-remove-hook: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$dir/worktree_guard.log"
    return 0
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
    [[ -n "$out" ]]
}

# has_ignored_user_data <wt>: rc 0 when the worktree holds gitignored files that
# are not known-rebuildable (local DBs, data dirs, scratch notes, evidence), or
# the probe fails/times out (fail closed).
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
                .next|.turbo|.gradle|.tox|.eggs|*.egg-info|htmlcov|*.pyc|.DS_Store|\
                venv.bak.*|test-results|.testmondata|.coverage|*.tsbuildinfo)
                    ok=true; break ;;
            esac
            [[ "$rest" == */* ]] || break
            rest="${rest%/*}"
        done
        [[ "$ok" == true ]] || return 0
    done <<<"$out"
    return 1
}

wrh_main() {
    local p main real branch
    p="$(python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("worktree_path")
except Exception:
    sys.exit(1)
if not isinstance(v, str) or not v.startswith("/") or "\n" in v:
    sys.exit(1)
print(v)
' 2>/dev/null)" || { wrh_log "kept: malformed stdin"; return 0; }

    path_is_under_standard_root "$p" || { wrh_log "kept $p: outside $STANDARD_WORKTREE_ROOT"; return 0; }
    real="$(cd "$p" 2>/dev/null && pwd -P)" || { wrh_log "kept $p: not a directory"; return 0; }
    main="$(wtn_main_repo "$real")" || { wrh_log "kept $p: not a git repo"; return 0; }
    # Registered linked worktree: listed by the main repo, and not the main
    # checkout (first entry).
    if ! git -C "$main" worktree list --porcelain 2>/dev/null |
        awk -v want="worktree $real" 'NR > 1 && $0 == want { f = 1 } END { exit !f }'; then
        wrh_log "kept $p: not a registered linked worktree"
        return 0
    fi
    local status
    status="$(git -C "$real" status --porcelain --untracked-files=all 2>/dev/null)" ||
        { wrh_log "kept $p: git status failed"; return 0; }
    [[ -z "$status" ]] || { wrh_log "kept $p: dirty"; return 0; }
    if has_hidden_state "$real"; then
        wrh_log "kept $p: hidden state or ignored secret-like file(s) present"
        return 0
    fi
    if has_ignored_user_data "$real"; then
        wrh_log "kept $p: non-rebuildable ignored user data present"
        return 0
    fi
    [[ -n "$(git -C "$real" for-each-ref --count=1 --contains HEAD refs/remotes 2>/dev/null)" ]] ||
        { wrh_log "kept $p: HEAD not contained in any remote-tracking ref"; return 0; }

    branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
    git -C "$main" worktree remove "$real" >&2 || { wrh_log "kept $p: git worktree remove failed"; return 0; }
    wrh_log "removed $p"
    if [[ "$branch" == worktree-* ]]; then
        if git -C "$main" worktree list --porcelain | grep -qxF "branch refs/heads/$branch"; then
            wrh_log "kept branch $branch: checked out elsewhere"
        elif git -C "$main" branch -d "$branch" >&2; then
            wrh_log "deleted branch $branch"
        else
            wrh_log "kept branch $branch: git branch -d refused"
        fi
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wrh_main
    exit 0
fi

#!/usr/bin/env bash
# Shared by cleanup_worktrees.sh, worktree_remove_hook.sh and cleanup_codex_documents.sh (sourced, not run).

# ignored_entry_rebuildable <wt> <entry>: rc 0 when the ignored entry is a
# known-rebuildable path (any component matches the allowlist below; with a
# non-empty third arg, only the leaf component is considered).
ignored_entry_rebuildable() {
    local rest="${2%/}" comp
    case "$rest" in
        .husky/_|.husky/_/*|*/.husky/_|*/.husky/_/*|.beads/redirect) return 0 ;;
    esac
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
                return 0 ;;
            # File-oriented patterns are rebuildable only when the matched
            # path is not a directory containing user data.
            *.pyc|.DS_Store|.coverage|*.tsbuildinfo|*.egg-info|.testmondata|.xcode.env.local)
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
    # shellcheck disable=SC2086
    out="$($t git -C "$1" ls-files -o -i --exclude-standard --directory 2>/dev/null)" || return 0
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        ignored_entry_rebuildable "$1" "$entry" || return 0
    done <<<"$out"
    return 1
}

_WI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _wi_nonsecret_scan <dir>: rc 1 = no secret-like name anywhere under <dir>;
# rc 0 = a secret-like name exists, or the scan could not be completed (fail closed).
# Used only when <dir> is not a git repository, where there is no index in which
# anything can be hidden and `git ls-files` therefore has no answer to give.
_wi_nonsecret_scan() {
    local dir="$1" out rc=0 t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    # shellcheck disable=SC2086
    # -type f matters: the git path this mirrors only ever lists files, but `find`
    # would also match DIRECTORY names such as hermes/skills/google-credentials-fallback,
    # which is not secret material. Generated build caches are pruned for the same
    # reason (jest transform caches are named after the module they compile).
    out="$($t find "$dir" -maxdepth 6 \
        \( -name node_modules -o -name __pycache__ -o -name jest_rs -o -name .cache \
        -o -name .pytest_cache -o -name .mypy_cache -o -name coverage -o -name dist \
        -o -name build -o -name DerivedData \) -prune -o \
        -type f \( -iname '.env*' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' \
        -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname 'id_dsa*' \
        -o -iname '.npmrc' -o -iname '.netrc' -o -iname '*credentials*' -o -iname 'secrets*' \) \
        -print 2>/dev/null)" || return 0
    # A timeout kill gives empty output and a non-zero rc above; an empty result set
    # is the only conclusive "nothing found".
    [[ -n "$out" ]] || return 1
    local res
    res="$(printf '%s\n' "$out" | sed "s|^$dir/||" | python3 -I "$_WI_DIR/../c14_probe.py" any-secret 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 1 && "$res" == none ]] && return 1
    return 0
}

# _wi_has_flagged_index_entries <wt> <ls_files_v_output>: rc 0 when any entry has
# assume-unchanged ([a-z]) or a skip-worktree (S) flag that could hide local
# edits on disk. Sparse-checkout exclusions written by slim-worktrees set S on
# paths removed from the working tree while info/sparse-checkout is present;
# those absent paths cannot hold uncaptured local edits.
_wi_has_flagged_index_entries() {
    local wt="$1" flags="$2" sp rc=0
    grep -q '^[a-z]' <<<"$flags" && return 0
    grep -q '^S' <<<"$flags" || return 1
    sp="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/sparse-checkout 2>/dev/null)" || return 0
    [[ -s "$sp" ]] || return 0
    python3 -I -c 'import os,sys; wt=sys.argv[1]; sys.exit(0 if any(l.startswith("S ") and (l[2:3]==chr(34) or os.path.lexists(os.path.join(wt, l[2:].splitlines()[0]))) for l in sys.stdin) else 1)' "$wt" <<<"$flags" 2>/dev/null || rc=$?
    [[ "$rc" -eq 1 ]] && return 1
    return 0
}

# has_hidden_state <wt>: rc 0 when state `git status` cannot see exists
# (assume-unchanged/skip-worktree entries, ignored secret-like files) or a
# probe fails/times out (fail closed).
has_hidden_state() {
    local out flags t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    # Not a git repository: there is no index, so nothing can be assume-unchanged or
    # skip-worktree. Fall through to a filesystem secret-like scan instead of
    # fail-closing, which made every non-repo scratch directory permanently
    # unremovable (13 of 14 largest /tmp scratch dirs on 2026-10-29). An unreadable
    # or timed-out scan still fails closed.
    if ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
        _wi_nonsecret_scan "$1"
        return $?
    fi
    flags="$(git -C "$1" ls-files -v 2>/dev/null)" || return 0
    _wi_has_flagged_index_entries "$1" "$flags" && return 0
    # shellcheck disable=SC2086
    out="$($t git -C "$1" ls-files -o -i --exclude-standard -- \
        ':(icase).env*' ':(icase)*/.env*' ':(icase)*.pem' ':(icase)*.key' \
        ':(icase)*.p12' ':(icase)*.pfx' ':(icase)*.pem.map' ':(icase)*.key.map' ':(icase)*.p12.map' ':(icase)*.pfx.map' ':(icase)id_rsa*' ':(icase)*/id_rsa*' \
        ':(icase)id_ed25519*' ':(icase)*/id_ed25519*' ':(icase)id_ecdsa*' ':(icase)*/id_ecdsa*' \
        ':(icase)id_dsa*' ':(icase)*/id_dsa*' \
        ':(icase).npmrc' ':(icase)*/.npmrc' ':(icase).netrc' ':(icase)*/.netrc' \
        ':(icase)*credentials*' ':(icase)secrets*' ':(icase)*/secrets*' 2>/dev/null)" || return 0
    # Every hit counts unless c14_probe.py exempt_name (the single owner of the rule) clears it.
    # Only an explicit rc 1 + "none" means no secret; any other result (secret found, probe
    # crash, missing module, bad input) is hidden state.
    local res rc=0
    res="$(printf '%s\n' "$out" | python3 -I "$_WI_DIR/../c14_probe.py" any-secret 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 1 && "$res" == none ]] && return 1
    return 0
}

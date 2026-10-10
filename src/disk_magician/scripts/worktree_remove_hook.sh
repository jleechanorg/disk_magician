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
source "$_WRH_DIR/lib/worktree_recency.sh"
source "$_WRH_DIR/lib/ao_worktree_config.sh"

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


wrh_live_cwd_reason() {
    local target=$1 out err rc=0 line pid= seen=0 live=0 path path_seen=0 caller_chain=" $$ $PPID " walk=$$ parent steps=0 caller_pid=$PPID
    WRH_LIVE_CWD_REASON=
    command -v lsof >/dev/null 2>&1 || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    if [[ ${DISK_MAGICIAN_LIFECYCLE_PARENT_PID:-} =~ ^[0-9]+$ ]]; then
        ancestry=$(ps -Ao pid=,ppid= 2>/dev/null | awk -v start="$$" -v wanted="$DISK_MAGICIAN_LIFECYCLE_PARENT_PID" '
            { parent[$1] = $2 }
            END { p = start; out = ""; for (i = 0; i < 8; i++) {
                p = parent[p]; if (p == "" || p == "0") exit 1
                out = out " " p
                if (p == wanted) { print out; exit 0 }
            } exit 1 }')
        if [[ -n $ancestry ]]; then caller_chain=" $$ $ancestry "; caller_pid=$DISK_MAGICIAN_LIFECYCLE_PARENT_PID
        else caller_chain=" $$ $PPID "; fi
    fi
    err=$(mktemp -t disk-magician-worktree-remove.XXXXXX 2>/dev/null) || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    cd / || { wrh_log "cwd-unknown: cannot change directory"; return; }
    out=$(WRH_LIFECYCLE_CALLER_PID="$caller_pid" WRH_LIFECYCLE_CALLER_CHAIN="$caller_chain" lsof -n -P -d cwd -Fpn 2>"$err") || rc=$?
    [[ ! -s $err ]] || rc=1
    [[ -z $err ]] || { [[ -e $err ]] && rm -f "$err"; }
    [[ $rc == 0 && -n $out ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    while IFS= read -r line; do case $line in
        p*)
            [[ -z $pid || $path_seen == 1 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
            pid=${line#p}; [[ $pid =~ ^[0-9]+$ ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
            path_seen=0 ;;
        n*)
            [[ -n $pid && $path_seen == 0 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
            path=${line#n}; [[ $path == /* ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
            path_seen=1; seen=1
            case " $caller_chain " in *" $pid "*) ;; *) [[ $path != "$target" && $path != "$target"/* ]] || live=1 ;; esac ;;
        *) [[ -z $line ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; } ;;
    esac; done <<<"$out"
    [[ $seen == 1 && $path_seen == 1 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    [[ $live == 1 ]] && WRH_LIVE_CWD_REASON=live-cwd
}
wrh_expand_path() {
    local p=$1
    if [[ $p == "~/"* ]]; then printf '%s\n' "${HOME}/${p:2}"
    elif [[ $p == "~" ]]; then printf '%s\n' "$HOME"
    elif [[ $p == /* ]]; then printf '%s\n' "$p"
    else return 1; fi
}

wrh_ao_skip_reason() {
    local target=$1 config=${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml} lines kind dir root candidate
    [[ -e $config ]] || { [[ -n ${DISK_MAGICIAN_AO_CONFIG+x} ]] && echo ao-config-unreadable; return; }
    lines=$(ao_worktree_dirs "$config") || { echo ao-config-unreadable; return; }
    [[ -n $lines ]] || return 0
    candidate=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null) || { echo ao-config-unreadable; return; }
    while IFS= read -r line; do
        case $line in P\ *|C\ *) dir=${line#? };; *) echo ao-config-unreadable; return;; esac
        [[ -n $dir ]] || { echo ao-config-unreadable; return; }
        root=$(wrh_expand_path "$dir") || { echo ao-config-unreadable; return; }
        root=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root" 2>/dev/null) || { echo ao-config-unreadable; return; }
        [[ $candidate == "$root" || $candidate == "$root/"* ]] && { echo ao-owned; return; }
    done <<<"$lines"
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
    local guard_reason
    wrh_live_cwd_reason "$real"
    guard_reason=$WRH_LIVE_CWD_REASON
    [[ -z "$guard_reason" ]] || { wrh_log "kept $p: $guard_reason"; return 0; }
    guard_reason="$(wrh_ao_skip_reason "$real")"
    [[ -z "$guard_reason" ]] || { wrh_log "kept $p: $guard_reason"; return 0; }
    if worktree_is_recently_active "$real" 7; then
        wrh_log "kept $p: recent-activity"
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

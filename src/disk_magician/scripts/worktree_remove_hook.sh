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
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_WRH_DIR/lib/worktree_ignored.sh"
# Lease bookkeeping is optional: the hook still works without the lease lib,
# it just cannot delete the lease after removing the worktree.
# shellcheck source=scripts/lib/worktree_lease.sh
[[ -f "$_WRH_DIR/lib/worktree_lease.sh" ]] && source "$_WRH_DIR/lib/worktree_lease.sh"

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
    # Python bytecode (e.g. __pycache__/openrouter_credentials.cpython-312.pyc)
    # is rebuildable, not a secret; dependency dirs stay covered.
    out="$(grep -Ev '(^|/)__pycache__/|\.pyc$' <<<"$out" || true)"
    [[ -n "$out" ]]
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
        f*)
            # Standard lsof -F descriptor record (e.g. fcwd). Valid only after a pid.
            [[ -n $pid && $path_seen == 0 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
            ;;
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
    case "$target" in */.ao/data/worktrees/*|*/ao/data/worktrees/*) echo ao-owned; return;; esac
    [[ -e $config ]] || { [[ -n ${DISK_MAGICIAN_AO_CONFIG+x} ]] && echo ao-config-unreadable; return; }
    lines=$(ao_worktree_dirs "$config") || { echo ao-config-unreadable; return; }
    [[ -n $lines ]] || return 0
    candidate=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null) || { echo ao-config-unreadable; return; }
    while IFS= read -r line; do
        case $line in P\ *|C\ *) kind=${line%% *}; dir=${line#? };; *) echo ao-config-unreadable; return;; esac
        [[ -n $dir ]] || { echo ao-config-unreadable; return; }
        root=$(wrh_expand_path "$dir") || { echo ao-config-unreadable; return; }
        root=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root" 2>/dev/null) || { echo ao-config-unreadable; return; }
        if [[ $kind == P && ( $candidate == "$root" || $candidate == "$root/"* ) ]] ||
           [[ $kind == C && ${candidate%/*} == "$root" ]]; then echo ao-owned; return; fi
    done <<<"$lines"
}

# wrh_removal_verdict <real_path> <recency_spec> [pushed_scope]
# Pure verdict: prints "remove" or "kept:<token>" and always returns rc 0.
# It NEVER deletes anything — the caller (wrh_main or the reaper) acts on the
# token. recency_spec is days:N or minutes:N. pushed_scope is all-remotes
# (the hook's historical default), origin, or origin-or-merged-pr (origin
# containment OR a gh-verified merged PR head via worktree_merged_pr.sh;
# fails closed when that library is not loaded). Check order matches the
# historical hook exactly; do not reorder without updating the tests.
wrh_removal_verdict() {
    local real="$1" spec="$2" scope="${3:-all-remotes}"
    local main status branch unit amount
    real="$(cd "$real" 2>/dev/null && pwd -P)" || { printf 'kept:not-a-directory\n'; return 0; }
    main="$(wtn_main_repo "$real")" || { printf 'kept:not-registered\n'; return 0; }
    # Registered linked worktree: listed by the main repo, and not the main
    # checkout (first entry).
    if ! git -C "$main" worktree list --porcelain 2>/dev/null |
        awk -v want="worktree $real" 'NR > 1 && $0 == want { f = 1 } END { exit !f }'; then
        printf 'kept:not-registered\n'
        return 0
    fi
    wrh_live_cwd_reason "$real"
    [[ -z "$WRH_LIVE_CWD_REASON" ]] || { printf 'kept:%s\n' "$WRH_LIVE_CWD_REASON"; return 0; }
    local guard_reason
    guard_reason="$(wrh_ao_skip_reason "$real")"
    [[ -z "$guard_reason" ]] || { printf 'kept:%s\n' "$guard_reason"; return 0; }
    unit="${spec%%:*}"
    amount="${spec#*:}"
    case "$unit" in
        days)
            worktree_is_recently_active "$real" "$amount" && { printf 'kept:recent-activity\n'; return 0; } ;;
        minutes)
            worktree_is_recently_active_minutes "$real" "$amount" && { printf 'kept:recent-activity\n'; return 0; } ;;
        *) printf 'kept:recent-activity\n'; return 0 ;;  # invalid spec fails closed
    esac
    status="$(git -C "$real" status --porcelain --untracked-files=all 2>/dev/null)" ||
        { printf 'kept:git-status-failed\n'; return 0; }
    [[ -z "$status" ]] || { printf 'kept:dirty\n'; return 0; }
    has_hidden_state "$real" && { printf 'kept:hidden-state\n'; return 0; }
    has_ignored_user_data "$real" && { printf 'kept:ignored-data\n'; return 0; }
    case "$scope" in
        all-remotes)
            [[ -n "$(git -C "$real" for-each-ref --count=1 --contains HEAD refs/remotes 2>/dev/null)" ]] ||
                { printf 'kept:not-pushed\n'; return 0; } ;;
        origin)
            [[ -n "$(git -C "$real" for-each-ref --count=1 --contains HEAD refs/remotes/origin 2>/dev/null)" ]] ||
                { printf 'kept:not-pushed\n'; return 0; } ;;
        origin-or-merged-pr)
            if [[ -z "$(git -C "$real" for-each-ref --count=1 --contains HEAD refs/remotes/origin 2>/dev/null)" ]]; then
                if ! declare -F worktree_head_is_merged_pr >/dev/null 2>&1; then
                    printf 'kept:not-pushed\n'; return 0
                fi
                branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
                worktree_head_is_merged_pr "$main" "$branch" "$(git -C "$real" rev-parse HEAD 2>/dev/null)" ||
                    { printf 'kept:not-pushed\n'; return 0; }
            fi ;;
        *) printf 'kept:not-pushed\n'; return 0 ;;
    esac
    printf 'remove\n'
    return 0
}

# wrh_remove_now <real_path> <display_path> [--quarantine <inventory.json>] —
# remove an approved worktree. The historical path remains the default. The
# opt-in quarantine path is intentionally not wired to any production caller.
# rc 0 only when the worktree was removed.
wrh_remove_now() {
    local real="$1" display="$2" main branch result qid
    real="$(cd "$real" 2>/dev/null && pwd -P)" || return 1
    main="$(wtn_main_repo "$real")" || return 1
    branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
    if [[ ${3:-} == --quarantine ]]; then
        [[ $# == 4 && -f $4 ]] || return 1
        result="$(python3 "$_WRH_DIR/worktree_quarantine.py" phase1 "$main" "$real" "$4")" || return 1
        [[ $result == quarantined:* ]] || { wrh_log "kept $display: $result"; return 1; }
        qid="${result#quarantined:}"
        result="$(python3 "$_WRH_DIR/worktree_quarantine.py" phase2 "$qid")" || result=kept:quarantine_partial_kept
        [[ $result == removed ]] || { wrh_log "kept $display: $result"; return 1; }
    else
        [[ $# == 2 ]] || return 1
        git -C "$main" worktree remove "$real" >&2 || return 1
    fi
    wrh_log "removed $display"
    if [[ "$branch" == worktree-* ]]; then
        if git -C "$main" worktree list --porcelain | grep -qxF "branch refs/heads/$branch"; then
            wrh_log "kept branch $branch: checked out elsewhere"
        elif git -C "$main" branch -d "$branch" >&2; then
            wrh_log "deleted branch $branch"
        else
            wrh_log "kept branch $branch: git branch -d refused"
        fi
    fi
    if declare -F lease_path_for >/dev/null 2>&1; then
        rm -f -- "$(lease_path_for "$real")" 2>/dev/null
    fi
    return 0
}

wrh_main() {
    local p main real verdict
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

    verdict="$(wrh_removal_verdict "$real" days:7)"
    case "$verdict" in
        remove) ;;
        kept:not-registered)         wrh_log "kept $p: not a registered linked worktree"; return 0 ;;
        kept:live-cwd)                wrh_log "kept $p: live-cwd"; return 0 ;;
        kept:cwd-unknown)             wrh_log "kept $p: cwd-unknown"; return 0 ;;
        kept:ao-owned)                wrh_log "kept $p: ao-owned"; return 0 ;;
        kept:ao-config-unreadable)    wrh_log "kept $p: ao-config-unreadable"; return 0 ;;
        kept:recent-activity)         wrh_log "kept $p: recent-activity"; return 0 ;;
        kept:git-status-failed)       wrh_log "kept $p: git status failed"; return 0 ;;
        kept:dirty)                   wrh_log "kept $p: dirty"; return 0 ;;
        kept:hidden-state)           wrh_log "kept $p: hidden state or ignored secret-like file(s) present"; return 0 ;;
        kept:ignored-data)            wrh_log "kept $p: non-rebuildable ignored user data present"; return 0 ;;
        kept:not-pushed)              wrh_log "kept $p: HEAD not contained in any remote-tracking ref"; return 0 ;;
        *)                            wrh_log "kept $p: ${verdict#kept:}"; return 0 ;;
    esac

    if ! wrh_remove_now "$real" "$p"; then
        wrh_log "kept $p: git worktree remove failed"
        return 0
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wrh_main
    exit 0
fi

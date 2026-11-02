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
# shellcheck source=scripts/lib/lsof_linux.sh
source "$_WRH_DIR/lib/lsof_linux.sh"
source "$_WRH_DIR/lib/ao_worktree_config.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_WRH_DIR/lib/worktree_ignored.sh"
# shellcheck source=scripts/lib/worktree_restore_receipt.sh
source "$_WRH_DIR/lib/worktree_restore_receipt.sh"
# Lease bookkeeping is optional: the hook still works without the lease lib,
# it just cannot delete the lease after removing the worktree.
# shellcheck source=scripts/lib/worktree_lease.sh
[[ -f "$_WRH_DIR/lib/worktree_lease.sh" ]] && source "$_WRH_DIR/lib/worktree_lease.sh"
declare -F deletion_log_removal >/dev/null || source "$_WRH_DIR/safety_lib.sh"

wrh_log() {
    local dir="$HOME/.disk_magician_state"
    mkdir -p "$dir" 2>/dev/null &&
        printf '%s worktree-remove-hook: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$dir/worktree_guard.log"
    return 0
}

wrh_live_cwd_reason() {
    local target=$1 out err err_text blocks rc=0 line pid= status path seen=0 live=0 caller_chain=" $$ $PPID " walk=$$ parent steps=0 caller_pid=$PPID stderr_status=0
    WRH_LIVE_CWD_REASON=
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
    cd / || { wrh_log "cwd-unknown: cannot change directory"; return; }
    local srv=0
    lsof_scanner_fpn || srv=$?
    [[ $srv != 2 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    if [[ $srv == 0 ]]; then
        # Root scanner gave a complete pid->cwd map (no lsof, no stderr to judge).
        out=$LSOF_SCANNER_OUT
    else
        command -v lsof >/dev/null 2>&1 || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
        err=$(mktemp -t disk-magician-worktree-remove.XXXXXX 2>/dev/null) || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
        # -Fpn keeps the pid so this hook can exclude its own ancestry; the parsing
        # itself is the shared strict parser, never a local reimplementation.
        out=$(WRH_LIFECYCLE_CALLER_PID="$caller_pid" WRH_LIFECYCLE_CALLER_CHAIN="$caller_chain" lsof -n -P -d cwd -Fpn 2>"$err") || rc=$?
        lsof_stderr_byte_status "$err" || stderr_status=$?
        case "$stderr_status" in
            1|2) [[ -e $err ]] && rm -f "$err"; WRH_LIVE_CWD_REASON=cwd-unknown; return ;;
        esac
        # A failed stderr read is NOT an empty stderr: it means the diagnostics are
        # unknown, which must fail closed just like a non-empty read would.
        if ! err_text="$(cat "$err" 2>/dev/null)"; then
            [[ -e $err ]] && rm -f "$err"
            WRH_LIVE_CWD_REASON=cwd-unknown; return
        fi
        [[ -z $err ]] || { [[ -e $err ]] && rm -f "$err"; }
        [[ $rc == 0 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
        lsof_stderr_incomplete "$err_text" && { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    fi
    blocks="$(lsof_cwd_blocks <<<"$out")" || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
    while IFS='|' read -r pid status path; do
        [[ -n $pid ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
        [[ $status == ok ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
        case "$(lsof_cwd_value_verdict "$path")" in
            resolved)
                seen=1
                case " $caller_chain " in *" $pid "*) ;; *) [[ $path != "$target" && $path != "$target"/* ]] || live=1 ;; esac ;;
            ignorable) ;;
            *) WRH_LIVE_CWD_REASON=cwd-unknown; return ;;
        esac
    done <<<"$blocks"
    [[ $seen == 1 ]] || { WRH_LIVE_CWD_REASON=cwd-unknown; return; }
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

# wrh_quarantine_capable — explicit capability contract for callers that must
# know whether this adapter implements `wrh_remove_now ... --quarantine <inv>`.
# The canonical WRH adapter always provides quarantine mode; a consumer must
# ask this function rather than infer support from the body text of
# wrh_remove_now (a partial/older adapter can mention the flag without
# implementing the contract). Returns 0 only when quarantine removal is
# supported; any other adapter shape fails closed.
wrh_quarantine_capable() { return 0; }

# wrh_remove_now <real_path> <display_path> --quarantine <inventory.json>
#   [--deadline-at <monotonic>] — remove an approved worktree. The inventory
# MUST be the receipt produced by a same-target `artifact_removal_verdict`
# (C14) immediately before this call; the quarantine remover re-validates
# identity/locks against that exact receipt. `--deadline-at` is optional and
# forwarded verbatim to the quarantine remover's own cooperative deadline; an
# absent flag preserves today's unbounded behavior. There is no unguarded
# `git worktree remove` fallback. rc 0 only when the worktree was removed.
wrh_remove_now() {
    local real="$1" display="$2" main branch result inv='' deadline='' dkb restore_receipt
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quarantine)
                [[ $# -ge 2 && -n ${2:-} && -f ${2:-} ]] || return 1
                inv="$2"; shift 2 ;;
            --deadline-at)
                [[ $# -ge 2 && -n ${2:-} ]] || return 1
                deadline="$2"; shift 2 ;;
            *) return 1 ;;
        esac
    done
    [[ -n "$inv" ]] || return 1
    real="$(cd "$real" 2>/dev/null && pwd -P)" || return 1
    main="$(wtn_main_repo "$real")" || return 1
    branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
    dkb="$(deletion_size_kb "$real")"
    if [[ ${WRH_RECENCY_SPEC:-days:7} == minutes:* && -z ${DISK_MAGICIAN_WORKTREE_RESTORE_RECEIPTS:-} ]]; then
        wrh_log "kept $display: minute recency override requires durable restore receipt"
        return 1
    fi
    if [[ ${DISK_MAGICIAN_WORKTREE_RESTORE_RECEIPTS+x} == x ]]; then
        restore_receipt="$(worktree_restore_receipt_resolve "$real" "$DISK_MAGICIAN_WORKTREE_RESTORE_RECEIPTS")" || {
            wrh_log "kept $display: durable restore receipt unavailable"
            return 1
        }
        if ! worktree_restore_receipt_matches_live "$real" "$restore_receipt"; then
            wrh_log "kept $display: durable restore receipt no longer matches live ref/head/tree/remote"
            return 1
        fi
    fi
    if [[ -n "$deadline" ]]; then
        result="$(python3 "$_WRH_DIR/worktree_quarantine.py" remove "$main" "$real" "$inv" --deadline-at "$deadline")" || return 1
    else
        result="$(python3 "$_WRH_DIR/worktree_quarantine.py" remove "$main" "$real" "$inv")" || return 1
    fi
    [[ $result == removed:* ]] || { wrh_log "kept $display: $result"; return 1; }
    wrh_log "removed $display"
    deletion_log_removal "$real" "$dkb" remove_worktree "${WRH_RECENCY_SPEC:+recency=$WRH_RECENCY_SPEC}${WRH_REASON:+ reason=$WRH_REASON}"
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

wrh_main() { _lease_lock_scope release _wrh_main "$@"; }
_wrh_main() {
    local p main real verdict inv wrh_c14_verdict min_idle
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

    # Idle-floor override (operator decision 2026-10-20): DISK_MAGICIAN_REMOVE_HOOK_RECENCY=days:N (N>=7)
    # or minutes:N (N>=60). Anything else, including a lower floor, falls back to days:7.
    local recency_spec=days:7 env_spec="${DISK_MAGICIAN_REMOVE_HOOK_RECENCY:-}"
    if [[ "$env_spec" =~ ^days:([0-9]{1,4})$ && "${BASH_REMATCH[1]}" -ge 7 ]] ||
       [[ "$env_spec" =~ ^minutes:([0-9]{1,7})$ && "${BASH_REMATCH[1]}" -ge 60 ]]; then
        recency_spec="$env_spec"
    fi
    if [[ "$recency_spec" != days:7 ]]; then
        # Audit-first: a shorter floor is used only if its record was actually written.
        local sdir="$HOME/.disk_magician_state"
        if ! { mkdir -p "$sdir" && printf '%s worktree-remove-hook: recency override active: %s (%s)\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$recency_spec" "$p" >>"$sdir/worktree_guard.log"; } 2>/dev/null; then
            echo "worktree-remove-hook: cannot record recency override $recency_spec; using days:7" >&2
            recency_spec=days:7
        fi
    fi
    [[ "$recency_spec" == days:* ]] && min_idle=$(( ${recency_spec#days:} * 1440 )) || min_idle=${recency_spec#minutes:}
    WRH_RECENCY_SPEC=$recency_spec
    verdict="$(wrh_removal_verdict "$real" "$recency_spec")"
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

    # Canonical C14-before-removal: the shared WRH entry point produces the
    # same-target inventory receipt and hands exactly it to the quarantine
    # remover. No second verdict, no unguarded git removal.
    declare -F artifact_removal_verdict >/dev/null 2>&1 || { wrh_log "kept $p: C14 unavailable"; return 0; }
    inv="$(mktemp "${TMPDIR:-/tmp}/wrh-c14-inventory.XXXXXX")" || { wrh_log "kept $p: inventory allocation failed"; return 0; }
    lease_registry_mutation_lock_enter || { rm -f -- "$inv" 2>/dev/null; wrh_log "kept $p: lease-busy"; return 0; }
    wrh_c14_verdict="$(artifact_removal_verdict "$real" --min-idle-minutes "$min_idle" --inventory-out "$inv")" || wrh_c14_verdict=kept:check-failed
    if [[ "$wrh_c14_verdict" != remove ]]; then
        rm -f -- "$inv" 2>/dev/null
        lease_registry_mutation_lock_exit || true
        wrh_log "kept $p: ${wrh_c14_verdict#kept:}"
        return 0
    fi
    if ! wrh_remove_now "$real" "$p" --quarantine "$inv"; then
        rm -f -- "$inv" 2>/dev/null
        lease_registry_mutation_lock_exit || true
        wrh_log "kept $p: quarantine remove failed"
        return 0
    fi
    rm -f -- "$inv" 2>/dev/null
    lease_registry_mutation_lock_exit || true
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wrh_main
    exit 0
fi

# shellcheck shell=bash
# degraded_gate.sh — detect a cleanup category that ran "successfully" but
# reclaimed nothing because the cwd safety gate refused every candidate.
#
# Root cause (2026-10-21): on jeff-ubuntu the scheduled 6-tier cleaner reported
#   Categories attempted: 18
#   All attempted categories completed without error.
# with exit status 0 while the host sat at 98% and swap was fully exhausted.
# Every candidate had been refused as `kept:cwd-unknown` (517 unreadable
# readlink records), so the automation looked healthy while doing nothing. A
# run that had eligible candidates and reclaimed zero MUST NOT report success;
# that is the difference between a cleaner and a placebo.

# String a category emits when the cwd gate cannot prove a candidate is idle.
# Matched case-sensitively on the two spellings actually produced by the
# codebase: the C14 verdict (`kept:cwd-unknown`) and the tmp lane's prose form
# (`Preserving (C14 kept:cwd-unknown): <path>`).
DEGRADED_GATE_PATTERN='kept:cwd-unknown'

# gate_refusal_count <log-file> — echoes the number of lines recording a
# cwd-gate refusal. Missing/unreadable file => 0 (never fails the caller).
gate_refusal_count() {
    local file="$1" n
    if [[ -z "$file" || ! -f "$file" ]]; then
        echo 0
        return 0
    fi
    n="$(grep -cF -- "$DEGRADED_GATE_PATTERN" "$file" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

# gate_is_degraded <refusal-count> [threshold] — rc 0 when the count is at or
# above the threshold. Threshold defaults to
# DISK_MAGICIAN_DEGRADED_REFUSALS (itself default 5); 0 disables the gate so an
# operator can mute it without editing code.
gate_is_degraded() {
    local count="${1:-0}" threshold="${2:-${DISK_MAGICIAN_DEGRADED_REFUSALS:-5}}"
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=5
    (( threshold == 0 )) && return 1
    (( count >= threshold ))
}

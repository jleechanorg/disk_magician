# shellcheck shell=bash
# verdict_tally.sh — per-run tally of removal verdicts for the DEGRADED gate
# (bead disk_magician-kub3). A runner opens a tally; every verdict producer
# appends one token (remove | kept:<why> | deferred:<why>); the runner closes it
# and `job_receipt.py tally` decides whether every eligible candidate was
# refused for an unmeasurable-gate reason (cwd-unknown) rather than "nothing to do".
_VT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Documented exit code of a run whose gates refused everything unmeasurably.
DISK_MAGICIAN_DEGRADED_EXIT=4

# vt_record <token>: producer side; a no-op unless a runner opened a tally.
vt_record() {
    [[ -n "${DISK_MAGICIAN_VERDICT_TALLY:-}" ]] || return 0
    printf '%s\n' "$1" >>"$DISK_MAGICIAN_VERDICT_TALLY" 2>/dev/null || true
}

# vt_open: runner side; an unavailable tally degrades to "no tally", never an error.
vt_open() {
    DISK_MAGICIAN_VERDICT_TALLY="$(mktemp "${TMPDIR:-/tmp}/dm-verdict-tally.XXXXXX" 2>/dev/null)" \
        && export DISK_MAGICIAN_VERDICT_TALLY || unset DISK_MAGICIAN_VERDICT_TALLY
}

# vt_close: sets VT_SUMMARY (receipt candidates JSON); rc 4 when DEGRADED.
vt_close() {
    local f="${DISK_MAGICIAN_VERDICT_TALLY:-}" rc=0
    VT_SUMMARY=""
    unset DISK_MAGICIAN_VERDICT_TALLY
    [[ -n "$f" && -f "$f" ]] || return 0
    VT_SUMMARY="$(python3 "$_VT_DIR/../job_receipt.py" tally --file "$f")" || rc=$?
    rm -f "$f"
    [[ "$rc" -eq "$DISK_MAGICIAN_DEGRADED_EXIT" ]] && return "$rc"
    return 0
}

# vt_field <name>: integer field of VT_SUMMARY (0 when absent).
vt_field() {
    local v
    v="$(printf '%s' "${VT_SUMMARY:-}" | sed -n "s/.*\"$1\": \([0-9][0-9]*\).*/\1/p")"
    printf '%s\n' "${v:-0}"
}

# vt_reason: the summary's human reason string.
vt_reason() { printf '%s' "${VT_SUMMARY:-}" | sed -n 's/.*"reason": "\([^"]*\)".*/\1/p'; }

#!/usr/bin/env bash
# test_wrh_quarantine_capability.sh — focused capability-contract test for the
# WRH quarantine API (replaces the transitional function-body probe).
#
# The canonical WRH adapter (scripts/worktree_remove_hook.sh) exports an
# explicit `wrh_quarantine_capable` function. cleanup_codex_documents.sh must
# consume that capability fail-closed, never infer support from the body text
# of `wrh_remove_now`. This test:
#   1. sources the real adapter and asserts the capability is exported and true;
#   2. extracts the real `wrh_quarantine_available` consumer from the sweeper and
#      exercises it across the full adapter-shape matrix:
#        - no adapter                       -> keep (rc 1)
#        - wrh_remove_now only (text match) -> keep (rc 1), no body probe
#        - capability returning false       -> keep (rc 1)
#        - capability returning true        -> available (rc 0)
#        - capability true, body text has no `--quarantine` -> available (rc 0)
#      The last two prove the decision is the capability, not the text.
#
# Nothing destructive runs; no live CLI/cleanup. Isolated HOME/TMPDIR under /tmp.
# Run: bash tests/test_wrh_quarantine_capability.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/scripts/worktree_remove_hook.sh"
SWEEPER="$ROOT/scripts/cleanup_codex_documents.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_ROOT="$(mktemp -d /tmp/disk-magician-wrh-cap.XXXXXX)" || {
    echo "FATAL: could not allocate /tmp fixture root" >&2; exit 2;
}
case "$TMP_ROOT" in
    /tmp/*|/private/tmp/*) ;;
    *) echo "FATAL: fixture root not under /tmp: '$TMP_ROOT'" >&2; exit 2 ;;
esac
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$TMPDIR"

# --- 1. the canonical adapter exports the capability ---------------------
if bash -c 'source "$1" >/dev/null 2>&1; declare -F wrh_quarantine_capable >/dev/null' _ "$ADAPTER"; then
    ok "canonical WRH adapter exports wrh_quarantine_capable"
else
    bad "canonical WRH adapter does not export wrh_quarantine_capable"
fi
if bash -c 'source "$1" >/dev/null 2>&1; wrh_quarantine_capable' _ "$ADAPTER"; then
    ok "wrh_quarantine_capable returns true for the canonical adapter"
else
    bad "wrh_quarantine_capable did not return true"
fi

# --- 2. consume the REAL consumer function from the sweeper --------------
CONSUMER_FN="$(sed -n '/^wrh_quarantine_available() {/,/^}/p' "$SWEEPER")"
if [[ -n "$CONSUMER_FN" ]]; then
    ok "extracted real wrh_quarantine_available from cleanup_codex_documents.sh"
else
    bad "could not extract wrh_quarantine_available from cleanup_codex_documents.sh"
fi

# Run the consumer under an adapter shape and print its rc.
consumer_rc() {
    local setup="$1"
    (
        eval "$setup"
        eval "$CONSUMER_FN"
        wrh_quarantine_available
    ) >/dev/null 2>&1
    echo $?
}

NO_ADAPTER="true"
WRH_TEXT_ONLY="wrh_remove_now() { case \"\${1:-}\" in *--quarantine*) : ;; esac; }"
CAP_FALSE="wrh_remove_now() { :; }; wrh_quarantine_capable() { return 1; }"
CAP_TRUE="wrh_remove_now() { :; }; wrh_quarantine_capable() { return 0; }"
CAP_TRUE_NO_TEXT="wrh_remove_now() { return 1; }; wrh_quarantine_capable() { return 0; }"

check_rc() {
    local label="$1" setup="$2" want="$3" rc
    rc="$(consumer_rc "$setup")"
    if [[ "$rc" == "$want" ]]; then
        ok "$label (rc=$rc)"
    else
        bad "$label — expected rc=$want, got rc=$rc"
    fi
}

check_rc "no WRH adapter keeps fail-closed" "$NO_ADAPTER" 1
check_rc "wrh_remove_now body text mentioning --quarantine without capability keeps (no body probe)" "$WRH_TEXT_ONLY" 1
check_rc "capability returning false keeps" "$CAP_FALSE" 1
check_rc "capability returning true is available" "$CAP_TRUE" 0
check_rc "capability true drives decision despite no --quarantine text" "$CAP_TRUE_NO_TEXT" 0

# --- 3. regression guard: the transitional body probe is gone ------------
if grep -q 'declare -f wrh_remove_now' "$SWEEPER"; then
    bad "cleanup_codex_documents.sh still body-probes wrh_remove_now"
else
    ok "cleanup_codex_documents.sh no longer body-probes wrh_remove_now"
fi
if grep -q 'wrh_quarantine_capable' "$SWEEPER"; then
    ok "cleanup_codex_documents.sh consumes wrh_quarantine_capable"
else
    bad "cleanup_codex_documents.sh does not consume wrh_quarantine_capable"
fi

echo
echo "test_wrh_quarantine_capability.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

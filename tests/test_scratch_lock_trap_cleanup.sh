#!/usr/bin/env bash
# Verify scratch-lock traps clean owned temp files and compose with prior handlers.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/scratch_lock.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/scratch-lock-trap.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+ ($2)}"; }

run_exit_case() {
  local label="$1" status="$2" temp="$T/$1.batch" marker="$T/$1.marker" rc=0
  PREVIOUS_TRAP_MARKER="$marker" bash -c '
    source "$1"
    artifact_batch_output_file="$2"
    : >"$artifact_batch_output_file"
    trap '\''printf "prior-exit\\n" >>"$PREVIOUS_TRAP_MARKER"'\'' EXIT
    scratch_lock_set_traps
    exit "$3"
  ' _ "$LIB" "$temp" "$status" || rc=$?
  [[ "$rc" == "$status" ]] && ok "$label preserves the shell exit status" || bad "$label preserves the shell exit status" "rc=$rc"
  [[ ! -e "$temp" ]] && ok "$label removes its owned batch temp" || bad "$label removes its owned batch temp"
  [[ "$(cat "$marker" 2>/dev/null)" == prior-exit ]] && ok "$label runs the prior EXIT handler once" || bad "$label runs the prior EXIT handler once"
}

run_exit_case normal-exit 7
run_exit_case command-error 19

run_signal_case() {
  local signal_name="$1" signal_number="$2" temp="$T/$1.batch" marker="$T/$1.marker" pidfile="$T/$1.pid" rc=0 timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  if [[ -z "$timeout_bin" ]]; then bad "$signal_name bounded signal test has timeout"; return; fi
  (
    for _ in {1..100}; do
      [[ -s "$pidfile" ]] && { kill -"$signal_name" "$(cat "$pidfile")" 2>/dev/null || true; exit 0; }
      /bin/sleep 0.02
    done
  ) &
  local sender=$!
  PREVIOUS_TRAP_MARKER="$marker" \
    "$timeout_bin" --signal=TERM --kill-after=1s 5s bash -c '
      source "$1"
      artifact_batch_output_file="$2"
      : >"$artifact_batch_output_file"
      trap '\''printf "prior\\n" >>"$PREVIOUS_TRAP_MARKER"'\'' "$4"
      scratch_lock_set_traps
      printf "%s\\n" "$$" >"$5"
      while :; do /bin/sleep 0.05; done
    ' _ "$LIB" "$temp" "$marker" "$signal_name" "$pidfile" || rc=$?
  kill "$sender" 2>/dev/null || true
  wait "$sender" 2>/dev/null || true
  [[ "$rc" == "$((128 + signal_number))" ]] && ok "$signal_name preserves signal exit status" || bad "$signal_name preserves signal exit status" "rc=$rc"
  [[ ! -e "$temp" ]] && ok "$signal_name removes its owned batch temp" || bad "$signal_name removes its owned batch temp"
  [[ "$(cat "$marker" 2>/dev/null)" == prior ]] && ok "$signal_name runs the prior signal handler once" || bad "$signal_name runs the prior signal handler once" "marker=$(cat "$marker" 2>/dev/null)"
}

run_signal_case TERM 15
run_signal_case INT 2

echo "test_scratch_lock_trap_cleanup: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

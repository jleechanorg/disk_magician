# shellcheck shell=bash
# Compatibility hooks for formerly serialized cleanup entrypoints.
# These jobs now run independently; scoped safety checks remain in the cleaners.
scratch_lock_acquire() {
  return 0
}

# Shared scratch cleanup traps preserve handlers installed by the caller, then
# release only temporary files owned by the current script.
SCRATCH_LOCK_PREVIOUS_EXIT_TRAP=""
SCRATCH_LOCK_PREVIOUS_HUP_TRAP=""
SCRATCH_LOCK_PREVIOUS_INT_TRAP=""
SCRATCH_LOCK_PREVIOUS_TERM_TRAP=""

scratch_lock_run_saved_trap() {
  local definition="${1:-}" signal="${2:-EXIT}" body
  [[ -n "$definition" ]] || return 0
  body="${definition#trap -- }"
  body="${body% $signal}"
  [[ "$body" != "$definition" && -n "$body" ]] || return 0
  # trap -p returns a shell-quoted command; the nested eval decodes then runs it.
  eval "eval $body"
}

scratch_lock_trap_handler() {
  local rc=$? sig="${1:-0}" previous="" signal_name=""
  trap - EXIT HUP INT TERM
  [[ -n "${dylib_candidate_file:-}" ]] && rm -f "$dylib_candidate_file"
  [[ -n "${artifact_batch_output_file:-}" ]] && rm -f "$artifact_batch_output_file"
  [[ -n "${artifact_blocked_file:-}" ]] && rm -f "$artifact_blocked_file"
  case "$sig" in
    0) previous="$SCRATCH_LOCK_PREVIOUS_EXIT_TRAP"; scratch_lock_run_saved_trap "$previous" EXIT || true; exit "$rc" ;;
    1) previous="$SCRATCH_LOCK_PREVIOUS_HUP_TRAP"; signal_name=HUP ;;
    2) previous="$SCRATCH_LOCK_PREVIOUS_INT_TRAP"; signal_name=INT ;;
    15) previous="$SCRATCH_LOCK_PREVIOUS_TERM_TRAP"; signal_name=TERM ;;
  esac
  scratch_lock_run_saved_trap "$previous" "$signal_name" || true
  kill -"$sig" "$$" 2>/dev/null || exit "$((128 + sig))"
}

scratch_lock_set_traps() {
  SCRATCH_LOCK_PREVIOUS_EXIT_TRAP="$(trap -p EXIT)"
  SCRATCH_LOCK_PREVIOUS_HUP_TRAP="$(trap -p HUP)"
  SCRATCH_LOCK_PREVIOUS_INT_TRAP="$(trap -p INT)"
  SCRATCH_LOCK_PREVIOUS_TERM_TRAP="$(trap -p TERM)"
  trap 'scratch_lock_trap_handler 0' EXIT
  trap 'scratch_lock_trap_handler 1' HUP
  trap 'scratch_lock_trap_handler 2' INT
  trap 'scratch_lock_trap_handler 15' TERM
}

# shellcheck shell=bash
# Shared kernel lock for destructive scratch cleanup passes.
# Dry-run skips this helper; Python owns the inherited flock descriptor.
SCRATCH_LOCK_FD="${DISK_MAGICIAN_SCRATCH_LOCK_FD:-}"

scratch_lock_acquire() {
  local caller="$1" script_path="${BASH_SOURCE[1]}"
  local helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scratch_lock.py"

  # A caller may continue only when the inherited descriptor proves ownership
  # of this state root's canonical lock file. Environment alone is not proof.
  if [[ "$SCRATCH_LOCK_FD" =~ ^[0-9]+$ ]] && \
      python3 "$helper" verify --fd "$SCRATCH_LOCK_FD" >/dev/null 2>&1; then
    return 0
  fi

  unset DISK_MAGICIAN_SCRATCH_LOCK_FD
  shift
  exec python3 "$helper" run --caller "$caller" --script "$script_path" --args -- "$@"
}

# Retained for cleanup_tmp.sh's dylib temp-file EXIT/signal cleanup. The lock
# itself is kernel-managed and intentionally has no shell release operation.
scratch_lock_trap_handler() {
  local rc=$? sig="${1:-0}"
  trap - EXIT HUP INT TERM
  [[ -n "${dylib_candidate_file:-}" ]] && rm -f "$dylib_candidate_file"
  if [[ "$sig" -ne 0 ]]; then
    kill -"$sig" "$$" 2>/dev/null || exit "$((128 + sig))"
  fi
  return "$rc"
}

scratch_lock_set_traps() {
  trap 'scratch_lock_trap_handler 0' EXIT
  trap 'scratch_lock_trap_handler 1' HUP
  trap 'scratch_lock_trap_handler 2' INT
  trap 'scratch_lock_trap_handler 15' TERM
}

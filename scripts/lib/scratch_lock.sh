# shellcheck shell=bash
# Shared lock invariant: cleanup_tmp.sh and cleanup_pr_scratch.sh share temp roots.
# Destructive passes acquire this lock to prevent TOCTOU races; dry-run skips it.
SCRATCH_LOCK_DIR=""
SCRATCH_LOCK_PID=""

scratch_lock_acquire() {
  local caller="$1" state_dir="${DISK_MAGICIAN_STATE_DIR:-${HOME:-}/.disk_magician_state}"
  [[ -n "$state_dir" ]] || { echo "[$caller] state dir unavailable" >&2; return 2; }
  mkdir -p "$state_dir" 2>/dev/null || { echo "[$caller] failed to create state dir: $state_dir" >&2; return 2; }
  [[ -d "$state_dir" && -w "$state_dir" ]] || { echo "[$caller] state dir unwritable: $state_dir" >&2; return 2; }

  local lock_dir="$state_dir/scratch_cleanup.lock"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo $$ > "$lock_dir/pid"
    SCRATCH_LOCK_DIR="$lock_dir"
    SCRATCH_LOCK_PID="$$"
    scratch_lock_set_traps
    return 0
  fi
  local held_pid; held_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  echo "[$caller] skipped, scratch lock held by PID ${held_pid:-unknown} — not queuing" >&2
  return 1
}

scratch_lock_release() {
  local lock_dir="$SCRATCH_LOCK_DIR" pid="$SCRATCH_LOCK_PID"
  SCRATCH_LOCK_DIR="" SCRATCH_LOCK_PID=""
  if [[ -n "$lock_dir" && -n "$pid" && "$$" == "$pid" && -d "$lock_dir" ]]; then
    if [[ "$(cat "$lock_dir/pid" 2>/dev/null || echo "")" == "$pid" ]]; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
    fi
  fi
}

scratch_lock_trap_handler() {
  local sig="${1:-0}"
  trap - EXIT HUP INT TERM
  [[ -n "${dylib_candidate_file:-}" ]] && rm -f "$dylib_candidate_file"
  scratch_lock_release
  if [[ "$sig" -ne 0 ]]; then
    kill -"$sig" "$$" 2>/dev/null || exit "$((128 + sig))"
  fi
}

scratch_lock_set_traps() {
  trap 'scratch_lock_trap_handler 0' EXIT
  trap 'scratch_lock_trap_handler 1' HUP
  trap 'scratch_lock_trap_handler 2' INT
  trap 'scratch_lock_trap_handler 15' TERM
}

# shellcheck shell=bash
# scratch_lock.sh — Shared mutual exclusion primitive for temporary/scratch
# sweepers (cleanup_tmp.sh and cleanup_pr_scratch.sh).
#
# Shared Lock Invariant:
# Both cleanup_tmp.sh and cleanup_pr_scratch.sh inspect overlapping scratch roots
# (/private/tmp, /tmp, and Darwin user temp directories) and can concurrently
# target the same directory/file candidate. Neither entry point is serialized by
# main_sweeper.sh's unrelated lock when run independently, via launchd, or under
# disk_audit. To prevent TOCTOU deletion/archival races, both destructive paths
# must acquire this shared lock before enumerating roots or candidates and hold it
# until all scans, decisions, and mutations complete.
#
# Dry-run skip invariant:
# Dry-run mode (--dry-run) is strictly read-only: it enumerates and evaluates
# candidates for reporting without performing removals, renames, or state changes.
# Because dry-run never mutates the filesystem, it does not race against other
# processes and does not require mutual exclusion. Skipping lock acquisition in
# dry-run ensures previews never block, contend, fail, or create state artifacts.

SCRATCH_LOCK_DIR=""
SCRATCH_LOCK_OWNER_TOKEN=""
SCRATCH_LOCK_PID=""
SCRATCH_LOCK_CALLER=""
SCRATCH_LOCK_TRAPS_SET=false
SCRATCH_LOCK_EXIT_HOOKS=()

_scratch_lock_log() {
  if command -v log >/dev/null 2>&1; then
    log "$@"
  else
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2
  fi
}

scratch_lock_get_state_dir() {
  local state_dir="${DISK_MAGICIAN_STATE_DIR:-}"
  if [[ -z "$state_dir" ]]; then
    if [[ -n "${HOME:-}" ]]; then
      state_dir="$HOME/.disk_magician_state"
    else
      return 1
    fi
  fi
  printf '%s\n' "$state_dir"
}

scratch_lock_get_lock_dir() {
  if [[ -n "${DISK_MAGICIAN_SCRATCH_LOCK_DIR:-}" ]]; then
    printf '%s\n' "$DISK_MAGICIAN_SCRATCH_LOCK_DIR"
    return 0
  fi
  local state_dir
  state_dir="$(scratch_lock_get_state_dir)" || return 1
  printf '%s/scratch_cleanup.lock\n' "$state_dir"
}

scratch_lock_register_exit_hook() {
  local hook="$1"
  SCRATCH_LOCK_EXIT_HOOKS+=("$hook")
  scratch_lock_set_traps
}

scratch_lock_run_exit_hooks() {
  local hook
  for hook in "${SCRATCH_LOCK_EXIT_HOOKS[@]:-}"; do
    if [[ -n "$hook" ]]; then
      eval "$hook" 2>/dev/null || true
    fi
  done
}

scratch_lock_release() {
  # Provable ownership check:
  # Release ONLY if this invocation provably owns the lock.
  local token="$SCRATCH_LOCK_OWNER_TOKEN"
  local pid="$SCRATCH_LOCK_PID"
  local lock_dir="$SCRATCH_LOCK_DIR"

  # Reset in-memory state so duplicate calls are no-ops
  SCRATCH_LOCK_OWNER_TOKEN=""
  SCRATCH_LOCK_PID=""
  SCRATCH_LOCK_DIR=""

  if [[ -z "$token" || -z "$lock_dir" || -z "$pid" ]]; then
    return 0
  fi

  # Subshell guard: $$ is identical in subshells under bash, but if PID differs do not release
  if [[ "$$" != "$pid" ]]; then
    return 0
  fi

  if [[ ! -d "$lock_dir" ]]; then
    return 0
  fi

  # Verify recorded owner token inside the lock directory matches exactly
  local recorded_token
  recorded_token="$(cat "$lock_dir/owner" 2>/dev/null || echo "")"
  if [[ -n "$recorded_token" && "$recorded_token" == "$token" ]]; then
    rm -f "$lock_dir/owner" "$lock_dir/pid" "$lock_dir/caller" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
  else
    _scratch_lock_log "WARNING: scratch lock at '$lock_dir' ownership mismatch or uncertain; preserving lock"
  fi
  return 0
}

scratch_lock_trap_handler() {
  local sig="${1:-0}"
  trap - EXIT HUP INT TERM
  scratch_lock_run_exit_hooks
  scratch_lock_release
  if [[ "$sig" -ne 0 ]]; then
    kill -"$sig" "$$" 2>/dev/null || exit "$((128 + sig))"
  fi
}

scratch_lock_set_traps() {
  if [[ "$SCRATCH_LOCK_TRAPS_SET" == true ]]; then
    return 0
  fi
  trap 'scratch_lock_trap_handler 0' EXIT
  trap 'scratch_lock_trap_handler 1' HUP
  trap 'scratch_lock_trap_handler 2' INT
  trap 'scratch_lock_trap_handler 15' TERM
  SCRATCH_LOCK_TRAPS_SET=true
}

scratch_lock_acquire() {
  local caller="${1:-scratch_cleanup}"
  local lock_dir
  lock_dir="$(scratch_lock_get_lock_dir)" || {
    _scratch_lock_log "ERROR: cannot determine state or lock directory — fail closed"
    return 2
  }

  local parent_dir
  parent_dir="$(dirname "$lock_dir")"
  if ! mkdir -p "$parent_dir" 2>/dev/null; then
    _scratch_lock_log "ERROR: cannot create state directory '$parent_dir' for lock — fail closed"
    return 2
  fi

  if [[ ! -d "$parent_dir" || ! -w "$parent_dir" || ! -x "$parent_dir" ]]; then
    _scratch_lock_log "ERROR: state directory '$parent_dir' is not writable or inaccessible — fail closed"
    return 2
  fi

  # Attempt atomic mutual exclusion via mkdir
  if mkdir "$lock_dir" 2>/dev/null; then
    SCRATCH_LOCK_DIR="$lock_dir"
    SCRATCH_LOCK_PID="$$"
    SCRATCH_LOCK_CALLER="$caller"
    SCRATCH_LOCK_OWNER_TOKEN="pid=$$-ts=$(date +%s)-rnd=${RANDOM:-0}-${caller}"

    echo "$$" > "$lock_dir/pid" 2>/dev/null || true
    echo "$caller" > "$lock_dir/caller" 2>/dev/null || true
    echo "$SCRATCH_LOCK_OWNER_TOKEN" > "$lock_dir/owner" 2>/dev/null || true

    scratch_lock_set_traps
    return 0
  fi

  # mkdir failed: check if lock is held (contention) or filesystem error
  if [[ -d "$lock_dir" ]]; then
    local held_pid held_caller
    held_pid="$(cat "$lock_dir/pid" 2>/dev/null || echo "")"
    held_caller="$(cat "$lock_dir/caller" 2>/dev/null || echo "")"
    _scratch_lock_log "${caller}: skipped, scratch lock held by ${held_caller:+caller '$held_caller' }(PID ${held_pid:-unknown}) at $lock_dir — not queuing"
    return 1
  fi

  _scratch_lock_log "ERROR: ${caller}: failed to create lock dir '$lock_dir' — fail closed"
  return 2
}

#!/usr/bin/env bash
# shellcheck shell=bash
# agent_scratch.sh — managed scratch root for agent runtimes (Task 7 producer migration:
# namespaced runtime/run-id subtree under $AGENT_SCRATCH_ROOT so budget eviction and
# scheduled cleanup can target exactly a session's own scratch without touching
# unrelated temp entries).
#
# Exposes:
#   agent_scratch_create <runtime> <run-id>   # atomic mkdir, prints leaf path
#   agent_scratch_trap_cleanup <path>          # arms EXIT/INT/TERM traps with containment & safety
#
AGENT_SCRATCH_ROOT="${AGENT_SCRATCH_ROOT:-/private/tmp/agent-scratch}"

_AGENT_SCRATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if type safety_gate >/dev/null 2>&1; then
  :
elif [[ -f "$_AGENT_SCRATCH_DIR/../safety_lib.sh" ]]; then
  # shellcheck source=scripts/safety_lib.sh
  source "$_AGENT_SCRATCH_DIR/../safety_lib.sh"
fi

_agent_scratch_valid_component() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  [[ "$c" != "." && "$c" != ".." ]] || return 1
  [[ "$c" != *"/"* && "$c" != *"\\"* ]] || return 1
  [[ "$c" != *".."* ]] || return 1
}

_agent_scratch_fs_id() {
  local target="${1:-}"
  [[ -e "$target" || -L "$target" ]] || return 1
  stat -f '%d:%i' "$target" 2>/dev/null || python3 -c 'import os, sys; st = os.stat(sys.argv[1]); print(f"{st.st_dev}:{st.st_ino}")' "$target" 2>/dev/null
}

agent_scratch_create() {
  local runtime="${1:-}" run_id="${2:-}"
  if ! _agent_scratch_valid_component "$runtime"; then
    echo "agent_scratch_create: invalid runtime: $runtime" >&2
    return 1
  fi
  if ! _agent_scratch_valid_component "$run_id"; then
    echo "agent_scratch_create: invalid run-id: $run_id" >&2
    return 1
  fi

  local root="${AGENT_SCRATCH_ROOT:-/private/tmp/agent-scratch}"
  root="${root%/}"
  if [[ -z "$root" ]]; then
    echo "agent_scratch_create: empty AGENT_SCRATCH_ROOT" >&2
    return 1
  fi

  # Explicit symlink rejection for root (preserves legitimate parent aliases)
  if [[ -L "$root" ]]; then
    echo "agent_scratch_create: AGENT_SCRATCH_ROOT is an explicit symlink: $root" >&2
    return 1
  fi

  if [[ ! -d "$root" ]]; then
    mkdir -p "$root" 2>/dev/null || {
      echo "agent_scratch_create: failed to create root $root" >&2
      return 1
    }
  fi

  if [[ -L "$root" ]]; then
    echo "agent_scratch_create: AGENT_SCRATCH_ROOT is an explicit symlink: $root" >&2
    return 1
  fi

  local canon_root
  canon_root="$(cd "$root" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_create: cannot resolve root: $root" >&2
    return 1
  }

  local runtime_dir="$root/$runtime"
  if [[ -L "$runtime_dir" ]]; then
    echo "agent_scratch_create: runtime dir is a symlink: $runtime_dir" >&2
    return 1
  fi

  if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir" 2>/dev/null || {
      echo "agent_scratch_create: failed to create runtime dir: $runtime_dir" >&2
      return 1
    }
  fi

  if [[ -L "$runtime_dir" ]]; then
    echo "agent_scratch_create: runtime dir is a symlink: $runtime_dir" >&2
    return 1
  fi

  local canon_runtime
  canon_runtime="$(cd "$runtime_dir" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_create: cannot resolve runtime dir: $runtime_dir" >&2
    return 1
  }

  if [[ "$canon_runtime" != "$canon_root/$runtime" ]]; then
    echo "agent_scratch_create: runtime dir escaped root: $canon_runtime" >&2
    return 1
  fi

  local leaf="$runtime_dir/$run_id"
  # Atomic mkdir for leaf — refuses existing leaf without reusing data
  if ! mkdir "$leaf" 2>/dev/null; then
    echo "agent_scratch_create: leaf already exists or cannot be created: $leaf" >&2
    return 1
  fi

  if [[ -L "$leaf" ]]; then
    rmdir "$leaf" 2>/dev/null || true
    echo "agent_scratch_create: created leaf is a symlink: $leaf" >&2
    return 1
  fi

  local canon_leaf
  canon_leaf="$(cd "$leaf" 2>/dev/null && pwd -P)" || {
    rmdir "$leaf" 2>/dev/null || true
    echo "agent_scratch_create: cannot resolve created leaf: $leaf" >&2
    return 1
  }

  if [[ "$canon_leaf" != "$canon_runtime/$run_id" ]]; then
    rmdir "$leaf" 2>/dev/null || true
    echo "agent_scratch_create: created leaf escaped runtime dir: $canon_leaf" >&2
    return 1
  fi

  # Stdout purity: emit created leaf path only
  echo "$leaf"
}

_agent_scratch_contains_git() {
  local p="$1"
  if [[ -d "$p/.git" || -f "$p/.git" ]]; then
    return 0
  fi
  local found
  if ! found="$(find "$p" -name .git -prune -print -quit 2>/dev/null)"; then
    # Traversal error: fail closed
    return 0
  fi
  [[ -n "$found" ]]
}

_agent_scratch_cleanup_path() {
  local target="${1:-}" exp_root_id="${2:-}" exp_runtime_id="${3:-}" exp_leaf_id="${4:-}"
  [[ -n "$target" ]] || return 0
  [[ -e "$target" || -L "$target" ]] || return 0

  if [[ -L "$target" ]]; then
    echo "agent_scratch_cleanup: refusing cleanup of symlink: $target" >&2
    return 1
  fi

  if [[ ! -d "$target" ]]; then
    echo "agent_scratch_cleanup: refusing cleanup of non-directory: $target" >&2
    return 1
  fi

  # Filesystem identity revalidation (prevents deleting replaced leaves)
  local curr_leaf_id
  curr_leaf_id="$(_agent_scratch_fs_id "$target")"
  if [[ -n "$exp_leaf_id" && "$curr_leaf_id" != "$exp_leaf_id" ]]; then
    echo "agent_scratch_cleanup: leaf filesystem identity mismatch (leaf was replaced): $target" >&2
    return 1
  fi

  local root="${AGENT_SCRATCH_ROOT:-/private/tmp/agent-scratch}"
  if [[ -L "$root" ]]; then
    echo "agent_scratch_cleanup: AGENT_SCRATCH_ROOT is an explicit symlink: $root" >&2
    return 1
  fi

  local canon_root
  canon_root="$(cd "$root" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_cleanup: cannot resolve AGENT_SCRATCH_ROOT: $root" >&2
    return 1
  }

  local curr_root_id
  curr_root_id="$(_agent_scratch_fs_id "$canon_root")"
  if [[ -n "$exp_root_id" && "$curr_root_id" != "$exp_root_id" ]]; then
    echo "agent_scratch_cleanup: root filesystem identity mismatch: $canon_root" >&2
    return 1
  fi

  local canon_target
  canon_target="$(cd "$target" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_cleanup: cannot resolve target path: $target" >&2
    return 1
  }

  local curr_runtime_id
  curr_runtime_id="$(_agent_scratch_fs_id "${canon_target%/*}")"
  if [[ -n "$exp_runtime_id" && "$curr_runtime_id" != "$exp_runtime_id" ]]; then
    echo "agent_scratch_cleanup: runtime filesystem identity mismatch: ${canon_target%/*}" >&2
    return 1
  fi

  case "$canon_target" in
    "$canon_root"/*/*) ;;
    *)
      echo "agent_scratch_cleanup: refusing — $canon_target is not strictly under $canon_root/<runtime>/" >&2
      return 1
      ;;
  esac

  local rel="${canon_target#"$canon_root"/}"
  case "$rel" in
    */*/*)
      echo "agent_scratch_cleanup: refusing — $canon_target is nested deeper than <runtime>/<run-id>" >&2
      return 1
      ;;
  esac

  if [[ "$canon_target" == "/" || "$canon_target" == "$canon_root" ]]; then
    echo "agent_scratch_cleanup: refusing — target is root: $canon_target" >&2
    return 1
  fi

  if type sandbox_guard_roots >/dev/null 2>&1; then
    sandbox_guard_roots "$canon_target"
  fi

  if type safety_gate >/dev/null 2>&1; then
    if ! safety_gate "$canon_target"; then
      echo "agent_scratch_cleanup: safety_gate refused deletion of $canon_target" >&2
      return 1
    fi
  elif [[ -f "${_AGENT_SCRATCH_DIR:-}/../safety_lib.sh" ]]; then
    # shellcheck source=scripts/safety_lib.sh
    source "${_AGENT_SCRATCH_DIR}/../safety_lib.sh"
    if ! safety_gate "$canon_target"; then
      echo "agent_scratch_cleanup: safety_gate refused deletion of $canon_target" >&2
      return 1
    fi
  else
    echo "agent_scratch_cleanup: safety_gate unavailable, failing closed" >&2
    return 1
  fi

  if _agent_scratch_contains_git "$canon_target"; then
    echo "agent_scratch_cleanup: refusing deletion — path contains git repository: $canon_target" >&2
    return 1
  fi

  rm -rf "$canon_target"

  if type deletion_log >/dev/null 2>&1; then
    deletion_log "agent_scratch" "rmdir" "0" "$canon_target"
  fi
  return 0
}

_AGENT_SCRATCH_REGISTERED_RECORDS=()
_AGENT_SCRATCH_TRAPS_ARMED=0
_AGENT_SCRATCH_PREV_EXIT=""
_AGENT_SCRATCH_PREV_INT=""
_AGENT_SCRATCH_PREV_TERM=""
_AGENT_SCRATCH_EXIT_RAN=0

_agent_scratch_get_trap() {
  local sig="$1"
  local __captured=""
  trap() {
    shift
    __captured="$1"
  }
  eval "$(builtin trap -p "$sig" 2>/dev/null)"
  unset -f trap
  printf "%s" "$__captured"
}

_agent_scratch_clean_registered() {
  if [[ "${#_AGENT_SCRATCH_REGISTERED_RECORDS[@]}" -eq 0 ]]; then
    return 0
  fi
  local rec target root_id runtime_id leaf_id
  for rec in "${_AGENT_SCRATCH_REGISTERED_RECORDS[@]}"; do
    target="${rec%%|*}"
    local rest="${rec#*|}"
    root_id="${rest%%|*}"
    rest="${rest#*|}"
    runtime_id="${rest%%|*}"
    leaf_id="${rest#*|}"
    _agent_scratch_cleanup_path "$target" "$root_id" "$runtime_id" "$leaf_id"
  done
  _AGENT_SCRATCH_REGISTERED_RECORDS=()
}

_agent_scratch_on_exit() {
  local __status=$?
  set +e
  if [[ "${_AGENT_SCRATCH_EXIT_RAN:-0}" -eq 1 ]]; then
    exit "$__status"
  fi
  _AGENT_SCRATCH_EXIT_RAN=1
  _agent_scratch_clean_registered

  if [[ -n "${_AGENT_SCRATCH_PREV_EXIT:-}" ]]; then
    (exit "$__status")
    eval "$_AGENT_SCRATCH_PREV_EXIT"
    exit "$__status"
  fi
  exit "$__status"
}

_agent_scratch_on_signal() {
  local sig="$1"
  set +e
  if [[ "${_AGENT_SCRATCH_EXIT_RAN:-0}" -eq 1 ]]; then
    return 0
  fi
  _AGENT_SCRATCH_EXIT_RAN=1

  local sig_num=0
  case "$sig" in
    INT) sig_num=2 ;;
    TERM) sig_num=15 ;;
    *) sig_num="$(kill -l "$sig" 2>/dev/null || echo 0)" ;;
  esac
  local __sig_status=$(( 128 + sig_num ))

  _agent_scratch_clean_registered

  local prev_sig=""
  case "$sig" in
    INT) prev_sig="${_AGENT_SCRATCH_PREV_INT:-}" ;;
    TERM) prev_sig="${_AGENT_SCRATCH_PREV_TERM:-}" ;;
  esac
  if [[ -n "$prev_sig" ]]; then
    (exit "$__sig_status")
    eval "$prev_sig"
  fi

  if [[ -n "${_AGENT_SCRATCH_PREV_EXIT:-}" ]]; then
    (exit "$__sig_status")
    eval "$_AGENT_SCRATCH_PREV_EXIT"
  fi

  trap - "$sig"
  local pid="${BASHPID:-$$}"
  kill -s "$sig" "$pid" 2>/dev/null || kill -s "$sig" $$ 2>/dev/null || true
  exit "$__sig_status"
}

agent_scratch_trap_cleanup() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    echo "agent_scratch_trap_cleanup: missing path argument" >&2
    return 1
  fi

  local root="${AGENT_SCRATCH_ROOT:-/private/tmp/agent-scratch}"
  if [[ -L "$root" ]]; then
    echo "agent_scratch_trap_cleanup: AGENT_SCRATCH_ROOT is an explicit symlink: $root" >&2
    return 1
  fi

  local canon_root
  canon_root="$(cd "$root" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_trap_cleanup: AGENT_SCRATCH_ROOT does not exist, refusing: $root" >&2
    return 1
  }

  if [[ ! -d "$path" ]]; then
    echo "agent_scratch_trap_cleanup: path does not exist, refusing: $path" >&2
    return 1
  fi

  if [[ -L "$path" ]]; then
    echo "agent_scratch_trap_cleanup: path is a symlink, refusing: $path" >&2
    return 1
  fi

  local canon_path
  canon_path="$(cd "$path" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_trap_cleanup: cannot canonicalize path, refusing: $path" >&2
    return 1
  }

  case "$canon_path" in
    "$canon_root"/*/*) ;;
    *)
      echo "agent_scratch_trap_cleanup: refusing — $canon_path is not a leaf strictly under $canon_root/<runtime>/" >&2
      return 1
      ;;
  esac

  local rel="${canon_path#"$canon_root"/}"
  case "$rel" in
    */*/*)
      echo "agent_scratch_trap_cleanup: refusing — $canon_path is nested deeper than <runtime>/<run-id>" >&2
      return 1
      ;;
  esac

  local leaf_id
  leaf_id="$(_agent_scratch_fs_id "$canon_path")" || {
    echo "agent_scratch_trap_cleanup: cannot determine filesystem identity of leaf: $canon_path" >&2
    return 1
  }

  local runtime_dir="${canon_path%/*}"
  local runtime_id
  runtime_id="$(_agent_scratch_fs_id "$runtime_dir")" || {
    echo "agent_scratch_trap_cleanup: cannot determine filesystem identity of runtime: $runtime_dir" >&2
    return 1
  }

  local root_id
  root_id="$(_agent_scratch_fs_id "$canon_root")" || {
    echo "agent_scratch_trap_cleanup: cannot determine filesystem identity of root: $canon_root" >&2
    return 1
  }

  local record="${canon_path}|${root_id}|${runtime_id}|${leaf_id}"
  local existing already_present=0
  if [[ "${#_AGENT_SCRATCH_REGISTERED_RECORDS[@]}" -gt 0 ]]; then
    for existing in "${_AGENT_SCRATCH_REGISTERED_RECORDS[@]}"; do
      if [[ "$existing" == "$record" ]]; then
        already_present=1
        break
      fi
    done
  fi
  if [[ "$already_present" -eq 0 ]]; then
    _AGENT_SCRATCH_REGISTERED_RECORDS+=("$record")
  fi

  if [[ "${_AGENT_SCRATCH_TRAPS_ARMED:-0}" -eq 0 ]]; then
    _AGENT_SCRATCH_PREV_EXIT="$(_agent_scratch_get_trap EXIT)"
    _AGENT_SCRATCH_PREV_INT="$(_agent_scratch_get_trap INT)"
    _AGENT_SCRATCH_PREV_TERM="$(_agent_scratch_get_trap TERM)"
    _AGENT_SCRATCH_TRAPS_ARMED=1

    trap '_agent_scratch_on_exit' EXIT
    trap '_agent_scratch_on_signal INT' INT
    trap '_agent_scratch_on_signal TERM' TERM
  fi
  return 0
}

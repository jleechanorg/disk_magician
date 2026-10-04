#!/usr/bin/env bash
# shellcheck shell=bash
# docker_probe.sh — Bounded external Docker CLI probe runner with explicit deadlines.
#
# Operational invariant (Bead disk_magician-3ma):
# External Docker CLI probes must have bounded deadlines. Failed/hung safety
# checks must never hang indefinitely, invent zero container references, or
# invent zero cache size.
#
# Provides:
#   docker_probe <args...>
#     Executes `docker <args...>` under an explicit deadline.
#     Kills lingering descendants via kill-after grace period when supported.
#     Fails closed if timeout support is unavailable, input is malformed,
#     or probe times out / fails.
#   resolve_docker_probe_deadline
#     Validates and resolves the probe deadline in seconds.
#     Default: 5s. Overridden by DOCKER_PROBE_DEADLINE_SECONDS.
#     Rejects malformed, zero, negative, or unreasonable (>60s) input.

DEFAULT_DOCKER_PROBE_DEADLINE=5
MAX_DOCKER_PROBE_DEADLINE=60

resolve_docker_probe_deadline() {
  local val="${DOCKER_PROBE_DEADLINE_SECONDS:-${DOCKER_PROBE_TIMEOUT_SECONDS:-$DEFAULT_DOCKER_PROBE_DEADLINE}}"

  # Must be non-empty and purely digits with no leading zero (positive integer)
  if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: invalid Docker probe deadline: '$val' (must be a positive integer between 1 and $MAX_DOCKER_PROBE_DEADLINE)" >&2
    return 1
  fi

  if (( ${#val} > ${#MAX_DOCKER_PROBE_DEADLINE} )) || (( val > MAX_DOCKER_PROBE_DEADLINE )); then
    echo "ERROR: unreasonable Docker probe deadline: '$val' (exceeds maximum limit of $MAX_DOCKER_PROBE_DEADLINE seconds)" >&2
    return 1
  fi

  echo "$val"
  return 0
}

_resolve_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    command -v timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    command -v gtimeout
  else
    return 1
  fi
}

docker_probe() {
  if ! command -v docker >/dev/null 2>&1; then
    return 127
  fi

  local deadline
  if ! deadline="$(resolve_docker_probe_deadline)"; then
    return 1
  fi

  local timeout_bin
  if ! timeout_bin="$(_resolve_timeout_cmd)"; then
    echo "DEGRADED: timeout utility unavailable; refusing unbounded docker probe: docker $*" >&2
    return 125
  fi

  if ! "$timeout_bin" -k 1s 1 true >/dev/null 2>&1; then
    echo "DEGRADED: timeout utility lacks GNU kill-after (-k) support; refusing unbounded docker probe: docker $*" >&2
    return 125
  fi

  local -a timeout_opts
  timeout_opts=("-k" "1s" "$deadline")

  local rc=0
  "$timeout_bin" "${timeout_opts[@]}" docker "$@"
  rc=$?

  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "DEGRADED: docker probe timed out after ${deadline}s: docker $*" >&2
  fi
  return $rc
}

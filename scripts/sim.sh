#!/bin/bash
# sim.sh — CLI shim for `diskm sim <status|lease|release|prune>`. Behavior lives
# in sim_lifecycle.sh (design: ~/roadmap/sq-ios-simulator-reuse-design-2026-11-16.md).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/sim_lifecycle.sh"

# Load the shared removal verdict so prune's gate is REAL, not an
# always-skipped `declare -F` check (review P0: the CLI never loaded it, so
# `prune` silently bypassed the secret/repo/liveness gates entirely).
if [[ -f "$SCRIPT_DIR/lib/artifact_verdict.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/artifact_verdict.sh"
fi
sub="${1:-status}"; shift || true
case "$sub" in
  status)  sim_status_json "$@" ;;
  lease)   sim_lease "$@" ;;
  release) sim_release "$@" ;;
  prune)   sim_prune "$@" ;;
  create)  sim_create "$@" ;;
  adopt)   echo "sim adopt: not implemented in this PR; requires explicit owner authorisation (contract § Adopt path)" >&2; exit 22 ;;
  *) echo "usage: diskm sim <status|lease|release|prune|create|adopt>" >&2; exit 2 ;;
esac

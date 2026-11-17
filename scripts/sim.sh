#!/bin/bash
# sim.sh — CLI shim for `diskm sim <status|lease|release|prune>`. Behavior lives
# in sim_lifecycle.sh (design: ~/roadmap/sq-ios-simulator-reuse-design-2026-11-16.md).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/sim_lifecycle.sh"
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

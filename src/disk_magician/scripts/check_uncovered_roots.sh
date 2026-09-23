#!/usr/bin/env bash
# check_uncovered_roots.sh — thin wrapper for check_uncovered_roots.py
# (bead disk_magician-8to). Flags >=5 GiB directories with no registered
# cleanup sweeper owner, from already-measured frontier/discover data —
# never runs a fresh du. See config/sweeper_roots.txt for the registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"

exec python3 "$SCRIPT_DIR/check_uncovered_roots.py" \
  --snapshot "$STATE_DIR/frontier_last.json" \
  --discover "$STATE_DIR/discover_last.json" \
  --registry "$REPO_ROOT/config/sweeper_roots.txt" \
  "$@"

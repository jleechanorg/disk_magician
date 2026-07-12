#!/usr/bin/env bash
# disk_frontier_scan.sh — thin launchd/cron-compatible entrypoint for the
# frontier-BFS exhaustive coverage scanner.
#
# The scanner itself is implemented in Python (worker-pool backpressure,
# dedup trie, plist parsing are all cleaner there than in bash) — this
# wrapper just resolves the repo path and execs it so callers get a stable
# .sh entrypoint matching every other script in scripts/.
#
# Standalone tool: NOT wired into disk_snapshot.sh or launchd yet. See
# roadmap/2026-07-11-total-coverage-snapshot-v2.md, implementation-order
# step 3, and config.json's future `topdown_enabled` gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/disk_frontier_scan.py" "$@"

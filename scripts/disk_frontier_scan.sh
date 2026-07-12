#!/usr/bin/env bash
# disk_frontier_scan.sh — thin launchd/cron-compatible entrypoint for the
# frontier-BFS exhaustive coverage scanner.
#
# The scanner itself is implemented in Python (worker-pool backpressure,
# dedup trie, plist parsing are all cleaner there than in bash) — this
# wrapper just resolves the repo path and execs it so callers get a stable
# .sh entrypoint matching every other script in scripts/.
#
# Wired in two places: the nightly launchd job
# (com.jleechanorg.disk-magician-frontier-nightly) runs this with
# --wall-clock-cap 2700 --output-default, and disk_snapshot.sh embeds the
# resulting frontier_last.json summary as `topdown_coverage` when fresh.
# Disable via config `topdown_enabled: false`. See
# roadmap/2026-07-11-total-coverage-snapshot-v2.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/disk_frontier_scan.py" "$@"

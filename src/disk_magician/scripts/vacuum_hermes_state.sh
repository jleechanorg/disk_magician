#!/bin/bash
# vacuum_hermes_state.sh — Monthly SQLite VACUUM for ~/.hermes/state.db.
#
# Without VACUUM, deleted rows leave free pages in the SQLite file that
# WAL doesn't release. state.db is currently 5.7 GB; regular VACUUM
# reclaims ~10-30% over time. Safe to run while daemon is up — VACUUM
# rewrites the file atomically (renames state.db to state.db-old then
# back) but blocks writers briefly. Hermes tolerates this; the daemon
# reconnects on next op.
#
# Default dry-run. Pass --apply to actually VACUUM.
#
# Caller: launchd/com.jleechan.disk-magician-hermes-vacuum.plist
#         (scheduled Sundays 04:30 local time, passes --apply).
set -euo pipefail

DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"
APPLY=false
for arg in "$@"; do [[ "$arg" == "--apply" ]] && APPLY=true; done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

if [[ ! -f "$DB" ]]; then
  log "No $DB — skipping"
  exit 0
fi

# Sanity check: sqlite3 must exist. Don't silently succeed on missing tool.
if ! command -v sqlite3 >/dev/null 2>&1; then
  log "ERROR: sqlite3 binary not on PATH — cannot VACUUM $DB" >&2
  log "PATH=$PATH" >&2
  exit 1
fi

before=$(stat -f%z "$DB" 2>/dev/null || echo 0)
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
log "state.db before: ${before_mb} MB ($DB)"

if $APPLY; then
  # VACUUM into a temp file then atomic rename is what SQLite does itself;
  # we just invoke the command. The rewrite can briefly block writers.
  sqlite3 "$DB" 'VACUUM;'
  after=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
  delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
  log "VACUUM: ${before_mb} → ${after_mb} MB (reclaimed ${delta_mb} MB)"
else
  log "[dry-run] would VACUUM $DB (${before_mb} MB) — pass --apply to execute"
fi
#!/bin/bash
# vacuum_hermes_state.sh — SQLite WAL checkpoint + (optional, guarded) VACUUM for ~/.hermes/state.db.
#
# SAFETY (incident 2026-07-22, jleechan-4dtg): the prior version of this
# script treated `--apply` as "unconditional `sqlite3 state.db 'VACUUM;'`"
# on a ~5.9 GB WAL-mode db. VACUUM rewrites the entire file (writes a full
# second copy), which drove host free space from 12 GB to 5 GB in ~13
# minutes and nearly wedged the disk — exactly when disk pressure is
# already the reason you'd want a cleanup sweeper to run. The script now
# distinguishes two modes:
#
#   --apply           PRAGMA wal_checkpoint(TRUNCATE);  — flushes the WAL
#                     into the main file and truncates state.db-wal, no
#                     second full-size copy, safe with the daemon up.
#                     This is what the weekly launchd plist passes.
#
#   --apply --full-vacuum
#                     Full VACUUM. Free-space-guarded: refuses unless
#                     free space >= max(2x current DB size, 15 GB).
#                     Intentionally NOT wired into the automated schedule
#                     — run it manually when you want the file to actually
#                     shrink. state.db checkpoints keep the WAL itself
#                     from growing large between writes; checkpoint alone
#                     does not shrink the main file (that needs VACUUM).
#
# Default: dry-run report of current db size + WAL size.
#
# Caller: launchd/com.disk-magician.hermes-vacuum.plist passes --apply.
set -euo pipefail

DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"
APPLY=false
FULL_VACUUM=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --full-vacuum) FULL_VACUUM=true ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

if [[ ! -f "$DB" ]]; then
  log "No $DB — skipping"
  exit 0
fi

# Sanity check: sqlite3 must exist. Don't silently succeed on missing tool.
if ! command -v sqlite3 >/dev/null 2>&1; then
  log "ERROR: sqlite3 binary not on PATH — cannot process $DB" >&2
  log "PATH=$PATH" >&2
  exit 1
fi

before=$(stat -f%z "$DB" 2>/dev/null || echo 0)
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
WAL_FILE="${DB}-wal"
wal_before=$(stat -f%z "$WAL_FILE" 2>/dev/null || echo 0)
wal_before_mb=$(awk "BEGIN {printf \"%.1f\", $wal_before / 1048576}")
log "state.db before: ${before_mb} MB ($DB), WAL: ${wal_before_mb} MB"

if ! $APPLY; then
  log "[dry-run] would wal_checkpoint(TRUNCATE) $DB (${before_mb} MB, WAL ${wal_before_mb} MB) — pass --apply to execute"
  exit 0
fi

# --- --apply path: PRAGMA wal_checkpoint(TRUNCATE); ---
if ! $FULL_VACUUM; then
  # PRAGMA wal_checkpoint(TRUNCATE) flushes WAL frames into the main file
  # then truncates the -wal to zero. Doesn't shrink the main file (only
  # VACUUM does), but it caps WAL growth at ~zero between writes, which
  # is what we want for a recurring weekly sweep.
  checkpoint_rc=$(sqlite3 "$DB" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>&1) || {
    log "ERROR: wal_checkpoint(TRUNCATE) failed: $checkpoint_rc" >&2
    exit 1
  }
  log "wal_checkpoint(TRUNCATE) result: $checkpoint_rc"
  after=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  wal_after=$(stat -f%z "$WAL_FILE" 2>/dev/null || echo 0)
  after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
  wal_after_mb=$(awk "BEGIN {printf \"%.1f\", $wal_after / 1048576}")
  log "checkpoint: main ${before_mb} → ${after_mb} MB, WAL ${wal_before_mb} → ${wal_after_mb} MB"
  exit 0
fi

# --- --apply --full-vacuum path: free-space-guarded full VACUUM ---
# SQLite VACUUM rewrites the file atomically (rename state.db → state.db-old
# → state.db after rewrite) and writes a full second copy of the file.
# Hermes daemon tolerates brief writer blocking and reconnects on next op.
# This is intentionally NOT in the weekly launchd schedule.
db_bytes="$before"
required_bytes=$(( db_bytes * 2 ))
required_bytes_floor=$(( 15 * 1024 * 1024 * 1024 ))  # 15 GB hard floor
[[ "$required_bytes" -lt "$required_bytes_floor" ]] && required_bytes="$required_bytes_floor"
avail_kb=$( (df -k "$DB" 2>/dev/null | awk 'NR==2 {print $4}') || true )
avail_bytes=$(( ${avail_kb:-0} * 1024 ))
if [[ "$avail_bytes" -lt "$required_bytes" ]]; then
  log "ERROR: refusing --full-vacuum — free space (${avail_bytes} bytes) below max(2x db size, 15GB) (${required_bytes} bytes)" >&2
  exit 1
fi
log "free space OK (${avail_bytes} bytes >= ${required_bytes} required) — running VACUUM"
sqlite3 "$DB" 'VACUUM;'
after=$(stat -f%z "$DB" 2>/dev/null || echo 0)
after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
log "VACUUM: ${before_mb} → ${after_mb} MB (reclaimed ${delta_mb} MB)"
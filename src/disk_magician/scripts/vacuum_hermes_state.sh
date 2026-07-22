#!/bin/bash
# vacuum_hermes_state.sh — Reclaim space from ~/.hermes/state.db (WAL-mode SQLite).
#
# Incident 2026-07-22 (mission jleechan-4dtg): this script's old unconditional
# `sqlite3 "$DB" 'VACUUM;'` path wrote a FULL rewritten copy of a 5.9 GB
# database. VACUUM's temp file ballooned the WAL to 5.5 GB and drove host
# free space from 12 GB to 5 GB in ~13 minutes -- on a box that was already
# tight on space, i.e. exactly the condition under which this "cleanup"
# sweeper is most likely to run. The old header claimed "safe to run while
# daemon is up" without qualifying that VACUUM needs to write a full second
# copy of the database first.
#
# Fix: two-tier reclaim.
#   1. Default action (--apply, no other flags): `PRAGMA wal_checkpoint
#      (TRUNCATE);`. This flushes the WAL back into the main db file and
#      truncates state.db-wal to 0 bytes -- no second full-size copy, safe
#      with the daemon up, and was used live during the incident to reclaim
#      5.5 GB with zero risk. This is the routine, frequently-safe path.
#   2. Full VACUUM (--full-vacuum, in addition to --apply): only runs after
#      an explicit free-space guard passes -- refuses (logs + exit 0,
#      non-fatal) unless free space on the data volume is at least
#      max(2 * current DB size, VACUUM_MIN_FREE_GB). VACUUM needs to write a
#      complete copy of the file, so anything less risks wedging the disk
#      the same way the incident did. Intended for occasional/manual use,
#      not the default automated cadence -- not wired into the weekly
#      launchd plist by default (see com.disk-magician.hermes-vacuum.plist).
#
# Default dry-run. Pass --apply to actually run the checkpoint (and
# --full-vacuum on top of --apply to also attempt the guarded full VACUUM).
#
# Caller: launchd/com.disk-magician.hermes-vacuum.plist
#         (scheduled weekly, passes --apply only -- checkpoint, no VACUUM).
set -euo pipefail

DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"
# Floor below which a full VACUUM refuses even if 2x DB size is smaller
# (e.g. a tiny DB shouldn't "pass" the guard at a razor-thin free margin).
VACUUM_MIN_FREE_GB="${VACUUM_MIN_FREE_GB:-15}"
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
  log "ERROR: sqlite3 binary not on PATH — cannot operate on $DB" >&2
  log "PATH=$PATH" >&2
  exit 1
fi

FREE_GB_OVERRIDE="${DISK_MAGICIAN_VACUUM_FREE_GB_OVERRIDE:-}"
free_gb() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    echo "$FREE_GB_OVERRIDE"
    return
  fi
  local check_path="/"
  if [[ "$OSTYPE" == "darwin"* ]] && df "/System/Volumes/Data" >/dev/null 2>&1; then
    check_path="/System/Volumes/Data"
  fi
  df -kP "$check_path" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}'
}

before=$(stat -f%z "$DB" 2>/dev/null || echo 0)
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
log "state.db before: ${before_mb} MB ($DB)"

if ! $APPLY; then
  log "[dry-run] would wal_checkpoint(TRUNCATE) $DB (${before_mb} MB) — pass --apply to execute"
  if $FULL_VACUUM; then
    log "[dry-run] would also attempt guarded full VACUUM (--full-vacuum) if free space allows"
  fi
  exit 0
fi

# ────────── Step 1: WAL checkpoint (routine, low-risk, no amplification) ──────────
log "Running wal_checkpoint(TRUNCATE) — flushes WAL into the main file, no full-size temp copy."
sqlite3 "$DB" 'PRAGMA wal_checkpoint(TRUNCATE);'
after_checkpoint=$(stat -f%z "$DB" 2>/dev/null || echo 0)
after_checkpoint_mb=$(awk "BEGIN {printf \"%.1f\", $after_checkpoint / 1048576}")
log "wal_checkpoint(TRUNCATE) done — state.db now ${after_checkpoint_mb} MB (a checkpoint truncates *.db-wal, not the main file; main file only shrinks via VACUUM below)."

# ────────── Step 2: full VACUUM (opt-in, free-space-gated) ──────────
if $FULL_VACUUM; then
  current_size=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  current_gb=$(awk "BEGIN {printf \"%.1f\", $current_size / 1073741824}")
  free_now="$(free_gb)"
  if [[ -z "$free_now" ]]; then
    log "REFUSING full VACUUM: could not read free space — fail safe, no VACUUM attempted."
    exit 0
  fi
  required_gb=$(awk -v db="$current_gb" -v floor="$VACUUM_MIN_FREE_GB" 'BEGIN{req = db * 2; print (req > floor) ? req : floor}')
  guard_pass=$(awk -v f="$free_now" -v r="$required_gb" 'BEGIN{print (f >= r) ? "1" : "0"}')
  if [[ "$guard_pass" != "1" ]]; then
    log "REFUSING full VACUUM: free ${free_now} GB < required ${required_gb} GB (2x current DB size ${current_gb} GB, floor ${VACUUM_MIN_FREE_GB} GB). VACUUM writes a full second copy of the file — this is exactly the condition that nearly wedged the disk on 2026-07-22. Checkpoint above already ran; skipping VACUUM only."
    exit 0
  fi
  log "Guard passed (free ${free_now} GB >= required ${required_gb} GB) — running full VACUUM."
  sqlite3 "$DB" 'VACUUM;'
  after=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
  delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
  log "VACUUM: ${before_mb} → ${after_mb} MB (reclaimed ${delta_mb} MB)"
fi

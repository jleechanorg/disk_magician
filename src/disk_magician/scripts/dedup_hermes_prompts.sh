#!/bin/bash
# dedup_hermes_prompts.sh — Reclaim disk space from duplicated
# sessions.system_prompt values in ~/.hermes/state.db (bead jleechan-m8um).
#
# Measured 2026-07-20: state.db 6.88 GiB, system_prompt payload ~1.95 GiB,
# avg 147KB/session, largely duplicate content because the same system
# prompt is stored verbatim per-session instead of once.
#
# DESIGN DECISION — why this is NOT a prompts(hash, body) reference table:
# the bead's default mechanism was hashing system_prompt into a shared
# table and replacing sessions.system_prompt with a hash/FK. We inspected
# the live consumer (hermes-agent's hermes_state.py): get_session() runs
# `SELECT * FROM sessions WHERE id = ?` and returns the row dict as-is;
# update_system_prompt() runs a raw `UPDATE sessions SET system_prompt = ?`.
# Both read and write the column as literal prompt text with zero
# indirection. Swapping in a hash/FK would silently corrupt every
# session's system_prompt for any Hermes process still running against
# the current schema — that's a hermes-agent release change, out of scope
# for a disk-maintenance script that must be safe to run today.
#
# SAFE VARIANT CHOSEN: instead of restructuring the schema, --apply NULLs
# out system_prompt on sessions older than a retention window (default 30
# days, HERMES_DEDUP_RETENTION_DAYS-overridable) after a mandatory
# verified backup, then VACUUMs. Old sessions' system_prompt values are
# cold — nothing reads them back — so this reclaims the same duplicated
# bytes without any schema/consumer risk.
#
# Default DRY-RUN — reports duplicate-content groups (informational) and
# the retention-based reclaim target (what --apply would actually do)
# without mutating the database. Pass --apply to mutate.
#
# HARD RULE: never run --apply against a live production Hermes state.db
# without confirming a fresh, verified backup and a low-traffic window —
# this script's backup + free-space gate is a safety net, not a
# substitute for that judgment call. Test/verify only against fixture
# databases (HERMES_STATE_DB=/path/to/fixture.db).
set -euo pipefail

DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"
RETENTION_DAYS="${HERMES_DEDUP_RETENTION_DAYS:-30}"
BACKUP_DIR="${HERMES_DEDUP_BACKUP_DIR:-$(dirname -- "$DB")}"
APPLY=false
for arg in "$@"; do [[ "$arg" == "--apply" ]] && APPLY=true; done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

# --- Interrupt trap (codex cross-model review defect 2026-07-23) ---
# If the script is interrupted (SIGINT/SIGTERM) mid-VACUUM, an orphaned
# .dedup-backup-<ts> file in BACKUP_DIR silently accumulates and is
# never cleaned by the retention sweep because the timestamp embeds
# the moment of the abort, not the original completion time. Surface
# the abort in the log and exit non-zero so the sweeper framework can
# detect it.
ABORTED_BACKUP=""
on_abort() {
  local sig="$1"
  log "ERROR: received $sig — aborting dedup_hermes_prompts.sh" >&2
  if [[ -n "$ABORTED_BACKUP" && -f "$ABORTED_BACKUP" ]]; then
    log "WARNING: orphaned backup left in place: $ABORTED_BACKUP (not auto-deleted — review manually)" >&2
  fi
  exit 130
}
trap 'on_abort SIGINT' INT
trap 'on_abort SIGTERM' TERM

if [[ ! -f "$DB" ]]; then
  log "No $DB — skipping"
  exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  log "ERROR: sqlite3 binary not on PATH — cannot process $DB" >&2
  exit 1
fi

db_abs="$DB"
case "$db_abs" in
  /*) ;;
  *) db_abs="$(pwd)/$db_abs" ;;
esac

sql_ro() { sqlite3 "file:${db_abs}?mode=ro" "$1"; }
sql_rw() { sqlite3 "$DB" "$1"; }

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

before=$(file_size "$DB")
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
log "state.db before: ${before_mb} MB ($DB)"

# --- Retention sweep for stale pre-flight backups (jleechan-ss5o) ---
# The pre-flight backup created below is deliberately kept on success as a
# safety net, but nothing ever removed it — so interrupted runs (see the trap
# below) AND old successful runs left full-size (multi-GB) dedup-backup-* copies
# forever (12 GB of orphans observed 2026-07-22). Purge copies older than the
# retention window on EVERY run (dry-run included) so they self-expire.
DEDUP_BACKUP_RETENTION_HOURS="${HERMES_DEDUP_BACKUP_RETENTION_HOURS:-48}"
purge_old_backups() {
  local dir="$BACKUP_DIR" pat n=0 freed=0 f sz
  [[ -d "$dir" ]] || return 0
  pat="$(basename -- "$DB").dedup-backup-*"
  while IFS= read -r -d '' f; do
    sz=$(file_size "$f")
    if rm -f -- "$f" 2>/dev/null; then
      n=$(( n + 1 )); freed=$(( freed + sz ))
      log "Purged stale dedup backup (>${DEDUP_BACKUP_RETENTION_HOURS}h, $(awk "BEGIN{printf \"%.1f\", $sz/1048576}") MB): $f"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "$pat" \
             -mmin "+$(( DEDUP_BACKUP_RETENTION_HOURS * 60 ))" -print0 2>/dev/null)
  [[ "$n" -gt 0 ]] && log "Retention sweep: removed ${n} stale backup(s), reclaimed $(awk "BEGIN{printf \"%.1f\", $freed/1048576}") MB"
  return 0
}
purge_old_backups

# --- Report: exact-duplicate system_prompt groups (informational only —
# this is NOT what --apply reclaims; see header for why). ---
dup_stats=$(sql_ro "
  SELECT COUNT(*), COALESCE(SUM((cnt - 1) * len), 0)
  FROM (
    SELECT length(system_prompt) AS len, COUNT(*) AS cnt
    FROM sessions
    WHERE system_prompt IS NOT NULL AND system_prompt != ''
    GROUP BY system_prompt
    HAVING COUNT(*) > 1
  );
")
dup_groups="${dup_stats%%|*}"
dup_bytes="${dup_stats##*|}"
dup_mb=$(awk "BEGIN {printf \"%.1f\", $dup_bytes / 1048576}")
log "Duplicate-content groups: ${dup_groups} (~${dup_mb} MB in duplicate copies; informational — see header for why this isn't deduped via a reference table)"

# --- Report: retention-based reclaim target (what --apply actually does) ---
old_stats=$(sql_ro "
  SELECT COUNT(*), COALESCE(SUM(length(system_prompt)), 0)
  FROM sessions
  WHERE system_prompt IS NOT NULL AND system_prompt != ''
    AND started_at < (strftime('%s','now') - ${RETENTION_DAYS} * 86400);
")
old_count="${old_stats%%|*}"
old_bytes="${old_stats##*|}"
old_mb=$(awk "BEGIN {printf \"%.1f\", $old_bytes / 1048576}")
log "Sessions older than ${RETENTION_DAYS}d with system_prompt set: ${old_count} (~${old_mb} MB reclaimable)"

if ! $APPLY; then
  log "[dry-run] would NULL system_prompt on ${old_count} sessions (~${old_mb} MB) and VACUUM — pass --apply to execute"
  exit 0
fi

if [[ "$old_count" -eq 0 ]]; then
  log "Nothing to do — no sessions older than ${RETENTION_DAYS}d have a system_prompt set"
  exit 0
fi

# --- Mandatory pre-flight backup; refuse --apply if it fails. ---
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
backup_path="${BACKUP_DIR%/}/$(basename -- "$DB").dedup-backup-$(date '+%Y%m%d-%H%M%S')"

db_size=$(file_size "$DB")
# `|| true` neutralizes pipeline failure (e.g. BACKUP_DIR unwritable/missing
# after the mkdir -p above failed) so `set -e` doesn't abort before the
# explicit refusal message below can print; a failed lookup falls through
# as avail_kb="" -> avail_bytes=0, which the size check then refuses.
avail_kb=$( (df -k "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}') || true )
avail_bytes=$(( ${avail_kb:-0} * 1024 ))
required_bytes=$(( db_size * 2 ))
if [[ "$avail_bytes" -lt "$required_bytes" ]]; then
  log "ERROR: refusing --apply — free space (${avail_bytes} bytes) at $BACKUP_DIR is below 2x db size (${required_bytes} bytes)" >&2
  exit 1
fi

if ! cp -- "$DB" "$backup_path" 2>/dev/null; then
  log "ERROR: refusing --apply — backup to $backup_path failed" >&2
  exit 1
fi
backup_size=$(file_size "$backup_path")
ABORTED_BACKUP="$backup_path"
if [[ "$backup_size" -eq 0 ]] || [[ "$backup_size" -ne "$db_size" ]]; then
  log "ERROR: refusing --apply — backup at $backup_path is incomplete (${backup_size} vs ${db_size} bytes)" >&2
  rm -f -- "$backup_path"
  exit 1
fi
log "Backup verified: $backup_path (${backup_size} bytes)"

# Remove this run's backup if we're interrupted/killed mid-mutation — an aborted
# run (e.g. the 2026-07-22 VACUUM incident) otherwise orphans a full-size copy
# with no owner. On NORMAL success the backup is kept as a safety net (swept
# later by purge_old_backups once it ages past the retention window). (ss5o)
trap 'rm -f -- "$backup_path" 2>/dev/null || true' INT TERM

# --- Mutate + reclaim ---
sql_rw "
  UPDATE sessions
  SET system_prompt = NULL
  WHERE system_prompt IS NOT NULL AND system_prompt != ''
    AND started_at < (strftime('%s','now') - ${RETENTION_DAYS} * 86400);
"
sql_rw "VACUUM;"

after=$(file_size "$DB")
after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
log "Dedup+VACUUM: ${before_mb} -> ${after_mb} MB (reclaimed ${delta_mb} MB, NULLed ${old_count} sessions), backup at $backup_path"

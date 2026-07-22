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
# VACUUM needs to write a full second copy of the file -- same class of
# incident as vacuum_hermes_state.sh's hermes-vacuum guard (jleechan-sd1t),
# and per team review this script's own VACUUM call (not hermes-vacuum's)
# was the actual trigger for the 2026-07-22 WAL-blowup. Reused pattern:
# refuse VACUUM unless free space >= max(2x current db size, floor).
VACUUM_MIN_FREE_GB="${HERMES_DEDUP_VACUUM_MIN_FREE_GB:-15}"
FREE_GB_OVERRIDE="${DISK_MAGICIAN_DEDUP_FREE_GB_OVERRIDE:-}"
APPLY=false
DELETE_BACKUPS=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --delete-backups) DELETE_BACKUPS=true ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

free_gb() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    echo "$FREE_GB_OVERRIDE"
    return
  fi
  local check_path="$BACKUP_DIR"
  [[ -d "$check_path" ]] || check_path="/"
  df -kP "$check_path" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}'
}

# --delete-backups: on-demand full cleanup of state.db.dedup-backup-*
# regardless of age, mirroring symlink-shared-playwright-cache.sh's pattern.
# Dry-run unless combined with --apply.
if [[ "$DELETE_BACKUPS" == true ]]; then
  log "=== DELETE HERMES DEDUP BACKUPS ==="
  if [[ "$APPLY" == true ]]; then
    log "Mode: APPLY (will delete)"
  else
    log "Mode: dry-run (pass --apply --delete-backups to actually delete)"
  fi
  base="$(basename -- "$DB")"
  found=0
  freed_kb=0
  shopt -s nullglob
  for f in "$BACKUP_DIR/${base}".dedup-backup-*; do
    [[ -f "$f" ]] || continue
    size_kb=$(( $(file_size "$f") / 1024 ))
    if [[ "$APPLY" == true ]]; then
      rm -f -- "$f"
      log "  deleted: $f (~$((size_kb / 1024)) MB)"
    else
      log "  [dry-run] would delete: $f (~$((size_kb / 1024)) MB)"
    fi
    found=$(( found + 1 ))
    freed_kb=$(( freed_kb + size_kb ))
  done
  shopt -u nullglob
  log "Backups found: ${found}  $([[ "$APPLY" == true ]] && echo Reclaimed || echo Would-reclaim): $(( freed_kb / 1024 )) MB"
  exit 0
fi

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

before=$(file_size "$DB")
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
log "state.db before: ${before_mb} MB ($DB)"

# --- Retention sweep for stale pre-flight backups (jleechan-ss5o) ---
# The pre-flight backup created below is deliberately kept on success as a
# safety net, but nothing ever removed it — so interrupted runs (see the trap
# below) AND old successful runs left full-size (multi-GB) dedup-backup-* copies
# forever (12 GB of orphans observed 2026-07-22). Purge copies older than the
# retention window so they self-expire. Deletions happen only under --apply;
# dry-run reports what WOULD be purged (a preview must not have side effects —
# codex review 2026-07-22).
DEDUP_BACKUP_RETENTION_HOURS="${HERMES_DEDUP_BACKUP_RETENTION_HOURS:-48}"
purge_old_backups() {
  local dir="$BACKUP_DIR" pat n=0 freed=0 f sz
  [[ -d "$dir" ]] || return 0
  pat="$(basename -- "$DB").dedup-backup-*"
  while IFS= read -r -d '' f; do
    sz=$(file_size "$f")
    if [[ "$APPLY" == true ]]; then
      rm -f -- "$f" 2>/dev/null || continue
      log "Purged stale dedup backup (>${DEDUP_BACKUP_RETENTION_HOURS}h, $(awk "BEGIN{printf \"%.1f\", $sz/1048576}") MB): $f"
    else
      log "[dry-run] would purge stale dedup backup (>${DEDUP_BACKUP_RETENTION_HOURS}h, $(awk "BEGIN{printf \"%.1f\", $sz/1048576}") MB): $f"
    fi
    n=$(( n + 1 )); freed=$(( freed + sz ))
  done < <(find "$dir" -maxdepth 1 -type f -name "$pat" \
             -mmin "+$(( DEDUP_BACKUP_RETENTION_HOURS * 60 ))" -print0 2>/dev/null)
  [[ "$n" -gt 0 ]] && log "Retention sweep: $([[ "$APPLY" == true ]] && echo removed || echo 'would remove') ${n} stale backup(s), $(awk "BEGIN{printf \"%.1f\", $freed/1048576}") MB"
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
# Also traps EXIT (not just INT/TERM): a `set -e`-triggered abort from any
# command between here and the committed=true line below (e.g. the UPDATE
# or VACUUM itself failing) is a normal-exit path, not a signal, so an
# INT/TERM-only trap would miss it and orphan the backup exactly the same
# way. `committed` gates the EXIT-trap cleanup so a genuinely successful
# run still keeps its backup unchanged from before.
committed=false
cleanup_backup_on_exit() {
  if [[ "$committed" != true ]]; then
    rm -f -- "$backup_path" 2>/dev/null || true
  fi
}
trap cleanup_backup_on_exit EXIT INT TERM

# --- Mutate + reclaim ---
# Keep the backup from the moment mutation BEGINS: once the UPDATE/VACUUM below
# start, an interrupt must PRESERVE the pre-mutation backup (it's the only
# recovery copy) rather than delete it — deleting it mid-VACUUM was a real
# data-loss path (codex review 2026-07-22). Orphaned backups from an interrupt
# are reclaimed later by purge_old_backups once they age past retention.
committed=true
sql_rw "
  UPDATE sessions
  SET system_prompt = NULL
  WHERE system_prompt IS NOT NULL AND system_prompt != ''
    AND started_at < (strftime('%s','now') - ${RETENTION_DAYS} * 86400);
"

# VACUUM free-space guard (jleechan-sd1t pattern): VACUUM writes a full
# second copy of the db, so refuse (non-fatal — the UPDATE above already
# safely reclaimed the logical space) unless free space is comfortably
# above 2x the current db size. This is the guard that would have caught
# the 2026-07-22 WAL-blowup incident.
vacuum_ran=false
current_size=$(file_size "$DB")
current_gb=$(awk "BEGIN {printf \"%.1f\", $current_size / 1073741824}")
free_now="$(free_gb)"
if [[ -z "$free_now" ]]; then
  log "REFUSING VACUUM: could not read free space — fail safe, no VACUUM attempted. UPDATE already applied; backup at $backup_path."
else
  required_gb=$(awk -v db="$current_gb" -v floor="$VACUUM_MIN_FREE_GB" 'BEGIN{req = db * 2; print (req > floor) ? req : floor}')
  guard_pass=$(awk -v f="$free_now" -v r="$required_gb" 'BEGIN{print (f >= r) ? "1" : "0"}')
  if [[ "$guard_pass" != "1" ]]; then
    log "REFUSING VACUUM: free ${free_now} GB < required ${required_gb} GB (2x current db size ${current_gb} GB, floor ${VACUUM_MIN_FREE_GB} GB). UPDATE already applied; backup at $backup_path. Re-run once free space recovers to reclaim the physical bytes."
  else
    sql_rw "VACUUM;"
    vacuum_ran=true
  fi
fi

after=$(file_size "$DB")
after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
if [[ "$vacuum_ran" == true ]]; then
  log "Dedup+VACUUM: ${before_mb} -> ${after_mb} MB (reclaimed ${delta_mb} MB, NULLed ${old_count} sessions), backup at $backup_path"
else
  log "Dedup (VACUUM deferred, see REFUSING line above): ${old_count} sessions NULLed, file size unchanged at ${after_mb} MB, backup at $backup_path"
fi

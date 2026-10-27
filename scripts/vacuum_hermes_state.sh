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
# Checkpoint-only on a live db: wait this long for a competing writer/reader.
BUSY_TIMEOUT_MS="${HERMES_DB_BUSY_TIMEOUT_MS:-30000}"
# Floor below which a full VACUUM refuses even if 2x DB size is smaller
# (e.g. a tiny DB shouldn't "pass" the guard at a razor-thin free margin).
VACUUM_MIN_FREE_GB="${VACUUM_MIN_FREE_GB:-15}"
RETENTION_DAYS="${HERMES_RETENTION_DAYS:-14}"
APPLY=false
FULL_VACUUM=false
COMPACT_FTS=false
ONLINE_CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --full-vacuum) FULL_VACUUM=true ;;
    --compact-fts) COMPACT_FTS=true ;;
    --clean)
      APPLY=true
      FULL_VACUUM=true
      COMPACT_FTS=true
      ONLINE_CLEAN=true
      export HERMES_DB_CHECKPOINT_APPROVED=1
      ;;
    --retention-days=*) RETENTION_DAYS="${arg#--retention-days=}" ;;
    --db=*) DB="${arg#--db=}" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/safety_lib.sh" ]]; then
  # shellcheck source=scripts/safety_lib.sh
  source "$SCRIPT_DIR/safety_lib.sh"
fi

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
# free_bytes — available bytes on the filesystem that actually holds $DB.
# NOT a hardcoded /System/Volumes/Data: HERMES_STATE_DB may live on a different
# mount, and checking the wrong volume could pass the guard while the DB's own
# volume is nearly full (codex review 2026-07-22). Byte precision (not rounded
# GB) so the 2x-DB comparison can't pass on a fractional-GB margin.
free_bytes() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    # test override is expressed in whole GB
    awk -v g="$FREE_GB_OVERRIDE" 'BEGIN{printf "%.0f", g * 1073741824}'
    return
  fi
  local target
  target="$(dirname -- "$DB")"
  [[ -e "$target" ]] || target="$DB"
  df -kP "$target" 2>/dev/null | awk 'NR==2{printf "%.0f", $4 * 1024}'
}

before=$(stat -f%z "$DB" 2>/dev/null || echo 0)
before_mb=$(awk "BEGIN {printf \"%.1f\", $before / 1048576}")
log "state.db before: ${before_mb} MB ($DB)"

wal_bytes=$(stat -f%z "$DB-wal" 2>/dev/null || echo 0)
wal_mb=$(awk "BEGIN {printf \"%.1f\", $wal_bytes / 1048576}")
jmode=$(sqlite3 -readonly -cmd ".timeout $BUSY_TIMEOUT_MS" "$DB" 'PRAGMA journal_mode;' 2>/dev/null | tail -1 || true)
log "state.db-wal: ${wal_mb} MB; journal_mode=${jmode:-unknown}"
# Live holder (another process has the db open): checkpoint is still safe under
# SQLite locking, but real runs on a live db need explicit approval.
holders=$(timeout 30 lsof -t -- "$DB" 2>/dev/null | grep -v -x "$$" | tr '\n' ' ' || true)
[[ -n "$holders" ]] && log "db held open by pid(s): ${holders}"

if ! $APPLY; then
  log "[dry-run] would wal_checkpoint(TRUNCATE) $DB (WAL ${wal_mb} MB, busy_timeout ${BUSY_TIMEOUT_MS}ms) — pass --apply to execute"
  [[ -n "$holders" ]] && log "[dry-run] live db: --apply also needs HERMES_DB_CHECKPOINT_APPROVED=1"
  if $FULL_VACUUM; then
    log "[dry-run] would also attempt guarded full VACUUM (--full-vacuum) if free space allows"
  fi
  exit 0
fi

if [[ -n "$holders" && "${HERMES_DB_CHECKPOINT_APPROVED:-}" != 1 ]]; then
  log "REFUSING: $DB is held open by pid(s) ${holders}; set HERMES_DB_CHECKPOINT_APPROVED=1 to checkpoint a live db."
  exit 0
fi

# ────────── Step 1: WAL checkpoint (routine, low-risk, no amplification) ──────────
log "Running wal_checkpoint(TRUNCATE) — flushes WAL into the main file, no full-size temp copy."
# Result row is busy|log_frames|checkpointed_frames; busy=1 means a reader pinned the WAL.
ckpt=$(sqlite3 -cmd ".timeout $BUSY_TIMEOUT_MS" "$DB" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>&1 | tail -1) || true
wal_after=$(stat -f%z "$DB-wal" 2>/dev/null || echo 0)
wal_after_mb=$(awk -v b="${wal_after:-0}" 'BEGIN {printf "%.1f", b / 1048576}')
log "checkpoint result busy|log|checkpointed=${ckpt:-none}; WAL ${wal_mb} MB -> ${wal_after_mb} MB"
[[ "$ckpt" == 1\|* ]] && log "checkpoint BUSY: a reader holds an old snapshot or a writer is active; WAL not truncated (retry later)."
after_checkpoint=$(stat -f%z "$DB" 2>/dev/null || echo 0)
after_checkpoint_mb=$(awk "BEGIN {printf \"%.1f\", $after_checkpoint / 1048576}")
log "wal_checkpoint(TRUNCATE) done — state.db now ${after_checkpoint_mb} MB (a checkpoint truncates *.db-wal, not the main file; main file only shrinks via VACUUM below)."

# ────────── Step 1b: FTS external-content migration & message retention (--compact-fts / --clean) ──────────
if $COMPACT_FTS && [[ "$ckpt" != 1\|* ]]; then
  log "Compacting Hermes messages (> ${RETENTION_DAYS}d) and migrating FTS5 indexes to v23 external-content layout..."
  python3 - "$DB" "$RETENTION_DAYS" "$BUSY_TIMEOUT_MS" <<'PY'
import os, sqlite3, sys, time

db_path = os.path.realpath(sys.argv[1])
retention_days = int(sys.argv[2])
timeout_ms = int(sys.argv[3])
cutoff_s = time.time() - retention_days * 86400

conn = sqlite3.connect(db_path, timeout=max(timeout_ms / 1000.0, 30.0), isolation_level=None)
conn.execute(f"PRAGMA busy_timeout = {max(timeout_ms, 30000)};")
conn.execute("PRAGMA cache_size = -1048576;")
conn.execute("PRAGMA mmap_size = 2147418112;")
conn.execute("PRAGMA temp_store = MEMORY;")
conn.execute("PRAGMA synchronous = NORMAL;")

has_messages = conn.execute(
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='messages'"
).fetchone()[0] > 0

if not has_messages:
    conn.close()
    sys.exit(0)

cols = {r[1] for r in conn.execute("PRAGMA table_info(messages)")}
if not {"id", "content", "timestamp"}.issubset(cols):
    conn.close()
    sys.exit(0)

# 1. Drop legacy/existing FTS triggers, views, and virtual tables before bulk message prune
for trig in (
    "messages_fts_insert",
    "messages_fts_delete",
    "messages_fts_update",
    "messages_fts_trigram_insert",
    "messages_fts_trigram_delete",
    "messages_fts_trigram_update",
):
    conn.execute(f"DROP TRIGGER IF EXISTS {trig};")

conn.execute("DROP VIEW IF EXISTS messages_fts_trigram_src;")
conn.execute("DROP TABLE IF EXISTS messages_fts;")
conn.execute("DROP TABLE IF EXISTS messages_fts_trigram;")

trash_tables = [
    r[0]
    for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'fts_v22_trash_%'"
    ).fetchall()
]
for t in trash_tables:
    conn.execute(f"DROP TABLE IF EXISTS {t};")

# 2. Prune expired messages in bounded batches
total_before = conn.execute("SELECT count(*) FROM messages").fetchone()[0]
pruned_msgs = 0
while True:
    conn.execute("BEGIN IMMEDIATE;")
    cur = conn.execute(
        "DELETE FROM messages WHERE id IN (SELECT id FROM messages WHERE timestamp < ? LIMIT 100000)",
        (cutoff_s,),
    )
    n = max(cur.rowcount, 0)
    conn.execute("COMMIT;")
    pruned_msgs += n
    if n < 100000:
        break

total_after = conn.execute("SELECT count(*) FROM messages").fetchone()[0]
print(f"[compact-fts] pruned {pruned_msgs}/{total_before} messages older than {retention_days}d ({total_after} remaining)", flush=True)

# 3. Recreate v23 external-content FTS5 schema and triggers
conn.execute("CREATE TABLE IF NOT EXISTS state_meta (key TEXT PRIMARY KEY, value TEXT);")

has_tool_cols = {"role", "tool_name", "tool_calls"}.issubset(cols)
if has_tool_cols:
    conn.executescript("""
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content,
    tool_name,
    tool_calls,
    content='messages',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages
WHEN (new.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                         WHERE key = 'fts_rebuild_high_water'), -1)
   OR new.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                          WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages
WHEN (old.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                         WHERE key = 'fts_rebuild_high_water'), -1)
   OR old.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                          WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, tool_calls)
    VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_update
AFTER UPDATE OF content, tool_name, tool_calls ON messages
WHEN (old.content IS NOT new.content
    OR old.tool_name IS NOT new.tool_name
    OR old.tool_calls IS NOT new.tool_calls)
   AND (old.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_rebuild_high_water'), -1)
     OR old.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, tool_calls)
    VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
    INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;

CREATE VIEW IF NOT EXISTS messages_fts_trigram_src AS
    SELECT id, role, content, tool_name, tool_calls
    FROM messages
    WHERE role <> 'tool';

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_trigram USING fts5(
    content,
    tool_name,
    tool_calls,
    content='messages_fts_trigram_src',
    content_rowid='id',
    tokenize='trigram'
);

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_insert AFTER INSERT ON messages
WHEN new.role <> 'tool'
   AND (new.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_rebuild_high_water'), -1)
     OR new.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts_trigram(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_delete AFTER DELETE ON messages
WHEN old.role <> 'tool'
   AND (old.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_rebuild_high_water'), -1)
     OR old.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts_trigram(messages_fts_trigram, rowid, content, tool_name, tool_calls)
    VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_trigram_update
AFTER UPDATE OF content, tool_name, tool_calls, role ON messages
WHEN (old.content IS NOT new.content
    OR old.tool_name IS NOT new.tool_name
    OR old.tool_calls IS NOT new.tool_calls
    OR old.role IS NOT new.role)
   AND (old.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_rebuild_high_water'), -1)
     OR old.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts_trigram(messages_fts_trigram, rowid, content, tool_name, tool_calls)
    SELECT 'delete', old.id, old.content, old.tool_name, old.tool_calls
    WHERE old.role <> 'tool';
    INSERT INTO messages_fts_trigram(rowid, content, tool_name, tool_calls)
    SELECT new.id, new.content, new.tool_name, new.tool_calls
    WHERE new.role <> 'tool';
END;
""")
    conn.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild');")
    conn.execute("INSERT INTO messages_fts_trigram(messages_fts_trigram) VALUES('rebuild');")
else:
    conn.executescript("""
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content,
    content='messages',
    content_rowid='id'
);
""")
    conn.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild');")

conn.execute(
    "INSERT INTO state_meta (key, value) VALUES ('fts_storage_version', '1') "
    "ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
)
conn.execute(
    "DELETE FROM state_meta WHERE key IN ('fts_optimize_available', 'fts_rebuild_high_water', 'fts_rebuild_progress');"
)
try:
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE);").fetchall()
except sqlite3.Error:
    pass
conn.close()
print("[compact-fts] rebuilt external-content FTS5 indexes (fts_storage_version=1)", flush=True)
PY
fi

# ────────── Step 2: full VACUUM (opt-in, free-space-gated) ──────────
if $FULL_VACUUM && [[ -n "$holders" ]] && { ! $ONLINE_CLEAN || [[ "$ckpt" == 1\|* ]]; }; then
  log "REFUSING full VACUUM: db is held open by pid(s) ${holders}; checkpoint only on a live db."
elif $FULL_VACUUM; then
  current_size=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  free_now_bytes="$(free_bytes)"
  if [[ -z "$free_now_bytes" || "$free_now_bytes" == 0 ]]; then
    log "REFUSING full VACUUM: could not read free space — fail safe, no VACUUM attempted."
    exit 0
  fi
  # Byte-precise: required = max(2 * current DB size, floor GB). No GB rounding,
  # so a fractional-GB shortfall can't slip past (codex review 2026-07-22).
  floor_bytes=$(( VACUUM_MIN_FREE_GB * 1073741824 ))
  twice_db_bytes=$(( current_size * 2 ))
  required_bytes=$(( twice_db_bytes > floor_bytes ? twice_db_bytes : floor_bytes ))
  current_gb=$(awk "BEGIN {printf \"%.2f\", $current_size / 1073741824}")
  free_gb_disp=$(awk "BEGIN {printf \"%.2f\", $free_now_bytes / 1073741824}")
  required_gb_disp=$(awk "BEGIN {printf \"%.2f\", $required_bytes / 1073741824}")
  if (( free_now_bytes < required_bytes )); then
    log "REFUSING full VACUUM: free ${free_gb_disp} GB < required ${required_gb_disp} GB (2x current DB size ${current_gb} GB, floor ${VACUUM_MIN_FREE_GB} GB). VACUUM writes a full second copy of the file — this is exactly the condition that nearly wedged the disk on 2026-07-22. Checkpoint above already ran; skipping VACUUM only."
    exit 0
  fi
  log "Guard passed (free ${free_gb_disp} GB >= required ${required_gb_disp} GB) — running full VACUUM."
  sqlite3 -cmd ".timeout $BUSY_TIMEOUT_MS" "$DB" 'PRAGMA cache_size = -1048576; PRAGMA mmap_size = 2147418112; PRAGMA temp_store = MEMORY; PRAGMA synchronous = NORMAL; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  after=$(stat -f%z "$DB" 2>/dev/null || echo 0)
  after_mb=$(awk "BEGIN {printf \"%.1f\", $after / 1048576}")
  delta_mb=$(awk "BEGIN {printf \"%.1f\", ($before - $after) / 1048576}")
  if declare -F deletion_log >/dev/null 2>&1 && (( before > after + 1048576 )); then
    deletion_log "$(basename "$0")" "vacuum_hermes_state" "$(( (before - after) / 1024 ))" "$DB"
  fi
  log "VACUUM: ${before_mb} → ${after_mb} MB (reclaimed ${delta_mb} MB)"
fi

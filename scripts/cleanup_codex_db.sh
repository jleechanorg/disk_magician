#!/usr/bin/env bash
# cleanup_codex_db.sh — Non-destructive online incremental vacuum & WAL checkpointing for ~/.codex SQLite DBs.
#
# Background (2026-10-03):
# In ~/.codex/, logs_2.sqlite accumulated 1,280,277 freelist pages (~4.88 GiB)
# of bloat because SQLite is in auto_vacuum=2 (incremental) mode, but no launchd
# sweeper or disk_magician script ever ran PRAGMA incremental_vacuum or
# PRAGMA wal_checkpoint(TRUNCATE).
#
# Hard Invariant:
# ~/.codex is on the hard never_delete list. Database files must NEVER be
# deleted, unlinked, or truncated directly. Only online SQLite incremental vacuum
# and WAL checkpointing may be performed. Fail closed: refuses deletion.
#
# Defaults to dry-run (pass --clean to actually vacuum and checkpoint).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
BUSY_TIMEOUT_MS="${CODEX_DB_BUSY_TIMEOUT_MS:-5000}"
MIN_FREELIST="${CODEX_DB_MIN_FREELIST:-1}"
CHUNK_SIZE="${CODEX_DB_CHUNK_SIZE:-50000}"
CODEX_DIR="${DISK_MAGICIAN_CODEX_DIR_OVERRIDE:-${CODEX_DIR:-$HOME/.codex}}"
TARGET_DBS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--db PATH] [--codex-dir PATH] [--min-freelist N] [--busy-timeout MS] [-h|--help]

Options:
  --clean            Execute incremental_vacuum and wal_checkpoint(TRUNCATE) (default: dry-run)
  --dry-run          Preview reclaimable freelist pages and sizes without modifying databases (default)
  --db PATH          Target a specific SQLite database (can be specified multiple times)
  --codex-dir PATH   Directory containing Codex databases (default: ~/.codex)
  --min-freelist N   Minimum freelist page count to trigger vacuum (default: 1)
  --busy-timeout MS  SQLite busy timeout in milliseconds (default: 5000)
  --chunk-size N     Incremental vacuum batch size in pages (default: 50000)
  -h, --help         Show this help message

Invariants:
  - Database files are NEVER deleted or unlinked (fail closed).
  - Uses online PRAGMA incremental_vacuum and PRAGMA wal_checkpoint(TRUNCATE).
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)
      DRY_RUN=false
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --db)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --db requires a file path" >&2; exit 2; }
      TARGET_DBS+=("$1")
      ;;
    --codex-dir)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --codex-dir requires a directory path" >&2; exit 2; }
      CODEX_DIR="$1"
      ;;
    --min-freelist)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --min-freelist requires a number" >&2; exit 2; }
      MIN_FREELIST="$1"
      ;;
    --busy-timeout)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --busy-timeout requires milliseconds" >&2; exit 2; }
      BUSY_TIMEOUT_MS="$1"
      ;;
    --chunk-size)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --chunk-size requires a page count" >&2; exit 2; }
      CHUNK_SIZE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$BUSY_TIMEOUT_MS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --busy-timeout / CODEX_DB_BUSY_TIMEOUT_MS must be an unsigned integer, got: $BUSY_TIMEOUT_MS" >&2
  exit 2
fi
BUSY_TIMEOUT_MS=$(( 10#$BUSY_TIMEOUT_MS ))

if ! [[ "$MIN_FREELIST" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --min-freelist / CODEX_DB_MIN_FREELIST must be an unsigned integer, got: $MIN_FREELIST" >&2
  exit 2
fi
MIN_FREELIST=$(( 10#$MIN_FREELIST ))

if ! [[ "$CHUNK_SIZE" =~ ^[0-9]+$ && "$(( 10#$CHUNK_SIZE ))" -gt 0 ]]; then
  echo "ERROR: --chunk-size / CODEX_DB_CHUNK_SIZE must be a positive integer, got: $CHUNK_SIZE" >&2
  exit 2
fi
CHUNK_SIZE=$(( 10#$CHUNK_SIZE ))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v sqlite3 >/dev/null 2>&1; then
  log "ERROR: sqlite3 binary not found on PATH — cannot inspect or vacuum databases" >&2
  exit 1
fi

file_size_bytes() {
  local f="$1"
  if [[ ! -f "$f" ]]; then echo 0; return; fi
  stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0
}

fmt_bytes() {
  local bytes="${1:-0}"
  awk "BEGIN{
    b = $bytes + 0
    if (b >= 1073741824)      printf \"%.2f GiB\", b / 1073741824
    else if (b >= 1048576)    printf \"%.2f MiB\", b / 1048576
    else if (b >= 1024)       printf \"%.1f KiB\", b / 1024
    else                      printf \"%d B\", b
  }"
}

# Resolve candidate databases
CANDIDATES=()
if [[ ${#TARGET_DBS[@]} -gt 0 ]]; then
  for db in "${TARGET_DBS[@]}"; do
    if [[ ! -e "$db" ]]; then
      log "WARNING: Specified database does not exist: $db — skipping"
      continue
    fi
    if [[ -L "$db" ]]; then
      log "WARNING: Specified database is a symbolic link: $db — refusing symlink target for safety"
      continue
    fi
    CANDIDATES+=("$db")
  done
else
  if [[ ! -d "$CODEX_DIR" ]]; then
    log "Codex directory not found at $CODEX_DIR — nothing to do."
    exit 0
  fi

  # Discover databases in CODEX_DIR, prioritizing primary telemetry and state files
  shopt -s nullglob
  seen_dbs=()
  for db in \
    "$CODEX_DIR"/logs_*.sqlite \
    "$CODEX_DIR"/state_*.sqlite \
    "$CODEX_DIR"/thread_history_*.sqlite \
    "$CODEX_DIR"/memories_*.sqlite \
    "$CODEX_DIR"/goals_*.sqlite \
    "$CODEX_DIR"/queue_*.sqlite \
    "$CODEX_DIR"/*.sqlite; do
      # Avoid duplicates, symlinks, and non-sqlite files
      [[ -f "$db" ]] || continue
      [[ -L "$db" ]] && continue
      [[ "$db" == *-wal || "$db" == *-shm ]] && continue
      already_seen=false
      for s in "${seen_dbs[@]:-}"; do
        if [[ "$s" == "$db" ]]; then
          already_seen=true
          break
        fi
      done
      if [[ "$already_seen" == false ]]; then
        seen_dbs+=("$db")
        CANDIDATES+=("$db")
      fi
  done
  shopt -u nullglob
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  log "No SQLite databases found to inspect."
  exit 0
fi

CODEX_DIR_REAL="$(cd "$CODEX_DIR" 2>/dev/null && pwd -P || echo "")"

total_checked=0
total_vacuumed=0
total_reclaimable=0
total_freed=0
total_locked=0

for db in "${CANDIDATES[@]}"; do
  # Skip 0-byte or inaccessible files
  if [[ ! -s "$db" ]]; then
    log "Skipping empty or 0-byte database: $db"
    continue
  fi

  # Fail-closed safety assertion: NEVER follow symlinks or mutate non-regular files
  if [[ -L "$db" ]]; then
    log "WARNING: $db is a symbolic link — refusing to mutate symlink target"
    continue
  fi

  if [[ ! -f "$db" ]]; then
    log "WARNING: $db is not a regular file — skipping"
    continue
  fi

  # Check hard link count portably across BSD/macOS (stat -f %l) and GNU/Linux (stat -c %h)
  link_count=""
  if link_count=$(stat -c %h "$db" 2>/dev/null) && [[ "$link_count" =~ ^[0-9]+$ ]]; then
    : # GNU/Linux stat succeeded
  elif link_count=$(stat -f %l "$db" 2>/dev/null) && [[ "$link_count" =~ ^[0-9]+$ ]]; then
    : # BSD/macOS stat succeeded
  else
    link_count=999 # Fail closed if stat dialect could not determine link count
  fi

  if [[ "$link_count" -gt 1 ]]; then
    log "WARNING: $db has multiple hard links (link count $link_count) — refusing hard-linked database for safety"
    continue
  elif [[ "$link_count" -ne 1 ]]; then
    log "WARNING: $db has unverified link count $link_count (!= 1) — refusing database for safety"
    continue
  fi

  # Verify canonical path remains inside the intended directory (unconditionally for all candidates)
  db_dir_real="$(cd "$(dirname "$db")" 2>/dev/null && pwd -P || echo "")"
  if [[ -z "$CODEX_DIR_REAL" || "$db_dir_real" != "$CODEX_DIR_REAL" ]]; then
    log "WARNING: $db directory ($db_dir_real) resolves outside $CODEX_DIR ($CODEX_DIR_REAL) — skipping"
    continue
  fi

  total_checked=$(( total_checked + 1 ))

  db_size_before=$(file_size_bytes "$db")
  wal_file="${db}-wal"
  wal_size_before=$(file_size_bytes "$wal_file")
  total_size_before=$(( db_size_before + wal_size_before ))

  # Query basic DB pragmas using -readonly to prevent SQLite from checkpointing WAL or mutating DB in dry-run
  set +e
  pragma_out=$(sqlite3 -readonly "$db" "PRAGMA busy_timeout=$BUSY_TIMEOUT_MS; PRAGMA page_size; PRAGMA page_count; PRAGMA freelist_count; PRAGMA auto_vacuum;" 2>&1)
  pragma_rc=$?
  set -e

  if [[ $pragma_rc -ne 0 ]]; then
    if [[ "$pragma_out" == *"database is locked"* || $pragma_rc -eq 5 ]]; then
      log "WARNING: Database is locked (busy timeout reached): $db — skipping"
      total_locked=$(( total_locked + 1 ))
    else
      log "WARNING: Failed to read pragmas from $db (code $pragma_rc): $pragma_out — skipping"
    fi
    continue
  fi

  read -r _busy_res page_size page_count freelist_count auto_vacuum <<< "$(echo "$pragma_out" | tr '\n' ' ')"
  page_size="${page_size:-0}"
  page_count="${page_count:-0}"
  freelist_count="${freelist_count:-0}"
  auto_vacuum="${auto_vacuum:-0}"

  if ! [[ "$page_size" =~ ^[0-9]+$ && "$freelist_count" =~ ^[0-9]+$ && "$auto_vacuum" =~ ^[0-9]+$ ]]; then
    log "WARNING: Malformed pragma response from $db: $pragma_out — skipping"
    continue
  fi

  reclaimable_bytes=$(( freelist_count * page_size ))

  if [[ "$auto_vacuum" -ne 2 ]]; then
    # auto_vacuum: 0 = none, 1 = full, 2 = incremental
    auto_vac_desc="none (0)"
    [[ "$auto_vacuum" -eq 1 ]] && auto_vac_desc="full (1)"
    log "INFO: $db auto_vacuum=$auto_vac_desc — incremental_vacuum requires auto_vacuum=2 (incremental); skipping vacuum"
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] $db: page_count=$page_count, freelist=$freelist_count pages, WAL size: $(fmt_bytes $wal_size_before)"
    fi
    continue
  fi

  needs_vacuum=false
  if (( freelist_count >= MIN_FREELIST && freelist_count > 0 )); then
    needs_vacuum=true
    total_reclaimable=$(( total_reclaimable + reclaimable_bytes ))
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$needs_vacuum" == true ]]; then
      log "  [dry-run] $db: freelist=$freelist_count pages, page_size=$page_size B, page_count=$page_count, reclaimable: $(fmt_bytes $reclaimable_bytes) (WAL size: $(fmt_bytes $wal_size_before))"
    else
      log "  [dry-run] $db: clean (freelist=$freelist_count pages, 0 B reclaimable, WAL size: $(fmt_bytes $wal_size_before))"
    fi
    continue
  fi

  # ── Execution mode (--clean) ──────────────────────────────────────────────
  if [[ "$needs_vacuum" == true ]]; then
    log "Vacuuming $db: $freelist_count freelist pages (~$(fmt_bytes $reclaimable_bytes))..."
    vacuum_failed=false

    if (( freelist_count > CHUNK_SIZE )); then
      log "  Running incremental_vacuum in batches of $CHUNK_SIZE pages..."
      remaining=$freelist_count
      while (( remaining > 0 )); do
        chunk=$(( remaining > CHUNK_SIZE ? CHUNK_SIZE : remaining ))
        set +e
        v_out=$(sqlite3 "$db" "PRAGMA busy_timeout=$BUSY_TIMEOUT_MS; PRAGMA incremental_vacuum($chunk);" 2>&1)
        v_rc=$?
        set -e
        if [[ $v_rc -ne 0 ]]; then
          if [[ "$v_out" == *"database is locked"* || $v_rc -eq 5 ]]; then
            log "WARNING: Database is locked (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping vacuum batch"
            total_locked=$(( total_locked + 1 ))
          else
            log "WARNING: incremental_vacuum batch failed for $db (code $v_rc): $v_out"
          fi
          vacuum_failed=true
          break
        fi
        remaining=$(( remaining - chunk ))
        # Check current freelist count to avoid unnecessary iterations
        cur_fl=$(sqlite3 -readonly "$db" "PRAGMA busy_timeout=$BUSY_TIMEOUT_MS; PRAGMA freelist_count;" 2>/dev/null | tail -n 1 || echo "")
        if [[ "$cur_fl" =~ ^[0-9]+$ ]] && (( cur_fl == 0 )); then break; fi
      done
    else
      set +e
      v_out=$(sqlite3 "$db" "PRAGMA busy_timeout=$BUSY_TIMEOUT_MS; PRAGMA incremental_vacuum;" 2>&1)
      v_rc=$?
      set -e
      if [[ $v_rc -ne 0 ]]; then
        if [[ "$v_out" == *"database is locked"* || $v_rc -eq 5 ]]; then
          log "WARNING: Database is locked (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping vacuum"
          total_locked=$(( total_locked + 1 ))
        else
          log "WARNING: incremental_vacuum failed for $db (code $v_rc): $v_out"
        fi
        vacuum_failed=true
      fi
    fi

    if [[ "$vacuum_failed" == false ]]; then
      total_vacuumed=$(( total_vacuumed + 1 ))
    fi
  fi

  # Always perform wal_checkpoint(TRUNCATE) to truncate the WAL file
  set +e
  cp_out=$(sqlite3 "$db" "PRAGMA busy_timeout=$BUSY_TIMEOUT_MS; PRAGMA wal_checkpoint(TRUNCATE);" 2>&1)
  cp_rc=$?
  set -e
  if [[ $cp_rc -ne 0 ]]; then
    if [[ "$cp_out" == *"database is locked"* || $cp_rc -eq 5 ]]; then
      log "WARNING: Database is locked during checkpoint (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping checkpoint"
    else
      log "WARNING: wal_checkpoint failed for $db (code $cp_rc): $cp_out"
    fi
  fi

  db_size_after=$(file_size_bytes "$db")
  wal_size_after=$(file_size_bytes "$wal_file")
  total_size_after=$(( db_size_after + wal_size_after ))

  freed=0
  if (( total_size_before > total_size_after )); then
    freed=$(( total_size_before - total_size_after ))
  fi
  total_freed=$(( total_freed + freed ))

  log "  [clean] $db: freed $(fmt_bytes $freed) (DB: $(fmt_bytes $db_size_before) -> $(fmt_bytes $db_size_after), WAL: $(fmt_bytes $wal_size_before) -> $(fmt_bytes $wal_size_after))"
done

echo
if [[ "$DRY_RUN" == true ]]; then
  log "Codex DB vacuum preview: checked $total_checked database(s), total reclaimable: $(fmt_bytes $total_reclaimable)"
else
  log "Codex DB vacuum complete: checked $total_checked database(s), vacuumed $total_vacuumed, total freed: $(fmt_bytes $total_freed)"
fi

if [[ $total_locked -gt 0 ]]; then
  log "Notice: $total_locked database operation(s) skipped due to concurrent locks/busy timeout."
fi

exit 0

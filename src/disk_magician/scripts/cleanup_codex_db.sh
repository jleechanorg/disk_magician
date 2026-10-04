#!/usr/bin/env bash
# cleanup_codex_db.sh — Non-destructive online incremental vacuum & WAL checkpointing for ~/.codex SQLite DBs.
#
# Hard Invariants:
# - Database files are NEVER deleted, unlinked, overwritten, truncated directly or recreated.
# - Only online SQLite incremental vacuum and WAL checkpointing may be performed.
# - Every SQLite operation applies busy_timeout via CLI -cmd '.timeout N'.
# - Per-database single-maintainer lease keyed by canonical physical identity (dev:inode).
# - Conservative active-open-client check via lsof (fails closed; skips open DB/WAL/SHM).
# - Parses every wal_checkpoint result row (busy=1 or incomplete counters mark non-success).
# - Verifies poststate: freelist, WAL, database identity/existence.
# - Failed/busy/active/leased/incomplete outcomes exit non-zero without claiming success.
#
# Defaults to dry-run (pass --clean to actually vacuum and checkpoint).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
BUSY_TIMEOUT_MS="${CODEX_DB_BUSY_TIMEOUT_MS:-5000}"
MIN_FREELIST="${CODEX_DB_MIN_FREELIST:-1}"
CHUNK_SIZE="${CODEX_DB_CHUNK_SIZE:-50000}"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LEASE_DIR_BASE="$STATE_DIR/codex_db_leases"
TARGET_DBS=()

ACTIVE_LEASES=()
cleanup_all_leases() {
  local l pid
  for l in "${ACTIVE_LEASES[@]:-}"; do
    if [[ -d "$l" ]]; then
      pid=$(cat "$l/pid" 2>/dev/null || echo "")
      if [[ "$pid" == "$$" ]]; then
        rm -f "$l/pid" 2>/dev/null || true
        rmdir "$l" 2>/dev/null || true
      fi
    fi
  done
  ACTIVE_LEASES=()
}

trap_handler() {
  local sig="${1:-0}"
  cleanup_all_leases
  if [[ "$sig" -ne 0 ]]; then
    trap - EXIT HUP INT TERM
    exit $(( 128 + sig ))
  fi
}

trap 'trap_handler 0' EXIT
trap 'trap_handler 1' HUP
trap 'trap_handler 2' INT
trap 'trap_handler 15' TERM

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--db PATH] [--codex-dir PATH] [--min-freelist N] [--busy-timeout MS] [--chunk-size N] [-h|--help]

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
  - Database files are NEVER deleted, unlinked, or truncated directly (fail closed).
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

# Numeric validation (applies to CLI args and CODEX_DB_* environment variables)
validate_int_gte_zero() {
  local val="$1" name="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name requires a non-negative integer, got '$val'" >&2
    exit 2
  fi
}

validate_int_gt_zero() {
  local val="$1" name="$2" max_val="${3:-}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( 10#$val <= 0 )); then
    echo "ERROR: $name requires a positive integer, got '$val'" >&2
    exit 2
  fi
  if [[ -n "$max_val" ]] && (( 10#$val > max_val )); then
    echo "ERROR: $name exceeds maximum allowed ($max_val), got '$val'" >&2
    exit 2
  fi
}

validate_int_gt_zero "$BUSY_TIMEOUT_MS" "--busy-timeout / CODEX_DB_BUSY_TIMEOUT_MS" 3600000
validate_int_gte_zero "$MIN_FREELIST" "--min-freelist / CODEX_DB_MIN_FREELIST"
validate_int_gt_zero "$CHUNK_SIZE" "--chunk-size / CODEX_DB_CHUNK_SIZE" 10000000

BUSY_TIMEOUT_MS=$(( 10#$BUSY_TIMEOUT_MS ))
MIN_FREELIST=$(( 10#$MIN_FREELIST ))
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

file_inode() {
  local f="$1"
  if [[ ! -e "$f" ]]; then echo ""; return; fi
  stat -f%i "$f" 2>/dev/null || stat -c%i "$f" 2>/dev/null || echo ""
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

get_db_physical_id() {
  local target="$1"
  local real_target
  if ! real_target=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null); then
    return 1
  fi
  local id=""
  if id=$(stat -f '%d_%i' "$real_target" 2>/dev/null); then
    printf '%s\n' "$id"
    return 0
  fi
  if id=$(stat -c '%d_%i' "$real_target" 2>/dev/null); then
    printf '%s\n' "$id"
    return 0
  fi
  return 1
}

verify_db_identity() {
  local target="$1" expected_id="$2"
  local cur_id
  if ! cur_id=$(get_db_physical_id "$target"); then
    return 1
  fi
  [[ "$cur_id" == "$expected_id" ]]
}

current_lease=""
acquire_db_lease() {
  local target="$1" db_id="$2"
  current_lease=""
  local lease_path="$LEASE_DIR_BASE/${db_id}.lease"
  mkdir -p "$LEASE_DIR_BASE"
  if mkdir "$lease_path" 2>/dev/null; then
    echo "$$" > "$lease_path/pid"
    current_lease="$lease_path"
    ACTIVE_LEASES+=("$lease_path")
    return 0
  fi
  local held_pid
  held_pid=$(cat "$lease_path/pid" 2>/dev/null || echo "unknown")
  log "WARNING: Database lease held by another maintainer (pid: $held_pid, lease: $lease_path): $target — skipping" >&2
  return 1
}

release_db_lease() {
  local lease_path="$1"
  if [[ -n "$lease_path" && -d "$lease_path" ]]; then
    local pid
    pid=$(cat "$lease_path/pid" 2>/dev/null || echo "")
    if [[ "$pid" == "$$" ]]; then
      rm -f "$lease_path/pid" 2>/dev/null || true
      rmdir "$lease_path" 2>/dev/null || true
    fi
  fi
  local remaining=()
  for l in "${ACTIVE_LEASES[@]:-}"; do
    [[ "$l" != "$lease_path" ]] && remaining+=("$l")
  done
  ACTIVE_LEASES=("${remaining[@]:-}")
  current_lease=""
}

db_uri() {
  local path="$1" mode="$2"
  local real_p
  real_p=$(python3 -c 'import os, sys, urllib.parse; print(urllib.parse.quote(os.path.realpath(sys.argv[1])))' "$path" 2>/dev/null)
  if [[ -z "$real_p" ]]; then
    return 1
  fi
  printf 'file:%s?mode=%s\n' "$real_p" "$mode"
}

run_sqlite() {
  local uri="$1" sql="$2"
  sqlite3 -cmd ".timeout $BUSY_TIMEOUT_MS" "$uri" "$sql"
}

check_active_open_clients() {
  local target="$1"
  local wal="${target}-wal"
  local shm="${target}-shm"
  local lsof_bin=""
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
    lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif command -v lsof >/dev/null 2>&1; then
    lsof_bin="$(command -v lsof)"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin="/usr/sbin/lsof"
  fi
  if [[ -z "$lsof_bin" || ! -x "$lsof_bin" ]]; then
    log "WARNING: lsof unavailable to inspect active clients for $target — fail-closed, skipping" >&2
    return 1
  fi

  local timeout_sec="${DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS:-60}"
  local timeout_cmd=()
  if [[ -n "${DISK_MAGICIAN_TIMEOUT_BIN:-}" ]]; then
    timeout_cmd=("${DISK_MAGICIAN_TIMEOUT_BIN}" "$timeout_sec")
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd=("timeout" "$timeout_sec")
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=("gtimeout" "$timeout_sec")
  elif command -v python3 >/dev/null 2>&1; then
    timeout_cmd=("python3" "-c" 'import subprocess, sys; p = subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])); sys.exit(p.returncode)' "$timeout_sec")
  else
    log "WARNING: timeout capability unavailable for lsof — fail-closed, skipping" >&2
    return 1
  fi

  local real_target
  if ! real_target=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null); then
    log "WARNING: Could not resolve realpath for $target — fail-closed, skipping" >&2
    return 1
  fi
  local probe_files=("$real_target")
  local real_wal="${real_target}-wal"
  local real_shm="${real_target}-shm"
  if [[ -e "$real_wal" ]]; then
    probe_files+=("$real_wal")
  fi
  if [[ -e "$real_shm" ]]; then
    probe_files+=("$real_shm")
  fi

  local lsof_out lsof_err rc=0
  lsof_out=$(mktemp)
  lsof_err=$(mktemp)
  set +e
  "${timeout_cmd[@]}" "$lsof_bin" -nP -F p "${probe_files[@]}" >"$lsof_out" 2>"$lsof_err"
  rc=$?
  set -e

  local err_content=""
  err_content=$(cat "$lsof_err" 2>/dev/null || true)
  rm -f "$lsof_err"

  if [[ -n "$err_content" ]]; then
    log "WARNING: lsof inspection warning/error for $target (rc=$rc, stderr: $err_content) — fail-closed, skipping" >&2
    rm -f "$lsof_out"
    return 1
  fi

  if [[ $rc -ne 0 && $rc -ne 1 ]]; then
    log "WARNING: lsof inspection failed (rc=$rc) for $target — fail-closed, skipping" >&2
    rm -f "$lsof_out"
    return 1
  fi

  local out_content=""
  out_content=$(cat "$lsof_out" 2>/dev/null || true)
  rm -f "$lsof_out"

  if [[ $rc -eq 1 ]]; then
    if [[ -n "$out_content" ]]; then
      log "WARNING: unexpected stdout from lsof with rc=1 for $target: $out_content — fail-closed, skipping" >&2
      return 1
    fi
    return 0
  fi

  local pids=()
  local malformed=false
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^p([0-9]+)$ ]]; then
      pids+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^f[a-zA-Z0-9]+$ ]]; then
      # Valid file descriptor line in lsof -F output
      continue
    else
      malformed=true
      break
    fi
  done <<< "$out_content"

  if [[ "$malformed" == true || ${#pids[@]} -eq 0 ]]; then
    log "WARNING: malformed lsof stdout for $target (rc=$rc): '$out_content' — fail-closed, skipping" >&2
    return 1
  fi

  local pid_list
  pid_list="${pids[*]}"
  log "WARNING: Active open client(s) detected for $target (pids: $pid_list) — skipping" >&2
  return 1
}

parse_wal_checkpoint() {
  local cp_raw="$1" db="$2"
  local cp_trimmed
  cp_trimmed=$(echo "$cp_raw" | grep -v '^[[:space:]]*$' || true)
  if [[ -z "$cp_trimmed" ]]; then
    log "WARNING: empty wal_checkpoint output for $db" >&2
    return 1
  fi

  local row_count=0
  local has_failure=false

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    row_count=$(( row_count + 1 ))
    if ! [[ "$line" =~ ^(-?[0-9]+)\|(-?[0-9]+)\|(-?[0-9]+)$ ]]; then
      log "WARNING: malformed wal_checkpoint row: '$line' for $db" >&2
      has_failure=true
      continue
    fi
    local cp_busy="${BASH_REMATCH[1]}"
    local cp_log="${BASH_REMATCH[2]}"
    local cp_ckpt="${BASH_REMATCH[3]}"

    if (( cp_busy != 0 )); then
      log "WARNING: wal_checkpoint busy (busy=$cp_busy, log=$cp_log, checkpointed=$cp_ckpt) for $db" >&2
      has_failure=true
      continue
    fi

    if (( cp_log == -1 && cp_ckpt == -1 )); then
      log "INFO: $db is not in WAL mode (wal_checkpoint no-op: 0|-1|-1)"
      continue
    fi

    if (( cp_log < 0 || cp_ckpt < 0 )); then
      log "WARNING: malformed/impossible wal_checkpoint counters: '$line' for $db" >&2
      has_failure=true
      continue
    fi

    if (( cp_ckpt < cp_log )); then
      log "WARNING: wal_checkpoint incomplete (busy=0, log=$cp_log, checkpointed=$cp_ckpt) for $db" >&2
      has_failure=true
      continue
    fi

    if (( cp_log != 0 || cp_ckpt != 0 )); then
      log "WARNING: wal_checkpoint TRUNCATE did not reset WAL (busy=0, log=$cp_log, checkpointed=$cp_ckpt) for $db" >&2
      has_failure=true
      continue
    fi
  done <<< "$cp_trimmed"

  if (( row_count == 0 )); then
    log "WARNING: no wal_checkpoint rows parsed for $db" >&2
    return 1
  fi

  if [[ "$has_failure" == true ]]; then
    return 1
  fi

  return 0
}

# Resolve candidate databases
CANDIDATES=()
any_non_success=false
if [[ ${#TARGET_DBS[@]} -gt 0 ]]; then
  for db in "${TARGET_DBS[@]}"; do
    if [[ ! -e "$db" ]]; then
      log "WARNING: Specified database does not exist: $db — skipping" >&2
      any_non_success=true
      continue
    fi
    if [[ ! -f "$db" ]]; then
      log "WARNING: Specified database is not a regular file: $db — skipping" >&2
      any_non_success=true
      continue
    fi
    CANDIDATES+=("$db")
  done
else
  if [[ ! -d "$CODEX_DIR" ]]; then
    log "Codex directory not found at $CODEX_DIR — nothing to do."
    exit 0
  fi

  shopt -s nullglob
  primary_patterns=(
    "$CODEX_DIR"/logs_*.sqlite
    "$CODEX_DIR"/state_*.sqlite
    "$CODEX_DIR"/thread_history_*.sqlite
    "$CODEX_DIR"/memories_*.sqlite
    "$CODEX_DIR"/goals_*.sqlite
    "$CODEX_DIR"/queue_*.sqlite
    "$CODEX_DIR"/*.sqlite
  )
  seen_dbs=()
  for db_pattern in "${primary_patterns[@]}"; do
    for db in $db_pattern; do
      [[ -f "$db" ]] || continue
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
  done
  shopt -u nullglob
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  if [[ "$any_non_success" == true ]]; then
    log "ERROR: None of the specified databases could be processed." >&2
    exit 1
  fi
  log "No SQLite databases found to inspect."
  exit 0
fi

total_checked=0
total_vacuumed=0
total_reclaimable=0
total_freed=0
total_locked=0

for db in "${CANDIDATES[@]}"; do
  # Check existence: must exist and be regular file
  if [[ ! -e "$db" || ! -f "$db" ]]; then
    log "WARNING: $db is not a regular file — skipping" >&2
    any_non_success=true
    continue
  fi

  # Skip 0-byte files safely
  if [[ ! -s "$db" ]]; then
    log "Skipping empty or 0-byte database: $db"
    continue
  fi

  db_physical_id=$(get_db_physical_id "$db") || {
    log "WARNING: Could not determine physical identity for $db — skipping" >&2
    any_non_success=true
    continue
  }

  total_checked=$(( total_checked + 1 ))

  # Acquire per-database single-maintainer lease
  current_lease=""
  if [[ "$DRY_RUN" == false ]]; then
    if ! acquire_db_lease "$db" "$db_physical_id"; then
      total_locked=$(( total_locked + 1 ))
      any_non_success=true
      continue
    fi
  fi

  # Conservative active-open-client check
  if [[ "$DRY_RUN" == false ]]; then
    if ! check_active_open_clients "$db"; then
      total_locked=$(( total_locked + 1 ))
      any_non_success=true
      [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
      continue
    fi
  fi

  # Recheck physical identity before opening URI
  if ! verify_db_identity "$db" "$db_physical_id"; then
    log "ERROR: Database identity changed or disappeared: $db" >&2
    any_non_success=true
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
    continue
  fi

  mode="rw"
  [[ "$DRY_RUN" == true ]] && mode="ro"
  target_uri=$(db_uri "$db" "$mode")
  if [[ -z "$target_uri" ]]; then
    log "WARNING: Could not construct valid URI for $db — skipping" >&2
    any_non_success=true
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
    continue
  fi

  db_size_before=$(file_size_bytes "$db")
  wal_file="${db}-wal"
  wal_size_before=$(file_size_bytes "$wal_file")
  total_size_before=$(( db_size_before + wal_size_before ))

  # Query basic DB pragmas with busy timeout via URI mode
  set +e
  pragma_out=$(run_sqlite "$target_uri" "PRAGMA page_size; PRAGMA page_count; PRAGMA freelist_count; PRAGMA auto_vacuum;" 2>&1)
  pragma_rc=$?
  set -e

  if [[ $pragma_rc -ne 0 ]]; then
    any_non_success=true
    if [[ "$pragma_out" == *"database is locked"* || $pragma_rc -eq 5 ]]; then
      log "WARNING: Database locked (busy timeout reached): $db — skipping" >&2
      total_locked=$(( total_locked + 1 ))
    else
      log "WARNING: Failed to read pragmas from $db (code $pragma_rc): $pragma_out — skipping" >&2
    fi
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
    continue
  fi

  read -r page_size page_count freelist_count auto_vacuum <<< "$(echo "$pragma_out" | tr '\n' ' ')"
  page_size="${page_size:-0}"
  page_count="${page_count:-0}"
  freelist_count="${freelist_count:-0}"
  auto_vacuum="${auto_vacuum:-0}"

  if ! [[ "$page_size" =~ ^[0-9]+$ && "$freelist_count" =~ ^[0-9]+$ && "$auto_vacuum" =~ ^[0-9]+$ ]]; then
    log "WARNING: Malformed pragma response from $db: $pragma_out — skipping" >&2
    any_non_success=true
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
    continue
  fi

  reclaimable_bytes=$(( freelist_count * page_size ))

  if [[ "$auto_vacuum" -ne 2 ]]; then
    auto_vac_desc="none (0)"
    [[ "$auto_vacuum" -eq 1 ]] && auto_vac_desc="full (1)"
    log "INFO: $db auto_vacuum=$auto_vac_desc — incremental_vacuum requires auto_vacuum=2 (incremental); skipping vacuum"
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] $db: page_count=$page_count, freelist=$freelist_count pages, WAL size: $(fmt_bytes $wal_size_before)"
    fi
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
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
    [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
    continue
  fi

  # ── Execution mode (--clean) ──────────────────────────────────────────────
  vacuum_failed=false
  if [[ "$needs_vacuum" == true ]]; then
    log "Vacuuming $db: $freelist_count freelist pages (~$(fmt_bytes $reclaimable_bytes))..."

    if (( freelist_count > CHUNK_SIZE )); then
      log "  Running incremental_vacuum in batches of $CHUNK_SIZE pages..."
      remaining=$freelist_count
      while (( remaining > 0 )); do
        if ! verify_db_identity "$db" "$db_physical_id"; then
          log "ERROR: Database identity changed or disappeared during vacuum: $db" >&2
          vacuum_failed=true
          break
        fi
        chunk=$(( remaining > CHUNK_SIZE ? CHUNK_SIZE : remaining ))
        set +e
        v_out=$(run_sqlite "$target_uri" "PRAGMA incremental_vacuum($chunk);" 2>&1)
        v_rc=$?
        set -e
        if [[ $v_rc -ne 0 ]]; then
          if [[ "$v_out" == *"database is locked"* || $v_rc -eq 5 ]]; then
            log "WARNING: Database is locked (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping vacuum batch" >&2
            total_locked=$(( total_locked + 1 ))
          else
            log "WARNING: incremental_vacuum batch failed for $db (code $v_rc): $v_out" >&2
          fi
          vacuum_failed=true
          break
        fi
        remaining=$(( remaining - chunk ))
        set +e
        cur_fl_out=$(run_sqlite "$target_uri" "PRAGMA freelist_count;" 2>&1)
        cur_fl_rc=$?
        set -e
        if [[ $cur_fl_rc -ne 0 || ! "$cur_fl_out" =~ ^[0-9]+$ ]]; then
          log "WARNING: Failed to query freelist count during vacuum of $db: $cur_fl_out" >&2
          vacuum_failed=true
          break
        fi
        if (( cur_fl_out == 0 )); then break; fi
      done
    else
      if ! verify_db_identity "$db" "$db_physical_id"; then
        log "ERROR: Database identity changed or disappeared before vacuum: $db" >&2
        vacuum_failed=true
      else
        set +e
        v_out=$(run_sqlite "$target_uri" "PRAGMA incremental_vacuum;" 2>&1)
        v_rc=$?
        set -e
        if [[ $v_rc -ne 0 ]]; then
          if [[ "$v_out" == *"database is locked"* || $v_rc -eq 5 ]]; then
            log "WARNING: Database is locked (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping vacuum" >&2
            total_locked=$(( total_locked + 1 ))
          else
            log "WARNING: incremental_vacuum failed for $db (code $v_rc): $v_out" >&2
          fi
          vacuum_failed=true
        fi
      fi
    fi
  fi

  # Always perform wal_checkpoint(TRUNCATE) to truncate the WAL file
  checkpoint_failed=false
  if ! verify_db_identity "$db" "$db_physical_id"; then
    log "ERROR: Database identity changed or disappeared before checkpoint: $db" >&2
    checkpoint_failed=true
  else
    set +e
    cp_out=$(run_sqlite "$target_uri" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1)
    cp_rc=$?
    set -e
    if [[ $cp_rc -ne 0 ]]; then
      checkpoint_failed=true
      if [[ "$cp_out" == *"database is locked"* || $cp_rc -eq 5 ]]; then
        log "WARNING: Database is locked during checkpoint (busy timeout after ${BUSY_TIMEOUT_MS}ms): $db — skipping checkpoint" >&2
        total_locked=$(( total_locked + 1 ))
      else
        log "WARNING: wal_checkpoint failed for $db (code $cp_rc): $cp_out" >&2
      fi
    else
      if ! parse_wal_checkpoint "$cp_out" "$db"; then
        checkpoint_failed=true
        total_locked=$(( total_locked + 1 ))
      fi
    fi
  fi

  # Poststate verification: freelist, WAL, database identity/existence
  db_size_after=$(file_size_bytes "$db")
  wal_size_after=$(file_size_bytes "$wal_file")
  total_size_after=$(( db_size_after + wal_size_after ))

  # Identity verification: DB file identity must never change
  if [[ ! -f "$db" ]]; then
    log "ERROR: Invariant violation: database file disappeared: $db" >&2
    exit 1
  fi
  if ! verify_db_identity "$db" "$db_physical_id"; then
    log "ERROR: Invariant violation: database file identity changed for $db" >&2
    exit 1
  fi

  # Query poststate pragmas with busy timeout
  set +e
  post_pragma=$(run_sqlite "$target_uri" "PRAGMA page_size; PRAGMA page_count; PRAGMA freelist_count;" 2>&1)
  post_rc=$?
  set -e
  if [[ $post_rc -ne 0 ]]; then
    log "WARNING: Failed to read poststate pragmas from $db (code $post_rc): $post_pragma — skipping" >&2
    vacuum_failed=true
    checkpoint_failed=true
  else
    read -r post_ps post_pc post_fl <<< "$(echo "$post_pragma" | tr '\n' ' ')"
    if ! [[ "$post_ps" =~ ^[0-9]+$ && "$post_pc" =~ ^[0-9]+$ && "$post_fl" =~ ^[0-9]+$ ]]; then
      log "WARNING: Malformed poststate pragma output for $db: $post_pragma" >&2
      vacuum_failed=true
      checkpoint_failed=true
    else
      if [[ "$needs_vacuum" == true && "$vacuum_failed" == false ]]; then
        if (( post_fl != 0 )); then
          log "WARNING: Freelist was not reduced to 0 after vacuum for $db (before: $freelist_count, after: $post_fl)" >&2
          vacuum_failed=true
        fi
      fi
    fi
  fi

  # Check that WAL file is truncated to 0 bytes after clean TRUNCATE checkpoint
  if [[ "$checkpoint_failed" == false && -f "$wal_file" ]]; then
    if (( wal_size_after > 0 )); then
      log "WARNING: WAL file not truncated to 0 bytes after checkpoint for $db (size: $wal_size_after)" >&2
      checkpoint_failed=true
    fi
  fi

  if [[ "$vacuum_failed" == true || "$checkpoint_failed" == true ]]; then
    any_non_success=true
    log "WARNING: Maintenance incomplete for $db (vacuum_failed=$vacuum_failed, checkpoint_failed=$checkpoint_failed)" >&2
  else
    total_vacuumed=$(( total_vacuumed + 1 ))
    freed=0
    if (( total_size_before > total_size_after )); then
      freed=$(( total_size_before - total_size_after ))
    fi
    total_freed=$(( total_freed + freed ))
    log "  [clean] $db: freed $(fmt_bytes $freed) (DB: $(fmt_bytes $db_size_before) -> $(fmt_bytes $db_size_after), WAL: $(fmt_bytes $wal_size_before) -> $(fmt_bytes $wal_size_after))"
  fi

  [[ -n "$current_lease" ]] && release_db_lease "$current_lease"
done

echo
if [[ "$any_non_success" == true ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    log "Codex DB vacuum preview incomplete: checked $total_checked database(s), total reclaimable: $(fmt_bytes $total_reclaimable)"
  else
    log "Codex DB vacuum incomplete: checked $total_checked database(s), vacuumed $total_vacuumed, total freed: $(fmt_bytes $total_freed)"
  fi
  if [[ $total_locked -gt 0 ]]; then
    log "Notice: $total_locked database operation(s) skipped due to concurrent locks/busy timeout."
  fi
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  log "Codex DB vacuum preview: checked $total_checked database(s), total reclaimable: $(fmt_bytes $total_reclaimable)"
else
  log "Codex DB vacuum complete: checked $total_checked database(s), vacuumed $total_vacuumed, total freed: $(fmt_bytes $total_freed)"
fi

if [[ $total_locked -gt 0 ]]; then
  log "Notice: $total_locked database operation(s) skipped due to concurrent locks/busy timeout."
fi

exit 0

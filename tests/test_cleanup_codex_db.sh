#!/bin/bash
# test_cleanup_codex_db.sh — Comprehensive unit & concurrency regression tests for cleanup_codex_db.sh.
#
# Asserts:
# 1. --dry-run reports freelist pages and reclaimable bytes without modifying the database.
# 2. --clean executes incremental_vacuum, drops freelist to 0, truncates WAL, shrinks file size.
# 3. Lock timeout handling: when DB is locked, handles timeout promptly, exits non-zero, lacks success summary.
# 4. Large freelist chunked vacuuming works across multiple batches.
# 5. Directory discovery via --codex-dir correctly discovers and processes databases.
# 6. Safety invariant: databases are never deleted, empty/0-byte DBs are skipped safely, non-incremental DBs handled.
# 7. Numeric validation rejects SQL-injection, invalid, zero, and huge overflow values without arithmetic wrapping.
# 8. Single-maintainer lease:
#    - Two real processes with barrier: maintainer 2 skips leased DB, exits non-zero.
#    - Stale lease PID is NOT stolen or deleted.
#    - Legal canonical-equivalent path alias shares physical lease.
#    - Termination (SIGTERM) returns 143/non-zero, halts maintenance without vacuum/checkpoint, and removes owned lease.
#    - Lease cleanup removes only own PID and rmdir; unexpected contents in lease dir are retained.
# 9. Conservative active-open-client policy:
#    - PID-scoped real native lsof fixture for active reader skips DB and exits non-zero.
#    - PID-scoped real native lsof fixture for active writer skips DB and exits non-zero.
#    - lsof rc1 + stderr warning fails closed.
#    - lsof rc0 + stderr warning fails closed.
#    - Malformed lsof stdout fails closed.
#    - Missing lsof capability fails closed.
#    - lsof timeout fails closed.
# 10. REAL exit-0 wal_checkpoint busy row handled as non-success, with DB inode/data retained, printed into test log.
# 11. Checkpoint parser matrix:
#     - Multiple rows [0|0|0, 1|5|5] (success+busy) treated as non-success.
#     - Multiple rows [0|-1|-1, 1|5|5] (no-WAL+busy) treated as non-success.
#     - Incomplete counters [0|10|5] treated as non-success.
#     - Malformed rows treated as non-success.
#     - Negative/impossible counters treated as non-success.
#     - Incomplete TRUNCATE (0|5|5) treated as non-success.
#     - Legitimate non-WAL (0|-1|-1) handled safely.
# 12. Disappearing path fixture: database is not silently recreated by SQLite CLI.
# 13. Timeout configured on EVERY SQLite call (read probes, vacuum loop, checkpoint, poststate) with captured-args assertion.
# 14. Poststate verification: freelist drop to 0, WAL truncation to 0 bytes, DB identity preserved, incomplete vacuum fails.
# 15. Explicit missing requested database fails closed without false success.
# 16. Path guards:
#     - Symlink database leaf refused for safety, data/freelist preserved.
#     - Multiple hard links refused for safety, data/freelist preserved.
#     - External database outside canonical CODEX_DIR refused for safety.
#     - Parent symlink escape outside canonical CODEX_DIR refused for safety.
# 17. Pragma row count & constraints schema validation:
#     - Initial pragma requires exact 4 rows and sensible bounds.
#     - Poststate pragma requires exact 3 rows and sensible bounds.
# 18. Strict file_size_bytes & unstatable retained WAL poststate fail-closed:
#     - Absent WAL path outputs 0, rc 0.
#     - Unstatable/failing stat returns non-zero, does not output 0.
#     - Directory/symlink returns non-zero.
#     - Retained WAL unstatable after checkpoint fails closed without [clean] or success summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_codex_db.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "FAIL: sqlite3 required for concurrency tests" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 required for concurrency tests" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d -t test_cleanup_codex_db.XXXXXX)
TEST_PIDS=()
cleanup_test_env() {
  for pid in "${TEST_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup_test_env EXIT

export CODEX_DIR="$TMP_DIR"
export DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"

REAL_SQLITE3="$(command -v sqlite3)"
REAL_STAT="$(command -v stat)"
REAL_LSOF=""
if command -v lsof >/dev/null 2>&1; then
  REAL_LSOF="$(command -v lsof)"
elif [[ -x /usr/sbin/lsof ]]; then
  REAL_LSOF="/usr/sbin/lsof"
fi

MOCK_CLEAN_LSOF="$TMP_DIR/mock_clean_lsof"
cat > "$MOCK_CLEAN_LSOF" <<'SHIM'
#!/bin/bash
exit 1
SHIM
chmod +x "$MOCK_CLEAN_LSOF"

PASS=0
FAIL=0

expect() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (did not find: $needle)" >&2
    echo "--- Haystack was: ---" >&2
    echo "$haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

expect_not() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (found forbidden: $needle)" >&2
    FAIL=$((FAIL + 1))
  fi
}

expect_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (expected '$expected', got '$actual')" >&2
    FAIL=$((FAIL + 1))
  fi
}

expect_gt() {
  local desc="$1" val1="$2" val2="$3"
  if (( val1 > val2 )); then
    echo "  PASS  $desc ($val1 > $val2)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (expected $val1 > $val2)" >&2
    FAIL=$((FAIL + 1))
  fi
}

wait_for_barrier() {
  local file="$1" max_sec="${2:-5}"
  local count=$(( max_sec * 20 ))
  while [[ ! -f "$file" ]]; do
    sleep 0.05
    count=$((count - 1))
    if (( count <= 0 )); then
      echo "FAIL: Timed out waiting for barrier $file" >&2
      exit 1
    fi
  done
  return 0
}

create_test_db() {
  local db="$1"
  local rows="${2:-100}"
  local delete_above="${3:-50}"
  local auto_vac="${4:-2}"

  "$REAL_SQLITE3" "$db" >/dev/null <<SQL
PRAGMA auto_vacuum = $auto_vac;
PRAGMA journal_mode = WAL;
CREATE TABLE t (id INTEGER PRIMARY KEY, payload TEXT);
INSERT INTO t (payload) SELECT randomblob(4000) FROM generate_series(1, $rows);
DELETE FROM t WHERE id > $delete_above;
SQL
}

echo "=== test_cleanup_codex_db.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: --dry-run preview
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: --dry-run reports reclaimable space without modifying file"
DB1="$TMP_DIR/test1.sqlite"
create_test_db "$DB1" 200 100 2

size_before=$(stat -f%z "$DB1" 2>/dev/null || stat -c%s "$DB1")
fl_before=$("$REAL_SQLITE3" "$DB1" "PRAGMA freelist_count;")
expect_gt "freelist pages exist before run" "$fl_before" 0

OUT1=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --dry-run --db "$DB1" 2>&1)
size_after_dry=$(stat -f%z "$DB1" 2>/dev/null || stat -c%s "$DB1")
fl_after_dry=$("$REAL_SQLITE3" "$DB1" "PRAGMA freelist_count;")

expect_eq "file size untouched in dry-run" "$size_before" "$size_after_dry"
expect_eq "freelist count untouched in dry-run" "$fl_before" "$fl_after_dry"
expect "dry-run label present" "[dry-run]" "$OUT1"
expect "freelist pages mentioned" "freelist=$fl_before pages" "$OUT1"
expect "reclaimable bytes mentioned" "reclaimable:" "$OUT1"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: --clean execution
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: --clean vacuums freelist, truncates WAL, shrinks file size"
OUT2=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB1" 2>&1)
size_after_clean=$(stat -f%z "$DB1" 2>/dev/null || stat -c%s "$DB1")
fl_after_clean=$("$REAL_SQLITE3" "$DB1" "PRAGMA freelist_count;")

expect_eq "freelist count dropped to 0 after clean" "0" "$fl_after_clean"
expect_gt "file size shrank after clean" "$size_before" "$size_after_clean"
expect "clean label present" "[clean]" "$OUT2"
expect "freed bytes reported" "freed" "$OUT2"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Lock timeout handling (non-success on locked DB)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Lock timeout handling on locked database"
DB3="$TMP_DIR/test3.sqlite"
create_test_db "$DB3" 100 50 2

READY3="$TMP_DIR/r3_ready"
RELEASE3="$TMP_DIR/r3_release"
python3 -c '
import sqlite3, time, sys, os
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
conn.execute("INSERT INTO t (id, payload) VALUES (99999, \"locked\")")
with open(sys.argv[2], "w") as f: f.write("ok")
cnt = 0
while not os.path.exists(sys.argv[3]) and cnt < 200:
  time.sleep(0.05)
  cnt += 1
conn.execute("ROLLBACK")
conn.close()
' "$DB3" "$READY3" "$RELEASE3" &
LOCK_PID=$!
TEST_PIDS+=("$LOCK_PID")
wait_for_barrier "$READY3" 5

set +e
OUT3=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB3" --busy-timeout 200 2>&1)
RC3=$?
set -e

touch "$RELEASE3"
wait "$LOCK_PID" 2>/dev/null || true

if [[ "$RC3" -ne 0 ]]; then
  echo "  PASS  lock timeout exits non-zero (rc=$RC3)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  lock timeout exited 0 despite locked database" >&2
  FAIL=$((FAIL + 1))
fi
if [[ "$OUT3" == *"Database is locked"* || "$OUT3" == *"Database locked"* || "$OUT3" == *"Active open client"* || "$OUT3" == *"wal_checkpoint busy"* || "$OUT3" == *"Maintenance incomplete"* ]]; then
  echo "  PASS  lock or active-client warning logged"
  PASS=$((PASS + 1))
else
  echo "  FAIL  neither lock warning nor active client warning logged in OUT3" >&2
  FAIL=$((FAIL + 1))
fi
expect_not "summary lacks vacuum complete on failure" "Codex DB vacuum complete" "$OUT3"
expect "summary notes incomplete" "incomplete" "$OUT3"

INTEGRITY3=$("$REAL_SQLITE3" "$DB3" "PRAGMA integrity_check;")
expect_eq "db integrity check passes" "ok" "$INTEGRITY3"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Chunked incremental vacuum
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Large freelist chunked vacuum across multiple batches"
DB4="$TMP_DIR/test4.sqlite"
create_test_db "$DB4" 300 50 2
fl4_before=$("$REAL_SQLITE3" "$DB4" "PRAGMA freelist_count;")
expect_gt "freelist pages exist for chunk test" "$fl4_before" 100

OUT4=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB4" --chunk-size 50 2>&1)
fl4_after=$("$REAL_SQLITE3" "$DB4" "PRAGMA freelist_count;")

expect_eq "freelist dropped to 0 after chunked vacuum" "0" "$fl4_after"
expect "chunked batches logged" "batches of 50 pages" "$OUT4"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Directory scanning via --codex-dir
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Directory discovery via --codex-dir"
MOCK_CODEX="$TMP_DIR/mock_codex"
mkdir -p "$MOCK_CODEX"

create_test_db "$MOCK_CODEX/logs_2.sqlite" 100 50 2
create_test_db "$MOCK_CODEX/state_5.sqlite" 100 50 2
create_test_db "$MOCK_CODEX/thread_history_1.sqlite" 100 50 2
touch "$MOCK_CODEX/empty.sqlite"

OUT5=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --dry-run --codex-dir "$MOCK_CODEX" 2>&1)
expect "discovered logs_2.sqlite" "logs_2.sqlite" "$OUT5"
expect "discovered state_5.sqlite" "state_5.sqlite" "$OUT5"
expect "discovered thread_history_1.sqlite" "thread_history_1.sqlite" "$OUT5"
expect "skipped empty file" "Skipping empty or 0-byte database" "$OUT5"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Invariant & Safety (never deletes DB, handles non-incremental)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 6: Safety invariants and non-incremental auto_vacuum"
DB6="$TMP_DIR/test6_non_incremental.sqlite"
create_test_db "$DB6" 100 50 0 # auto_vacuum = 0 (none)

OUT6=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB6" 2>&1)
expect "logged non-incremental info" "incremental_vacuum requires auto_vacuum=2" "$OUT6"

if [[ -f "$DB6" ]]; then
  echo "  PASS  database file still exists (never deleted)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  database file was deleted!" >&2
  FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Numeric validation (SQL injection, invalid, zero, huge overflow bounds)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 7: Numeric validation rejects invalid, SQL injection, and overflow values"
set +e
OUT7_ZERO=$("$SCRIPT" --dry-run --db "$DB1" --chunk-size 0 2>&1)
RC7_ZERO=$?
OUT7_NEG=$("$SCRIPT" --dry-run --db "$DB1" --chunk-size -5 2>&1)
RC7_NEG=$?
OUT7_ALPHA=$("$SCRIPT" --dry-run --db "$DB1" --chunk-size abc 2>&1)
RC7_ALPHA=$?
OUT7_SQL_INJECT=$("$SCRIPT" --busy-timeout "5000; DROP TABLE t" 2>&1)
RC7_SQL_INJECT=$?
OUT7_ENV_SQL=$(CODEX_DB_BUSY_TIMEOUT_MS="5000; DROP TABLE t" "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_ENV_SQL=$?
OUT7_ALPHA_MIN_FL=$("$SCRIPT" --min-freelist abc 2>&1)
RC7_ALPHA_MIN_FL=$?
OUT7_ENV_ZERO=$(CODEX_DB_CHUNK_SIZE=0 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_ENV_ZERO=$?
OUT7_ENV_OCTAL=$(CODEX_DB_CHUNK_SIZE=08 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_ENV_OCTAL=$?
OUT7_OVERFLOW=$(CODEX_DB_CHUNK_SIZE=18446744073709551617 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_OVERFLOW=$?
OUT7_LSOF_ZERO=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=0 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_LSOF_ZERO=$?
OUT7_LSOF_NEG=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=-5 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_LSOF_NEG=$?
OUT7_LSOF_ALPHA=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=abc "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_LSOF_ALPHA=$?
OUT7_LSOF_OVERFLOW=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=18446744073709551617 "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_LSOF_OVERFLOW=$?
OUT7_LSOF_OCTAL=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=08 DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --dry-run --db "$DB1" 2>&1)
RC7_LSOF_OCTAL=$?
set -e

expect_eq "--chunk-size 0 exits with error (2)" "2" "$RC7_ZERO"
expect_eq "--chunk-size -5 exits with error (2)" "2" "$RC7_NEG"
expect_eq "--chunk-size abc exits with error (2)" "2" "$RC7_ALPHA"
expect_eq "rejects SQL injection --busy-timeout (2)" "2" "$RC7_SQL_INJECT"
expect_eq "rejects SQL injection in env CODEX_DB_BUSY_TIMEOUT_MS (2)" "2" "$RC7_ENV_SQL"
expect_eq "rejects alphabetic --min-freelist (2)" "2" "$RC7_ALPHA_MIN_FL"
expect_eq "CODEX_DB_CHUNK_SIZE=0 exits with error (2)" "2" "$RC7_ENV_ZERO"
expect_eq "CODEX_DB_CHUNK_SIZE=08 accepted safely" "0" "$RC7_ENV_OCTAL"
expect_eq "huge 18446744073709551617 rejected without arithmetic wrap (2)" "2" "$RC7_OVERFLOW"
expect_eq "DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=0 exits with error (2)" "2" "$RC7_LSOF_ZERO"
expect_eq "DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=-5 exits with error (2)" "2" "$RC7_LSOF_NEG"
expect_eq "DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=abc exits with error (2)" "2" "$RC7_LSOF_ALPHA"
expect_eq "DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=18446744073709551617 exits with error (2)" "2" "$RC7_LSOF_OVERFLOW"
expect_eq "DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=08 accepted safely" "0" "$RC7_LSOF_OCTAL"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Per-database single-maintainer lease, aliases, and termination trap
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 8: Per-database single-maintainer lease, aliases, and signal cleanup"
DB8="$TMP_DIR/test8_lease.sqlite"
create_test_db "$DB8" 100 50 2
STATE8="$TMP_DIR/state8"
mkdir -p "$STATE8/codex_db_leases"

# Two maintainers with barrier
M1_BIN="$TMP_DIR/m1_bin"
mkdir -p "$M1_BIN"
BARRIER_INSIDE="$TMP_DIR/m1_inside"
BARRIER_RELEASE="$TMP_DIR/m1_release"

M1_CAPTURE_LOG="$TMP_DIR/m1_captured.log"
cat > "$M1_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ -f "$M1_CAPTURE_LOG" ]]; then
  echo "\$*" >> "$M1_CAPTURE_LOG"
fi
if [[ "\$*" == *"PRAGMA"* && ! -f "$BARRIER_INSIDE" ]]; then
  touch "$BARRIER_INSIDE"
  cnt=0
  while [[ ! -f "$BARRIER_RELEASE" ]]; do
    sleep 0.05
    cnt=\$((cnt + 1))
    if (( cnt > 700 )); then break; fi
  done
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$M1_BIN/sqlite3"

OUT8_M1_FILE="$TMP_DIR/m1.out"
PATH="$M1_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" >"$OUT8_M1_FILE" 2>&1 &
M1_PID=$!
TEST_PIDS+=("$M1_PID")
wait_for_barrier "$BARRIER_INSIDE" 5

set +e
OUT8_M2=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" 2>&1)
RC8_M2=$?
set -e

touch "$BARRIER_RELEASE"
wait "$M1_PID" 2>/dev/null || true

expect "maintainer 2 skipped leased db" "lease held by another maintainer" "$OUT8_M2"
if [[ "$RC8_M2" -ne 0 ]]; then
  echo "  PASS  maintainer 2 exited non-zero on lease contention"
  PASS=$((PASS + 1))
else
  echo "  FAIL  maintainer 2 exited 0 despite skipping database" >&2
  FAIL=$((FAIL + 1))
fi

OUT8_M1=$(cat "$OUT8_M1_FILE")
expect "maintainer 1 succeeded" "[clean]" "$OUT8_M1"

# Verify legal canonical-equivalent path alias shares physical lease (e.g. ./ within authorized dir)
DB8_ALIAS="$TMP_DIR/./test8_lease.sqlite"
rm -f "$BARRIER_INSIDE" "$BARRIER_RELEASE"

PATH="$M1_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" >/dev/null 2>&1 &
M1_ALIAS_PID=$!
TEST_PIDS+=("$M1_ALIAS_PID")
wait_for_barrier "$BARRIER_INSIDE" 5

set +e
OUT8_ALIAS=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8_ALIAS" 2>&1)
RC8_ALIAS=$?
set -e

touch "$BARRIER_RELEASE"
wait "$M1_ALIAS_PID" 2>/dev/null || true

expect "path alias detected physical lease contention" "lease held by another maintainer" "$OUT8_ALIAS"
expect_eq "alias contention exited non-zero" "1" "$RC8_ALIAS"

# Verify stale lease preservation (no stale lease stealing)
DB8_ID=$(python3 -c 'import os, sys; print(f"{os.stat(sys.argv[1]).st_dev}_{os.stat(sys.argv[1]).st_ino}")' "$DB8")
STALE_LEASE="$STATE8/codex_db_leases/${DB8_ID}.lease"
mkdir -p "$STALE_LEASE"
echo "99997" > "$STALE_LEASE/pid"

set +e
OUT8_STALE=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" 2>&1)
RC8_STALE=$?
set -e

expect "stale lease was not stolen" "lease held by another maintainer" "$OUT8_STALE"
expect_eq "stale lease PID untouched" "99997" "$(cat "$STALE_LEASE/pid")"
rm -rf "$STALE_LEASE"

# Verify SIGTERM returns 143/non-zero, halts maintenance without vacuum/checkpoint, and removes owned lease
rm -f "$BARRIER_INSIDE" "$BARRIER_RELEASE"
TERM_OUT="$TMP_DIR/term.out"
> "$M1_CAPTURE_LOG"
PATH="$M1_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" >"$TERM_OUT" 2>&1 &
TERM_PID=$!
TEST_PIDS+=("$TERM_PID")
wait_for_barrier "$BARRIER_INSIDE" 5

kill -TERM "$TERM_PID" 2>/dev/null || true
touch "$BARRIER_RELEASE"
set +e
wait "$TERM_PID" 2>/dev/null
TERM_RC=$?
set -e

expect_eq "termination returns 143" "143" "$TERM_RC"
expect_eq "owned lease removed upon SIGTERM" "0" "$([[ -d "$STATE8/codex_db_leases/${DB8_ID}.lease" ]] && echo 1 || echo 0)"
expect_not "no clean summary after SIGTERM" "[clean]" "$(cat "$TERM_OUT")"
expect_not "no vacuum complete after SIGTERM" "Codex DB vacuum complete" "$(cat "$TERM_OUT")"
expect_not "no vacuum in captured-args after SIGTERM" "incremental_vacuum" "$(cat "$M1_CAPTURE_LOG" 2>/dev/null || true)"
expect_not "no checkpoint in captured-args after SIGTERM" "wal_checkpoint" "$(cat "$M1_CAPTURE_LOG" 2>/dev/null || true)"
rm -f "$M1_CAPTURE_LOG"
rm -rf "$M1_BIN"

# Verify lease cleanup removes only own PID and rmdir; unexpected contents in lease dir are retained
rm -f "$BARRIER_INSIDE" "$BARRIER_RELEASE"
mkdir -p "$M1_BIN"
cat > "$M1_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"PRAGMA"* && ! -f "$BARRIER_INSIDE" ]]; then
  touch "$BARRIER_INSIDE"
  touch "$STATE8/codex_db_leases/${DB8_ID}.lease/unexpected_file.txt"
  cnt=0
  while [[ ! -f "$BARRIER_RELEASE" ]]; do
    sleep 0.05
    cnt=\$((cnt + 1))
    if (( cnt > 700 )); then break; fi
  done
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$M1_BIN/sqlite3"

PATH="$M1_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE8" "$SCRIPT" --clean --db "$DB8" >/dev/null 2>&1 &
UNEXP_PID=$!
TEST_PIDS+=("$UNEXP_PID")
wait_for_barrier "$BARRIER_INSIDE" 5
touch "$BARRIER_RELEASE"
wait "$UNEXP_PID" 2>/dev/null || true

expect_eq "unexpected content in lease dir retained" "1" "$([[ -f "$STATE8/codex_db_leases/${DB8_ID}.lease/unexpected_file.txt" ]] && echo 1 || echo 0)"
expect_eq "own PID file removed from lease dir" "0" "$([[ -f "$STATE8/codex_db_leases/${DB8_ID}.lease/pid" ]] && echo 1 || echo 0)"
rm -rf "$STATE8/codex_db_leases/${DB8_ID}.lease" "$M1_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Conservative active-open-client policy & error handling
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 9: Conservative active-open-client policy (dedicated real reader/writer and uncertain scan)"
DB9="$TMP_DIR/test9_open.sqlite"
create_test_db "$DB9" 100 50 2
DB9_INODE_BEFORE=$(stat -f '%i' "$DB9" 2>/dev/null || stat -c '%i' "$DB9")

# Case 9A: Dedicated REAL active reader held until release signal
READY9_R="$TMP_DIR/ready9_reader"
RELEASE9_R="$TMP_DIR/release9_reader"
python3 -c '
import sqlite3, time, sys, os
db, ready, release = sys.argv[1], sys.argv[2], sys.argv[3]
f = open(db, "rb")
conn = sqlite3.connect(db)
cursor = conn.cursor()
cursor.execute("SELECT * FROM t;")
with open(ready, "w") as rf: rf.write("ok")
cnt = 0
while not os.path.exists(release) and cnt < 300:
  time.sleep(0.05)
  cnt += 1
conn.close()
f.close()
' "$DB9" "$READY9_R" "$RELEASE9_R" &
READER_PID9=$!
TEST_PIDS+=("$READER_PID9")
wait_for_barrier "$READY9_R" 5

WRAP_LSOF_READER="$TMP_DIR/wrap_lsof_reader"
cat > "$WRAP_LSOF_READER" <<SHIM
#!/bin/bash
# PID-scoped real native lsof fixture (restricts scan to test child PID)
exec "$REAL_LSOF" -a -p "$READER_PID9" "\$@"
SHIM
chmod +x "$WRAP_LSOF_READER"

set +e
OUT9_READER=$(DISK_MAGICIAN_LSOF_BIN="$WRAP_LSOF_READER" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9a" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_READER=$?
set -e

touch "$RELEASE9_R"
wait "$READER_PID9" 2>/dev/null || true

expect "real active reader detected and DB skipped" "Active open client" "$OUT9_READER"
expect_eq "real active reader exited non-zero" "1" "$RC9_READER"

# Case 9B: Dedicated REAL active writer held until release signal
READY9_W="$TMP_DIR/ready9_writer"
RELEASE9_W="$TMP_DIR/release9_writer"
python3 -c '
import sqlite3, time, sys, os
db, ready, release = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db)
conn.execute("BEGIN IMMEDIATE")
conn.execute("INSERT INTO t (id, payload) VALUES (88888, \"writer\")")
with open(ready, "w") as rf: rf.write("ok")
cnt = 0
while not os.path.exists(release) and cnt < 300:
  time.sleep(0.05)
  cnt += 1
conn.execute("ROLLBACK")
conn.close()
' "$DB9" "$READY9_W" "$RELEASE9_W" &
WRITER_PID9=$!
TEST_PIDS+=("$WRITER_PID9")
wait_for_barrier "$READY9_W" 5

WRAP_LSOF_WRITER="$TMP_DIR/wrap_lsof_writer"
cat > "$WRAP_LSOF_WRITER" <<SHIM
#!/bin/bash
# PID-scoped real native lsof fixture (restricts scan to test child PID)
exec "$REAL_LSOF" -a -p "$WRITER_PID9" "\$@"
SHIM
chmod +x "$WRAP_LSOF_WRITER"

set +e
OUT9_WRITER=$(DISK_MAGICIAN_LSOF_BIN="$WRAP_LSOF_WRITER" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9b" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_WRITER=$?
set -e

touch "$RELEASE9_W"
wait "$WRITER_PID9" 2>/dev/null || true

expect "real active writer detected and DB skipped" "Active open client" "$OUT9_WRITER"
expect_eq "real active writer exited non-zero" "1" "$RC9_WRITER"

DB9_INODE_AFTER=$(stat -f '%i' "$DB9" 2>/dev/null || stat -c '%i' "$DB9")
expect_eq "DB inode unchanged after open client skip" "$DB9_INODE_BEFORE" "$DB9_INODE_AFTER"

# Case 9C: Uncertain lsof scan: rc1 with stderr warning fails closed
MOCK_LSOF="$TMP_DIR/mock_lsof"
mkdir -p "$MOCK_LSOF"
cat > "$MOCK_LSOF/lsof" <<'SHIM'
#!/bin/bash
echo "lsof: warning: could not inspect device" >&2
exit 1
SHIM
chmod +x "$MOCK_LSOF/lsof"

set +e
OUT9_WARN=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_LSOF/lsof" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9c" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_WARN=$?
set -e

expect "rc1+warning fails closed" "lsof inspection warning/error" "$OUT9_WARN"
expect_eq "rc1+warning exits non-zero" "1" "$RC9_WARN"

# Case 9D: Uncertain lsof scan: rc0 with partial warning fails closed
cat > "$MOCK_LSOF/lsof" <<'SHIM'
#!/bin/bash
echo "lsof: warning: partial scan error" >&2
exit 0
SHIM
chmod +x "$MOCK_LSOF/lsof"

set +e
OUT9_RC0_WARN=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_LSOF/lsof" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9d" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_RC0_WARN=$?
set -e

expect "rc0+warning fails closed" "lsof inspection warning/error" "$OUT9_RC0_WARN"
expect_eq "rc0+warning exits non-zero" "1" "$RC9_RC0_WARN"

# Case 9E: Malformed lsof stdout (garbage) fails closed
cat > "$MOCK_LSOF/lsof" <<'SHIM'
#!/bin/bash
echo "corrupt_garbage_lsof_output"
exit 0
SHIM
chmod +x "$MOCK_LSOF/lsof"

set +e
OUT9_MALFORMED=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_LSOF/lsof" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9e" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_MALFORMED=$?
set -e

expect "malformed lsof stdout fails closed" "malformed lsof stdout" "$OUT9_MALFORMED"
expect_eq "malformed lsof exits non-zero" "1" "$RC9_MALFORMED"

# Case 9F: Missing lsof capability fails closed
set +e
OUT9_MISSING=$(DISK_MAGICIAN_LSOF_BIN="/nonexistent/lsof/binary" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9f" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_MISSING=$?
set -e

expect "missing lsof capability fails closed" "lsof unavailable" "$OUT9_MISSING"
expect_eq "missing lsof exits non-zero" "1" "$RC9_MISSING"

# Case 9G: lsof timeout fails closed
cat > "$MOCK_LSOF/lsof" <<'SHIM'
#!/bin/bash
sleep 3
exit 0
SHIM
chmod +x "$MOCK_LSOF/lsof"

set +e
OUT9_TIMEOUT=$(DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=1 DISK_MAGICIAN_LSOF_BIN="$MOCK_LSOF/lsof" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state9g" "$SCRIPT" --clean --db "$DB9" 2>&1)
RC9_TIMEOUT=$?
set -e

expect "lsof timeout fails closed" "lsof inspection failed" "$OUT9_TIMEOUT"
expect_eq "lsof timeout exits non-zero" "1" "$RC9_TIMEOUT"
rm -rf "$MOCK_LSOF" "$WRAP_LSOF_READER" "$WRAP_LSOF_WRITER"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: REAL exit-0 wal_checkpoint busy row induced via controlled race
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 10: REAL exit-0 wal_checkpoint busy row handled as non-success"
DB10="$TMP_DIR/test10_busy_checkpoint.sqlite"
create_test_db "$DB10" 200 100 2
DB10_INODE_BEFORE=$(stat -f '%i' "$DB10" 2>/dev/null || stat -c '%i' "$DB10")
ROWS_BEFORE=$("$REAL_SQLITE3" "$DB10" "SELECT count(*) FROM t;")

SHIM_BIN="$TMP_DIR/shim_bin"
mkdir -p "$SHIM_BIN"
EVIDENCE10="$TMP_DIR/sqlite_busy_evidence.txt"

cat > "$SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  READY="$TMP_DIR/r10_ready"
  RELEASE="$TMP_DIR/r10_release"
  python3 -c '
import sqlite3, os, time, sys
conn = sqlite3.connect(sys.argv[1])
c = conn.cursor()
c.execute("BEGIN;")
c.execute("SELECT * FROM t;")
with open(sys.argv[2], "w") as f: f.write("ok")
cnt = 0
while not os.path.exists(sys.argv[3]) and cnt < 300:
  time.sleep(0.01)
  cnt += 1
conn.close()
' "$DB10" "\$READY" "\$RELEASE" &
  RPID=\$!
  wait_count=0
  while [[ ! -f "\$READY" ]]; do
    sleep 0.01
    wait_count=\$((wait_count + 1))
    if (( wait_count > 200 )); then
      kill "\$RPID" 2>/dev/null || true
      break
    fi
  done
  "$REAL_SQLITE3" "$DB10" "INSERT INTO t (payload) VALUES ('busy_test');"
  out=\$("$REAL_SQLITE3" "\$@")
  rc=\$?
  touch "\$RELEASE"
  wait "\$RPID" 2>/dev/null || true
  echo "RC:\$rc|OUT:\$out" > "$EVIDENCE10"
  printf '%s\n' "\$out"
  exit \$rc
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$SHIM_BIN/sqlite3"

set +e
OUT10=$(PATH="$SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state10" "$SCRIPT" --clean --db "$DB10" --busy-timeout 100 2>&1)
RC10=$?
set -e

DB10_INODE_AFTER=$(stat -f '%i' "$DB10" 2>/dev/null || stat -c '%i' "$DB10")
ROWS_AFTER=$("$REAL_SQLITE3" "$DB10" "SELECT count(*) FROM t WHERE payload != 'busy_test';")
INTEG10=$("$REAL_SQLITE3" "$DB10" "PRAGMA integrity_check;")

EVIDENCE_CONTENT=$(cat "$EVIDENCE10" 2>/dev/null || echo "")
echo "  [evidence] Test 10 exact sqlite3 output: $EVIDENCE_CONTENT"
expect "sqlite3 returned rc=0" "RC:0" "$EVIDENCE_CONTENT"
expect "sqlite3 returned busy=1 row" "OUT:1|" "$EVIDENCE_CONTENT"

expect "parsed busy checkpoint row" "wal_checkpoint busy" "$OUT10"
if [[ "$RC10" -ne 0 ]]; then
  echo "  PASS  busy checkpoint exited non-zero (got rc=$RC10)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  busy checkpoint exited 0" >&2
  FAIL=$((FAIL + 1))
fi

expect_not "no clean success reported for busy checkpoint" "[clean] $DB10: freed" "$OUT10"
expect_not "summary lacks vacuum complete" "Codex DB vacuum complete" "$OUT10"
expect_eq "poststate: DB inode preserved" "$DB10_INODE_BEFORE" "$DB10_INODE_AFTER"
expect_eq "poststate: original rows preserved" "$ROWS_BEFORE" "$ROWS_AFTER"
expect_eq "poststate: integrity check ok" "ok" "$INTEG10"
rm -rf "$SHIM_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Checkpoint parser matrix
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 11: Checkpoint parser matrix (multiple rows, incomplete counters, malformed, non-WAL)"
CP_SHIM_BIN="$TMP_DIR/cp_shim_bin"
mkdir -p "$CP_SHIM_BIN"

# Case 11A: Multiple rows [0|0|0, 1|5|5] (success followed by busy)
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|0|0\n1|5|5\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11A="$TMP_DIR/test11a.sqlite"
create_test_db "$DB11A" 100 50 2
set +e
OUT11A=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11a" "$SCRIPT" --clean --db "$DB11A" 2>&1)
RC11A=$?
set -e
expect "multiple rows with busy row detected" "wal_checkpoint busy" "$OUT11A"
expect_eq "multiple rows with busy exits non-zero" "1" "$RC11A"

# Case 11B: Multiple rows [0|-1|-1, 1|5|5] (no-WAL followed by busy)
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|-1|-1\n1|5|5\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11B="$TMP_DIR/test11b.sqlite"
create_test_db "$DB11B" 100 50 2
set +e
OUT11B=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11b" "$SCRIPT" --clean --db "$DB11B" 2>&1)
RC11B=$?
set -e
expect "no-WAL followed by busy detected" "wal_checkpoint busy" "$OUT11B"
expect_eq "no-WAL followed by busy exits non-zero" "1" "$RC11B"

# Case 11C: Incomplete TRUNCATE counters (0|10|5)
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|10|5\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11C="$TMP_DIR/test11c.sqlite"
create_test_db "$DB11C" 100 50 2
set +e
OUT11C=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11c" "$SCRIPT" --clean --db "$DB11C" 2>&1)
RC11C=$?
set -e
expect "incomplete counters detected" "wal_checkpoint incomplete" "$OUT11C"
expect_eq "incomplete counters exits non-zero" "1" "$RC11C"

# Case 11D: Malformed output
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf 'corrupt_output\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11D="$TMP_DIR/test11d.sqlite"
create_test_db "$DB11D" 100 50 2
set +e
OUT11D=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11d" "$SCRIPT" --clean --db "$DB11D" 2>&1)
RC11D=$?
set -e
expect "malformed checkpoint output detected" "malformed wal_checkpoint row" "$OUT11D"
expect_eq "malformed checkpoint exits non-zero" "1" "$RC11D"

# Case 11E: Negative/impossible counters (0|-2|5)
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|-2|5\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11E="$TMP_DIR/test11e.sqlite"
create_test_db "$DB11E" 100 50 2
set +e
OUT11E=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11e" "$SCRIPT" --clean --db "$DB11E" 2>&1)
RC11E=$?
set -e
expect "impossible counters detected" "malformed/impossible wal_checkpoint counters" "$OUT11E"
expect_eq "impossible counters exits non-zero" "1" "$RC11E"

# Case 11F: TRUNCATE did not reset WAL (0|5|5)
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|5|5\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11F="$TMP_DIR/test11f.sqlite"
create_test_db "$DB11F" 100 50 2
set +e
OUT11F=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11f" "$SCRIPT" --clean --db "$DB11F" 2>&1)
RC11F=$?
set -e
expect "untruncated WAL row detected" "TRUNCATE did not reset WAL" "$OUT11F"
expect_eq "untruncated WAL row exits non-zero" "1" "$RC11F"

# Case 11G: Legitimate non-WAL database (0|-1|-1) handled safely as no-op
cat > "$CP_SHIM_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  printf '0|-1|-1\n'
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$CP_SHIM_BIN/sqlite3"

DB11G="$TMP_DIR/test11g.sqlite"
create_test_db "$DB11G" 100 50 2
set +e
OUT11G=$(PATH="$CP_SHIM_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state11g" "$SCRIPT" --clean --db "$DB11G" 2>&1)
RC11G=$?
set -e
expect "non-WAL recognized as no-op" "is not in WAL mode" "$OUT11G"
rm -rf "$CP_SHIM_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: Disappearing path fixture (URI mode=rw prevents recreation)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 12: Disappearing database is not silently recreated by SQLite"
DB12="$TMP_DIR/test12_disappear.sqlite"
create_test_db "$DB12" 100 50 2

DISAPPEAR_BIN="$TMP_DIR/disappear_bin"
mkdir -p "$DISAPPEAR_BIN"
cat > "$DISAPPEAR_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ -f "$DB12" ]]; then
  mv "$DB12" "${DB12}.moved"
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$DISAPPEAR_BIN/sqlite3"

set +e
OUT12=$(PATH="$DISAPPEAR_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state12" "$SCRIPT" --clean --db "$DB12" 2>&1)
RC12=$?
set -e

if [[ -f "$DB12" ]]; then
  echo "  FAIL  database was recreated after disappearing!" >&2
  FAIL=$((FAIL + 1))
else
  echo "  PASS  disappeared database was NOT recreated"
  PASS=$((PASS + 1))
fi
expect_eq "disappeared database exits non-zero" "1" "$RC12"
rm -rf "$DISAPPEAR_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: Timeout configured on every SQLite operation & captured-args assertion
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 13: Timeout configured on every SQLite operation and captured args verified"
WRAP_BIN="$TMP_DIR/wrap_bin"
mkdir -p "$WRAP_BIN"
LOG13="$TMP_DIR/timeout_calls.log"

cat > "$WRAP_BIN/sqlite3" <<SHIM
#!/bin/bash
found_timeout=false
for arg in "\$@"; do
  if [[ "\$arg" == *".timeout"* ]]; then
    found_timeout=true
    break
  fi
done
echo "\$found_timeout: \$*" >> "$LOG13"
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$WRAP_BIN/sqlite3"

DB13="$TMP_DIR/test13.sqlite"
create_test_db "$DB13" 150 75 2

OUT13=$(PATH="$WRAP_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state13" "$SCRIPT" --clean --db "$DB13" --busy-timeout 4321 2>&1)

total_calls=$(wc -l < "$LOG13" | tr -d ' ')
timeout_calls=$(grep -c '^true:' "$LOG13" || true)

expect_gt "multiple sqlite calls executed" "$total_calls" 2
expect_eq "every sqlite call configured timeout" "$total_calls" "$timeout_calls"
expect "configured custom timeout applied" ".timeout 4321" "$(cat "$LOG13")"
expect "initial probe captured args verified" "PRAGMA auto_vacuum" "$(cat "$LOG13")"
expect "vacuum captured args verified" "incremental_vacuum" "$(cat "$LOG13")"
expect "checkpoint captured args verified" "wal_checkpoint(TRUNCATE)" "$(cat "$LOG13")"
expect "poststate captured args verified" "PRAGMA freelist_count" "$(cat "$LOG13")"
rm -rf "$WRAP_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: Poststate verification: freelist drop, WAL truncation, and data integrity
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 14: Clean execution verifies freelist drop, WAL truncation, and data integrity"
DB14="$TMP_DIR/test14_clean_verified.sqlite"
create_test_db "$DB14" 150 75 2
DB14_INODE_BEFORE=$(stat -f '%i' "$DB14" 2>/dev/null || stat -c '%i' "$DB14")
ROWS14_BEFORE=$("$REAL_SQLITE3" "$DB14" "SELECT count(*) FROM t;")

OUT14=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state14" "$SCRIPT" --clean --db "$DB14" 2>&1)
DB14_INODE_AFTER=$(stat -f '%i' "$DB14" 2>/dev/null || stat -c '%i' "$DB14")
ROWS14_AFTER=$("$REAL_SQLITE3" "$DB14" "SELECT count(*) FROM t;")
INTEG14=$("$REAL_SQLITE3" "$DB14" "PRAGMA integrity_check;")
FL14_AFTER=$("$REAL_SQLITE3" "$DB14" "PRAGMA freelist_count;")

expect_eq "clean execution preserves inode" "$DB14_INODE_BEFORE" "$DB14_INODE_AFTER"
expect_eq "clean execution preserves rows" "$ROWS14_BEFORE" "$ROWS14_AFTER"
expect_eq "clean execution integrity check ok" "ok" "$INTEG14"
expect_eq "freelist dropped to 0 after clean" "0" "$FL14_AFTER"
expect "summary reports vacuum complete on success" "Codex DB vacuum complete" "$OUT14"

# Subcase: Incomplete partial vacuum (poststate freelist > 0 fails closed)
POST_FAIL_BIN="$TMP_DIR/post_fail_bin"
mkdir -p "$POST_FAIL_BIN"
cat > "$POST_FAIL_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"PRAGMA freelist_count;"* && "\$*" != *"auto_vacuum"* ]]; then
  printf '4096\n100\n25\n' # fake non-zero poststate freelist (3 rows)
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$POST_FAIL_BIN/sqlite3"

DB14_PARTIAL="$TMP_DIR/test14_partial.sqlite"
create_test_db "$DB14_PARTIAL" 100 50 2
set +e
OUT14_PARTIAL=$(PATH="$POST_FAIL_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state14b" "$SCRIPT" --clean --db "$DB14_PARTIAL" 2>&1)
RC14_PARTIAL=$?
set -e

expect "incomplete freelist detected in poststate" "Freelist was not reduced to 0" "$OUT14_PARTIAL"
expect_eq "incomplete freelist exits non-zero" "1" "$RC14_PARTIAL"
expect_not "incomplete freelist lacks vacuum complete" "Codex DB vacuum complete" "$OUT14_PARTIAL"
rm -rf "$POST_FAIL_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 15: Explicit missing requested database
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 15: Explicit missing requested database exits non-zero without false success"
set +e
OUT15=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$TMP_DIR/nonexistent_database.sqlite" 2>&1)
RC15=$?
set -e

expect "missing requested db warning logged" "Specified database does not exist" "$OUT15"
expect_eq "missing requested db exits non-zero" "1" "$RC15"
expect_not "summary lacks vacuum complete on missing db" "Codex DB vacuum complete" "$OUT15"

# ─────────────────────────────────────────────────────────────────────────────
# Test 16: Path guards (symlink leaf, hardlinks, external db, parent symlink escape)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 16: Path guards enforce containment, reject symlink leaves and multiple hardlinks"
DB16="$TMP_DIR/test16_target.sqlite"
create_test_db "$DB16" 100 50 2
DB16_FL_BEFORE=$("$REAL_SQLITE3" "$DB16" "PRAGMA freelist_count;")

# Case 16A: Symlink database leaf is refused for safety
DB16_SYM="$TMP_DIR/test16_symlink.sqlite"
ln -s "$DB16" "$DB16_SYM"

set +e
OUT16_SYM=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB16_SYM" 2>&1)
RC16_SYM=$?
set -e

DB16_FL_AFTER_SYM=$("$REAL_SQLITE3" "$DB16" "PRAGMA freelist_count;")
expect "refused symlink leaf database" "refusing symlink target for safety" "$OUT16_SYM"
expect_eq "symlink leaf target freelist untouched" "$DB16_FL_BEFORE" "$DB16_FL_AFTER_SYM"
expect_eq "symlink leaf exits non-zero" "1" "$RC16_SYM"
rm -f "$DB16_SYM"

# Case 16B: Multiple hard links rejected for safety
DB16_HARD="$TMP_DIR/test16_hardlink.sqlite"
ln "$DB16" "$DB16_HARD"

set +e
OUT16_HARD=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$DB16_HARD" 2>&1)
RC16_HARD=$?
set -e

DB16_FL_AFTER_HARD=$("$REAL_SQLITE3" "$DB16" "PRAGMA freelist_count;")
expect "refused multiple hard links" "has multiple hard links" "$OUT16_HARD"
expect_eq "hardlinked database freelist untouched" "$DB16_FL_BEFORE" "$DB16_FL_AFTER_HARD"
expect_eq "multiple hard links exits non-zero" "1" "$RC16_HARD"
rm -f "$DB16_HARD"

# Case 16C: External database outside canonical CODEX_DIR refused without matching --codex-dir
EXTERNAL_DIR="$TMP_DIR/external"
mkdir -p "$EXTERNAL_DIR"
EXT_DB="$EXTERNAL_DIR/external.sqlite"
create_test_db "$EXT_DB" 100 50 2
EXT_FL_BEFORE=$("$REAL_SQLITE3" "$EXT_DB" "PRAGMA freelist_count;")

set +e
OUT16_EXT=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$EXT_DB" 2>&1)
RC16_EXT=$?
set -e

EXT_FL_AFTER=$("$REAL_SQLITE3" "$EXT_DB" "PRAGMA freelist_count;")
expect "refused external db outside CODEX_DIR" "resolves outside" "$OUT16_EXT"
expect_eq "external database freelist untouched" "$EXT_FL_BEFORE" "$EXT_FL_AFTER"
expect_eq "external database exits non-zero" "1" "$RC16_EXT"

# Case 16D: Parent symlink escape outside canonical CODEX_DIR refused
OUTSIDE_DIR="$TMP_DIR/outside_dir"
mkdir -p "$OUTSIDE_DIR"
OUTSIDE_DB="$OUTSIDE_DIR/escaped.sqlite"
create_test_db "$OUTSIDE_DB" 100 50 2
OUTSIDE_FL_BEFORE=$("$REAL_SQLITE3" "$OUTSIDE_DB" "PRAGMA freelist_count;")

ln -s "$OUTSIDE_DIR" "$TMP_DIR/symlink_parent"
set +e
OUT16_ESCAPE=$(DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" "$SCRIPT" --clean --db "$TMP_DIR/symlink_parent/escaped.sqlite" 2>&1)
RC16_ESCAPE=$?
set -e

OUTSIDE_FL_AFTER=$("$REAL_SQLITE3" "$OUTSIDE_DB" "PRAGMA freelist_count;")
expect "refused realpath escape through parent symlink" "resolves outside" "$OUT16_ESCAPE"
expect_eq "escaped database freelist untouched" "$OUTSIDE_FL_BEFORE" "$OUTSIDE_FL_AFTER"
expect_eq "escaped parent symlink exits non-zero" "1" "$RC16_ESCAPE"
rm -rf "$TMP_DIR/symlink_parent" "$OUTSIDE_DIR" "$EXTERNAL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Test 17: Pragma row count & constraints schema validation
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 17: Pragma schema validation rejects missing/extra rows and invalid constraints"
PRAGMA_TEST_BIN="$TMP_DIR/pragma_test_bin"
mkdir -p "$PRAGMA_TEST_BIN"

# Case 17A: Initial pragma returns only 3 rows instead of exact 4
cat > "$PRAGMA_TEST_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"PRAGMA auto_vacuum"* ]]; then
  printf '4096\n100\n50\n' # only 3 rows
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$PRAGMA_TEST_BIN/sqlite3"

DB17A="$TMP_DIR/test17a.sqlite"
create_test_db "$DB17A" 100 50 2
set +e
OUT17A=$(PATH="$PRAGMA_TEST_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state17a" "$SCRIPT" --clean --db "$DB17A" 2>&1)
RC17A=$?
set -e

expect "rejected incomplete initial pragma rows" "Expected exactly 4 pragma rows" "$OUT17A"
expect_eq "incomplete initial pragma exits non-zero" "1" "$RC17A"

# Case 17B: Poststate pragma returns 2 rows instead of exact 3
cat > "$PRAGMA_TEST_BIN/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"PRAGMA freelist_count;"* && "\$*" != *"auto_vacuum"* ]]; then
  printf '4096\n100\n' # only 2 rows
  exit 0
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$PRAGMA_TEST_BIN/sqlite3"

DB17B="$TMP_DIR/test17b.sqlite"
create_test_db "$DB17B" 100 50 2
set +e
OUT17B=$(PATH="$PRAGMA_TEST_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state17b" "$SCRIPT" --clean --db "$DB17B" 2>&1)
RC17B=$?
set -e

expect "rejected incomplete poststate pragma rows" "Expected exactly 3 poststate pragma rows" "$OUT17B"
expect_eq "incomplete poststate pragma exits non-zero" "1" "$RC17B"
rm -rf "$PRAGMA_TEST_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Test 18: Strict file_size_bytes & unstatable retained WAL poststate fail-closed
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 18: Strict file_size_bytes & unstatable retained WAL poststate fail-closed"

# Case 18A: Direct helper assertions on file_size_bytes
eval "$(awk '/^file_size_bytes\(\)[ ]*\{/,/^}/' "$SCRIPT")"

# 1. Legitimate absent path returns 0, outputs "0"
set +e
absent_sz=$(file_size_bytes "$TMP_DIR/nonexistent_wal_file.sqlite-wal")
absent_rc=$?
set -e
expect_eq "file_size_bytes on absent file exits 0" "0" "$absent_rc"
expect_eq "file_size_bytes on absent file outputs 0" "0" "$absent_sz"

# 2. Existing regular file with shadowed/failing stat returns non-zero, does not output 0
set +e
shadow_sz=$(
  stat() { return 1; }
  file_size_bytes "$SCRIPT"
)
shadow_rc=$?
set -e
expect_gt "file_size_bytes with failing stat exits non-zero" "$shadow_rc" 0
expect_not "file_size_bytes with failing stat does not output 0" "0" "$shadow_sz"

# 3. Non-regular paths (directories or symlinks) return non-zero
set +e
dir_sz=$(file_size_bytes "$TMP_DIR")
dir_rc=$?
set -e
expect_gt "file_size_bytes on directory exits non-zero" "$dir_rc" 0

TEST18_SYMLINK="$TMP_DIR/test18_symlink"
ln -s "$SCRIPT" "$TEST18_SYMLINK"
set +e
symlink_sz=$(file_size_bytes "$TEST18_SYMLINK")
symlink_rc=$?
set -e
expect_gt "file_size_bytes on symlink exits non-zero" "$symlink_rc" 0
rm -f "$TEST18_SYMLINK"

# Case 18B: Production workflow with stat shim failing only size query on retained WAL after checkpoint
# while physical inode and linkcount queries still work.
DB18="$TMP_DIR/test18.sqlite"
create_test_db "$DB18" 100 50 2
WAL18="${DB18}-wal"
touch "$WAL18"

DB18_INODE_BEFORE=$(stat -f '%i' "$DB18" 2>/dev/null || stat -c '%i' "$DB18")
DB18_ROWS_BEFORE=$("$REAL_SQLITE3" "$DB18" "SELECT count(*) FROM t;")
STATE18="$TMP_DIR/state18"
mkdir -p "$STATE18/codex_db_leases"
DB18_ID=$(python3 -c 'import os, sys; print(f"{os.stat(sys.argv[1]).st_dev}_{os.stat(sys.argv[1]).st_ino}")' "$DB18")

STAT_SHIM_DIR="$TMP_DIR/stat_shim_bin"
mkdir -p "$STAT_SHIM_DIR"
CP_FLAG="$TMP_DIR/cp18_done"
rm -f "$CP_FLAG"

cat > "$STAT_SHIM_DIR/sqlite3" <<SHIM
#!/bin/bash
if [[ "\$*" == *"wal_checkpoint"* ]]; then
  touch "$CP_FLAG"
fi
exec "$REAL_SQLITE3" "\$@"
SHIM
chmod +x "$STAT_SHIM_DIR/sqlite3"

cat > "$STAT_SHIM_DIR/stat" <<SHIM
#!/bin/bash
if [[ -f "$CP_FLAG" && "\$*" == *"$WAL18"* && ( "\$*" == *"-f%z"* || "\$*" == *"-c%s"* ) ]]; then
  exit 1
fi
exec "$REAL_STAT" "\$@"
SHIM
chmod +x "$STAT_SHIM_DIR/stat"

set +e
OUT18=$(PATH="$STAT_SHIM_DIR:$PATH" DISK_MAGICIAN_LSOF_BIN="$MOCK_CLEAN_LSOF" DISK_MAGICIAN_STATE_DIR="$STATE18" "$SCRIPT" --clean --db "$DB18" 2>&1)
RC18=$?
set -e

expect_gt "unstatable retained WAL poststate exits non-zero" "$RC18" 0
expect_not "no clean summary on unstatable WAL" "[clean]" "$OUT18"
expect_not "no vacuum complete summary on unstatable WAL" "Codex DB vacuum complete" "$OUT18"
expect "logged WAL read failure or incomplete maintenance" "Maintenance incomplete" "$OUT18"

# Verify DB file, data, inode, integrity intact
expect_eq "DB file still exists" "1" "$([[ -f "$DB18" ]] && echo 1 || echo 0)"
DB18_INODE_AFTER=$(stat -f '%i' "$DB18" 2>/dev/null || stat -c '%i' "$DB18")
expect_eq "DB inode preserved" "$DB18_INODE_BEFORE" "$DB18_INODE_AFTER"
DB18_ROWS_AFTER=$("$REAL_SQLITE3" "$DB18" "SELECT count(*) FROM t;")
expect_eq "DB row count preserved" "$DB18_ROWS_BEFORE" "$DB18_ROWS_AFTER"
DB18_INTEG=$("$REAL_SQLITE3" "$DB18" "PRAGMA integrity_check;")
expect_eq "DB integrity check ok" "ok" "$DB18_INTEG"

# Verify lease was cleanly removed (not leaked)
expect_eq "owned lease removed upon fail-closed unstatable WAL" "0" "$([[ -d "$STATE18/codex_db_leases/${DB18_ID}.lease" ]] && echo 1 || echo 0)"

rm -rf "$STAT_SHIM_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Directory discovery with whitespace in --codex-dir
# ─────────────────────────────────────────────────────────────────────────────
echo "Directory discovery handles path with whitespace without word-splitting"
MOCK_SPACES="$TMP_DIR/mock codex with spaces"
mkdir -p "$MOCK_SPACES"
create_test_db "$MOCK_SPACES/logs_space_1.sqlite" 100 50 2
OUT13=$("$SCRIPT" --dry-run --codex-dir "$MOCK_SPACES" 2>&1)
RC13=$?
expect_eq "directory with spaces exit code 0" "0" "$RC13"
expect "discovered db in directory with spaces" "logs_space_1.sqlite" "$OUT13"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

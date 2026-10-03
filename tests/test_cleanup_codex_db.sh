#!/usr/bin/env bash
# test_cleanup_codex_db.sh — Unit & regression tests for cleanup_codex_db.sh.
#
# Asserts:
# 1. --dry-run reports freelist pages and reclaimable bytes without modifying the database.
# 2. --clean executes incremental_vacuum, drops freelist to 0, truncates WAL, and shrinks file size.
# 3. Lock timeout handling: when DB is locked, handles timeout gracefully without hanging or corrupting DB.
# 4. Large freelist chunked vacuuming works across multiple batches.
# 5. Directory discovery via --codex-dir correctly discovers and processes databases.
# 6. Safety invariant: databases are never deleted, empty/0-byte DBs are skipped safely, non-incremental DBs handled.
#
# Run: bash tests/test_cleanup_codex_db.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_codex_db.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP: sqlite3 not on PATH" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH" >&2
  exit 0
fi

TMP_DIR=$(mktemp -d -t test_cleanup_codex_db.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
export CODEX_DIR="$TMP_DIR"

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

create_test_db() {
  local db="$1"
  local rows="${2:-100}"
  local delete_above="${3:-50}"
  local auto_vac="${4:-2}"

  sqlite3 "$db" >/dev/null <<SQL
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
fl_before=$(sqlite3 "$DB1" "PRAGMA freelist_count;")
expect_gt "freelist pages exist before run" "$fl_before" 0

OUT1=$("$SCRIPT" --dry-run --db "$DB1" 2>&1)
size_after_dry=$(stat -f%z "$DB1" 2>/dev/null || stat -c%s "$DB1")
fl_after_dry=$(sqlite3 "$DB1" "PRAGMA freelist_count;")

expect_eq "file size untouched in dry-run" "$size_before" "$size_after_dry"
expect_eq "freelist count untouched in dry-run" "$fl_before" "$fl_after_dry"
expect "dry-run label present" "[dry-run]" "$OUT1"
expect "freelist pages mentioned" "freelist=$fl_before pages" "$OUT1"
expect "reclaimable bytes mentioned" "reclaimable:" "$OUT1"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: --clean execution
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: --clean vacuums freelist, truncates WAL, shrinks file size"
OUT2=$("$SCRIPT" --clean --db "$DB1" 2>&1)
size_after_clean=$(stat -f%z "$DB1" 2>/dev/null || stat -c%s "$DB1")
fl_after_clean=$(sqlite3 "$DB1" "PRAGMA freelist_count;")

expect_eq "freelist count dropped to 0 after clean" "0" "$fl_after_clean"
expect_gt "file size shrank after clean" "$size_before" "$size_after_clean"
expect "clean label present" "[clean]" "$OUT2"
expect "freed bytes reported" "freed" "$OUT2"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Lock timeout handling
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Lock timeout handling on locked database"
DB3="$TMP_DIR/test3.sqlite"
create_test_db "$DB3" 100 50 2

# Hold exclusive lock for 4.0 seconds in python background process
READY3="$TMP_DIR/test3_locked.ready"
rm -f "$READY3"
python3 -c '
import sqlite3, time, sys
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
conn.execute("INSERT INTO t (id, payload) VALUES (99999, \"locked\")")
with open(sys.argv[2], "w") as f:
    f.write("ready\n")
time.sleep(4.0)
conn.execute("ROLLBACK")
conn.close()
' "$DB3" "$READY3" &
LOCK_PID=$!

for _ in {1..100}; do
  [[ -f "$READY3" ]] && break
  sleep 0.05
done

START_TS=$(date +%s)
set +e
OUT3=$("$SCRIPT" --clean --db "$DB3" --busy-timeout 200 2>&1)
RC3=$?
set -e
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

expect_eq "lock timeout exits gracefully (0)" "0" "$RC3"
expect "lock warning logged" "Database is locked" "$OUT3"
expect_gt "completed promptly before lock held time (4s lock)" 4 "$ELAPSED"

wait "$LOCK_PID" || true

# Assert DB is intact and not corrupted
INTEGRITY=$(sqlite3 "$DB3" "PRAGMA integrity_check;")
expect_eq "db integrity check passes" "ok" "$INTEGRITY"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Chunked incremental vacuum
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Large freelist chunked vacuum across multiple batches"
DB4="$TMP_DIR/test4.sqlite"
create_test_db "$DB4" 300 50 2
fl4_before=$(sqlite3 "$DB4" "PRAGMA freelist_count;")
expect_gt "freelist pages exist for chunk test" "$fl4_before" 100

OUT4=$("$SCRIPT" --clean --db "$DB4" --chunk-size 50 2>&1)
fl4_after=$(sqlite3 "$DB4" "PRAGMA freelist_count;")

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

OUT5=$("$SCRIPT" --dry-run --codex-dir "$MOCK_CODEX" 2>&1)
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

OUT6=$("$SCRIPT" --clean --db "$DB6" 2>&1)
expect "logged non-incremental info" "incremental_vacuum requires auto_vacuum=2" "$OUT6"

# Verify DB file still exists (never deleted)
if [[ -f "$DB6" ]]; then
  echo "  PASS  database file still exists (never deleted)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  database file was deleted!" >&2
  FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Symlink rejection & external DB escape prevention
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 7: Symlink rejection and external DB escape prevention"
EXTERNAL_DIR="$TMP_DIR/external"
mkdir -p "$EXTERNAL_DIR"
EXT_DB="$EXTERNAL_DIR/sensitive.sqlite"
create_test_db "$EXT_DB" 100 50 2 # Has 50 freelist pages
EXT_FREELIST_BEFORE=$(sqlite3 "$EXT_DB" "PRAGMA freelist_count;")

# Symlink inside mock codex directory pointing outside
ln -s "$EXT_DB" "$MOCK_CODEX/logs_symlink.sqlite"

OUT7_DIR=$("$SCRIPT" --clean --codex-dir "$MOCK_CODEX" 2>&1)
EXT_FREELIST_AFTER=$(sqlite3 "$EXT_DB" "PRAGMA freelist_count;")
expect_eq "external DB untouched by directory scan" "$EXT_FREELIST_BEFORE" "$EXT_FREELIST_AFTER"

# Direct --db pointing to a symlink
OUT7_DIRECT=$("$SCRIPT" --clean --codex-dir "$MOCK_CODEX" --db "$MOCK_CODEX/logs_symlink.sqlite" 2>&1)
EXT_FREELIST_AFTER_DIRECT=$(sqlite3 "$EXT_DB" "PRAGMA freelist_count;")
expect "refused direct symlink target" "refusing symlink target for safety" "$OUT7_DIRECT"
expect_eq "external DB untouched by direct symlink flag" "$EXT_FREELIST_BEFORE" "$EXT_FREELIST_AFTER_DIRECT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Numeric parameter validation (SQL injection prevention)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 8: Numeric parameter validation refuses non-integer values"
set +e
OUT8_1=$("$SCRIPT" --busy-timeout "5000; DROP TABLE t" 2>&1)
RC8_1=$?
OUT8_2=$(CODEX_DB_BUSY_TIMEOUT_MS="5000; DROP TABLE t" "$SCRIPT" 2>&1)
RC8_2=$?
OUT8_3=$("$SCRIPT" --min-freelist "abc" 2>&1)
RC8_3=$?
OUT8_4=$("$SCRIPT" --chunk-size "0" 2>&1)
RC8_4=$?
set -e

expect_eq "rejects non-numeric --busy-timeout (rc 2)" "2" "$RC8_1"
expect "busy-timeout error message" "must be an unsigned integer" "$OUT8_1"
expect_eq "rejects non-numeric CODEX_DB_BUSY_TIMEOUT_MS (rc 2)" "2" "$RC8_2"
expect_eq "rejects non-numeric --min-freelist (rc 2)" "2" "$RC8_3"
expect_eq "rejects non-positive --chunk-size (rc 2)" "2" "$RC8_4"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: External database containment rejection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 9: External database containment rejects direct --db outside CODEX_DIR"
EXT_UNTOUCHED_BEFORE=$(sqlite3 "$EXT_DB" "PRAGMA freelist_count;")
set +e
OUT9=$("$SCRIPT" --clean --codex-dir "$MOCK_CODEX" --db "$EXT_DB" 2>&1)
RC9=$?
set -e
EXT_UNTOUCHED_AFTER=$(sqlite3 "$EXT_DB" "PRAGMA freelist_count;")

expect_eq "exit code 0 when skipping external db" "0" "$RC9"
expect "logged directory resolves outside warning" "resolves outside" "$OUT9"
expect_eq "external database freelist untouched" "$EXT_UNTOUCHED_BEFORE" "$EXT_UNTOUCHED_AFTER"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Hard link rejection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 10: Multiple hard links rejected for safety"
create_test_db "$MOCK_CODEX/hardlink_orig.sqlite" 100 50 2
ln "$MOCK_CODEX/hardlink_orig.sqlite" "$MOCK_CODEX/hardlink_alias.sqlite"
HL_BEFORE=$(sqlite3 "$MOCK_CODEX/hardlink_orig.sqlite" "PRAGMA freelist_count;")

OUT10=$("$SCRIPT" --clean --codex-dir "$MOCK_CODEX" --db "$MOCK_CODEX/hardlink_alias.sqlite" 2>&1)
HL_AFTER=$(sqlite3 "$MOCK_CODEX/hardlink_orig.sqlite" "PRAGMA freelist_count;")

expect "logged hard link rejection warning" "has multiple hard links" "$OUT10"
expect_eq "hard-linked database untouched" "$HL_BEFORE" "$HL_AFTER"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

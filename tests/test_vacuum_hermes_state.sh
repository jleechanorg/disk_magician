#!/usr/bin/env bash
# test_vacuum_hermes_state.sh — Behavioral tests for vacuum_hermes_state.sh
#
# Incident 2026-07-22 (jleechan-4dtg): the old unconditional `VACUUM;` path
# on a WAL-mode db drove free space from 12 GB to 5 GB in ~13 minutes. These
# tests lock in the fix: checkpoint is the default/safe action, and a full
# VACUUM only runs after an explicit free-space guard passes.
#
# Run: bash tests/test_vacuum_hermes_state.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vacuum_hermes_state.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP: sqlite3 not on PATH" >&2
  exit 0
fi

TMP_DIR=$(mktemp -d -t vacuum_hermes_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
DB="$TMP_DIR/state.db"

# Build a small WAL-mode fixture db with some churn (insert + delete) so a
# checkpoint/VACUUM has real work to do.
sqlite3 "$DB" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t (v) SELECT 'x' || value FROM generate_series(1, 500);
DELETE FROM t WHERE id % 2 = 0;
SQL

PASS=0
FAIL=0
expect() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (did not find: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== vacuum_hermes_state.sh test ==="

echo "Test 1: dry-run makes no changes and reports checkpoint intent"
OUT=$(HERMES_STATE_DB="$DB" "$SCRIPT" 2>&1)
expect "dry-run mentions wal_checkpoint" "would wal_checkpoint(TRUNCATE)" "$OUT"

echo "Test 2: --apply with no other flags runs checkpoint only, no VACUUM log"
OUT=$(HERMES_STATE_DB="$DB" "$SCRIPT" --apply 2>&1)
expect "checkpoint ran" "Running wal_checkpoint(TRUNCATE)" "$OUT"
expect "no full VACUUM attempted" "true" "$([[ "$OUT" != *"Guard passed"* && "$OUT" != *"REFUSING full VACUUM"* ]] && echo true)"

echo "Test 3: --apply --full-vacuum refuses when free space is below the guard"
OUT=$(HERMES_STATE_DB="$DB" DISK_MAGICIAN_VACUUM_FREE_GB_OVERRIDE=1 "$SCRIPT" --apply --full-vacuum 2>&1)
expect "checkpoint still ran" "Running wal_checkpoint(TRUNCATE)" "$OUT"
expect "full VACUUM refused" "REFUSING full VACUUM" "$OUT"
expect "refusal cites the 2026-07-22 incident reasoning" "nearly wedged the disk" "$OUT"

echo "Test 4: --apply --full-vacuum proceeds when free space comfortably clears the guard"
OUT=$(HERMES_STATE_DB="$DB" DISK_MAGICIAN_VACUUM_FREE_GB_OVERRIDE=999 "$SCRIPT" --apply --full-vacuum 2>&1)
expect "guard passed" "Guard passed" "$OUT"
expect "VACUUM ran" "VACUUM:" "$OUT"
expect "no refusal this time" "true" "$([[ "$OUT" != *"REFUSING full VACUUM"* ]] && echo true)"

echo "Test 5: missing DB is a silent no-op (exit 0)"
set +e
OUT=$(HERMES_STATE_DB="$TMP_DIR/does-not-exist.db" "$SCRIPT" --apply 2>&1)
RC=$?
set -e
expect "missing DB exit code 0" "0" "$RC"
expect "missing DB logs skip" "skipping" "$OUT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

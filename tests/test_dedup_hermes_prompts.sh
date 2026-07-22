#!/usr/bin/env bash
# test_dedup_hermes_prompts.sh — Behavioral tests for dedup_hermes_prompts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/dedup_hermes_prompts.sh"

if [[ ! -x "$SOURCE_SCRIPT" ]]; then
  echo "FAIL: $SOURCE_SCRIPT not executable" >&2
  exit 2
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP: sqlite3 not on PATH — cannot test $SOURCE_SCRIPT" >&2
  exit 0
fi

TMP_ROOT=$(mktemp -d -t dedup_hermes_prompts_test.XXXXXX)
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name (expected: $expected, got: $actual)"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name (missing: $needle)"
    echo "        haystack: $haystack"
    FAIL=$(( FAIL + 1 ))
  fi
}

# make_fixture <db_path> — builds a sessions table with:
#   3 old (40+ days) sessions sharing one duplicated system_prompt
#   1 recent (2 days) session with that same duplicated prompt (must survive)
#   1 recent (1 day) session with a unique prompt (must survive)
make_fixture() {
  local db="$1"
  rm -f -- "$db"
  sqlite3 "$db" <<'SQL'
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    system_prompt TEXT,
    started_at REAL NOT NULL
);
INSERT INTO sessions VALUES ('old1', 'DUP_PROMPT_' || hex(randomblob(2000)), strftime('%s','now') - 40*86400);
SQL
  # Reuse the same prompt text across old2/old3 by copying old1's value —
  # keeps the fixture deterministic on prompt length without hardcoding a
  # giant literal in this file.
  local dup_prompt
  dup_prompt=$(sqlite3 "$db" "SELECT system_prompt FROM sessions WHERE id='old1';")
  sqlite3 "$db" \
    "INSERT INTO sessions VALUES ('old2', '$dup_prompt', strftime('%s','now') - 45*86400);"
  sqlite3 "$db" \
    "INSERT INTO sessions VALUES ('old3', '$dup_prompt', strftime('%s','now') - 50*86400);"
  sqlite3 "$db" \
    "INSERT INTO sessions VALUES ('new_dup', '$dup_prompt', strftime('%s','now') - 2*86400);"
  sqlite3 "$db" \
    "INSERT INTO sessions VALUES ('new_unique', 'UNIQUE_' || hex(randomblob(200)), strftime('%s','now') - 1*86400);"
}

null_flags() {
  local db="$1"
  sqlite3 "$db" "SELECT id || ':' || (system_prompt IS NULL) FROM sessions ORDER BY id;"
}

echo "Test 1: dry-run reports duplicate groups and the retention target, mutates nothing"
DB1="$TMP_ROOT/t1.db"
make_fixture "$DB1"
before_flags=$(null_flags "$DB1")
out1=$(HERMES_STATE_DB="$DB1" bash "$SOURCE_SCRIPT" 2>&1)
after_flags=$(null_flags "$DB1")
assert_contains "reports duplicate groups" "Duplicate-content groups: 1" "$out1"
assert_contains "reports retention target of 3 old sessions" "older than 30d with system_prompt set: 3" "$out1"
assert_contains "dry-run banner present" "[dry-run]" "$out1"
assert_eq "dry-run makes zero mutations" "$before_flags" "$after_flags"
if compgen -G "$TMP_ROOT/t1.db.dedup-backup-*" >/dev/null 2>&1; then
  echo "  FAIL  dry-run must not create a backup"
  FAIL=$(( FAIL + 1 ))
else
  echo "  PASS  dry-run creates no backup"
  PASS=$(( PASS + 1 ))
fi

echo "Test 2: --apply on a fixture reclaims bytes after VACUUM, keeps recent rows, writes a verified backup"
DB2="$TMP_ROOT/t2.db"
make_fixture "$DB2"
before_size=$(stat -f%z "$DB2" 2>/dev/null || stat -c%s "$DB2")
out2=$(HERMES_STATE_DB="$DB2" bash "$SOURCE_SCRIPT" --apply 2>&1)
after_size=$(stat -f%z "$DB2" 2>/dev/null || stat -c%s "$DB2")
flags2=$(null_flags "$DB2")
assert_contains "old1 nulled" "old1:1" "$flags2"
assert_contains "old2 nulled" "old2:1" "$flags2"
assert_contains "old3 nulled" "old3:1" "$flags2"
assert_contains "new_dup (2d old, under 30d retention) survives" "new_dup:0" "$flags2"
assert_contains "new_unique survives" "new_unique:0" "$flags2"
assert_contains "apply log reports reclaimed bytes" "reclaimed" "$out2"
if [[ "$after_size" -lt "$before_size" ]]; then
  echo "  PASS  db file shrank after --apply + VACUUM ($before_size -> $after_size bytes)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  db file did not shrink after --apply + VACUUM ($before_size -> $after_size bytes)"
  FAIL=$(( FAIL + 1 ))
fi
backup_count=$(find "$TMP_ROOT" -maxdepth 1 -name 't2.db.dedup-backup-*' | wc -l | tr -d ' ')
assert_eq "exactly one backup file created" "1" "$backup_count"
backup_file=$(find "$TMP_ROOT" -maxdepth 1 -name 't2.db.dedup-backup-*')
backup_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file")
assert_eq "backup size matches pre-apply db size" "$before_size" "$backup_size"

echo "Test 3: --apply refuses when the backup directory is unwritable, mutates nothing"
DB3="$TMP_ROOT/t3.db"
make_fixture "$DB3"
before_flags3=$(null_flags "$DB3")
RO_DIR="$TMP_ROOT/ro_backup_dir"
mkdir -p "$RO_DIR"
chmod 500 "$RO_DIR"
set +e
out3=$(HERMES_STATE_DB="$DB3" HERMES_DEDUP_BACKUP_DIR="$RO_DIR/sub" bash "$SOURCE_SCRIPT" --apply 2>&1)
rc3=$?
set -e
chmod 700 "$RO_DIR"
after_flags3=$(null_flags "$DB3")
assert_eq "refusal exits non-zero" "1" "$rc3"
assert_contains "refusal message present" "refusing --apply" "$out3"
assert_eq "unwritable-backup path makes zero mutations" "$before_flags3" "$after_flags3"

echo "Test 4: VACUUM free-space guard refuses VACUUM but keeps the UPDATE + backup (jleechan-sd1t pattern)"
DB4="$TMP_ROOT/t4.db"
make_fixture "$DB4"
before_size4=$(stat -f%z "$DB4" 2>/dev/null || stat -c%s "$DB4")
out4=$(HERMES_STATE_DB="$DB4" DISK_MAGICIAN_DEDUP_FREE_GB_OVERRIDE=1 bash "$SOURCE_SCRIPT" --apply 2>&1)
flags4=$(null_flags "$DB4")
after_size4=$(stat -f%z "$DB4" 2>/dev/null || stat -c%s "$DB4")
assert_contains "guard refuses VACUUM" "REFUSING VACUUM" "$out4"
assert_contains "old1 still nulled despite refused VACUUM" "old1:1" "$flags4"
assert_contains "old2 still nulled despite refused VACUUM" "old2:1" "$flags4"
assert_contains "old3 still nulled despite refused VACUUM" "old3:1" "$flags4"
assert_eq "db file size unchanged (VACUUM did not run)" "$before_size4" "$after_size4"
backup_count4=$(find "$TMP_ROOT" -maxdepth 1 -name 't4.db.dedup-backup-*' | wc -l | tr -d ' ')
assert_eq "backup still kept even though VACUUM was refused" "1" "$backup_count4"

echo "Test 5: --delete-backups dry-run reports existing backups without deleting them"
DB5="$TMP_ROOT/t5.db"
make_fixture "$DB5"
HERMES_STATE_DB="$DB5" bash "$SOURCE_SCRIPT" --apply >/dev/null 2>&1
backup5=$(find "$TMP_ROOT" -maxdepth 1 -name 't5.db.dedup-backup-*')
out5=$(HERMES_STATE_DB="$DB5" bash "$SOURCE_SCRIPT" --delete-backups 2>&1)
assert_contains "dry-run reports the backup" "would delete: $backup5" "$out5"
if [[ -f "$backup5" ]]; then
  echo "  PASS  --delete-backups dry-run leaves the file in place"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  --delete-backups dry-run leaves the file in place"
  FAIL=$(( FAIL + 1 ))
fi

echo "Test 6: --delete-backups --apply actually deletes"
out6=$(HERMES_STATE_DB="$DB5" bash "$SOURCE_SCRIPT" --delete-backups --apply 2>&1)
assert_contains "apply mode reports the deletion" "deleted: $backup5" "$out6"
if [[ -f "$backup5" ]]; then
  echo "  FAIL  --delete-backups --apply removes the file"
  FAIL=$(( FAIL + 1 ))
else
  echo "  PASS  --delete-backups --apply removes the file"
  PASS=$(( PASS + 1 ))
fi

echo "Test 7: an aged-but-below-retention backup survives the startup sweep, an aged-past-retention one does not"
DB7="$TMP_ROOT/t7.db"
make_fixture "$DB7"
old_backup="$TMP_ROOT/t7.db.dedup-backup-19990101-000000"
cp -- "$DB7" "$old_backup"
touch -t "$(date -v-72H '+%Y%m%d%H%M' 2>/dev/null || date -d '-72 hours' '+%Y%m%d%H%M' 2>/dev/null)" "$old_backup" 2>/dev/null || true
recent_backup="$TMP_ROOT/t7.db.dedup-backup-20990101-000000"
cp -- "$DB7" "$recent_backup"
HERMES_STATE_DB="$DB7" HERMES_DEDUP_BACKUP_RETENTION_HOURS=24 bash "$SOURCE_SCRIPT" >/dev/null 2>&1
if [[ ! -f "$old_backup" ]]; then
  echo "  PASS  72h-old backup swept by the 24h-retention startup sweep"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  72h-old backup swept by the 24h-retention startup sweep"
  FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$recent_backup" ]]; then
  echo "  PASS  fresh backup survives the sweep"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  fresh backup survives the sweep"
  FAIL=$(( FAIL + 1 ))
fi
rm -f -- "$recent_backup"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

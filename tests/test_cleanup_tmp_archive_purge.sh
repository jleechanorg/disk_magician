#!/usr/bin/env bash
# test_cleanup_tmp_archive_purge.sh — Test coverage for _disk_magician_archive
# quarantine purging during standard cleanup_tmp.sh invocations (bead disk_magician-f0f).
#
# Verifies:
# 1. Standard run (without --large) purges aged archives (>24h).
# 2. Standard run purges over-cap archives (>168h) unconditionally.
# 3. Active archives (within active window, .in-use marker, open fds) are preserved when under-cap.
# 4. Standard dry-run reports preview without deleting.
# 5. Non-existent or empty archive root is handled cleanly without errors.
#
# Run: bash tests/test_cleanup_tmp_archive_purge.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"

TMP_ROOT=$(mktemp -d -t test_cleanup_tmp_archive_purge.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected rc=$expected, got rc=$actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output to contain: $needle"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  fi
}

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected path to exist: $path"
  fi
}

assert_missing() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected path to be absent: $path"
  fi
}

run_capture() {
  local out_file="$1"
  shift
  set +e
  "$@" >"$out_file" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

make_find_shim() {
  local bin_dir="$1" fake_private_tmp="$2" fake_tmp="$3"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/find" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  /private/tmp)
    shift
    exec /usr/bin/find "$fake_private_tmp" "\$@"
    ;;
  /tmp)
    shift
    exec /usr/bin/find "$fake_tmp" "\$@"
    ;;
  *)
    exec /usr/bin/find "\$@"
    ;;
esac
SHIM
  chmod +x "$bin_dir/find"

  cat > "$bin_dir/getconf" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  exit 0
fi
exec /usr/bin/getconf "$@"
SHIM
  chmod +x "$bin_dir/getconf"
}

set_old_mtime() {
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
}

echo "=== cleanup_tmp.sh standard archive purge tests (disk_magician-f0f) ==="

echo "Test 1: Standard run (--clean without --large) purges aged archives"
T1_PRIVATE_TMP="$TMP_ROOT/t1-private-tmp"
T1_TMP="$TMP_ROOT/t1-tmp"
T1_ARCHIVE="$TMP_ROOT/t1-archive"
T1_BIN="$TMP_ROOT/t1-bin"
mkdir -p "$T1_PRIVATE_TMP" "$T1_TMP" "$T1_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T1_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
set_old_mtime "$T1_ARCHIVE/20200101T000000Z"
make_find_shim "$T1_BIN" "$T1_PRIVATE_TMP" "$T1_TMP"

T1_OUT="$TMP_ROOT/t1.out"
if run_capture "$T1_OUT" env -i HOME="$TMP_ROOT/t1-home" \
  PATH="$T1_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T1_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean; then
  T1_RC=0
else
  T1_RC=$?
fi
T1_OUT_CONTENT=$(cat "$T1_OUT")
assert_rc "Test 1: exits 0" 0 "$T1_RC"
assert_contains "Test 1: logs purging aged archive" "Purging aged archive" "$T1_OUT_CONTENT"
assert_missing "Test 1: aged archive directory is removed" "$T1_ARCHIVE/20200101T000000Z"
assert_contains "Test 1: reports 1 dir removed" "Dirs removed: 1" "$T1_OUT_CONTENT"

echo "Test 2: Standard dry run preview without deleting"
T2_PRIVATE_TMP="$TMP_ROOT/t2-private-tmp"
T2_TMP="$TMP_ROOT/t2-tmp"
T2_ARCHIVE="$TMP_ROOT/t2-archive"
T2_BIN="$TMP_ROOT/t2-bin"
mkdir -p "$T2_PRIVATE_TMP" "$T2_TMP" "$T2_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T2_PRIVATE_TMP" "$T2_TMP" "$T2_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
set_old_mtime "$T2_ARCHIVE/20200101T000000Z"
make_find_shim "$T2_BIN" "$T2_PRIVATE_TMP" "$T2_TMP"

T2_OUT="$TMP_ROOT/t2.out"
if run_capture "$T2_OUT" env -i HOME="$TMP_ROOT/t2-home" \
  PATH="$T2_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T2_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --dry-run; then
  T2_RC=0
else
  T2_RC=$?
fi
T2_OUT_CONTENT=$(cat "$T2_OUT")
assert_rc "Test 2: exits 0" 0 "$T2_RC"
assert_contains "Test 2: logs DRY RUN preview" "DRY RUN: would purge aged archive" "$T2_OUT_CONTENT"
assert_exists "Test 2: archive directory is preserved" "$T2_ARCHIVE/20200101T000000Z"

echo "Test 3: Active-use marker (.in-use) preserves under-cap archive in standard run"
T3_PRIVATE_TMP="$TMP_ROOT/t3-private-tmp"
T3_TMP="$TMP_ROOT/t3-tmp"
T3_ARCHIVE="$TMP_ROOT/t3-archive"
T3_BIN="$TMP_ROOT/t3-bin"
mkdir -p "$T3_PRIVATE_TMP" "$T3_TMP" "$T3_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T3_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
touch "$T3_ARCHIVE/20200101T000000Z/quarantined_app/.in-use"
set_old_mtime "$T3_ARCHIVE/20200101T000000Z"
make_find_shim "$T3_BIN" "$T3_PRIVATE_TMP" "$T3_TMP"

T3_OUT="$TMP_ROOT/t3.out"
if run_capture "$T3_OUT" env -i HOME="$TMP_ROOT/t3-home" \
  PATH="$T3_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T3_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean; then
  T3_RC=0
else
  T3_RC=$?
fi
T3_OUT_CONTENT=$(cat "$T3_OUT")
assert_rc "Test 3: exits 0" 0 "$T3_RC"
assert_contains "Test 3: logs skipping marked-active" "Skipping marked-active aged archive" "$T3_OUT_CONTENT"
assert_exists "Test 3: marked archive is preserved" "$T3_ARCHIVE/20200101T000000Z"

echo "Test 4: Over-cap archive is purged despite .in-use marker in standard run"
T4_PRIVATE_TMP="$TMP_ROOT/t4-private-tmp"
T4_TMP="$TMP_ROOT/t4-tmp"
T4_ARCHIVE="$TMP_ROOT/t4-archive"
T4_BIN="$TMP_ROOT/t4-bin"
mkdir -p "$T4_PRIVATE_TMP" "$T4_TMP" "$T4_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T4_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
touch "$T4_ARCHIVE/20200101T000000Z/quarantined_app/.in-use"
set_old_mtime "$T4_ARCHIVE/20200101T000000Z"
make_find_shim "$T4_BIN" "$T4_PRIVATE_TMP" "$T4_TMP"

T4_OUT="$TMP_ROOT/t4.out"
if run_capture "$T4_OUT" env -i HOME="$TMP_ROOT/t4-home" \
  PATH="$T4_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=48 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T4_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean; then
  T4_RC=0
else
  T4_RC=$?
fi
T4_OUT_CONTENT=$(cat "$T4_OUT")
assert_rc "Test 4: exits 0" 0 "$T4_RC"
assert_contains "Test 4: logs over-cap purge" "Purging over-cap archive" "$T4_OUT_CONTENT"
assert_missing "Test 4: over-cap archive is removed" "$T4_ARCHIVE/20200101T000000Z"

echo "Test 5: Non-existent archive directory is handled cleanly without errors"
T5_PRIVATE_TMP="$TMP_ROOT/t5-private-tmp"
T5_TMP="$TMP_ROOT/t5-tmp"
T5_ARCHIVE="$TMP_ROOT/t5-archive-nonexistent"
T5_BIN="$TMP_ROOT/t5-bin"
mkdir -p "$T5_PRIVATE_TMP" "$T5_TMP"
make_find_shim "$T5_BIN" "$T5_PRIVATE_TMP" "$T5_TMP"

T5_OUT="$TMP_ROOT/t5.out"
if run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean; then
  T5_RC=0
else
  T5_RC=$?
fi
T5_OUT_CONTENT=$(cat "$T5_OUT")
assert_rc "Test 5: exits 0" 0 "$T5_RC"
assert_contains "Test 5: finishes successfully" "Done. Dirs removed: 0" "$T5_OUT_CONTENT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

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

TEST_FIXTURE_ROOT="${TMPDIR:-/tmp}/disk_magician/fixtures"
mkdir -p "$TEST_FIXTURE_ROOT"
export TMPDIR="$TEST_FIXTURE_ROOT"
TMP_ROOT=$(mktemp -d "$TEST_FIXTURE_ROOT/test_cleanup_tmp_archive_purge.XXXXXX")
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

  cat > "$bin_dir/timeout" <<'SHIM'
#!/usr/bin/env bash
[[ "${1:-}" == --kill-after=* ]] && shift
shift
exec "$@"
SHIM
  chmod +x "$bin_dir/timeout"

  cat > "$bin_dir/lsof" <<'SHIM'
#!/usr/bin/env bash
# Fixture lsof emulating the real contract c14_probe.open_file reads:
# a TARGETED query (a path argument or a +D tree scan) prints nothing and
# exits 1 when no descriptor matches. A TARGETLESS table query keeps the
# synthetic record so cleanup_tmp's fail-closed has_open_files() still sees
# well-formed output. (The old unconditional `-a` -> exit 0 made every
# targeted probe look empty-with-rc-0, i.e. kept:check-failed.)
target=""
for arg in "$@"; do
  case "$arg" in
    +D|--) exit 1 ;;
    /*) target="$arg" ;;
  esac
done
if [[ -n "$target" ]]; then
  exit 1
fi
echo "p1234"
echo "fcwd"
echo "n/"
exit 0
SHIM
  chmod +x "$bin_dir/lsof"
}

set_old_mtime() {
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
}

make_c14_archive_entry() {
  local source="$1" entry="$2" retention="$3" archived_at actual_retention inv
  mkdir -p "$source" "${entry%/*}"
  printf 'expired scratch fixture\n' >"$source/payload.bin"
  actual_retention="$(DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_PRIVATE_TMP" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2"' _ "$REPO_ROOT" "$source")"
  [[ "$actual_retention" == "$retention" ]] || { echo "unexpected E2 retention for $source: $actual_retention" >&2; return 1; }
  archived_at="$(python3 -c 'import sys,time; print(int(time.time())-int(sys.argv[1])*3600)' "$(( retention / 60 + 25 ))")"
  python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt "$source" "$entry.c14-origin.json" "$archived_at" "$retention" >/dev/null
  mv "$source" "$entry"
  set_old_mtime "$entry"
  inv="$(mktemp "$TEST_FIXTURE_ROOT/archive-inventory.XXXXXX")"
  python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$entry" "$inv" >/dev/null
  echo "archive origin fixture: $(python3 "$REPO_ROOT/scripts/c14_probe.py" archive-info "$entry" "$entry.c14-origin.json" "$inv")"
  rm -f "$inv"
}

echo "=== cleanup_tmp.sh standard archive purge tests (disk_magician-f0f) ==="

echo "Test 1: Standard run (--clean without --large) purges aged archives"
T1_PRIVATE_TMP="$TMP_ROOT/t1-private-tmp"
T1_TMP="$TMP_ROOT/t1-tmp"
T1_ARCHIVE="$TMP_ROOT/t1-archive"
T1_BIN="$TMP_ROOT/t1-bin"
mkdir -p "$T1_PRIVATE_TMP" "$T1_TMP"
T1_PRIVATE_TMP="$(cd "$T1_PRIVATE_TMP" && pwd -P)"
T1_TMP="$(cd "$T1_TMP" && pwd -P)"
T1_ENTRY="$T1_ARCHIVE/20200101T000000Z/cli_validation_gemini_test"
make_c14_archive_entry "$T1_TMP/cli_validation_gemini_test" "$T1_ENTRY" 60
printf 'expired agent prompt fixture\n' >"$T1_TMP/agent_prompt_expired.txt"
touch -t 202001010000 "$T1_TMP/agent_prompt_expired.txt"
make_find_shim "$T1_BIN" "$T1_PRIVATE_TMP" "$T1_TMP"

T1_OUT="$TMP_ROOT/t1.out"
if run_capture "$T1_OUT" env -i HOME="$TMP_ROOT/t1-home" \
  PATH="$T1_BIN:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T1_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  T1_RC=0
else
  T1_RC=$?
fi
T1_OUT_CONTENT=$(cat "$T1_OUT")
assert_rc "Test 1: exits 0" 0 "$T1_RC"
assert_contains "Test 1: logs C14-approved aged archive removal" "Purged aged archive after C14 approval" "$T1_OUT_CONTENT"
assert_missing "Test 1: expired agent prompt is removed through C14" "$T1_TMP/agent_prompt_expired.txt"
assert_missing "Test 1: expired E2 archive entry is removed" "$T1_ENTRY"
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
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T2_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
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
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T3_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  T3_RC=0
else
  T3_RC=$?
fi
T3_OUT_CONTENT=$(cat "$T3_OUT")
assert_rc "Test 3: exits 0" 0 "$T3_RC"
assert_contains "Test 3: logs skipping marked-active" "Skipping marked-active aged archive" "$T3_OUT_CONTENT"
assert_exists "Test 3: marked archive is preserved" "$T3_ARCHIVE/20200101T000000Z"

echo "Test 4: Over-cap archive without an origin proof is kept and reported"
T4_PRIVATE_TMP="$TMP_ROOT/t4-private-tmp"
T4_TMP="$TMP_ROOT/t4-tmp"
T4_ARCHIVE="$TMP_ROOT/t4-archive"
T4_BIN="$TMP_ROOT/t4-bin"
mkdir -p "$T4_PRIVATE_TMP" "$T4_TMP" "$T4_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T4_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
set_old_mtime "$T4_ARCHIVE/20200101T000000Z"
make_find_shim "$T4_BIN" "$T4_PRIVATE_TMP" "$T4_TMP"

T4_OUT="$TMP_ROOT/t4.out"
if run_capture "$T4_OUT" env -i HOME="$TMP_ROOT/t4-home" \
  PATH="$T4_BIN:/usr/sbin:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=48 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T4_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T4_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T4_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  T4_RC=0
else
  T4_RC=$?
fi
T4_OUT_CONTENT=$(cat "$T4_OUT")
assert_rc "Test 4: exits 0" 0 "$T4_RC"
assert_contains "Test 4: over-cap C14 keep is surfaced" "archive_overcap_kept" "$T4_OUT_CONTENT"
assert_exists "Test 4: over-cap archive is preserved by C14" "$T4_ARCHIVE/20200101T000000Z/quarantined_app"

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
  TMPDIR="$TEST_FIXTURE_ROOT" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  T5_RC=0
else
  T5_RC=$?
fi
T5_OUT_CONTENT=$(cat "$T5_OUT")
assert_rc "Test 5: exits 0" 0 "$T5_RC"
assert_contains "Test 5: finishes successfully" "Done. Dirs removed: 0" "$T5_OUT_CONTENT"

echo "Test 6: C14 keeps unproven OpenCode dylib content"
T6_PRIVATE_TMP="$TMP_ROOT/t6-private-tmp"
T6_TMP="$TMP_ROOT/t6-tmp"
T6_USER_TMP="$TMP_ROOT/t6-user-tmp"
T6_ARCHIVE="$TMP_ROOT/t6-archive"
T6_BIN="$TMP_ROOT/t6-bin"
mkdir -p "$T6_PRIVATE_TMP" "$T6_TMP" "$T6_USER_TMP"
printf 'candidate\n' >"$T6_USER_TMP/.opencode.libopentui.dylib"
touch -t 202001010000 "$T6_USER_TMP/.opencode.libopentui.dylib"
make_find_shim "$T6_BIN" "$T6_PRIVATE_TMP" "$T6_TMP"
cat >"$T6_BIN/otool" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$2" '@rpath/libopentui.dylib'
SHIM
chmod +x "$T6_BIN/otool"
T6_OUT="$TMP_ROOT/t6.out"
if run_capture "$T6_OUT" env -i HOME="$TMP_ROOT/t6-home" \
  PATH="$T6_BIN:/usr/bin:/bin" TMPDIR="$TEST_FIXTURE_ROOT" \
  OPENCODE_DYLIBS_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T6_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T6_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T6_TMP" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$T6_USER_TMP" \
  bash "$SOURCE_SCRIPT" --clean --opencode-dylibs; then
  T6_RC=0
else
  T6_RC=$?
fi
T6_OUT_CONTENT=$(cat "$T6_OUT")
assert_rc "Test 6: exits 0" 0 "$T6_RC"
assert_contains "Test 6: reports C14 keep for dylib" "Preserving OpenCode dylib (C14 kept:unproven-content)" "$T6_OUT_CONTENT"
assert_exists "Test 6: unproven dylib remains" "$T6_USER_TMP/.opencode.libopentui.dylib"

echo "Test 7: receipt collision preserves metadata not created by this call"
T7_PRIVATE_TMP="$TMP_ROOT/t7-private-tmp"
T7_TMP="$TMP_ROOT/t7-tmp"
T7_ARCHIVE="$TMP_ROOT/t7-archive"
T7_BIN="$TMP_ROOT/t7-bin"
T7_STAMP="20990101T000000Z"
mkdir -p "$T7_PRIVATE_TMP/collision_candidate" "$T7_TMP" "$T7_ARCHIVE/$T7_STAMP"
printf 'payload\n' >"$T7_PRIVATE_TMP/collision_candidate/payload.bin"
touch -t 202001010000 "$T7_PRIVATE_TMP/collision_candidate" "$T7_PRIVATE_TMP/collision_candidate/payload.bin"
T7_RECEIPT="$T7_ARCHIVE/$T7_STAMP/collision_candidate.c14-origin.json"
printf '{"sentinel":"preexisting receipt"}\n' >"$T7_RECEIPT"
cp "$T7_RECEIPT" "$TMP_ROOT/t7-receipt.expected"
make_find_shim "$T7_BIN" "$T7_PRIVATE_TMP" "$T7_TMP"
cat >"$T7_BIN/date" <<'SHIM'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" && "${2:-}" == "+%Y%m%dT%H%M%SZ" ]]; then
  echo 20990101T000000Z
else
  exec /bin/date "$@"
fi
SHIM
chmod +x "$T7_BIN/date"
T7_OUT="$TMP_ROOT/t7.out"
if run_capture "$T7_OUT" env -i HOME="$TMP_ROOT/t7-home" PATH="$T7_BIN:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" LARGE_TMP_APPROVED=1 LARGE_TMP_MIN_KB=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T7_ARCHIVE" DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T7_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T7_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  T7_RC=0
else
  T7_RC=$?
fi
# Cursor review 5/6 / parent archive-error contract: a receipt collision no
# longer aborts the whole sweep. The source is left unmoved, the preexisting
# receipt bytes are untouched, and the run continues (rc 0). The ORIGINAL
# abort behavior (rc 2, set -e) would fail this assertion, so the RED is
# preserved.
assert_rc "Test 7: receipt collision continues the run" 0 "$T7_RC"
assert_contains "Test 7: receipt collision fails closed" "could not write archive origin receipt" "$(cat "$T7_OUT")"
if cmp -s "$T7_RECEIPT" "$TMP_ROOT/t7-receipt.expected"; then record_pass "Test 7: preexisting receipt bytes are preserved"; else record_fail "Test 7: preexisting receipt bytes are preserved" "receipt changed or disappeared"; fi
assert_exists "Test 7: candidate remains unmoved" "$T7_PRIVATE_TMP/collision_candidate/payload.bin"

echo "Test 8: deadline cursor resumes the same archive unit"
T8_PRIVATE_TMP="$TMP_ROOT/t8-private-tmp"
T8_TMP="$TMP_ROOT/t8-tmp"
T8_ARCHIVE="$TMP_ROOT/t8-archive"
T8_BIN="$TMP_ROOT/t8-bin"
T8_CURSOR="$TMP_ROOT/t8-cursor.json"
mkdir -p "$T8_PRIVATE_TMP" "$T8_TMP"
T8_PRIVATE_TMP="$(cd "$T8_PRIVATE_TMP" && pwd -P)"
T8_TMP="$(cd "$T8_TMP" && pwd -P)"
T8_SOURCE="$T8_TMP/cli_validation_gemini_cursor"
T8_ENTRY="$T8_ARCHIVE/20200101T000000Z/cli_validation_gemini_cursor"
mkdir -p "$T8_SOURCE" "${T8_ENTRY%/*}"
printf 'cursor fixture\n' >"$T8_SOURCE/payload.bin"
T8_RETENTION="$(DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T8_PRIVATE_TMP" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T8_TMP" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2"' _ "$REPO_ROOT" "$T8_SOURCE")"
[[ "$T8_RETENTION" == 60 ]]
T8_ARCHIVED_AT="$(python3 -c 'import sys,time; print(int(time.time())-int(sys.argv[1])*3600)' "$(( T8_RETENTION / 60 + 25 ))")"
python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt "$T8_SOURCE" "$T8_ENTRY.c14-origin.json" "$T8_ARCHIVED_AT" "$T8_RETENTION" >/dev/null
mv "$T8_SOURCE" "$T8_ENTRY"
set_old_mtime "$T8_ENTRY"
make_find_shim "$TMP_ROOT/t8-bin" "$T8_PRIVATE_TMP" "$T8_TMP"
T8_OUT="$TMP_ROOT/t8-first.out"
if run_capture "$T8_OUT" env -i HOME="$TMP_ROOT/t8-home" PATH="$TMP_ROOT/t8-bin:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T8_ARCHIVE" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T8_PRIVATE_TMP" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T8_TMP" \
  bash "$REPO_ROOT/scripts/tmp_scratch_sweep.sh" --clean --deadline-at 0 --cursor "$T8_CURSOR"; then T8_RC=0; else T8_RC=$?; fi
assert_rc "Test 8: expired deadline exits cleanly" 0 "$T8_RC"
assert_exists "Test 8: deferred archive remains" "$T8_ENTRY/payload.bin"
assert_contains "Test 8: C14 unit is deferred" "C14 deferred:deadline" "$(cat "$T8_OUT")"
if python3 - "$T8_CURSOR" "$T8_ENTRY" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v["next_index"]==0 and v["items"]==[sys.argv[2]] else 1)
PY
then record_pass "Test 8: cursor retains deferred unit at index zero"; else record_fail "Test 8: cursor retains deferred unit at index zero" "cursor did not preserve the pending path"; fi
if python3 - "$TMP_ROOT/t8-home/.disk_magician_state/receipts/tmp_scratch_sweep.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["last_terminal"]
c=r.get("candidates",{}); p=r.get("postcondition",{})
ok=(r.get("outcome")=="partial" and c.get("removed_count")==0 and
    c.get("interrupted_count")==1 and isinstance(p.get("df_delta_bytes"),int))
if not ok:
    print(json.dumps(r,sort_keys=True))
    try:
        print("child=" + open(sys.argv[1].replace("tmp_scratch_sweep.json", "cleanup_tmp.json")).read())
    except Exception as e:
        print("child-error=" + repr(e))
raise SystemExit(0 if ok else 1)
PY
then record_pass "Test 8: wrapper receipt carries interrupted count and signed df delta"; else record_fail "Test 8: wrapper receipt carries interrupted count and signed df delta" "receipt metrics were missing or invalid"; fi
T8_DEADLINE="$(python3 -c 'import time; print(time.monotonic()+300)')"
T8_OUT="$TMP_ROOT/t8-resume.out"
if run_capture "$T8_OUT" env -i HOME="$TMP_ROOT/t8-home" PATH="$TMP_ROOT/t8-bin:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T8_ARCHIVE" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_CURSOR_DEBUG=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T8_PRIVATE_TMP" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T8_TMP" \
  bash "$REPO_ROOT/scripts/tmp_scratch_sweep.sh" --clean --deadline-at "$T8_DEADLINE" --cursor "$T8_CURSOR"; then T8_RC=0; else T8_RC=$?; fi
if [[ "$T8_RC" -ne 0 ]]; then sed 's/^/        | /' "$T8_OUT"; fi
assert_rc "Test 8: resume exits cleanly" 0 "$T8_RC"
assert_missing "Test 8: resumed archive is removed" "$T8_ENTRY"
if python3 - "$TMP_ROOT/t8-home/.disk_magician_state/receipts/tmp_scratch_sweep.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["last_terminal"]
c=r.get("candidates",{}); p=r.get("postcondition",{})
ok=(r.get("outcome")=="success" and c.get("removed_count")==1 and
    isinstance(p.get("df_delta_bytes"),int))
if not ok: print(json.dumps(r,sort_keys=True))
raise SystemExit(0 if ok else 1)
PY
then record_pass "Test 8: wrapper receipt counts the completed removal"; else record_fail "Test 8: wrapper receipt counts the completed removal" "terminal receipt did not include the completed candidate"; fi
if python3 - "$T8_CURSOR" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v["next_index"]==1 else 1)
PY
then record_pass "Test 8: cursor advances after unit completion"; else record_fail "Test 8: cursor advances after unit completion" "cursor index did not advance"; fi

echo "Test 9: --large --clean refuses to archive secret-like or non-purgeable repo candidates (bead disk_magician-archive-same-volume-regrowth-03bn)"
T9_PRIVATE_TMP="$TMP_ROOT/t9-private-tmp"
T9_TMP="$TMP_ROOT/t9-tmp"
T9_ARCHIVE="$TMP_ROOT/t9-archive"
T9_BIN="$TMP_ROOT/t9-bin"
mkdir -p "$T9_PRIVATE_TMP/secret_candidate" "$T9_PRIVATE_TMP/unpushed_repo_candidate" "$T9_PRIVATE_TMP/clean_candidate" "$T9_TMP"
printf 'secret=1\n' >"$T9_PRIVATE_TMP/secret_candidate/.env.local"
printf 'payload\n' >"$T9_PRIVATE_TMP/secret_candidate/payload.bin"
set_old_mtime "$T9_PRIVATE_TMP/secret_candidate"
git -C "$T9_PRIVATE_TMP/unpushed_repo_candidate" init -q
git -C "$T9_PRIVATE_TMP/unpushed_repo_candidate" config user.name test
git -C "$T9_PRIVATE_TMP/unpushed_repo_candidate" config user.email jleechan2015@users.noreply.github.com
printf 'repo payload\n' >"$T9_PRIVATE_TMP/unpushed_repo_candidate/payload.bin"
git -C "$T9_PRIVATE_TMP/unpushed_repo_candidate" add payload.bin
git -C "$T9_PRIVATE_TMP/unpushed_repo_candidate" commit -q -m init
set_old_mtime "$T9_PRIVATE_TMP/unpushed_repo_candidate"
printf 'clean payload\n' >"$T9_PRIVATE_TMP/clean_candidate/payload.bin"
set_old_mtime "$T9_PRIVATE_TMP/clean_candidate"
make_find_shim "$T9_BIN" "$T9_PRIVATE_TMP" "$T9_TMP"

T9_OUT="$TMP_ROOT/t9.out"
if run_capture "$T9_OUT" env -i HOME="$TMP_ROOT/t9-home" \
  PATH="$T9_BIN:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_APPROVED=1 \
  LARGE_TMP_MIN_KB=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T9_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T9_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T9_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  T9_RC=0
else
  T9_RC=$?
fi
T9_OUT_CONTENT=$(cat "$T9_OUT")
assert_rc "Test 9: exits 0" 0 "$T9_RC"
assert_contains "Test 9: logs C14 secret-like skip before archiving" \
  "Skipping archive candidate (C14 kept:secret-like): $T9_PRIVATE_TMP/secret_candidate" "$T9_OUT_CONTENT"
assert_contains "Test 9: logs C14 repo skip before archiving" \
  "Skipping archive candidate (C14 kept:not-pushed): $T9_PRIVATE_TMP/unpushed_repo_candidate" "$T9_OUT_CONTENT"
assert_exists "Test 9: secret-like candidate stays at original path" "$T9_PRIVATE_TMP/secret_candidate/.env.local"
assert_exists "Test 9: unpushed repo candidate stays at original path" "$T9_PRIVATE_TMP/unpushed_repo_candidate/payload.bin"
assert_missing "Test 9: clean candidate is archived" "$T9_PRIVATE_TMP/clean_candidate"
assert_contains "Test 9: only the clean candidate is counted as archived" "Dirs archived: 1" "$T9_OUT_CONTENT"

echo "Test 10: aged descended container archive entry is purged at depth 3 without false depth-2 container evaluation"
T10_PRIVATE_TMP="$TMP_ROOT/t10-private-tmp"
T10_TMP="$TMP_ROOT/t10-tmp"
T10_ARCHIVE="$TMP_ROOT/t10-archive"
T10_BIN="$TMP_ROOT/t10-bin"
mkdir -p "$T10_PRIVATE_TMP" "$T10_TMP"
T10_PRIVATE_TMP="$(cd "$T10_PRIVATE_TMP" && pwd -P)"
T10_TMP="$(cd "$T10_TMP" && pwd -P)"
T10_SOURCE="$T10_TMP/cli_validation_gemini_depth3"
T10_CONTAINER="$T10_ARCHIVE/20200101T000000Z/agent-scratch"
T10_ENTRY="$T10_CONTAINER/cli_validation_gemini_depth3"
mkdir -p "$T10_SOURCE" "$T10_CONTAINER"
printf 'depth3 payload\n' >"$T10_SOURCE/payload.bin"
T10_ARCHIVED_AT="$(python3 -c 'import time; print(int(time.time())-96*3600)')"
python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt "$T10_SOURCE" "$T10_ENTRY.c14-origin.json" "$T10_ARCHIVED_AT" 60 >/dev/null
mv "$T10_SOURCE" "$T10_ENTRY"
set_old_mtime "$T10_ARCHIVE/20200101T000000Z"
make_find_shim "$T10_BIN" "$T10_PRIVATE_TMP" "$T10_TMP"

T10_OUT="$TMP_ROOT/t10.out"
if run_capture "$T10_OUT" env -i HOME="$TMP_ROOT/t10-home" \
  PATH="$T10_BIN:/usr/bin:/bin" \
  TMPDIR="$TEST_FIXTURE_ROOT" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T10_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T10_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T10_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  T10_RC=0
else
  T10_RC=$?
fi
T10_OUT_CONTENT=$(cat "$T10_OUT")
assert_rc "Test 10: exits 0" 0 "$T10_RC"
assert_contains "Test 10: purges depth-3 receipted entry" "Purged aged archive after C14 approval" "$T10_OUT_CONTENT"
assert_missing "Test 10: depth-3 entry is removed" "$T10_ENTRY"
if grep -qF "Skipping aged archive (C14 kept:unproven-content): $T10_CONTAINER" <<<"$T10_OUT_CONTENT"; then
  record_fail "Test 10: depth-2 container is not falsely evaluated as an unreceipted unit" "found false depth-2 skip on $T10_CONTAINER"
else
  record_pass "Test 10: depth-2 container is not falsely evaluated as an unreceipted unit"
fi
assert_contains "Test 10: reports 1 dir removed" "Dirs removed: 1" "$T10_OUT_CONTENT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

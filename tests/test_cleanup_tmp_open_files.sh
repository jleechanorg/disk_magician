#!/usr/bin/env bash
# test_cleanup_tmp_open_files.sh — Regression coverage for bounded targetless lsof
# in cleanup_tmp.sh has_open_files (bead disk_magician-dcz).
#
# Verifies:
# 1. Targetless machine format: fake lsof only accepts `-n -P -F n` and fails if +D.
# 2. Fresh scan: closed-then-open two-scan case proves fresh pre-mutation check (no stale cache).
# 3. Canonical alias: candidate physical path resolution matches canonical path emitted by lsof.
# 4. Strict prefix matching: exact match and slash-delimited prefix match, prefix collisions do not match.
# 5. Fail-closed safety matrix:
#    - timeout preserves candidate
#    - nonzero status preserves candidate
#    - stderr partial output preserves candidate
#    - malformed output preserves candidate
#    - missing lsof preserves candidate
#    - missing timeout preserves candidate
# 6. Policy gates:
#    - normal under-cap archive is guarded and preserved when open
#    - normal under-cap archive is purged when closed
#    - over-cap archive (>168h) purges unconditionally (bypassing open-file check)
# 7. --large guard placement:
#    - open-file check runs after marker and mtime checks, directly before archive_path.
#
# Run: bash tests/test_cleanup_tmp_open_files.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"

TMP_ROOT=$(mktemp -d -t test_cleanup_tmp_open_files.XXXXXX)
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

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output NOT to contain: $needle"
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
  cat > "$bin_dir/find" <<EOF
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
EOF
  chmod +x "$bin_dir/find"

  cat > "$bin_dir/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  exit 0
fi
exec /usr/bin/getconf "$@"
EOF
  chmod +x "$bin_dir/getconf"
}

set_old_mtime() {
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
}

make_large_dir() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'x%.0s' {1..2048} > "$dir/payload.bin"
}

# Find native timeout command for tests
NATIVE_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
  NATIVE_TIMEOUT="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  NATIVE_TIMEOUT="$(command -v gtimeout)"
elif [[ -x /opt/homebrew/bin/timeout ]]; then
  NATIVE_TIMEOUT="/opt/homebrew/bin/timeout"
elif [[ -x /usr/local/bin/timeout ]]; then
  NATIVE_TIMEOUT="/usr/local/bin/timeout"
fi

echo "=== cleanup_tmp.sh open-file probes test suite (disk_magician-dcz) ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Fake lsof only accepts `-n -P -F n` and fails if +D is passed
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: Fake lsof requires targetless '-n -P -F n' and rejects '+D'"
T1_PRIVATE_TMP="$TMP_ROOT/t1-private-tmp"
T1_TMP="$TMP_ROOT/t1-tmp"
T1_ARCHIVE="$TMP_ROOT/t1-archive"
T1_BIN="$TMP_ROOT/t1-bin"
mkdir -p "$T1_PRIVATE_TMP" "$T1_TMP" "$T1_ARCHIVE/20200101T000000Z/quarantined_app"
touch "$T1_ARCHIVE/20200101T000000Z/quarantined_app/payload.bin"
set_old_mtime "$T1_ARCHIVE/20200101T000000Z"
make_find_shim "$T1_BIN" "$T1_PRIVATE_TMP" "$T1_TMP"

cat > "$T1_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T1_BIN/timeout"

cat > "$T1_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == *"+D"* || "$arg" == "+D" ]]; then
    echo "ERROR: +D is forbidden: $*" >&2
    exit 99
  fi
done
# Strictly verify required targetless machine-format flags
if [[ "$*" != "-n -P -F n" && "$*" != "-nP -Fn" ]]; then
  echo "ERROR: unexpected flags: $*" >&2
  exit 98
fi
# Valid machine format output showing no open files in archive
echo "p1234"
echo "fcwd"
echo "n/"
exit 0
EOF
chmod +x "$T1_BIN/lsof"

T1_OUT="$TMP_ROOT/t1.out"
run_capture "$T1_OUT" env -i HOME="$TMP_ROOT/t1-home" \
  PATH="$T1_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T1_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T1_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" \
  bash "$SOURCE_SCRIPT" --clean
T1_RC=$?
T1_OUT_CONTENT=$(cat "$T1_OUT")
assert_rc "Test 1: exits 0" 0 "$T1_RC"
assert_not_contains "Test 1: fake lsof did not reject +D" "+D is forbidden" "$T1_OUT_CONTENT"
assert_not_contains "Test 1: fake lsof did not reject unexpected flags" "unexpected flags" "$T1_OUT_CONTENT"
assert_contains "Test 1: aged archive purged with targetless machine lsof" "Purging aged archive" "$T1_OUT_CONTENT"
assert_missing "Test 1: archive dir purged" "$T1_ARCHIVE/20200101T000000Z"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Fresh authoritative scan at each guarded destructive decision
# (closed on scan 1, then open on pre-mutation scan -> candidate preserved)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: Fresh pre-mutation scan catches files opened between decisions"
T2_PRIVATE_TMP="$TMP_ROOT/t2-private-tmp"
T2_TMP="$TMP_ROOT/t2-tmp"
T2_ARCHIVE="$TMP_ROOT/t2-archive"
T2_BIN="$TMP_ROOT/t2-bin"
mkdir -p "$T2_PRIVATE_TMP" "$T2_TMP"
mkdir -p "$T2_ARCHIVE/20200101T000000Z/app1" "$T2_ARCHIVE/20200102T000000Z/app2"
touch "$T2_ARCHIVE/20200101T000000Z/app1/payload.bin"
touch "$T2_ARCHIVE/20200102T000000Z/app2/payload.bin"
set_old_mtime "$T2_ARCHIVE/20200101T000000Z"
set_old_mtime "$T2_ARCHIVE/20200102T000000Z"
make_find_shim "$T2_BIN" "$T2_PRIVATE_TMP" "$T2_TMP"

cat > "$T2_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T2_BIN/timeout"

T2_SCAN_COUNT_FILE="$TMP_ROOT/t2-scan.count"
echo "0" > "$T2_SCAN_COUNT_FILE"

# Resolve canonical paths of both archives
T2_APP1_CANON=$(cd "$T2_ARCHIVE/20200101T000000Z" && pwd -P)
T2_APP2_CANON=$(cd "$T2_ARCHIVE/20200102T000000Z" && pwd -P)

cat > "$T2_BIN/lsof" <<EOF
#!/usr/bin/env bash
count=\$(cat "$T2_SCAN_COUNT_FILE")
count=\$(( count + 1 ))
echo "\$count" > "$T2_SCAN_COUNT_FILE"

echo "p1234"
echo "fcwd"
echo "n/"
# On scan 1 (app1), report no open files
# On scan 2 (app2), report app2 open!
if [[ "\$count" -ge 2 ]]; then
  echo "f10"
  echo "n${T2_APP2_CANON}/app2/payload.bin"
fi
exit 0
EOF
chmod +x "$T2_BIN/lsof"

T2_OUT="$TMP_ROOT/t2.out"
run_capture "$T2_OUT" env -i HOME="$TMP_ROOT/t2-home" \
  PATH="$T2_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T2_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T2_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
  bash "$SOURCE_SCRIPT" --clean
T2_RC=$?
T2_OUT_CONTENT=$(cat "$T2_OUT")
assert_rc "Test 2: exits 0" 0 "$T2_RC"
assert_missing "Test 2: app1 (scanned closed) is purged" "$T2_ARCHIVE/20200101T000000Z"
assert_exists "Test 2: app2 (scanned open on fresh scan) is preserved" "$T2_ARCHIVE/20200102T000000Z"
assert_contains "Test 2: logs skipping in-use for app2" "Skipping in-use aged archive" "$T2_OUT_CONTENT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Canonical alias path emitted by fake lsof matches candidate
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Canonical physical resolution matches canonical alias emitted by lsof"
T3_PRIVATE_TMP="$TMP_ROOT/t3-private-tmp"
T3_TMP="$TMP_ROOT/t3-tmp"
T3_ARCHIVE="$TMP_ROOT/t3-archive"
T3_BIN="$TMP_ROOT/t3-bin"
mkdir -p "$T3_PRIVATE_TMP" "$T3_TMP"
make_find_shim "$T3_BIN" "$T3_PRIVATE_TMP" "$T3_TMP"

cat > "$T3_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T3_BIN/timeout"

# Test 3: Candidate is accessed through alias path ($T3_ARCHIVE in /var/...)
# while fake lsof emits the canonical physical path ($T3_CANON in /private/var/...).
# Candidate physical canonicalization via `cd "$path" && pwd -P` must match it.
T3_REAL_ARCHIVE="$T3_ARCHIVE/20200101T000000Z"
mkdir -p "$T3_REAL_ARCHIVE/quarantined_app"
touch "$T3_REAL_ARCHIVE/quarantined_app/payload.bin"
set_old_mtime "$T3_REAL_ARCHIVE"

# Canonical physical path of the archive entry (resolves /var -> /private/var)
T3_CANON=$(cd "$T3_REAL_ARCHIVE" && pwd -P)
cat > "$T3_BIN/lsof" <<EOF
#!/usr/bin/env bash
echo "p2222"
echo "f5"
# Emit canonical physical path (/private/var/...)
echo "n${T3_CANON}/quarantined_app/payload.bin"
exit 0
EOF
chmod +x "$T3_BIN/lsof"

T3_OUT="$TMP_ROOT/t3.out"
run_capture "$T3_OUT" env -i HOME="$TMP_ROOT/t3-home" \
  PATH="$T3_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T3_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T3_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
  bash "$SOURCE_SCRIPT" --clean
T3_RC=$?
T3_OUT_CONTENT=$(cat "$T3_OUT")
assert_rc "Test 3: exits 0" 0 "$T3_RC"
assert_contains "Test 3: logs skipping in-use via canonical path match" "Skipping in-use aged archive" "$T3_OUT_CONTENT"
assert_exists "Test 3: archive is preserved" "$T3_REAL_ARCHIVE"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Exact match, slash prefix, and prefix-collision behavior
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Strict record parsing: exact/slash-prefix matches; prefix-collision does NOT match"
T4_PRIVATE_TMP="$TMP_ROOT/t4-private-tmp"
T4_TMP="$TMP_ROOT/t4-tmp"
T4_ARCHIVE="$TMP_ROOT/t4-archive"
T4_BIN="$TMP_ROOT/t4-bin"
mkdir -p "$T4_PRIVATE_TMP" "$T4_TMP"
mkdir -p "$T4_ARCHIVE/20200101T000000Z/app"
touch "$T4_ARCHIVE/20200101T000000Z/app/payload.bin"
set_old_mtime "$T4_ARCHIVE/20200101T000000Z"
make_find_shim "$T4_BIN" "$T4_PRIVATE_TMP" "$T4_TMP"

cat > "$T4_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T4_BIN/timeout"

T4_CANON=$(cd "$T4_ARCHIVE/20200101T000000Z" && pwd -P)

# 4a: Prefix collision: file in "${T4_CANON}_other/file.txt" must NOT match "${T4_CANON}"
cat > "$T4_BIN/lsof" <<EOF
#!/usr/bin/env bash
echo "p3333"
echo "f4"
# Prefix collision: candidate path is prefix but not slash-delimited
echo "n${T4_CANON}_collision_extra/sub/file.txt"
exit 0
EOF
chmod +x "$T4_BIN/lsof"

T4_OUT="$TMP_ROOT/t4.out"
run_capture "$T4_OUT" env -i HOME="$TMP_ROOT/t4-home" \
  PATH="$T4_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T4_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T4_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T4_TMP" \
  bash "$SOURCE_SCRIPT" --clean
T4_RC=$?
T4_OUT_CONTENT=$(cat "$T4_OUT")
assert_rc "Test 4a: exits 0" 0 "$T4_RC"
assert_missing "Test 4a: prefix collision does NOT protect candidate; it is purged" "$T4_ARCHIVE/20200101T000000Z"

# 4b: Exact directory match protects candidate
mkdir -p "$T4_ARCHIVE/20200102T000000Z/app"
touch "$T4_ARCHIVE/20200102T000000Z/app/payload.bin"
set_old_mtime "$T4_ARCHIVE/20200102T000000Z"
T4B_CANON=$(cd "$T4_ARCHIVE/20200102T000000Z" && pwd -P)

cat > "$T4_BIN/lsof" <<EOF
#!/usr/bin/env bash
echo "p4444"
echo "fcwd"
# Exact directory match (e.g. cwd of process)
echo "n${T4B_CANON}"
exit 0
EOF
chmod +x "$T4_BIN/lsof"

run_capture "$T4_OUT" env -i HOME="$TMP_ROOT/t4-home" \
  PATH="$T4_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T4_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T4_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T4_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T4_TMP" \
  bash "$SOURCE_SCRIPT" --clean
T4B_RC=$?
T4B_OUT_CONTENT=$(cat "$T4_OUT")
assert_rc "Test 4b: exits 0" 0 "$T4B_RC"
assert_exists "Test 4b: exact dir match preserves archive" "$T4_ARCHIVE/20200102T000000Z"
assert_contains "Test 4b: logs skipping in-use" "Skipping in-use aged archive" "$T4B_OUT_CONTENT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Fail-closed matrix: timeout, nonzero, stderr, malformed, missing-lsof, missing-timeout
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Fail-closed safety matrix: timeout, nonzero, stderr, malformed, missing-lsof, missing-timeout"

T5_PRIVATE_TMP="$TMP_ROOT/t5-private-tmp"
T5_TMP="$TMP_ROOT/t5-tmp"
T5_ARCHIVE="$TMP_ROOT/t5-archive"
T5_BIN="$TMP_ROOT/t5-bin"
mkdir -p "$T5_PRIVATE_TMP" "$T5_TMP"
make_find_shim "$T5_BIN" "$T5_PRIVATE_TMP" "$T5_TMP"

reset_t5_archive() {
  rm -rf "$T5_ARCHIVE"
  mkdir -p "$T5_ARCHIVE/20200101T000000Z/app"
  touch "$T5_ARCHIVE/20200101T000000Z/app/payload.bin"
  set_old_mtime "$T5_ARCHIVE/20200101T000000Z"
}

# 5a: Timeout preserves candidate
reset_t5_archive
cat > "$T5_BIN/timeout" <<EOF
#!/usr/bin/env bash
# Simulate GNU timeout expiring with rc 124
exit 124
EOF
chmod +x "$T5_BIN/timeout"

cat > "$T5_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T5_BIN/lsof"

T5_OUT="$TMP_ROOT/t5.out"
run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T5_BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$T5_BIN/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5a (timeout): exits 0" 0 $?
assert_exists "Test 5a: archive preserved on timeout" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5a: logs fail-closed on timeout" "Open-file check failed" "$(cat "$T5_OUT")"

# 5b: Nonzero status preserves candidate
reset_t5_archive
cat > "$T5_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T5_BIN/timeout"

cat > "$T5_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T5_BIN/lsof"

run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T5_BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$T5_BIN/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5b (nonzero rc): exits 0" 0 $?
assert_exists "Test 5b: archive preserved on nonzero rc" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5b: logs fail-closed on nonzero rc" "Open-file check failed" "$(cat "$T5_OUT")"

# 5c: Stderr partial output preserves candidate
reset_t5_archive
cat > "$T5_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "p100"
echo "fcwd"
echo "n/"
echo "lsof: WARNING: could not stat /some/path" >&2
exit 0
EOF
chmod +x "$T5_BIN/lsof"

run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T5_BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$T5_BIN/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5c (stderr output): exits 0" 0 $?
assert_exists "Test 5c: archive preserved on stderr output" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5c: logs fail-closed on stderr" "Open-file check failed" "$(cat "$T5_OUT")"

# 5d: Malformed output preserves candidate
reset_t5_archive
cat > "$T5_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "corrupt_garbage_lsof_output"
exit 0
EOF
chmod +x "$T5_BIN/lsof"

run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T5_BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$T5_BIN/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5d (malformed output): exits 0" 0 $?
assert_exists "Test 5d: archive preserved on malformed output" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5d: logs malformed fail-closed" "Open-file check produced malformed output" "$(cat "$T5_OUT")"

# 5e: Missing lsof binary preserves candidate
reset_t5_archive
rm -f "$T5_BIN/lsof"

run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="/nonexistent/path/to/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$T5_BIN/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5e (missing lsof): exits 0" 0 $?
assert_exists "Test 5e: archive preserved on missing lsof" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5e: logs missing lsof" "Open-file check unavailable" "$(cat "$T5_OUT")"

# 5f: Missing timeout binary preserves candidate
reset_t5_archive
cat > "$T5_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "p100"
echo "fcwd"
echo "n/"
exit 0
EOF
chmod +x "$T5_BIN/lsof"
rm -f "$T5_BIN/timeout"

run_capture "$T5_OUT" env -i HOME="$TMP_ROOT/t5-home" \
  PATH="$T5_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T5_BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="/nonexistent/path/to/timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 5f (missing timeout): exits 0" 0 $?
assert_exists "Test 5f: archive preserved on missing timeout" "$T5_ARCHIVE/20200101T000000Z"
assert_contains "Test 5f: logs missing timeout" "Open-file check unavailable" "$(cat "$T5_OUT")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Policy gates: normal under-cap vs over-cap bypass
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 6: Policy gates: normal under-cap is guarded; over-cap bypasses activity guards"

T6_PRIVATE_TMP="$TMP_ROOT/t6-private-tmp"
T6_TMP="$TMP_ROOT/t6-tmp"
T6_ARCHIVE="$TMP_ROOT/t6-archive"
T6_BIN="$TMP_ROOT/t6-bin"
mkdir -p "$T6_PRIVATE_TMP" "$T6_TMP" "$T6_ARCHIVE/20200101T000000Z/app"
touch "$T6_ARCHIVE/20200101T000000Z/app/payload.bin"
set_old_mtime "$T6_ARCHIVE/20200101T000000Z"
make_find_shim "$T6_BIN" "$T6_PRIVATE_TMP" "$T6_TMP"

cat > "$T6_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T6_BIN/timeout"

T6_CANON=$(cd "$T6_ARCHIVE/20200101T000000Z" && pwd -P)
cat > "$T6_BIN/lsof" <<EOF
#!/usr/bin/env bash
echo "p600"
echo "f1"
echo "n${T6_CANON}/app/payload.bin"
exit 0
EOF
chmod +x "$T6_BIN/lsof"

# 6a: Under-cap archive (age <= 168h) is guarded: preserved because open
T6_OUT="$TMP_ROOT/t6.out"
run_capture "$T6_OUT" env -i HOME="$TMP_ROOT/t6-home" \
  PATH="$T6_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$T6_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T6_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T6_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T6_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 6a (under-cap guarded): exits 0" 0 $?
assert_exists "Test 6a: open under-cap archive is preserved" "$T6_ARCHIVE/20200101T000000Z"
assert_contains "Test 6a: logs skipping in-use" "Skipping in-use aged archive" "$(cat "$T6_OUT")"

# 6b: Over-cap archive (>168h) purges unconditionally (bypassing open-file check)
# Re-create/ensure archive exists before 6b
mkdir -p "$T6_ARCHIVE/20200101T000000Z/app"
touch "$T6_ARCHIVE/20200101T000000Z/app/payload.bin"
set_old_mtime "$T6_ARCHIVE/20200101T000000Z"

run_capture "$T6_OUT" env -i HOME="$TMP_ROOT/t6-home" \
  PATH="$T6_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=48 \
  DISK_MAGICIAN_LSOF_BIN="$T6_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T6_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T6_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T6_TMP" \
  bash "$SOURCE_SCRIPT" --clean
assert_rc "Test 6b (over-cap purge): exits 0" 0 $?
assert_missing "Test 6b: over-cap archive is purged despite open file" "$T6_ARCHIVE/20200101T000000Z"
assert_contains "Test 6b: logs over-cap bypass" "Purging over-cap archive" "$(cat "$T6_OUT")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: --large guard placement: open-file check runs after marker/mtime, directly before archive
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 7: --large guard placement: open-file check runs after marker and mtime"
T7_PRIVATE_TMP="$TMP_ROOT/t7-private-tmp"
T7_TMP="$TMP_ROOT/t7-tmp"
T7_ARCHIVE="$TMP_ROOT/t7-archive"
T7_BIN="$TMP_ROOT/t7-bin"
mkdir -p "$T7_PRIVATE_TMP" "$T7_TMP"
make_find_shim "$T7_BIN" "$T7_PRIVATE_TMP" "$T7_TMP"

cat > "$T7_BIN/timeout" <<EOF
#!/usr/bin/env bash
shift
exec "\$@"
EOF
chmod +x "$T7_BIN/timeout"

# Create a candidate that has .in-use marker: should be skipped by marker check BEFORE lsof runs
make_large_dir "$T7_PRIVATE_TMP/marked_large_dir"
touch "$T7_PRIVATE_TMP/marked_large_dir/.in-use"
set_old_mtime "$T7_PRIVATE_TMP/marked_large_dir"

T7_LSOF_INVOCATION_FILE="$TMP_ROOT/t7-lsof.called"
rm -f "$T7_LSOF_INVOCATION_FILE"

cat > "$T7_BIN/lsof" <<EOF
#!/usr/bin/env bash
touch "$T7_LSOF_INVOCATION_FILE"
echo "p700"
echo "fcwd"
echo "n/"
exit 0
EOF
chmod +x "$T7_BIN/lsof"

T7_OUT="$TMP_ROOT/t7.out"
run_capture "$T7_OUT" env -i HOME="$TMP_ROOT/t7-home" \
  PATH="$T7_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_LSOF_BIN="$T7_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T7_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T7_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T7_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large
T7_RC=$?
T7_OUT_CONTENT=$(cat "$T7_OUT")
assert_rc "Test 7: exits 0" 0 "$T7_RC"
assert_contains "Test 7: logs active-use marker skip" "Skipping active-use marker (.in-use present)" "$T7_OUT_CONTENT"
assert_missing "Test 7: lsof was NOT called because marker skipped it first" "$T7_LSOF_INVOCATION_FILE"

# Now test an unmarked, stale candidate: lsof IS called directly before archive_path
rm -rf "$T7_PRIVATE_TMP/marked_large_dir"
make_large_dir "$T7_PRIVATE_TMP/stale_large_dir"
set_old_mtime "$T7_PRIVATE_TMP/stale_large_dir"
T7_STALE_CANON=$(cd "$T7_PRIVATE_TMP/stale_large_dir" && pwd -P)

cat > "$T7_BIN/lsof" <<EOF
#!/usr/bin/env bash
touch "$T7_LSOF_INVOCATION_FILE"
echo "p700"
echo "f10"
echo "n${T7_STALE_CANON}/payload.bin"
exit 0
EOF
chmod +x "$T7_BIN/lsof"

run_capture "$T7_OUT" env -i HOME="$TMP_ROOT/t7-home" \
  PATH="$T7_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_LSOF_BIN="$T7_BIN/lsof" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T7_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T7_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T7_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large
T7_RC2=$?
T7_OUT_CONTENT2=$(cat "$T7_OUT")
assert_rc "Test 7b: exits 0" 0 "$T7_RC2"
assert_exists "Test 7b: lsof WAS called before archive" "$T7_LSOF_INVOCATION_FILE"
assert_contains "Test 7b: logs skipping in-use large tmp dir" "Skipping in-use large tmp dir" "$T7_OUT_CONTENT2"
assert_exists "Test 7b: candidate preserved at original location" "$T7_PRIVATE_TMP/stale_large_dir"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

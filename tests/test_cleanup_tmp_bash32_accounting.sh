#!/usr/bin/env bash
# test_cleanup_tmp_bash32_accounting.sh — Regression coverage for the
# Bash 3.2 nounset contract and remove_path completion accounting in
# cleanup_tmp.sh.
#
# Root cause (PR #180 review): `kb=$(remove_path ...)` ran the function in a
# command-substitution subshell, so REMOVE_PATH_COMPLETED (and the
# CANDIDATE_* counters) never reached the caller. Under `set -u` the caller's
# `[[ "$REMOVE_PATH_COMPLETED" == true ]]` then aborted with "unbound
# variable" the moment an old git-clone candidate was found, and no directory
# was ever counted. `set -- "${ACT_ARGS[@]}"` aborts the same way for a
# no-argument entrypoint.
#
# Verifies:
# 1. No-argument dry-run exits 0 under /bin/bash (Bash 3.2) without nounset.
# 2. An old git-clone candidate is counted ("Dirs removed: 1") in dry-run,
#    proving remove_path's completion flag survives to the caller.
#
# Run: /bin/bash tests/test_cleanup_tmp_bash32_accounting.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"

FIXTURE_ROOT="/tmp/disk_magician/fixtures"
mkdir -p "$FIXTURE_ROOT"
TMP_ROOT=$(mktemp -d "$FIXTURE_ROOT/cleanup_tmp_bash32.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }
assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then record_pass "$name"; else record_fail "$name" "expected rc=$expected, got rc=$actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then record_pass "$name"; else record_fail "$name" "expected output to contain: $needle"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! grep -qF "$needle" <<<"$haystack"; then record_pass "$name"; else record_fail "$name" "expected output NOT to contain: $needle"; fi
}

run_capture() {
  local out_file="$1"; shift
  set +e
  "$@" >"$out_file" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

FAKE_PRIVATE_TMP="$TMP_ROOT/private-tmp"
FAKE_TMP="$TMP_ROOT/tmp"
FAKE_USER_TMP="$TMP_ROOT/user-tmp"
ARCHIVE_ROOT="$TMP_ROOT/archive"
STATE_DIR="$TMP_ROOT/state"
HOME_DIR="$TMP_ROOT/home"
GIT_CLONE="$FAKE_TMP/gitclone_fixture"
mkdir -p "$FAKE_PRIVATE_TMP" "$FAKE_TMP" "$FAKE_USER_TMP" "$ARCHIVE_ROOT" "$STATE_DIR" "$HOME_DIR" "$GIT_CLONE/.git"
printf 'payload\n' > "$GIT_CLONE/.git/HEAD"
# Far older than any configured git_clone_minutes so the candidate is found.
/usr/bin/find "$GIT_CLONE" -exec touch -t 202001010000 {} +

echo "=== cleanup_tmp.sh Bash 3.2 accounting tests ==="

echo "Test 1: no-argument dry-run under Bash 3.2"
OUT1="$TMP_ROOT/noarg.out"
if run_capture "$OUT1" env -i HOME="$HOME_DIR" PATH="/usr/bin:/bin" \
    TMPDIR="$FIXTURE_ROOT" \
    DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FAKE_PRIVATE_TMP" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$FAKE_TMP" \
    DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$FAKE_USER_TMP" \
    /bin/bash "$SOURCE_SCRIPT"; then
  RC1=0
else
  RC1=$?
fi
OUT1_CONTENT="$(cat "$OUT1")"
assert_rc "Test 1: exits 0 under Bash 3.2 nounset" 0 "$RC1"
assert_not_contains "Test 1: no unbound-variable abort" "unbound variable" "$OUT1_CONTENT"

echo "Test 2: old git-clone candidate is counted (remove_path completion survives)"
OUT2="$TMP_ROOT/count.out"
if run_capture "$OUT2" env -i HOME="$HOME_DIR" PATH="/usr/bin:/bin" \
    TMPDIR="$FIXTURE_ROOT" \
    DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FAKE_PRIVATE_TMP" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$FAKE_TMP" \
    DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$FAKE_USER_TMP" \
    /bin/bash "$SOURCE_SCRIPT" --dry-run; then
  RC2=0
else
  RC2=$?
fi
OUT2_CONTENT="$(cat "$OUT2")"
assert_rc "Test 2: exits 0 under Bash 3.2 nounset" 0 "$RC2"
assert_contains "Test 2: reports the git-clone dry-run removal" "would remove: $GIT_CLONE" "$OUT2_CONTENT"
assert_contains "Test 2: counts the removed directory" "Dirs removed: 1" "$OUT2_CONTENT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All cleanup_tmp Bash 3.2 accounting tests passed."

#!/usr/bin/env bash
# test_scratch_roots.sh — coverage for scripts/lib/scratch_roots.sh
# (bead disk_magician-d45): the single source of truth for scratch-sweeper
# roots, shared by cleanup_tmp.sh and cleanup_pr_scratch.sh.
#
# Tests:
# 1. Static roots (/private/tmp, /tmp) are always present.
# 2. DARWIN_USER_TEMP_DIR (via override) is included and canonicalized
#    (/var -> /private/var style resolution via pwd -P).
# 3. Canonicalization failure (unreadable dir) fails closed: root skipped,
#    static roots still returned.
# 4. Missing/empty DARWIN_USER_TEMP_DIR is skipped without error.
# 5. scratch_roots_get_unique deduplicates.
#
# Run: bash tests/test_scratch_roots.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/scratch_roots.sh"

TMP_TEST_ROOT="$(mktemp -d -t test_scratch_roots.XXXXXX)"
trap 'chmod -R u+w "$TMP_TEST_ROOT" 2>/dev/null || true; rm -rf "$TMP_TEST_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

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

assert_line_count() {
  local name="$1" expected="$2" haystack="$3"
  local actual
  actual="$(grep -c . <<<"$haystack" || true)"
  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected $expected lines, got $actual"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  fi
}

# --- Test 1: static roots always present -----------------------------
out="$(bash -c "source '$LIB'; scratch_roots_get_unique")"
assert_contains "Test1: /private/tmp always present" "/private/tmp" "$out"
assert_contains "Test1: /tmp always present" "/tmp" "$out"

# --- Test 2: DARWIN_USER_TEMP_DIR override is canonicalized ----------
FAKE_USER_TMP="$TMP_TEST_ROOT/var/folders/xx/T"
mkdir -p "$FAKE_USER_TMP"
out="$(bash -c "source '$LIB'; DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE='$FAKE_USER_TMP' scratch_roots_get_unique")"
canon_expected="$(cd "$FAKE_USER_TMP" && pwd -P)"
assert_contains "Test2: canonicalized DARWIN_USER_TEMP_DIR root included" "$canon_expected" "$out"

# --- Test 3: canonicalization failure fails closed (root skipped) ----
UNREADABLE="$TMP_TEST_ROOT/noaccess"
mkdir -p "$UNREADABLE"
chmod 000 "$UNREADABLE"
out="$(bash -c "source '$LIB'; DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE='$UNREADABLE' scratch_roots_get_unique" 2>/dev/null)"
chmod 755 "$UNREADABLE"
assert_not_contains "Test3: unreadable DARWIN_USER_TEMP_DIR root skipped" "noaccess" "$out"
assert_contains "Test3: static roots still returned when TMPDIR canon fails" "/private/tmp" "$out"

# --- Test 4: missing DARWIN_USER_TEMP_DIR is skipped without error ---
out="$(bash -c "source '$LIB'; DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE='$TMP_TEST_ROOT/does-not-exist' scratch_roots_get_unique")"
assert_not_contains "Test4: nonexistent TMPDIR override skipped" "does-not-exist" "$out"
assert_contains "Test4: static roots still returned" "/private/tmp" "$out"

# --- Test 5: dedup -----------------------------------------------------
# Point the override AT /private/tmp itself (canonicalizes to the same
# path already in the static list) to prove scratch_roots_get_unique
# collapses the duplicate.
out="$(bash -c "source '$LIB'; DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE='/private/tmp' scratch_roots_get_unique")"
count_private_tmp="$(grep -cFx '/private/tmp' <<<"$out" || true)"
if [[ "$count_private_tmp" -eq 1 ]]; then
  record_pass "Test5: scratch_roots_get_unique dedups repeated root"
else
  record_fail "Test5: scratch_roots_get_unique dedups repeated root" "expected exactly 1 occurrence of /private/tmp, got $count_private_tmp"
fi

echo ""
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

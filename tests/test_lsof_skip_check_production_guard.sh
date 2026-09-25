#!/usr/bin/env bash
# test_lsof_skip_check_production_guard.sh — PR #71 /advice request-changes
# (Opus): cleanup_pr_scratch.sh's has_open_files() honored
# DISK_MAGICIAN_SKIP_LSOF_CHECK=1 unconditionally. That variable exists so
# tests can bypass a real lsof call; in production it must be IGNORED (with
# a logged warning), never allowed to disable the open-file safety check
# that stands between --clean and deleting an actively-open file.
#
# Restriction: the bypass now only takes effect when DISK_MAGICIAN_TEST_SANDBOX
# is also set (i.e. inside a real sandboxed test context, mirroring the
# mandatory sandbox_guard_roots enforcement in scripts/safety_lib.sh). Outside
# a sandbox, DISK_MAGICIAN_SKIP_LSOF_CHECK=1 is ignored and the real lsof
# check still runs.
#
# Run: bash tests/test_lsof_skip_check_production_guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMP_ROOT=$(mktemp -d -t test_lsof_skip_guard.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to exist: $path"; fi
}

assert_missing() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to be gone: $path"; fi
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

# make_always_open_lsof <path> — an lsof stub that reports EVERY target as
# having an open file handle (any non-empty stdout makes has_open_files()
# return true), regardless of arguments.
make_always_open_lsof() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
echo "p99999"
EOF
  chmod +x "$path"
}

FAKE_LSOF="$TMP_ROOT/fake-lsof-always-open"
make_always_open_lsof "$FAKE_LSOF"

echo "Test 1: outside a sandbox, DISK_MAGICIAN_SKIP_LSOF_CHECK=1 is IGNORED -- the real (stubbed) lsof check still runs"
T1_DIR="$TMP_ROOT/t1_tmp"
mkdir -p "$T1_DIR/pr-open-target"
touch "$T1_DIR/pr-open-target/file.txt"
/usr/bin/find "$T1_DIR" -exec touch -t 202001010000 {} +

# Deliberately NOT setting DISK_MAGICIAN_TEST_SANDBOX here -- this call must
# behave like production. Confinement is via --tmp-dir alone (cleanup_pr_scratch.sh
# replaces its whole root list with exactly this fixture dir when --tmp-dir is
# given), matching the pattern already used by the script's own dry-run/help
# invocations elsewhere in this test suite.
T1_OUT=$(DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" DISK_MAGICIAN_SKIP_LSOF_CHECK=1 \
  bash "$TARGET_SCRIPT" --clean --tmp-dir "$T1_DIR" 2>&1)
assert_exists "T1: open-marked target is preserved (lsof bypass ignored outside sandbox)" "$T1_DIR/pr-open-target"
assert_contains "T1: logs that the skip flag was ignored outside a sandbox" \
  "DISK_MAGICIAN_SKIP_LSOF_CHECK=1 ignored" "$T1_OUT"

echo "Test 2: inside a sandbox, DISK_MAGICIAN_SKIP_LSOF_CHECK=1 still bypasses the lsof check (existing test-only behavior preserved)"
T2_DIR="$TMP_ROOT/t2_tmp"
mkdir -p "$T2_DIR/pr-open-target"
touch "$T2_DIR/pr-open-target/file.txt"
/usr/bin/find "$T2_DIR" -exec touch -t 202001010000 {} +

T2_OUT=$(DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" DISK_MAGICIAN_SKIP_LSOF_CHECK=1 \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" DISK_MAGICIAN_TEST_SANDBOX="$T2_DIR" \
  bash "$TARGET_SCRIPT" --clean --tmp-dir "$T2_DIR" 2>&1)
assert_missing "T2: target removed (skip flag honored inside a sandbox)" "$T2_DIR/pr-open-target"
assert_contains "T2: logs actual removal" "Removing:" "$T2_OUT"

echo
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

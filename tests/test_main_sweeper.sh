#!/usr/bin/env bash
# test_main_sweeper.sh — Test suite for single main disk sweeper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_SWEEPER="$REPO_ROOT/scripts/main_sweeper.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $desc: expected '$expected', got '$actual'"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $desc: expected to contain '$needle'"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "=== test_main_sweeper.sh ==="

# Test 1: Help option
echo "Test 1: Help option"
out="$("$MAIN_SWEEPER" --help 2>&1 || true)"
assert_contains "shows usage message" "Usage: main_sweeper.sh" "$out"

# Test 2: Invalid argument handling
echo "Test 2: Invalid argument handling"
set +e
out="$("$MAIN_SWEEPER" --unsupported-flag 2>&1)"
exit_code=$?
set -e
assert_eq "unknown flag exits non-zero" "1" "$exit_code"
assert_contains "reports unknown argument" "Unknown argument: --unsupported-flag" "$out"

# Test 3: Lock concurrency & skip
echo "Test 3: Lock concurrency & skip"
TMP_STATE="$(mktemp -d -t test_main_sweeper_state.XXXXXX)"
TMP_LOGS="$(mktemp -d -t test_main_sweeper_logs.XXXXXX)"
trap 'rm -rf "$TMP_STATE" "$TMP_LOGS"' EXIT

mkdir -p "$TMP_STATE/main_sweeper.lock"
echo "$$" > "$TMP_STATE/main_sweeper.lock/pid"

out="$(DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-routine --skip-snapshot --skip-health 2>&1 || true)"
assert_contains "skips run when lock is active" "Already running" "$out"

# Test 4: Force flag bypasses lock
echo "Test 4: Force flag bypasses lock"
out="$(DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-snapshot --skip-routine --skip-health --force 2>&1 || true)"
assert_contains "force flag bypasses active lock" "Warning: --force specified" "$out"

# Test 5: Reclaim stale lock
echo "Test 5: Reclaim stale lock"
mkdir -p "$TMP_STATE/main_sweeper.lock"
echo "999999" > "$TMP_STATE/main_sweeper.lock/pid" # Non-existent PID
touch -t 202001010000 "$TMP_STATE/main_sweeper.lock" 2>/dev/null || true
out="$(DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-snapshot --skip-routine --skip-health 2>&1 || true)"
assert_contains "reclaims stale lock and starts" "Starting Unified Main Sweeper" "$out"

# Test 6: Skip snapshot flag
echo "Test 6: Skip snapshot flag"
rm -rf "$TMP_STATE/main_sweeper.lock"
out="$(DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-snapshot --skip-routine --skip-health 2>&1 || true)"
assert_contains "verifies Phase 1 skip" "Phase 1: Snapshot skipped (--skip-snapshot)" "$out"

# Test 7: Threshold flag parsing
echo "Test 7: Threshold flag parsing"
set +e
out="$("$MAIN_SWEEPER" --threshold-gb 2>&1)"
exit_code=$?
set -e
assert_eq "--threshold-gb requires argument" "2" "$exit_code"

# Test 8: Free space healthy path (Phase 2)
echo "Test 8: Free space healthy path"
rm -rf "$TMP_STATE/main_sweeper.lock"
out="$(DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-snapshot --skip-routine --skip-health --threshold-gb 40 2>&1 || true)"
assert_contains "free space healthy recognized" "Disk space healthy (100 GiB >= 40 GiB)" "$out"

# Test 9: Free space pressure trigger path (Phase 2)
echo "Test 9: Free space pressure trigger path"
rm -rf "$TMP_STATE/main_sweeper.lock"
out="$(DISK_MAGICIAN_SKIP_CLONES=1 DISK_MAGICIAN_SKIP_TMP_LARGE=1 DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=10 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --dry-run --skip-snapshot --skip-routine --skip-health --threshold-gb 40 2>&1 || true)"
assert_contains "disk pressure detected" "Disk pressure detected (10 GiB < 40 GiB)" "$out"

# Test 10: Step failure aggregates errors, exits non-zero, and prevents debounce marker
echo "Test 10: Step failure aggregates errors, exits non-zero, and prevents debounce marker"
rm -rf "$TMP_STATE/main_sweeper.lock"
MOCK_REPO="$(mktemp -d -t mock_repo.XXXXXX)"
mkdir -p "$MOCK_REPO/scripts"
cat > "$MOCK_REPO/scripts/cleanup_xcode.sh" << 'EOF'
#!/bin/sh
exit 17
EOF
chmod +x "$MOCK_REPO/scripts/cleanup_xcode.sh"

set +e
out="$(DISK_MAGICIAN_REPO_ROOT="$MOCK_REPO" DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --clean --skip-snapshot --skip-health 2>&1)"
exit_code=$?
set -e
assert_eq "step failure causes non-zero sweeper exit" "1" "$exit_code"
assert_contains "failure logged in output" "Main sweeper finished with 1 failure(s)" "$out"
if [[ ! -f "$TMP_STATE/last_xcode_clean" ]]; then
  echo "  PASS  failed heavy task does not record debounce marker"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  failed heavy task incorrectly recorded debounce marker"
  FAIL=$(( FAIL + 1 ))
fi

# Test 11: Successful heavy task marks debounce marker done and sweeper exits 0
echo "Test 11: Successful heavy task marks debounce marker done and sweeper exits 0"
rm -rf "$TMP_STATE/main_sweeper.lock"
cat > "$MOCK_REPO/scripts/cleanup_xcode.sh" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_REPO/scripts/cleanup_xcode.sh"

set +e
out="$(DISK_MAGICIAN_REPO_ROOT="$MOCK_REPO" DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" DISK_MAGICIAN_MAIN_SWEEPER_LOG="$TMP_LOGS/sweeper.log" "$MAIN_SWEEPER" --clean --skip-snapshot --skip-health 2>&1)"
exit_code=$?
set -e
assert_eq "successful run exits 0" "0" "$exit_code"
assert_contains "completion logged in output" "Main sweeper completed successfully" "$out"
if [[ -f "$TMP_STATE/last_xcode_clean" ]]; then
  echo "  PASS  successful heavy task recorded debounce marker"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  successful heavy task failed to record debounce marker"
  FAIL=$(( FAIL + 1 ))
fi

# Test 12: Terminal receipt publishes valid outcome "error" on failure and "success" on clean run
echo "Test 12: Terminal receipt publishes valid outcome error on failure and success on clean run"
RECEIPT_HELPER="$SCRIPT_DIR/../scripts/job_receipt.py"
MOCK_REPO_T12="$(mktemp -d -t mock_repo_t12.XXXXXX)"
mkdir -p "$MOCK_REPO_T12/scripts"
rm -rf "$TMP_STATE/main_sweeper.lock" "$TMP_STATE/receipts" "$TMP_STATE/last_xcode_clean"
cat > "$MOCK_REPO_T12/scripts/cleanup_xcode.sh" << 'EOF'
#!/bin/sh
exit 17
EOF
chmod +x "$MOCK_REPO_T12/scripts/cleanup_xcode.sh"

DISK_MAGICIAN_REPO_ROOT="$MOCK_REPO_T12" DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" "$MAIN_SWEEPER" --clean --skip-snapshot --skip-health >/dev/null 2>&1 || true
rc_fail=$(DISK_MAGICIAN_STATE_DIR="$TMP_STATE" python3 "$RECEIPT_HELPER" read --job main_sweeper --last 2>/dev/null || echo "")
assert_contains "receipt records error outcome on failure" '"outcome": "error"' "$rc_fail"
assert_contains "receipt records non-zero error count" '"errors": 1' "$rc_fail"

rm -rf "$TMP_STATE/main_sweeper.lock" "$TMP_STATE/receipts" "$TMP_STATE/last_xcode_clean"
cat > "$MOCK_REPO_T12/scripts/cleanup_xcode.sh" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_REPO_T12/scripts/cleanup_xcode.sh"

DISK_MAGICIAN_REPO_ROOT="$MOCK_REPO_T12" DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 DISK_MAGICIAN_STATE_DIR="$TMP_STATE" "$MAIN_SWEEPER" --clean --skip-snapshot --skip-health >/dev/null 2>&1 || true
rc_succ=$(DISK_MAGICIAN_STATE_DIR="$TMP_STATE" python3 "$RECEIPT_HELPER" read --job main_sweeper --last 2>/dev/null || echo "")
assert_contains "receipt records success outcome on clean run" '"outcome": "success"' "$rc_succ"
assert_contains "receipt records zero errors on clean run" '"errors": 0' "$rc_succ"

rm -rf "$MOCK_REPO_T12"

rm -rf "$MOCK_REPO"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]] || exit 1

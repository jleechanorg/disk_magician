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

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]] || exit 1

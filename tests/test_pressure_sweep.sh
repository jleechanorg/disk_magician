#!/usr/bin/env bash
# test_pressure_sweep.sh — Behavioral tests for pressure_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/pressure_sweep.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d -t pressure_sweep_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
LOG_FILE="$TMP_ROOT/pressure-sweep.log"
INVOCATION_LOG="$TMP_ROOT/invocations.log"
mkdir -p "$MOCK_BIN" "$STATE_DIR"
: > "$INVOCATION_LOG"

cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
exit 0
MOCK

cat > "$MOCK_BIN/cleanup_colima.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_colima $*" >> "${INVOCATION_LOG:?}"
exit 0
MOCK

chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_colima.sh"

run_pressure() {
  local free_gb="$1"
  shift
  local real_tmp="$REPO_ROOT/scripts/cleanup_tmp.sh"
  local real_colima="$REPO_ROOT/scripts/cleanup_colima.sh"
  local back_tmp="$TMP_ROOT/cleanup_tmp.sh.real"
  local back_colima="$TMP_ROOT/cleanup_colima.sh.real"
  cp -p "$real_tmp" "$back_tmp"
  cp -p "$real_colima" "$back_colima"
  cp "$MOCK_BIN/cleanup_tmp.sh" "$real_tmp"
  cp "$MOCK_BIN/cleanup_colima.sh" "$real_colima"
  restore_mocks() {
    cp -p "$back_tmp" "$real_tmp"
    cp -p "$back_colima" "$real_colima"
  }
  trap restore_mocks RETURN
  env -i \
    HOME="$TMP_ROOT/home" \
    PATH="/usr/bin:/bin" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
    DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE="$free_gb" \
    INVOCATION_LOG="$INVOCATION_LOG" \
    bash "$SCRIPT" "$@"
}

PASS=0
FAIL=0

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name (missing: $needle)"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  FAIL  $name (unexpected: $needle)"
    FAIL=$(( FAIL + 1 ))
  else
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  fi
}

echo "Test 1: no-op when free >= threshold"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
run_pressure 50
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs no-op line" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "skips cleanup_tmp" "cleanup_tmp" "$INVOCATIONS"

echo "Test 2: triggered clean path passes --large and LARGE_TMP_APPROVED=1"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 8
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs triggered sweep" "sweep triggered (dry_run=false)" "$LOG_CONTENT"
assert_contains "cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_contains "cleanup_colima --clean" "cleanup_colima --clean" "$INVOCATIONS"

echo "Test 3: dry-run passes --dry-run --large without LARGE_TMP_APPROVED"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 8 --dry-run
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp dry-run --large" "cleanup_tmp --dry-run --large LARGE_TMP_APPROVED=0" "$INVOCATIONS"
assert_contains "cleanup_colima dry-run" "cleanup_colima --dry-run" "$INVOCATIONS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All pressure_sweep tests passed."

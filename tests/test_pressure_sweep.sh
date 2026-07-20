#!/usr/bin/env bash
# test_pressure_sweep.sh — Behavioral tests for pressure_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/pressure_sweep.sh"

if [[ ! -x "$SOURCE_SCRIPT" ]]; then
  echo "FAIL: $SOURCE_SCRIPT not executable" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d -t pressure_sweep_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/scripts"
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
cp "$SOURCE_SCRIPT" "$MOCK_BIN/pressure_sweep.sh"
chmod +x "$MOCK_BIN/pressure_sweep.sh"
SCRIPT="$MOCK_BIN/pressure_sweep.sh"

run_pressure() {
  local free_gb="$1"
  shift
  # DISK_MAGICIAN_TMP_GB_OVERRIDE pinned to 0 here so these baseline tests
  # never pick up the real host's /private/tmp size (tmp_gb() reads an
  # absolute host path, not something scoped under the fake $HOME above).
  env -i \
    HOME="$TMP_ROOT/home" \
    PATH="/usr/bin:/bin" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
    DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE="$free_gb" \
    DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
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

echo "Test 4: healthy free space + Colima over ceiling triggers colima-only sweep"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=40 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs colima-only trigger" "Colima 40 GB >= ceiling 35 GB — colima-only sweep triggered" "$LOG_CONTENT"
assert_contains "logs step-1 skip" "step 1/2 skipped (colima-only mode" "$LOG_CONTENT"
assert_not_contains "does not run cleanup_tmp" "cleanup_tmp" "$INVOCATIONS"
assert_contains "runs cleanup_colima" "cleanup_colima --clean" "$INVOCATIONS"

echo "Test 5: healthy free space + Colima under ceiling stays a no-op"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=30 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs plain no-op" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "no colima invocation under ceiling" "cleanup_colima" "$INVOCATIONS"

echo "Test 6: ceiling=0 disables the colima-size trigger entirely"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=999 \
  DISK_MAGICIAN_COLIMA_CEILING_GB=0 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "ceiling=0 logs plain no-op" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "ceiling=0 runs nothing" "cleanup_colima" "$INVOCATIONS"

echo "Test 7: healthy free space + tmp over ceiling triggers tmp-only sweep"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=0 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=35 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs tmp-only trigger" "/private/tmp 35 GB >= ceiling 30 GB — tmp-only sweep triggered" "$LOG_CONTENT"
assert_contains "logs step-2 skip" "step 2/2 skipped (tmp-only mode" "$LOG_CONTENT"
assert_contains "runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_not_contains "does not run cleanup_colima" "cleanup_colima" "$INVOCATIONS"

echo "Test 8: healthy free space + tmp under ceiling stays a no-op"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=0 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=10 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs plain no-op" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "no cleanup_tmp invocation under ceiling" "cleanup_tmp" "$INVOCATIONS"

echo "Test 9: tmp ceiling=0 disables the tmp-size trigger entirely"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=0 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=999 \
  DISK_MAGICIAN_TMP_CEILING_GB=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "tmp ceiling=0 logs plain no-op" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "tmp ceiling=0 runs nothing" "cleanup_tmp" "$INVOCATIONS"

echo "Test 10: both Colima and tmp over ceiling triggers a full sweep"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=40 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=35 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs full-sweep trigger" "full sweep triggered" "$LOG_CONTENT"
assert_contains "runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_contains "runs cleanup_colima --clean" "cleanup_colima --clean" "$INVOCATIONS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All pressure_sweep tests passed."

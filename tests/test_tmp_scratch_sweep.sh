#!/bin/bash
# test_tmp_scratch_sweep.sh — Behavioral tests for tmp_scratch_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/tmp_scratch_sweep.sh"

TMP_ROOT=$(mktemp -d -t tmp_scratch_sweep_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/scripts"
STATE_DIR="$TMP_ROOT/state"
INVOCATION_LOG="$TMP_ROOT/invocations.log"
mkdir -p "$MOCK_BIN" "$STATE_DIR"
: > "$INVOCATION_LOG"

cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
[[ "${TMP_MOCK_EXIT:-0}" == "0" ]] && exit 0 || exit 1
MOCK

cat > "$MOCK_BIN/cleanup_claude_state.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_claude_state $* CLAUDE_STATE_APPROVED=${CLAUDE_STATE_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
[[ "${CLAUDE_STATE_MOCK_EXIT:-0}" == "0" ]] && exit 0 || exit 1
MOCK

chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_claude_state.sh"
cp "$REPO_ROOT/scripts/job_receipt.py" "$MOCK_BIN/job_receipt.py"
chmod +x "$MOCK_BIN/job_receipt.py"
cp "$SOURCE_SCRIPT" "$MOCK_BIN/tmp_scratch_sweep.sh"
chmod +x "$MOCK_BIN/tmp_scratch_sweep.sh"
SCRIPT="$MOCK_BIN/tmp_scratch_sweep.sh"

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

assert_receipt_field() {
  local name="$1" json_file="$2" py_expr="$3" expected="$4"
  local actual
  actual=$(python3 -c "import json, sys; d=json.load(open('$json_file')); print($py_expr)" 2>/dev/null || echo "__ERR__")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name (expected: $expected, got: $actual)"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "Test 1: --clean invokes cleanup_tmp.sh with LARGE_TMP_APPROVED=1"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" /bin/bash "$SCRIPT" --clean
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp invoked with --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"

echo "Test 2: --clean invokes cleanup_claude_state.sh with --dry-run"
assert_contains "cleanup_claude_state invoked with --dry-run" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"

echo "Test 3: order — cleanup_tmp line precedes cleanup_claude_state line"
TMP_LINE=$(grep -n "^cleanup_tmp" "$INVOCATION_LOG" | head -1 | cut -d: -f1)
STATE_LINE=$(grep -n "^cleanup_claude_state" "$INVOCATION_LOG" | head -1 | cut -d: -f1)
if [[ -n "$TMP_LINE" && -n "$STATE_LINE" && "$TMP_LINE" -lt "$STATE_LINE" ]]; then
  echo "  PASS  tmp step runs before state step"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  tmp step did not run before state step"
  FAIL=$(( FAIL + 1 ))
fi

echo "Test 4: failure-continue — cleanup_claude_state still runs if cleanup_tmp exits 1"
: > "$INVOCATION_LOG"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" TMP_MOCK_EXIT=1 /bin/bash "$SCRIPT" --clean
WRAPPER_RC=$?
set -e
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_claude_state still ran after cleanup_tmp failure" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"

echo "Test 5: dry-run mode passes --dry-run to both, sets neither approval var"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" /bin/bash "$SCRIPT" --dry-run
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp dry-run, no approval" "cleanup_tmp --dry-run --large LARGE_TMP_APPROVED=0" "$INVOCATIONS"
assert_contains "cleanup_claude_state dry-run, no approval" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"
assert_receipt_field "dry-run receipt outcome success_noop" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "success_noop"
assert_receipt_field "dry-run receipt freed_bytes null" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('postcondition', {}).get('freed_bytes'))" "None"
assert_receipt_field "dry-run receipt safety no_mutation" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('status')" "no_mutation"

echo "Test 6: exit code — wrapper exits nonzero if a step failed"
if [[ "$WRAPPER_RC" -ne 0 ]]; then
  echo "  PASS  wrapper propagates nonzero exit when cleanup_tmp failed"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited 0 despite cleanup_tmp failing (rc=$WRAPPER_RC)"
  FAIL=$(( FAIL + 1 ))
fi
# Re-run failure to check receipt outcome
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" TMP_MOCK_EXIT=1 /bin/bash "$SCRIPT" --clean || true
assert_receipt_field "failure receipt outcome error" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"

echo "Test 7: exit code — wrapper exits 0 when both steps succeed"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" /bin/bash "$SCRIPT" --clean
CLEAN_RC=$?
if [[ "$CLEAN_RC" -eq 0 ]]; then
  echo "  PASS  wrapper exits 0 when both steps succeed"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited $CLEAN_RC despite both steps succeeding"
  FAIL=$(( FAIL + 1 ))
fi
assert_receipt_field "clean receipt outcome success" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "success"
assert_receipt_field "clean receipt safety delegated" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('status')" "delegated"

echo "Test 8: exit code — wrapper exits nonzero if cleanup_claude_state fails alone while cleanup_tmp succeeds"
: > "$INVOCATION_LOG"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" CLAUDE_STATE_MOCK_EXIT=1 /bin/bash "$SCRIPT" --clean
STATE_FAIL_RC=$?
set -e
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp ran successfully in Test 8" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_contains "cleanup_claude_state ran and failed in Test 8" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"
if [[ "$STATE_FAIL_RC" -ne 0 ]]; then
  echo "  PASS  wrapper propagates nonzero exit when cleanup_claude_state failed alone"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited 0 despite cleanup_claude_state failing alone (rc=$STATE_FAIL_RC)"
  FAIL=$(( FAIL + 1 ))
fi
assert_receipt_field "state failure receipt outcome error" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All tmp_scratch_sweep tests passed."

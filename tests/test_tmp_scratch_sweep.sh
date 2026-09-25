#!/usr/bin/env bash
# test_tmp_scratch_sweep.sh — Behavioral tests for tmp_scratch_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/tmp_scratch_sweep.sh"

TMP_ROOT=$(mktemp -d -t tmp_scratch_sweep_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/scripts"
INVOCATION_LOG="$TMP_ROOT/invocations.log"
mkdir -p "$MOCK_BIN"
: > "$INVOCATION_LOG"

cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
[[ "${TMP_MOCK_EXIT:-0}" == "0" ]] && exit 0 || exit 1
MOCK

cat > "$MOCK_BIN/cleanup_claude_state.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_claude_state $* CLAUDE_STATE_APPROVED=${CLAUDE_STATE_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
exit 0
MOCK

chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_claude_state.sh"
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

echo "Test 1: --clean invokes cleanup_tmp.sh with LARGE_TMP_APPROVED=1"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" bash "$SCRIPT" --clean
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp invoked with --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"

echo "Test 2: --clean invokes cleanup_claude_state.sh with CLAUDE_STATE_APPROVED=1"
assert_contains "cleanup_claude_state invoked with --clean" "cleanup_claude_state --clean CLAUDE_STATE_APPROVED=1" "$INVOCATIONS"

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
INVOCATION_LOG="$INVOCATION_LOG" TMP_MOCK_EXIT=1 bash "$SCRIPT" --clean
WRAPPER_RC=$?
set -e
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_claude_state still ran after cleanup_tmp failure" "cleanup_claude_state --clean CLAUDE_STATE_APPROVED=1" "$INVOCATIONS"

echo "Test 5: dry-run mode passes --dry-run to both, sets neither approval var"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" bash "$SCRIPT" --dry-run
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp dry-run, no approval" "cleanup_tmp --dry-run --large LARGE_TMP_APPROVED=0" "$INVOCATIONS"
assert_contains "cleanup_claude_state dry-run, no approval" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"

echo "Test 6: exit code — wrapper exits nonzero if a step failed (round-1 /advice finding:"
echo "        hardcoded exit 0 masked failures from an unattended hourly launchd job)"
if [[ "$WRAPPER_RC" -ne 0 ]]; then
  echo "  PASS  wrapper propagates nonzero exit when cleanup_tmp failed"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited 0 despite cleanup_tmp failing (rc=$WRAPPER_RC)"
  FAIL=$(( FAIL + 1 ))
fi

echo "Test 7: exit code — wrapper exits 0 when both steps succeed"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" bash "$SCRIPT" --clean
CLEAN_RC=$?
if [[ "$CLEAN_RC" -eq 0 ]]; then
  echo "  PASS  wrapper exits 0 when both steps succeed"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited $CLEAN_RC despite both steps succeeding"
  FAIL=$(( FAIL + 1 ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All tmp_scratch_sweep tests passed."

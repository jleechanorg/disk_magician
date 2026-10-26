#!/bin/bash
# test_tmp_scratch_sweep.sh — Behavioral tests for tmp_scratch_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/tmp_scratch_sweep.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/disk-magician-tmp-scratch-sweep.XXXXXX") || {
  echo "FATAL: could not allocate fixture root under TMPDIR" >&2
  exit 2
}
if [[ -z "$TMP_ROOT" || ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  echo "FATAL: invalid or symlinked fixture root '$TMP_ROOT'" >&2
  exit 2
fi
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)" || {
  echo "FATAL: could not canonicalize fixture root" >&2
  exit 2
}
case "$TMP_ROOT" in
  "${TMPDIR:-/tmp}"/*|/tmp/*|/private/tmp/*) ;;
  *) echo "FATAL: fixture root outside TMPDIR: '$TMP_ROOT'" >&2; exit 2 ;;
esac
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/scripts"
STATE_DIR="$TMP_ROOT/state"
INVOCATION_LOG="$TMP_ROOT/invocations.log"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$MOCK_BIN" "$STATE_DIR" "$HOME_DIR"
export HOME="$HOME_DIR"
: > "$INVOCATION_LOG"

cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
helper="${DISK_MAGICIAN_RECEIPT_HELPER:-$(cd "$(dirname "$0")" && pwd)/job_receipt.py}"
rc="${TMP_MOCK_EXIT:-0}"
if [[ "$rc" == 75 ]]; then
  echo "[cleanup_tmp] skipped, scratch lock held after waiting 20s" >&2
  exit 75
fi
if [[ "$rc" == 0 ]]; then outcome=success; else outcome=error; fi
run_id="$(python3 "$helper" begin --job cleanup_tmp --trigger "${DISK_MAGICIAN_RECEIPT_TRIGGER:-mock}" --precondition '{}')"
python3 "$helper" finish --job cleanup_tmp --run-id "$run_id" --outcome "$outcome" \
  --reason "mock cleanup result" --safety '{}' \
  --candidates '{"count":null,"bytes":null,"removed_count":0,"deferred_count":0,"interrupted_count":0}' \
  --postcondition '{"df_delta_bytes":0,"freed_bytes":0}' >/dev/null
exit "$rc"
MOCK

cat > "$MOCK_BIN/cleanup_claude_state.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_claude_state $* CLAUDE_STATE_APPROVED=${CLAUDE_STATE_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
[[ "${CLAUDE_STATE_MOCK_EXIT:-0}" == "0" ]] && exit 0 || exit 1
MOCK

chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_claude_state.sh"
cp "$REPO_ROOT/scripts/job_receipt.py" "$MOCK_BIN/job_receipt.py"
chmod +x "$MOCK_BIN/job_receipt.py"
mkdir -p "$MOCK_BIN/lib"
cp "$REPO_ROOT/scripts/lib/actuator_deadline.sh" "$MOCK_BIN/lib/actuator_deadline.sh"
cp "$REPO_ROOT/scripts/lib/actuator_receipt.sh" "$MOCK_BIN/lib/actuator_receipt.sh"
cp "$SOURCE_SCRIPT" "$MOCK_BIN/tmp_scratch_sweep.sh"
chmod +x "$MOCK_BIN/tmp_scratch_sweep.sh"
cat > "$TMP_ROOT/disk_magician.sh" <<'MOCK'
#!/bin/bash
echo "disk_magician $* trigger=${DISK_MAGICIAN_TRIGGER:-} deadline=${ACT_DEADLINE_AT:-} cursor=${ACT_CURSOR:-}" >> "${INVOCATION_LOG:?}"
if [[ "$*" == "volume ballast ensure scratch" ]]; then exit "${VOLUME_MOCK_ENSURE_RC:-0}"; fi
[[ "${VOLUME_MOCK_SLEEP:-0}" == 0 ]] || sleep "$VOLUME_MOCK_SLEEP"
if [[ "${VOLUME_MOCK_MODE:-receipt}" == skip ]]; then
  echo "${VOLUME_MOCK_SKIP:-skipped:below-trigger:80}"
  exit 0
fi
helper="${DISK_MAGICIAN_RECEIPT_HELPER:?}"
run_id="$(python3 "$helper" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-mock}" --precondition '{}')"
trigger="${DISK_MAGICIAN_TRIGGER:-mock}"
[[ "${VOLUME_MOCK_MODE:-receipt}" != stale ]] || trigger=stale-trigger
outcome="${VOLUME_MOCK_OUTCOME:-success}"
target=true
[[ "$outcome" != partial ]] || target=false
python3 "$helper" finish --job volume_reclaim --run-id "$run_id" --outcome "$outcome"   --reason "mock volume result" --trigger "$trigger" --safety '{}'   --candidates "{\"aged_scanned\":3,\"removed\":${VOLUME_MOCK_REMOVED:-2},\"top_kept_reason\":\"lease_active\",\"ballast_restore_failures\":${VOLUME_MOCK_BALLAST_FAILURES:-0}}"   --postcondition "{\"target_reached\":$target}" >/dev/null
MOCK
chmod +x "$TMP_ROOT/disk_magician.sh"
export DISK_MAGICIAN_RECEIPT_HELPER="$MOCK_BIN/job_receipt.py"
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

echo "Test 0: launchd template is a valid plist with the expected schedule"
python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); assert p["Label"] == "com.jleechanorg.disk-magician-tmp-scratch", p["Label"]; assert p["ProgramArguments"] == ["@HOME@/.local/bin/diskm", "tmp-scratch-sweep", "--clean"], p["ProgramArguments"]; assert p["StartInterval"] == 3600, p["StartInterval"]; print("  PASS  plist parses and matches Label, ProgramArguments, and StartInterval")' "$REPO_ROOT/launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template"

echo "Test 1: --clean invokes cleanup_tmp.sh with LARGE_TMP_APPROVED=1"
: > "$INVOCATION_LOG"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" /bin/bash "$SCRIPT" --clean
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp invoked with --clean --aged" "cleanup_tmp --clean --aged LARGE_TMP_APPROVED=1" "$INVOCATIONS"

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
assert_contains "cleanup_tmp dry-run, no approval" "cleanup_tmp --dry-run --aged LARGE_TMP_APPROVED=0" "$INVOCATIONS"
assert_contains "cleanup_claude_state dry-run, no approval" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"
assert_receipt_field "dry-run receipt outcome success_noop" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "success_noop"
assert_receipt_field "dry-run receipt reports zero reclaimed bytes" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('postcondition', {}).get('freed_bytes'))" "0"
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

echo "Test 7a: scheduler routes volume reclaim and folds its trigger-bound metrics"
assert_contains "scheduler invokes volume reclaim" "disk_magician volume reclaim --clean trigger=tmp_scratch_sweep:" "$(cat "$INVOCATION_LOG")"
assert_receipt_field "parent receipt includes volume artifacts removed" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('candidates', {}).get('volume_removed'))" "2"
assert_receipt_field "parent receipt includes volume safety reason" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('candidates', {}).get('volume_top_kept_reason')" "lease_active"

echo "Test 7b: partial volume result propagates to scheduler receipt"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" VOLUME_MOCK_OUTCOME=partial /bin/bash "$SCRIPT" --clean
assert_receipt_field "volume partial produces parent partial" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "partial"

echo "Test 7b: ballast restore failure propagates partial and remains counted"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" VOLUME_MOCK_OUTCOME=partial VOLUME_MOCK_BALLAST_FAILURES=1 /bin/bash "$SCRIPT" --clean >/dev/null
DISK_MAGICIAN_STATE_DIR="$STATE_DIR" python3 "$MOCK_BIN/job_receipt.py" read --job tmp_scratch_sweep --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["volume_ballast_restore_failures"]==1 and "ballast restore failure" in r["reason"]'

echo "Test 7c: missing trigger-bound receipt fails closed"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" VOLUME_MOCK_MODE=stale /bin/bash "$SCRIPT" --clean
STALE_RC=$?
set -e
if [[ "$STALE_RC" -ne 0 ]]; then echo "  PASS  stale volume receipt fails"; PASS=$((PASS+1)); else echo "  FAIL  stale volume receipt accepted"; FAIL=$((FAIL+1)); fi
assert_receipt_field "stale volume receipt produces parent error" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"

echo "Test 7d: explicit below-trigger skip is valid and dry-run does not claim target recovery"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" VOLUME_MOCK_MODE=skip /bin/bash "$SCRIPT" --dry-run
assert_receipt_field "dry-run volume target is not claimed" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('candidates', {}).get('volume_target_reached'))" "None"

echo "Test 7e: volume reclaim receives governor state and a stalled scan has a bounded terminal receipt"
: >"$INVOCATION_LOG"
DEADLINE="$(python3 -c 'import time; print(time.monotonic()+60)')"
CURSOR="$TMP_ROOT/governor.cursor"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  /bin/bash "$SCRIPT" --clean --deadline-at "$DEADLINE" --cursor "$CURSOR" >/dev/null
assert_contains "volume invocation receives deadline and isolated cursor" "deadline=$DEADLINE cursor=${CURSOR}.volume-reclaim" "$(cat "$INVOCATION_LOG")"
: >"$INVOCATION_LOG"
STARTED="$(python3 -c 'import time; print(time.monotonic())')"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" VOLUME_MOCK_SLEEP=4 DISK_MAGICIAN_VOLUME_RECLAIM_TIMEOUT_SECONDS=1 \
  /bin/bash "$SCRIPT" --clean >"$TMP_ROOT/volume-timeout.out" 2>&1
TIMEOUT_RC=$?
set -e
ELAPSED="$(python3 - "$STARTED" <<'PY'
import sys,time
print(time.monotonic()-float(sys.argv[1]))
PY
)"
if [[ "$TIMEOUT_RC" -ne 0 && "$(python3 -c 'import sys; print(float(sys.argv[1]) < 6)' "$ELAPSED")" == True ]]; then
  echo "  PASS  stalled volume reclaim was terminated within the configured bound"
  PASS=$((PASS+1))
else
  echo "  FAIL  stalled volume reclaim exceeded bound or returned success (rc=$TIMEOUT_RC elapsed=$ELAPSED)"
  FAIL=$((FAIL+1))
fi
assert_receipt_field "stalled volume reclaim ends volume timeout receipt" "$STATE_DIR/receipts/volume_reclaim.json" "d.get('last_terminal', {}).get('outcome')" "timeout"
assert_receipt_field "stalled volume reclaim ends parent error receipt" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"
echo "Test 7f: missing timeout utility fails closed without invoking reclaim"
: >"$INVOCATION_LOG"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_VOLUME_TIMEOUT_BIN="$TMP_ROOT/no-timeout" \
  /bin/bash "$SCRIPT" --clean >"$TMP_ROOT/no-timeout.out" 2>&1
NO_TIMEOUT_RC=$?
set -e
if [[ "$NO_TIMEOUT_RC" -ne 0 ]] && ! grep -q '^disk_magician volume reclaim' "$INVOCATION_LOG"; then
  echo "  PASS  no timeout utility blocks volume reclaim"
  PASS=$((PASS+1))
else
  echo "  FAIL  missing timeout utility did not fail closed (rc=$NO_TIMEOUT_RC)"
  FAIL=$((FAIL+1))
fi
assert_receipt_field "missing timeout utility records volume timeout" "$STATE_DIR/receipts/volume_reclaim.json" "d.get('last_terminal', {}).get('outcome')" "timeout"
assert_receipt_field "missing timeout utility records parent error" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"

echo "Test 8: exit code — wrapper exits nonzero if cleanup_claude_state fails alone while cleanup_tmp succeeds"
: > "$INVOCATION_LOG"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" CLAUDE_STATE_MOCK_EXIT=1 /bin/bash "$SCRIPT" --clean
STATE_FAIL_RC=$?
set -e
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp ran successfully in Test 8" "cleanup_tmp --clean --aged LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_contains "cleanup_claude_state ran and failed in Test 8" "cleanup_claude_state --dry-run CLAUDE_STATE_APPROVED=0" "$INVOCATIONS"
if [[ "$STATE_FAIL_RC" -ne 0 ]]; then
  echo "  PASS  wrapper propagates nonzero exit when cleanup_claude_state failed alone"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited 0 despite cleanup_claude_state failing alone (rc=$STATE_FAIL_RC)"
  FAIL=$(( FAIL + 1 ))
fi
assert_receipt_field "state failure receipt outcome error" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"

echo "Test 9: no-argument entrypoint survives Bash 3.2 nounset and defaults to dry-run"
: > "$INVOCATION_LOG"
NOARG_OUT="$TMP_ROOT/noarg.out"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" /bin/bash "$SCRIPT" >"$NOARG_OUT" 2>&1
NOARG_RC=$?
set -e
INVOCATIONS="$(cat "$INVOCATION_LOG")"
if [[ "$NOARG_RC" -eq 0 ]]; then
  echo "  PASS  no-argument entrypoint exits 0"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  no-argument entrypoint exited $NOARG_RC: $(cat "$NOARG_OUT")"
  FAIL=$(( FAIL + 1 ))
fi
if ! grep -q "unbound variable" "$NOARG_OUT"; then
  echo "  PASS  no-argument entrypoint has no nounset abort"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  no-argument entrypoint aborted under nounset"
  FAIL=$(( FAIL + 1 ))
fi
assert_contains "no-argument entrypoint defaults to dry-run" "cleanup_tmp --dry-run --aged LARGE_TMP_APPROVED=0" "$INVOCATIONS"

echo "Test 10: cleanup_tmp exit 75 (scratch lock held) records skipped_lock and exits 0"
: > "$INVOCATION_LOG"
set +e
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" TMP_MOCK_EXIT=75 VOLUME_MOCK_REMOVED=0 /bin/bash "$SCRIPT" --clean
LOCK_SKIP_RC=$?
set -e
if [[ "$LOCK_SKIP_RC" -eq 0 ]]; then
  echo "  PASS  wrapper exits 0 when cleanup_tmp skips on scratch lock (rc=75)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  wrapper exited $LOCK_SKIP_RC on scratch lock contention (expected 0)"
  FAIL=$(( FAIL + 1 ))
fi
assert_receipt_field "scratch lock contention records skipped_lock" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "skipped_lock"
assert_receipt_field "scratch lock contention records removed_count 0" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('candidates', {}).get('removed_count'))" "0"

echo "Test 10a: volume mutation after cleanup_tmp lock is partial and delegated"
INVOCATION_LOG="$INVOCATION_LOG" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" TMP_MOCK_EXIT=75 VOLUME_MOCK_REMOVED=2 /bin/bash "$SCRIPT" --clean
assert_receipt_field "lock plus volume mutation records partial" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('outcome')" "partial"
assert_receipt_field "lock plus volume mutation preserves removal metric" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "str(d.get('last_terminal', {}).get('candidates', {}).get('volume_removed'))" "2"
assert_receipt_field "lock plus volume mutation is delegated safety" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('status')" "delegated"
assert_receipt_field "lock plus volume mutation avoids no-mutation reason" "$STATE_DIR/receipts/tmp_scratch_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('reason')" "delegated to cleanup_tmp, cleanup_claude_state, and quota volume reclaim"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All tmp_scratch_sweep tests passed."

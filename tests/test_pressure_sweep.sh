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
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0} ACTIVE_HOURS=${LARGE_TMP_ACTIVE_HOURS:-0} ARCHIVE_HOURS=${LARGE_TMP_ARCHIVE_RETENTION_HOURS:-0}" >> "${INVOCATION_LOG:?}"
exit 0
MOCK

cat > "$MOCK_BIN/cleanup_colima.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_colima $*" >> "${INVOCATION_LOG:?}"
exit 0
MOCK

cat > "$MOCK_BIN/cleanup_code_sign_clones.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_code_sign_clones $* CODE_SIGN_CLONES_APPROVED=${CODE_SIGN_CLONES_APPROVED:-0}" >> "${INVOCATION_LOG:?}"
case "${CODESIGN_MODE:-success}" in
  fail) exit 7 ;;
  timeout) exit 124 ;;
esac
exit 0
MOCK

chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_colima.sh" "$MOCK_BIN/cleanup_code_sign_clones.sh"
cp "$REPO_ROOT/scripts/job_receipt.py" "$MOCK_BIN/job_receipt.py"
chmod +x "$MOCK_BIN/job_receipt.py"
sed "s|\"/private/tmp\"|\"$TMP_ROOT/private/tmp\"|g" "$SOURCE_SCRIPT" > "$MOCK_BIN/pressure_sweep.sh"
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
    CODESIGN_MODE="${CODESIGN_MODE:-success}" \
    INVOCATION_LOG="$INVOCATION_LOG" \
    /bin/bash "$SCRIPT" "$@"
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

echo "Test 1: no-op when free >= threshold"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
run_pressure 50
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs no-op line" "free 50 GB >= threshold" "$LOG_CONTENT"
assert_not_contains "skips cleanup_tmp" "cleanup_tmp" "$INVOCATIONS"
assert_receipt_field "Test 1 receipt skipped_threshold" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "skipped_threshold"
assert_receipt_field "Test 1 last_skipped populated" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_skipped', {}).get('outcome')" "skipped_threshold"

echo "Test 2: triggered clean path passes --large, LARGE_TMP_APPROVED=1, and 4h pressure retention"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 8
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs triggered sweep" "sweep triggered (dry_run=false)" "$LOG_CONTENT"
assert_contains "cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1 ACTIVE_HOURS=4 ARCHIVE_HOURS=4" "$INVOCATIONS"
assert_contains "cleanup_colima --clean" "cleanup_colima --clean" "$INVOCATIONS"
assert_contains "cleanup_code_sign_clones --clean" "cleanup_code_sign_clones --clean CODE_SIGN_CLONES_APPROVED=1" "$INVOCATIONS"
assert_receipt_field "Test 2 receipt outcome success" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "success"
assert_receipt_field "Test 2 receipt freed_bytes null" "$STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('postcondition', {}).get('freed_bytes'))" "None"
assert_receipt_field "Test 2 safety delegated" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('status')" "delegated"

echo "Test 2b: custom pressure retention overrides are passed to cleanup_tmp"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=8 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  DISK_MAGICIAN_PRESSURE_TMP_ACTIVE_HOURS=2 \
  DISK_MAGICIAN_PRESSURE_TMP_ARCHIVE_RETENTION_HOURS=6 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp overrides honored" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1 ACTIVE_HOURS=2 ARCHIVE_HOURS=6" "$INVOCATIONS"

echo "Test 3: dry-run passes --dry-run --large without LARGE_TMP_APPROVED but with 4h pressure retention"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 8 --dry-run
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "cleanup_tmp dry-run --large" "cleanup_tmp --dry-run --large LARGE_TMP_APPROVED=0 ACTIVE_HOURS=4 ARCHIVE_HOURS=4" "$INVOCATIONS"
assert_contains "cleanup_colima dry-run" "cleanup_colima --dry-run" "$INVOCATIONS"
assert_contains "cleanup_code_sign_clones dry-run" "cleanup_code_sign_clones --dry-run CODE_SIGN_CLONES_APPROVED=0" "$INVOCATIONS"
assert_receipt_field "Test 3 receipt outcome success_noop" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "success_noop"
assert_receipt_field "Test 3 safety no_mutation" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('safety', {}).get('status')" "no_mutation"


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
  /bin/bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs colima-only trigger" "Colima 40 GB >= ceiling 35 GB — colima-only sweep triggered" "$LOG_CONTENT"
assert_contains "logs step-1 skip" "step 1/3 skipped (colima-only mode" "$LOG_CONTENT"
assert_not_contains "does not run cleanup_tmp" "cleanup_tmp" "$INVOCATIONS"
assert_contains "runs cleanup_colima" "cleanup_colima --clean" "$INVOCATIONS"
assert_contains "runs cleanup_code_sign_clones" "cleanup_code_sign_clones --clean CODE_SIGN_CLONES_APPROVED=1" "$INVOCATIONS"

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
  /bin/bash "$SCRIPT"
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
  /bin/bash "$SCRIPT"
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
  /bin/bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs tmp-only trigger" "/private/tmp 35 GB >= ceiling 30 GB — tmp-only sweep triggered" "$LOG_CONTENT"
assert_contains "logs step-2 skip" "step 2/3 skipped (tmp-only mode" "$LOG_CONTENT"
assert_contains "runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_not_contains "does not run cleanup_colima" "cleanup_colima" "$INVOCATIONS"
assert_contains "runs cleanup_code_sign_clones in tmp-only mode" "cleanup_code_sign_clones --clean CODE_SIGN_CLONES_APPROVED=1" "$INVOCATIONS"

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
  /bin/bash "$SCRIPT"
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
  /bin/bash "$SCRIPT"
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
  /bin/bash "$SCRIPT"
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "logs full-sweep trigger" "full sweep triggered" "$LOG_CONTENT"
assert_contains "runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_contains "runs cleanup_colima --clean" "cleanup_colima --clean" "$INVOCATIONS"

echo "Test 11: launchd plist template + lock TTL match the intended 30-min cadence"
PLIST_TEMPLATE="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-pressure-sweep.plist.template"
if [[ -f "$PLIST_TEMPLATE" ]]; then
  PLIST_CONTENT="$(cat "$PLIST_TEMPLATE")"
  assert_contains "StartInterval is 1800s (30min, tightened from 7200s/2h)" "<integer>1800</integer>" "$PLIST_CONTENT"
  assert_not_contains "StartInterval is no longer the old 2h value" "<integer>7200</integer>" "$PLIST_CONTENT"
else
  echo "  FAIL: plist template not found at $PLIST_TEMPLATE"
  FAIL=$(( FAIL + 1 ))
fi
# The work lock (TTL 3600s = 60min) is only acquired for an actual sweep run
# and released via EXIT trap the moment that run finishes — it must stay
# well above any single sweep's worst-case runtime (2 steps * 600s STEP_TIMEOUT)
# so a crash-reclaim window doesn't fire mid-legitimate-run, but it does NOT
# throttle idle fires or the 30-min StartInterval itself (see plist template
# comment). This assertion pins that TTL value so a future edit can't silently
# shrink it below the dual-step worst case without a test failure.
assert_contains "lock TTL is still 3600s (60min)" 'LOCK_TTL_SEC=3600' "$(cat "$SOURCE_SCRIPT")"

echo "Test 12: DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB=0 disables budget args"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=8 \
  DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "budget-gb=0 still runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_not_contains "budget-gb=0 omits --budget-gb from the invocation" " --budget-gb" "$INVOCATIONS"

echo "Test 12b: default (no DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB set) also omits --budget-gb"
# Safety-critical default: unlike --large (archive, reversible), budget
# mode does an immediate real rm -rf, so it must stay opt-in, not
# opt-out -- an unconfigured pressure sweep must behave exactly like it
# did before this feature existed.
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=8 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "unconfigured default still runs cleanup_tmp --clean --large" "cleanup_tmp --clean --large LARGE_TMP_APPROVED=1" "$INVOCATIONS"
assert_not_contains "unconfigured default omits --budget-gb (opt-in only)" " --budget-gb" "$INVOCATIONS"

echo "Test 13: custom DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB is passed through"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=8 \
  DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB=5 \
  DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_FLOOR_MINUTES=90 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "custom scratch budget passed through" "large --budget-gb 5 --budget-floor-minutes 90" "$INVOCATIONS"

echo "Test 12: triggered clean path invokes cleanup_code_sign_clones.sh with CODE_SIGN_CLONES_APPROVED=1"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 10
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "step 3 invoked" "cleanup_code_sign_clones" "$INVOCATIONS"
assert_contains "step 3 sets CODE_SIGN_CLONES_APPROVED=1" "CODE_SIGN_CLONES_APPROVED=1" "$INVOCATIONS"

echo "Test 13: dry-run path invokes cleanup_code_sign_clones.sh WITHOUT the approval env var"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
run_pressure 10 --dry-run
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "step 3 invoked in dry-run" "cleanup_code_sign_clones" "$INVOCATIONS"
assert_contains "step 3 does not set approval in dry-run" "CODE_SIGN_CLONES_APPROVED=0" "$INVOCATIONS"

echo "Test 13b: failed third stage cannot publish success"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
CODESIGN_MODE=fail run_pressure 8
assert_receipt_field "Test 13b third-stage failure outcome is error" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"
assert_receipt_field "Test 13b records STEP3_RC" "$STATE_DIR/receipts/pressure_sweep.json" "'STEP3_RC=7' in d.get('last_terminal', {}).get('reason', '')" "True"
assert_receipt_field "Test 13b delegated safety records STEP3_RC" "$STATE_DIR/receipts/pressure_sweep.json" "'STEP3_RC=7' in d.get('last_terminal', {}).get('safety', {}).get('reason', '')" "True"

echo "Test 13c: timed-out third stage cannot publish success"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
CODESIGN_MODE=timeout run_pressure 8
assert_receipt_field "Test 13c third-stage timeout outcome is timeout" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "timeout"
assert_receipt_field "Test 13c records STEP3_TIMEOUT" "$STATE_DIR/receipts/pressure_sweep.json" "'STEP3_TIMEOUT=true' in d.get('last_terminal', {}).get('reason', '')" "True"
assert_receipt_field "Test 13c delegated safety records STEP3_TIMEOUT" "$STATE_DIR/receipts/pressure_sweep.json" "'STEP3_TIMEOUT=true' in d.get('last_terminal', {}).get('safety', {}).get('reason', '')" "True"

echo "Test 14: lock contention records skipped_lock receipt"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
mkdir -p "$STATE_DIR/pressure_sweep.lock"
date -u +%s > "$STATE_DIR/pressure_sweep.lock/acquired_at"
run_pressure 8
assert_receipt_field "Test 14 skipped_lock receipt" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "skipped_lock"
rm -rf "$STATE_DIR/pressure_sweep.lock"

echo "Test 15: unreadable free space records blocked_safety receipt"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
FAKE_BIN="$TMP_ROOT/fake_bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/df" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAKE_BIN/df"
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT"
rm -rf "$FAKE_BIN"
assert_receipt_field "Test 15 blocked_safety receipt" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 15 safety reason" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('reason')" "could not read free space"

echo "Test 16: step failure records outcome error even when shell exits 0"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
chmod +x "$MOCK_BIN/cleanup_tmp.sh"
run_pressure 8
assert_receipt_field "Test 16 outcome error receipt" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "error"
cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_tmp $* LARGE_TMP_APPROVED=${LARGE_TMP_APPROVED:-0} ACTIVE_HOURS=${LARGE_TMP_ACTIVE_HOURS:-0} ARCHIVE_HOURS=${LARGE_TMP_ARCHIVE_RETENTION_HOURS:-0}" >> "${INVOCATION_LOG:?}"
exit 0
MOCK
chmod +x "$MOCK_BIN/cleanup_tmp.sh"

echo "Test 17: healthy no-op path runs cleanup_colima --trim-only when a Colima datadisk exists (bead mux)"
mkdir -p "$TMP_ROOT/home/.colima/_lima/_disks/colima"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rm -rf "$STATE_DIR/pressure_sweep.lock"
rc=0; run_pressure 50 || rc=$?
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "no-op path runs trim-only" "cleanup_colima --trim-only --clean" "$INVOCATIONS"
assert_not_contains "no-op path never runs full colima clean" "cleanup_colima --clean" "$INVOCATIONS"
assert_receipt_field "Test 17 receipt still skipped_threshold" "$STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "skipped_threshold"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 17 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 17 rc=$rc"; FAIL=$(( FAIL + 1 )); }

echo "Test 18: trim-only failure is logged and the no-op sweep still exits 0"
cat > "$MOCK_BIN/cleanup_colima.sh" <<'MOCK'
#!/bin/bash
echo "cleanup_colima $*" >> "${INVOCATION_LOG:?}"
exit 3
MOCK
chmod +x "$MOCK_BIN/cleanup_colima.sh"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
rc=0; run_pressure 50 || rc=$?
assert_contains "trim-only failure logged" "trim-only FAILED or timed out (rc=3)" "$(cat "$LOG_FILE")"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 18 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 18 rc=$rc"; FAIL=$(( FAIL + 1 )); }
rm -rf "$TMP_ROOT/home/.colima"

echo ""
cat > "$MOCK_BIN/cleanup_colima.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_colima $*" >> "${INVOCATION_LOG:?}"
exit 0
MOCK
chmod +x "$MOCK_BIN/cleanup_colima.sh"

echo "Test 19: partial numeric du output + exit 1 for tmp blocks size decision and pruning"
DU_BIN="$TMP_ROOT/fake_du_bin"
mkdir -p "$DU_BIN" "$TMP_ROOT/private/tmp" "$TMP_ROOT/home/.colima/_lima/_disks/colima"
cat > "$DU_BIN/du" <<'MOCK'
#!/bin/bash
printf '17000000\tpartial-size\n'
printf '17000000\tpartial-size\n' >> "${DU_LOG:?}"
exit 1
MOCK
chmod +x "$DU_BIN/du"
DU_LOG="$TMP_ROOT/du-tmp.log"
: > "$DU_LOG"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-tmp-du-fail"
rc=0
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="$DU_BIN:/usr/bin:/bin" \
  DU_LOG="$DU_LOG" \
  DISK_MAGICIAN_STATE_DIR="$FAIL_STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_PRESSURE_THRESHOLD_GB=0 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE=0 \
  DISK_MAGICIAN_TMP_GB_OVERRIDE="" \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT" --threshold-gb 0 || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 19 numeric partial du row emitted" "17000000" "$(cat "$DU_LOG")"
assert_contains "Test 19 failed tmp measurement logged" "size measurement failed or timed out for $TMP_ROOT/private/tmp (du rc=1)" "$LOG_CONTENT"
assert_contains "Test 19 no prune or scratch eviction claimed" "no pruning or scratch eviction attempted; independent guarded trim-only may still run" "$LOG_CONTENT"
assert_contains "Test 19 only guarded trim-only invoked" "cleanup_colima --trim-only --clean" "$INVOCATIONS"
assert_not_contains "Test 19 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
assert_not_contains "Test 19 no full Colima cleanup invoked" "cleanup_colima --clean" "$INVOCATIONS"
assert_not_contains "Test 19 no code-sign cleanup invoked" "cleanup_code_sign_clones" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 19 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 19 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 19 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 19 receipt nulls failed tmp metric" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('precondition', {}).get('tmp_gb'))" "None"
assert_receipt_field "Test 19 receipt does not claim delegated false" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('safety', {}).get('delegated'))" "None"


echo "Test 20: partial numeric du output + exit 1 for Colima blocks size decision and pruning"
DU_LOG="$TMP_ROOT/du-colima.log"
: > "$DU_LOG"
: > "$INVOCATION_LOG"
: > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-colima-du-fail"
rc=0
env -i \
  HOME="$TMP_ROOT/home" \
  PATH="$DU_BIN:/usr/bin:/bin" \
  DU_LOG="$DU_LOG" \
  DISK_MAGICIAN_STATE_DIR="$FAIL_STATE_DIR" \
  DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50 \
  DISK_MAGICIAN_PRESSURE_THRESHOLD_GB=0 \
  DISK_MAGICIAN_COLIMA_GB_OVERRIDE="" \
  DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
  INVOCATION_LOG="$INVOCATION_LOG" \
  /bin/bash "$SCRIPT" --threshold-gb 0 || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"
INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 20 numeric partial du row emitted" "17000000" "$(cat "$DU_LOG")"
assert_contains "Test 20 failed Colima measurement logged" "size measurement failed or timed out for $TMP_ROOT/home/.colima (du rc=1)" "$LOG_CONTENT"
assert_contains "Test 20 only guarded trim-only invoked" "cleanup_colima --trim-only --clean" "$INVOCATIONS"
assert_not_contains "Test 20 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
assert_not_contains "Test 20 no full Colima cleanup invoked" "cleanup_colima --clean" "$INVOCATIONS"
assert_not_contains "Test 20 no code-sign cleanup invoked" "cleanup_code_sign_clones" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 20 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 20 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 20 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 20 receipt nulls failed Colima metric" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('precondition', {}).get('colima_gb'))" "None"
assert_receipt_field "Test 20 receipt does not claim delegated false" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('safety', {}).get('delegated'))" "None"

run_raw_du_probe() {
  local state_dir="$1" path="$2" timeout_bin="${3:-}"
  local -a env_args=(
    "HOME=$TMP_ROOT/home"
    "PATH=$path"
    "DU_LOG=$DU_LOG"
    "DISK_MAGICIAN_STATE_DIR=$state_dir"
    "DISK_MAGICIAN_PRESSURE_LOG=$LOG_FILE"
    "DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=50"
    "DISK_MAGICIAN_PRESSURE_THRESHOLD_GB=0"
    "DISK_MAGICIAN_COLIMA_GB_OVERRIDE=0"
    "DISK_MAGICIAN_TMP_GB_OVERRIDE="
    "INVOCATION_LOG=$INVOCATION_LOG"
  )
  if [[ -n "$timeout_bin" ]]; then
    env_args+=("DISK_MAGICIAN_TIMEOUT_BIN=$timeout_bin")
  fi
  env -i "${env_args[@]}" /bin/bash "$SCRIPT" --threshold-gb 0
}

# Baseline fixture writes a sidecar record for proof and emits the same row on
# stdout, where command substitution captures it before observing du's status.
# The status remains the authority: numeric partial output must be discarded.

# Make successful size parsing explicit: a complete one-row du result is used,
# the threshold is evaluated normally, and the blocked receipt path is avoided.
cat > "$DU_BIN/du" <<'MOCK'
#!/bin/bash
printf '1048576\t%s\n' "$2"
printf '1048576\t%s\n' "$2" >> "${DU_LOG:?}"
MOCK
chmod +x "$DU_BIN/du"

echo "Test 21: successful bounded du output is parsed normally"
DU_LOG="$TMP_ROOT/du-success.log"
: > "$DU_LOG"; : > "$INVOCATION_LOG"; : > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-du-success"
rc=0; run_raw_du_probe "$FAIL_STATE_DIR" "$DU_BIN:/usr/bin:/bin" || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"; INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 21 du returned a complete row" "1048576" "$(cat "$DU_LOG")"
assert_contains "Test 21 successful measurement reaches ordinary no-op" "free 50 GB >= threshold 0 GB" "$LOG_CONTENT"
assert_contains "Test 21 independent trim-only remains available" "cleanup_colima --trim-only --clean" "$INVOCATIONS"
assert_not_contains "Test 21 does not report measurement failure" "size measurement failed" "$LOG_CONTENT"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 21 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 21 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 21 ordinary skipped receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "skipped_threshold"

cat > "$DU_BIN/du" <<'MOCK'
#!/bin/bash
printf 'not-a-size\tpartial\n'
printf 'not-a-size\tpartial\n' >> "${DU_LOG:?}"
MOCK
chmod +x "$DU_BIN/du"
echo "Test 22: malformed du output blocks size decision and cleanup"
DU_LOG="$TMP_ROOT/du-malformed.log"
: > "$DU_LOG"; : > "$INVOCATION_LOG"; : > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-du-malformed"
rc=0; run_raw_du_probe "$FAIL_STATE_DIR" "$DU_BIN:/usr/bin:/bin" || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"; INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 22 malformed row emitted" "not-a-size" "$(cat "$DU_LOG")"
assert_contains "Test 22 invalid output logged" "size measurement returned invalid output" "$LOG_CONTENT"
assert_not_contains "Test 22 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 22 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 22 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 22 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 22 receipt nulls malformed tmp metric" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('precondition', {}).get('tmp_gb'))" "None"

cat > "$DU_BIN/du" <<'MOCK'
#!/bin/bash
printf '17000000\tpartial-size\n17000000\tsecond-row\n'
printf '17000000\tpartial-size\n17000000\tsecond-row\n' >> "${DU_LOG:?}"
MOCK
chmod +x "$DU_BIN/du"
echo "Test 23: multiline du output blocks size decision and cleanup"
DU_LOG="$TMP_ROOT/du-multiline.log"
: > "$DU_LOG"; : > "$INVOCATION_LOG"; : > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-du-multiline"
rc=0; run_raw_du_probe "$FAIL_STATE_DIR" "$DU_BIN:/usr/bin:/bin" || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"; INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 23 multiline rows emitted" "second-row" "$(cat "$DU_LOG")"
assert_contains "Test 23 multiline output rejected" "size measurement returned invalid output" "$LOG_CONTENT"
assert_not_contains "Test 23 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 23 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 23 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 23 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"

cat > "$DU_BIN/du" <<'MOCK'
#!/bin/bash
printf '17000000\tpartial-size\n'
printf '17000000\tpartial-size\n' >> "${DU_LOG:?}"
MOCK
chmod +x "$DU_BIN/du"
echo "Test 24: unavailable bounded timeout blocks du before invocation"
DU_LOG="$TMP_ROOT/du-no-timeout.log"
: > "$DU_LOG"; : > "$INVOCATION_LOG"; : > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-du-no-timeout"
rc=0; run_raw_du_probe "$FAIL_STATE_DIR" "$DU_BIN:/usr/bin:/bin" "$TMP_ROOT/missing-timeout" || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"; INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 24 missing timeout is explicit" "bounded timeout unavailable; size measurement blocked" "$LOG_CONTENT"
assert_not_contains "Test 24 du was never invoked" "17000000" "$(cat "$DU_LOG")"
assert_not_contains "Test 24 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 24 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 24 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 24 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 24 receipt nulls unavailable-timeout tmp metric" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('precondition', {}).get('tmp_gb'))" "None"

TIMEOUT_BIN="$TMP_ROOT/fake_timeout_bin"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/timeout" <<'MOCK'
#!/bin/bash
printf '17000000\tpartial-size\n'
printf '17000000\tpartial-size\n' >> "${DU_LOG:?}"
exit 124
MOCK
chmod +x "$TIMEOUT_BIN/timeout"
echo "Test 25: timeout status with numeric partial stdout blocks size decision"
DU_LOG="$TMP_ROOT/du-timeout.log"
: > "$DU_LOG"; : > "$INVOCATION_LOG"; : > "$LOG_FILE"
FAIL_STATE_DIR="$TMP_ROOT/state-du-timeout"
rc=0; run_raw_du_probe "$FAIL_STATE_DIR" "$TIMEOUT_BIN:$DU_BIN:/usr/bin:/bin" || rc=$?
LOG_CONTENT="$(cat "$LOG_FILE")"; INVOCATIONS="$(cat "$INVOCATION_LOG")"
assert_contains "Test 25 timeout partial row emitted" "17000000" "$(cat "$DU_LOG")"
assert_contains "Test 25 timeout status blocks measurement" "size measurement failed or timed out for $TMP_ROOT/private/tmp (du rc=124)" "$LOG_CONTENT"
assert_not_contains "Test 25 no scratch cleanup invoked" "cleanup_tmp" "$INVOCATIONS"
[[ $rc -eq 0 ]] && { echo "  PASS  Test 25 rc 0"; PASS=$(( PASS + 1 )); } || { echo "  FAIL  Test 25 rc=$rc"; FAIL=$(( FAIL + 1 )); }
assert_receipt_field "Test 25 blocked_safety receipt" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "d.get('last_terminal', {}).get('outcome')" "blocked_safety"
assert_receipt_field "Test 25 receipt nulls timed-out tmp metric" "$FAIL_STATE_DIR/receipts/pressure_sweep.json" "str(d.get('last_terminal', {}).get('precondition', {}).get('tmp_gb'))" "None"

echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All pressure_sweep tests passed."

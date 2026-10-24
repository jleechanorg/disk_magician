#!/usr/bin/env bash
# test_pressure_sweep_kill_escalation.sh — SIGKILL escalation for run_step_timeout
# (bead disk_magician-xt2y).
#
# Root cause this pins: scripts/scratch_lock.py makes the scratch flock fd
# inheritable (os.set_inheritable), and flock lives on the open file
# description, so the lock is released only once EVERY duplicate of that fd is
# closed. pressure_sweep.sh used to call `timeout STEP_TIMEOUT cmd` with no
# --kill-after, so a step child that traps TERM and keeps working (the
# deferred-TERM case seen on this host) survived its deadline and kept
# ~/.disk_magician_locks/scratch_cleanup.lock held; competing cleanups then
# exited 75 ("skipped, scratch lock held after waiting 20s").
#
# Three cases, each driving the real pressure_sweep.sh with a fixture
# cleanup_tmp.sh:
#   1. GREEN — STEP_KILL_AFTER>0: the TERM-deferring fixture is gone within
#      STEP_TIMEOUT + STEP_KILL_AFTER + slack (SIGKILL escalation worked) and
#      step 1 reports the KILL exit code.
#   2. RED   — STEP_KILL_AFTER=0 (byte-for-byte the pre-fix invocation): the
#      fixture is STILL alive at that same deadline and step 1 has not
#      returned. This is the failing state the fix removes; it proves case 1
#      is not passing vacuously.
#   3. Fallback — the timeout binary rejects --kill-after: capability
#      detection falls back to the plain invocation, so a step that finishes
#      in time is untouched.
#
# Set PRESSURE_SWEEP_TEST_SCRIPT to point case 1/2 at another copy of the
# script (used to demonstrate RED against a pre-fix tree).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="${PRESSURE_SWEEP_TEST_SCRIPT:-$REPO_ROOT/scripts/pressure_sweep.sh}"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "FAIL: $SOURCE_SCRIPT not found" >&2
  exit 2
fi

STEP_TIMEOUT=5
KILL_AFTER=2
# Slack covers sweep startup (receipt begin), the two fast mock steps, and
# scheduler noise on a loaded box. It is deliberately much smaller than the
# fixture's own 30s deferred-TERM handler, so a non-escalating run cannot
# accidentally look healthy.
SLACK=10

find_timeout_bin() {
  local candidate
  for candidate in \
    "$(command -v timeout 2>/dev/null || true)" \
    /opt/homebrew/bin/timeout \
    /usr/local/bin/timeout \
    "$(command -v gtimeout 2>/dev/null || true)" \
    /opt/homebrew/bin/gtimeout \
    /usr/local/bin/gtimeout; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" --kill-after=1 5 true >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TIMEOUT_BIN="$(find_timeout_bin || true)"
if [[ -z "$TIMEOUT_BIN" ]]; then
  echo "SKIP: no timeout implementation supporting --kill-after found (coreutils timeout/gtimeout)."
  exit 0
fi
echo "Using timeout binary: $TIMEOUT_BIN"

TMP_ROOT="$(mktemp -d -t pressure_sweep_kill.XXXXXX)"
SWEEP_PID=""
cleanup() {
  if [[ -n "$SWEEP_PID" ]] && kill -0 "$SWEEP_PID" 2>/dev/null; then
    kill -9 "$SWEEP_PID" 2>/dev/null || true
  fi
  if [[ -f "$TMP_ROOT/fixture.pid" ]]; then
    local pid
    pid="$(cat "$TMP_ROOT/fixture.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

MOCK_BIN="$TMP_ROOT/scripts"
STATE_DIR="$TMP_ROOT/state"
LOG_FILE="$TMP_ROOT/pressure-sweep.log"
PIDFILE="$TMP_ROOT/fixture.pid"
MARKFILE="$TMP_ROOT/fixture.mark"
mkdir -p "$MOCK_BIN" "$STATE_DIR"
cp "$SOURCE_SCRIPT" "$MOCK_BIN/pressure_sweep.sh"
cp "$REPO_ROOT/scripts/job_receipt.py" "$MOCK_BIN/job_receipt.py"
# The script derives SCRIPT_DIR from its own path and then sources $SCRIPT_DIR/lib/*.sh
# (actuator_receipt.sh today). A fixture that mirrors only the top-level script fails
# with "actuator_receipt.sh: No such file or directory" and the steps never start, so
# mirror the whole lib tree -- the same rule as PR #224: deploy ships the whole
# scripts tree, therefore fixtures follow it. Copied (not symlinked) so a test run can
# never write back into the real repository.
cp -R "$REPO_ROOT/scripts/lib" "$MOCK_BIN/lib"
chmod +x "$MOCK_BIN/pressure_sweep.sh"
SCRIPT="$MOCK_BIN/pressure_sweep.sh"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

# The fixture is the shape the bug report describes: it takes TERM, then does
# 30s more work inside the handler, so TERM alone never ends it.
install_deferred_term_fixture() {
  cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/usr/bin/env bash
echo $$ > "${FIXTURE_PIDFILE:?}"
trap 'echo "TERM received" >> "${FIXTURE_MARK:?}"; sleep 30; echo "handler finished" >> "${FIXTURE_MARK:?}"' TERM
sleep 120
MOCK
  chmod +x "$MOCK_BIN/cleanup_tmp.sh"
  cat > "$MOCK_BIN/cleanup_colima.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  cat > "$MOCK_BIN/cleanup_code_sign_clones.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/cleanup_colima.sh" "$MOCK_BIN/cleanup_code_sign_clones.sh"
}

install_fast_fixture() {
  cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK'
#!/usr/bin/env bash
echo "cleanup_tmp $*" >> "${FIXTURE_INVOCATION_LOG:?}"
exit 0
MOCK
  chmod +x "$MOCK_BIN/cleanup_tmp.sh"
}

reset_case() {
  rm -rf "$STATE_DIR" "$PIDFILE" "$MARKFILE"
  mkdir -p "$STATE_DIR"
  : > "$LOG_FILE"
}

now_s() { date +%s; }

# start_sweep <step_kill_after> [timeout_bin]
start_sweep() {
  local kill_after="$1"
  local timeout_bin="${2:-$TIMEOUT_BIN}"
  env -i \
    HOME="$TMP_ROOT/home" \
    PATH="/usr/bin:/bin" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_PRESSURE_LOG="$LOG_FILE" \
    DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=8 \
    DISK_MAGICIAN_TMP_GB_OVERRIDE=0 \
    DISK_MAGICIAN_TIMEOUT_BIN="$timeout_bin" \
    DISK_MAGICIAN_PRESSURE_STEP_TIMEOUT="$STEP_TIMEOUT" \
    DISK_MAGICIAN_PRESSURE_STEP_KILL_AFTER="$kill_after" \
    FIXTURE_PIDFILE="$PIDFILE" \
    FIXTURE_MARK="$MARKFILE" \
    FIXTURE_INVOCATION_LOG="${FIXTURE_INVOCATION_LOG:-/dev/null}" \
    /bin/bash "$SCRIPT" &
  SWEEP_PID=$!
}

wait_for_fixture() {
  local waited=0
  while [[ ! -s "$PIDFILE" ]]; do
    sleep 0.2
    waited=$(( waited + 1 ))
    (( waited < 50 )) || return 1
  done
  return 0
}

fixture_alive() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

kill_fixture() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
}

finish_sweep() {
  local rc=0
  wait "$SWEEP_PID" || rc=$?
  SWEEP_PID=""
  return 0
}

wait_for_exit_or_deadline() {
  # Prints "gone:<elapsed>" or "alive:<elapsed>" for the fixture.
  local deadline="$1"
  local start="$2"
  local elapsed
  while :; do
    if ! fixture_alive; then
      elapsed=$(( $(now_s) - start ))
      echo "gone:$elapsed"
      return 0
    fi
    elapsed=$(( $(now_s) - start ))
    if (( elapsed >= deadline )); then
      echo "alive:$elapsed"
      return 0
    fi
    sleep 0.25
  done
}

BUDGET_ESCALATED=$(( STEP_TIMEOUT + KILL_AFTER + SLACK ))
BUDGET_UNESCALATED=$(( STEP_TIMEOUT + 0 + SLACK ))

echo ""
echo "Test 1 (GREEN): SIGKILL escalation ends a TERM-deferring step child"
install_deferred_term_fixture
reset_case
FIXTURE_INVOCATION_LOG=/dev/null
start_sweep "$KILL_AFTER"
CASE_START="$(now_s)"
if ! wait_for_fixture; then
  fail "Test 1 fixture never started"
else
  OUTCOME="$(wait_for_exit_or_deadline "$BUDGET_ESCALATED" "$CASE_START")"
  STATE="${OUTCOME%%:*}"
  ELAPSED="${OUTCOME##*:}"
  if [[ "$STATE" == "gone" ]]; then
    pass "Test 1 fixture killed within budget (${ELAPSED}s <= ${BUDGET_ESCALATED}s = step_timeout ${STEP_TIMEOUT}s + kill_after ${KILL_AFTER}s + slack ${SLACK}s)"
  else
    fail "Test 1 fixture still alive at ${ELAPSED}s (> ${BUDGET_ESCALATED}s): no SIGKILL escalation"
  fi
  if grep -qF "step 1/3 cleanup_tmp.sh FAILED or timed out (rc=137)" "$LOG_FILE"; then
    pass "Test 1 step 1 reports KILL exit code (rc=137)"
  else
    fail "Test 1 step 1 did not report rc=137; log tail: $(tail -3 "$LOG_FILE" | tr '\n' '|')"
  fi
  if grep -qF "TERM received" "$MARKFILE" 2>/dev/null; then
    pass "Test 1 fixture did receive TERM first (escalation, not an early kill)"
  else
    fail "Test 1 fixture never recorded TERM"
  fi
  finish_sweep
fi

echo ""
echo "Test 2 (RED): STEP_KILL_AFTER=0 -- the pre-fix invocation -- leaves the child alive"
install_deferred_term_fixture
reset_case
FIXTURE_INVOCATION_LOG=/dev/null
start_sweep 0
CASE_START="$(now_s)"
if ! wait_for_fixture; then
  fail "Test 2 fixture never started"
else
  OUTCOME="$(wait_for_exit_or_deadline "$BUDGET_UNESCALATED" "$CASE_START")"
  STATE="${OUTCOME%%:*}"
  ELAPSED="${OUTCOME##*:}"
  if [[ "$STATE" == "alive" ]]; then
    pass "Test 2 fixture survived past ${ELAPSED}s (>= ${BUDGET_UNESCALATED}s budget): unescalated timeout does not reclaim the step child"
  else
    fail "Test 2 fixture died at ${ELAPSED}s without escalation -- Test 1 would be vacuously green"
  fi
  if grep -qF "step 1/3 cleanup_tmp.sh FAILED or timed out" "$LOG_FILE"; then
    fail "Test 2 step 1 already returned by the deadline; the unescalated run should still be blocked"
  else
    pass "Test 2 step 1 had not returned at the deadline (the deferred-TERM child was still running)"
  fi
  kill_fixture
  finish_sweep
fi

echo ""
echo "Test 3 (fallback): a timeout binary without --kill-after keeps the plain invocation"
NO_KILL_DIR="$TMP_ROOT/nokill"
mkdir -p "$NO_KILL_DIR"
REJECT_LOG="$TMP_ROOT/nokill.log"
: > "$REJECT_LOG"
cat > "$NO_KILL_DIR/timeout" <<WRAP
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    --kill-after*|-k|--kill-after)
      echo "rejected \$*" >> "$REJECT_LOG"
      exit 125
      ;;
  esac
done
exec "$TIMEOUT_BIN" "\$@"
WRAP
chmod +x "$NO_KILL_DIR/timeout"
install_fast_fixture
reset_case
FIXTURE_INVOCATION_LOG="$TMP_ROOT/invocations.log"
: > "$FIXTURE_INVOCATION_LOG"
start_sweep "$KILL_AFTER" "$NO_KILL_DIR/timeout"
finish_sweep
if grep -qF "step 1/3 cleanup_tmp.sh done" "$LOG_FILE"; then
  pass "Test 3 step 1 completed normally through the fallback invocation"
else
  fail "Test 3 step 1 did not complete normally; log tail: $(tail -3 "$LOG_FILE" | tr '\n' '|')"
fi
if grep -qF "cleanup_tmp --clean --large" "$FIXTURE_INVOCATION_LOG"; then
  pass "Test 3 the step still ran under the non-escalating timeout"
else
  fail "Test 3 the step never ran under the non-escalating timeout"
fi
REJECT_COUNT="$(grep -c "rejected" "$REJECT_LOG" 2>/dev/null || true)"
if [[ "${REJECT_COUNT:-0}" == "1" ]]; then
  pass "Test 3 --kill-after was probed once and rejected once (capability detected, not assumed)"
else
  fail "Test 3 expected exactly one --kill-after probe rejection, saw ${REJECT_COUNT:-0}: $(tr '\n' '|' < "$REJECT_LOG")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All pressure_sweep kill-escalation tests passed."

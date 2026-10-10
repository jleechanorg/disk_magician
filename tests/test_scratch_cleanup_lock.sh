#!/usr/bin/env bash
# Focused integration tests for kernel flock serialization of scratch cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_TMP_BIN="$REPO_ROOT/scripts/cleanup_tmp.sh"
CLEANUP_PR_BIN="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"
ROOT=$(mktemp -d -t test_scratch_lock.XXXXXX)
cleanup() {
  rm -f "$ROOT/pause"
  if [[ -n "${HOLDER_PID:-}" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
record() {
  if [[ "$1" == pass ]]; then PASS=$((PASS + 1)); echo "  PASS  $2";
  else FAIL=$((FAIL + 1)); echo "  FAIL  $2" >&2; fi
}
wait_for_file() {
  for _ in {1..200}; do [[ -e "$1" ]] && return 0; sleep 0.025; done
  return 1
}

# A scanner child pauses while retaining the inherited lock descriptor.
mkdir -p "$ROOT/bin"
REAL_FIND=$(command -v find)
cat > "$ROOT/bin/find" <<EOF
#!/usr/bin/env bash
if [[ -n "\${TEST_PAUSE_FILE:-}" && -f "\$TEST_PAUSE_FILE" ]]; then
  touch "\$TEST_PAUSED_FILE"
  while [[ -f "\$TEST_PAUSE_FILE" ]]; do sleep 0.025; done
fi
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$ROOT/bin/find"
export PATH="$ROOT/bin:$PATH"
export DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find"
export DISK_MAGICIAN_TEST_SANDBOX="$ROOT"
export DISK_MAGICIAN_PR_SCRATCH_ROOTS="$ROOT"
export DISK_MAGICIAN_TEST_CONTEXT=1

echo "=== scratch cleanup kernel-lock integration tests ==="

# Both real entrypoints reject the other while its find child is paused.
for holder in tmp pr; do
  CASE="$ROOT/contend_$holder"
  STATE="$CASE/state"; TMP="$CASE/tmp"
  mkdir -p "$STATE" "$TMP"
  touch "$ROOT/pause"
  if [[ "$holder" == tmp ]]; then
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP" TEST_PAUSE_FILE="$ROOT/pause" \
      TEST_PAUSED_FILE="$CASE/paused" bash "$CLEANUP_TMP_BIN" --clean >"$CASE/holder.out" 2>&1 &
    HOLDER_PID=$!
    wait_for_file "$CASE/paused" || record fail "$holder reached paused scanner"
    set +e
    DISK_MAGICIAN_STATE_DIR="$STATE" bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$TMP" >"$CASE/contender.out" 2>&1
    rc=$?
    set -e
  else
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_TMP_DIR="$TMP" DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" TEST_PAUSE_FILE="$ROOT/pause" TEST_PAUSED_FILE="$CASE/paused" \
      bash "$CLEANUP_PR_BIN" --clean --min-age-hours 0 >"$CASE/holder.out" 2>&1 &
    HOLDER_PID=$!
    wait_for_file "$CASE/paused" || record fail "$holder reached paused scanner"
    set +e
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP" bash "$CLEANUP_TMP_BIN" --clean >"$CASE/contender.out" 2>&1
    rc=$?
    set -e
  fi
  [[ $rc -eq 1 ]] && grep -q "scratch lock held" "$CASE/contender.out" && record pass "$holder blocks the other entrypoint" || record fail "$holder blocks the other entrypoint (rc=$rc)"
  rm -f "$ROOT/pause"
  wait "$HOLDER_PID" || true
  HOLDER_PID=""
done

# Dry-run ignores a lock file (including a directory at that pathname).
DRY="$ROOT/dry"; mkdir -p "$DRY/state/scratch_cleanup.lock" "$DRY/tmp"
DISK_MAGICIAN_STATE_DIR="$DRY/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$DRY/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$DRY/tmp" bash "$CLEANUP_TMP_BIN" --dry-run >"$DRY.out" 2>&1
record pass "dry-run succeeds with lock pathname occupied by directory"

# Lock open failure is before any scan and preserves a candidate.
BAD="$ROOT/bad"; mkdir -p "$BAD/state/scratch_cleanup.lock" "$BAD/tmp/candidate"
set +e
DISK_MAGICIAN_STATE_DIR="$BAD/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$BAD/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$BAD/tmp" bash "$CLEANUP_TMP_BIN" --clean >"$BAD.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 && -d "$BAD/tmp/candidate" ]] && record pass "lock open failure stops before scan" || record fail "lock open failure stops before scan (rc=$rc)"

# Kill the shell while its paused scanner child still owns the descriptor.
ORPHAN="$ROOT/orphan"; mkdir -p "$ORPHAN/state" "$ORPHAN/tmp"
touch "$ROOT/pause"
DISK_MAGICIAN_STATE_DIR="$ORPHAN/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORPHAN/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$ORPHAN/tmp" TEST_PAUSE_FILE="$ROOT/pause" \
  TEST_PAUSED_FILE="$ORPHAN/paused" bash "$CLEANUP_TMP_BIN" --clean >"$ORPHAN/holder.out" 2>&1 &
HOLDER_PID=$!
wait_for_file "$ORPHAN/paused" || record fail "orphan fixture reached paused scanner"
CHILD_PID=$(pgrep -P "$HOLDER_PID" | head -1 || true)
if [[ -z "$CHILD_PID" ]]; then
  # Re-exec means Bash may have directly spawned the find shim; locate by marker env.
  CHILD_PID=$(ps -eo pid,args | awk -v pause="$ROOT/pause" '$0 ~ /find/ && $0 ~ pause {print $1; exit}')
fi
kill -KILL "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
set +e
DISK_MAGICIAN_STATE_DIR="$ORPHAN/state" DISK_MAGICIAN_TMP_DIR="$ORPHAN/tmp" \
  DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" \
  bash "$CLEANUP_PR_BIN" --clean --min-age-hours 0 >"$ORPHAN/contender.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] && record pass "SIGKILLed shell leaves child-held lock active" || record fail "SIGKILLed shell leaves child-held lock active (rc=$rc)"
rm -f "$ROOT/pause"
if [[ -n "$CHILD_PID" ]]; then
  for _ in {1..200}; do
    [[ -e "$ORPHAN/state/scratch_cleanup.lock" ]] || break
    # The kernel releases flock when the final descriptor owner exits; a lock
    # file itself is persistent, so use a real short acquisition probe below.
    sleep 0.025
    break
  done
fi
for _ in {1..200}; do
  if DISK_MAGICIAN_STATE_DIR="$ORPHAN/state" python3 "$REPO_ROOT/scripts/lib/scratch_lock.py" run \
      --caller probe --script /bin/true --args -- >/dev/null 2>&1; then break; fi
  sleep 0.025
done
DISK_MAGICIAN_STATE_DIR="$ORPHAN/state" DISK_MAGICIAN_TMP_DIR="$ORPHAN/tmp" \
  DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" \
  bash "$CLEANUP_PR_BIN" --clean --min-age-hours 0 >"$ORPHAN/retry.out" 2>&1
record pass "contender acquires after orphan scanner exits"

# The exec wrapper must preserve the original script's exit status.
STATUS="$ROOT/status"; mkdir -p "$STATUS"
cat > "$STATUS/exit.sh" <<'EOF'
#!/usr/bin/env bash
source "$SCRATCH_LOCK_LIB"
scratch_lock_acquire exit-test
exit 37
EOF
chmod +x "$STATUS/exit.sh"
set +e
SCRATCH_LOCK_LIB="$REPO_ROOT/scripts/lib/scratch_lock.sh" DISK_MAGICIAN_STATE_DIR="$STATUS/state" \
  bash "$STATUS/exit.sh" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 37 ]] && record pass "exec wrapper propagates child exit status" || record fail "exec wrapper propagates child exit status (rc=$rc)"

echo "=== Results: $PASS pass, $FAIL fail ==="
(( FAIL == 0 ))

#!/usr/bin/env bash
# test_scratch_cleanup_lock.sh — Focused integration tests for cross-entrypoint
# scratch cleanup serialization (cleanup_tmp.sh and cleanup_pr_scratch.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLEANUP_TMP_BIN="$REPO_ROOT/scripts/cleanup_tmp.sh"
CLEANUP_PR_SCRATCH_BIN="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"

TMP_TEST_ROOT=$(mktemp -d -t test_scratch_lock.XXXXXX)
trap 'rm -rf "$TMP_TEST_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() {
  echo "  PASS  $1"
  PASS=$(( PASS + 1 ))
}

record_fail() {
  echo "  FAIL  $1" >&2
  [[ -n "${2:-}" ]] && echo "        $2" >&2
  FAIL=$(( FAIL + 1 ))
}

assert_true() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    record_pass "$name"
  else
    record_fail "$name" "command returned non-zero: $cmd"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected to contain: $needle"
  fi
}

# Create pause shim for `find` so the test can hold a real caller inside its scan
SHIM_BIN="$TMP_TEST_ROOT/bin"
mkdir -p "$SHIM_BIN"
REAL_FIND="$(command -v find)"
cat > "$SHIM_BIN/find" <<EOF
#!/usr/bin/env bash
if [[ -n "\${TEST_PAUSE_FILE:-}" && -f "\${TEST_PAUSE_FILE}" ]]; then
  touch "\${TEST_PAUSED_FILE}"
  while [[ -f "\${TEST_PAUSE_FILE}" ]]; do
    sleep 0.05
  done
fi
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM_BIN/find"

export PATH="$SHIM_BIN:$PATH"
export DISK_MAGICIAN_TEST_SANDBOX="$TMP_TEST_ROOT"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_DELETION_LOG="$TMP_TEST_ROOT/deletions.log"

echo "=== Running scratch cleanup lock integration tests ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Ordering 1 — cleanup_tmp holds, cleanup_pr_scratch contends
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: Ordering 1 — cleanup_tmp holds, cleanup_pr_scratch contends"

T1_ROOT="$TMP_TEST_ROOT/t1"
T1_STATE="$T1_ROOT/state"
T1_TMP="$T1_ROOT/tmp"
mkdir -p "$T1_STATE" "$T1_TMP"

T1_TMP_CANDIDATE="$T1_TMP/cli_validation_gemini_t1"
T1_PR_CANDIDATE="$T1_TMP/pr-stale-t1"
mkdir -p "$T1_TMP_CANDIDATE" "$T1_PR_CANDIDATE"
touch -t 202001010000 "$T1_TMP_CANDIDATE" "$T1_PR_CANDIDATE"

T1_PAUSE="$T1_ROOT/pause_tmp"
T1_PAUSED="$T1_ROOT/paused_tmp"
touch "$T1_PAUSE"

DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_TMP" \
TEST_PAUSE_FILE="$T1_PAUSE" \
TEST_PAUSED_FILE="$T1_PAUSED" \
bash "$CLEANUP_TMP_BIN" --clean >"$T1_ROOT/tmp_holder.out" 2>&1 &
T1_PID=$!

for _ in {1..100}; do
  [[ -f "$T1_PAUSED" ]] && break
  sleep 0.05
done

LOCK_DIR="$T1_STATE/scratch_cleanup.lock"
assert_true "T1: cleanup_tmp holds lock" "[[ -d '$LOCK_DIR' ]]"

# Contending caller must be rejected before scanning
T1_CONTENDER_OUT="$T1_ROOT/pr_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T1_TMP" >"$T1_CONTENDER_OUT" 2>&1
T1_RC=$?
set -e

assert_true "T1: contender rejected before scan (rc=1)" "[[ $T1_RC -eq 1 ]]"
assert_contains "T1: contender diagnostic" "scratch lock held" "$(cat "$T1_CONTENDER_OUT")"
assert_true "T1: contender candidate intact" "[[ -d '$T1_PR_CANDIDATE' ]]"

# Resume holder
rm -f "$T1_PAUSE"
wait "$T1_PID" || true

assert_true "T1: holder cleaned its candidate" "[[ ! -d '$T1_TMP_CANDIDATE' ]]"
assert_true "T1: lock released when holder exited" "[[ ! -d '$LOCK_DIR' ]]"

# Re-run contending caller: now succeeds
DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T1_TMP" >"$T1_ROOT/pr_retry.out" 2>&1

assert_true "T1: pr_scratch succeeds after lock released" "[[ ! -d '$T1_PR_CANDIDATE' ]]"
assert_true "T1: lock released after pr_scratch finished" "[[ ! -d '$LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Ordering 2 — cleanup_pr_scratch holds, cleanup_tmp contends
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: Ordering 2 — cleanup_pr_scratch holds, cleanup_tmp contends"

T2_ROOT="$TMP_TEST_ROOT/t2"
T2_STATE="$T2_ROOT/state"
T2_TMP="$T2_ROOT/tmp"
mkdir -p "$T2_STATE" "$T2_TMP"

T2_PR_CANDIDATE="$T2_TMP/pr-stale-t2"
T2_TMP_CANDIDATE="$T2_TMP/cli_validation_gemini_t2"
mkdir -p "$T2_PR_CANDIDATE" "$T2_TMP_CANDIDATE"
touch -t 202001010000 "$T2_PR_CANDIDATE" "$T2_TMP_CANDIDATE"

T2_PAUSE="$T2_ROOT/pause_pr"
T2_PAUSED="$T2_ROOT/paused_pr"
touch "$T2_PAUSE"

DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
TEST_PAUSE_FILE="$T2_PAUSE" \
TEST_PAUSED_FILE="$T2_PAUSED" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T2_TMP" >"$T2_ROOT/pr_holder.out" 2>&1 &
T2_PID=$!

for _ in {1..100}; do
  [[ -f "$T2_PAUSED" ]] && break
  sleep 0.05
done

T2_LOCK_DIR="$T2_STATE/scratch_cleanup.lock"
assert_true "T2: cleanup_pr_scratch holds lock" "[[ -d '$T2_LOCK_DIR' ]]"

# Contending caller must be rejected before scanning
T2_CONTENDER_OUT="$T2_ROOT/tmp_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T2_CONTENDER_OUT" 2>&1
T2_RC=$?
set -e

assert_true "T2: contender rejected before scan (rc=1)" "[[ $T2_RC -eq 1 ]]"
assert_contains "T2: contender diagnostic" "scratch lock held" "$(cat "$T2_CONTENDER_OUT")"
assert_true "T2: contender candidate intact" "[[ -d '$T2_TMP_CANDIDATE' ]]"

# Resume holder
rm -f "$T2_PAUSE"
wait "$T2_PID" || true

assert_true "T2: holder cleaned its candidate" "[[ ! -d '$T2_PR_CANDIDATE' ]]"
assert_true "T2: lock released when holder exited" "[[ ! -d '$T2_LOCK_DIR' ]]"

# Re-run contending caller: now succeeds
DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T2_ROOT/tmp_retry.out" 2>&1

assert_true "T2: cleanup_tmp succeeds after lock released" "[[ ! -d '$T2_TMP_CANDIDATE' ]]"
assert_true "T2: lock released after cleanup_tmp finished" "[[ ! -d '$T2_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Dry-run is lock-free and read-only
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Dry-run is lock-free and read-only"

T3_ROOT="$TMP_TEST_ROOT/t3"
T3_STATE="$T3_ROOT/state"
T3_TMP="$T3_ROOT/tmp"
mkdir -p "$T3_STATE" "$T3_TMP"

T3_TMP_CANDIDATE="$T3_TMP/cli_validation_gemini_t3"
T3_PR_CANDIDATE="$T3_TMP/pr-stale-t3"
mkdir -p "$T3_TMP_CANDIDATE" "$T3_PR_CANDIDATE"
touch -t 202001010000 "$T3_TMP_CANDIDATE" "$T3_PR_CANDIDATE"

# Pre-create foreign lock: dry-run must not fail or delete candidates
T3_LOCK_DIR="$T3_STATE/scratch_cleanup.lock"
mkdir -p "$T3_LOCK_DIR"
echo 999999 > "$T3_LOCK_DIR/pid"

DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_TMP" \
bash "$CLEANUP_TMP_BIN" --dry-run >"$T3_ROOT/tmp_dry.out" 2>&1

assert_contains "T3: cleanup_tmp dry-run previews" "DRY RUN: would remove" "$(cat "$T3_ROOT/tmp_dry.out")"
assert_true "T3: cleanup_tmp candidate intact" "[[ -d '$T3_TMP_CANDIDATE' ]]"

DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --dry-run --tmp-dir "$T3_TMP" >"$T3_ROOT/pr_dry.out" 2>&1

assert_contains "T3: cleanup_pr_scratch dry-run previews" "DRY RUN: would remove" "$(cat "$T3_ROOT/pr_dry.out")"
assert_true "T3: cleanup_pr_scratch candidate intact" "[[ -d '$T3_PR_CANDIDATE' ]]"
assert_true "T3: foreign lock preserved" "[[ -d '$T3_LOCK_DIR' ]]"

# Dry-run without lock does not create lock
rm -rf "$T3_LOCK_DIR"
DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_TMP" \
bash "$CLEANUP_TMP_BIN" --dry-run >/dev/null 2>&1

DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --dry-run --tmp-dir "$T3_TMP" >/dev/null 2>&1

assert_true "T3: dry-run does not create lock" "[[ ! -d '$T3_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Signal releases owned lock
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Signal releases owned lock"

T4_ROOT="$TMP_TEST_ROOT/t4"
T4_STATE="$T4_ROOT/state"
T4_TMP="$T4_ROOT/tmp"
mkdir -p "$T4_STATE" "$T4_TMP"

T4_PAUSE="$T4_ROOT/pause"
T4_PAUSED="$T4_ROOT/paused"
touch "$T4_PAUSE"

DISK_MAGICIAN_STATE_DIR="$T4_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T4_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T4_TMP" \
TEST_PAUSE_FILE="$T4_PAUSE" \
TEST_PAUSED_FILE="$T4_PAUSED" \
bash "$CLEANUP_TMP_BIN" --clean >/dev/null 2>&1 &
T4_PID=$!

for _ in {1..100}; do
  [[ -f "$T4_PAUSED" ]] && break
  sleep 0.05
done

T4_LOCK_DIR="$T4_STATE/scratch_cleanup.lock"
assert_true "T4: lock acquired" "[[ -d '$T4_LOCK_DIR' ]]"

kill -TERM "$T4_PID" 2>/dev/null || true
rm -f "$T4_PAUSE"
wait "$T4_PID" 2>/dev/null || true

assert_true "T4: SIGTERM cleanly releases owned lock" "[[ ! -d '$T4_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Real caller SIGKILL then stale recovery (age fixture)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Real caller SIGKILL then stale recovery (age fixture)"

T5_ROOT="$TMP_TEST_ROOT/t5"
T5_STATE="$T5_ROOT/state"
T5_TMP="$T5_ROOT/tmp"
mkdir -p "$T5_STATE" "$T5_TMP"

T5_TMP_CANDIDATE="$T5_TMP/cli_validation_gemini_t5"
T5_PR_CANDIDATE="$T5_TMP/pr-stale-t5"
mkdir -p "$T5_TMP_CANDIDATE" "$T5_PR_CANDIDATE"
touch -t 202001010000 "$T5_TMP_CANDIDATE" "$T5_PR_CANDIDATE"

T5_PAUSE="$T5_ROOT/pause_tmp"
T5_PAUSED="$T5_ROOT/paused_tmp"
touch "$T5_PAUSE"

(
  DISK_MAGICIAN_STATE_DIR="$T5_STATE" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T5_TMP" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T5_TMP" \
  TEST_PAUSE_FILE="$T5_PAUSE" \
  TEST_PAUSED_FILE="$T5_PAUSED" \
  exec bash "$CLEANUP_TMP_BIN" --clean >"$T5_ROOT/tmp_holder.out" 2>&1
) &
T5_PID=$!

for _ in {1..100}; do
  [[ -f "$T5_PAUSED" ]] && break
  sleep 0.05
done

T5_LOCK_DIR="$T5_STATE/scratch_cleanup.lock"
assert_true "T5: cleanup_tmp holds lock" "[[ -d '$T5_LOCK_DIR' ]]"

# Kill holder process with SIGKILL (cannot run EXIT trap)
disown "$T5_PID" 2>/dev/null || true
kill -9 "$T5_PID" 2>/dev/null || true
rm -f "$T5_PAUSE"
while kill -0 "$T5_PID" 2>/dev/null; do sleep 0.05; done

assert_true "T5: holder process terminated" "! kill -0 '$T5_PID' 2>/dev/null"
assert_true "T5: lock retained after holder SIGKILL" "[[ -d '$T5_LOCK_DIR' ]]"

# Contender before aging: fresh dead lock must not be recovered yet (age < TTL)
T5_CONTENDER_OUT="$T5_ROOT/pr_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T5_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T5_TMP" >"$T5_CONTENDER_OUT" 2>&1
T5_CONTENDER_RC=$?
set -e

assert_true "T5: fresh dead lock rejects contender (rc=1)" "[[ $T5_CONTENDER_RC -eq 1 ]]"
assert_contains "T5: contender diagnostic" "scratch lock held" "$(cat "$T5_CONTENDER_OUT")"
assert_true "T5: contender candidate intact before aging" "[[ -d '$T5_PR_CANDIDATE' ]]"

# Apply age fixture to mark lock stale (older than TTL)
touch -t 202001010000 "$T5_LOCK_DIR"

# Now contending caller recovers stale lock, cleans candidate, and releases lock
DISK_MAGICIAN_STATE_DIR="$T5_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T5_TMP" >"$T5_ROOT/pr_recovery.out" 2>&1

assert_true "T5: pr_scratch recovers stale lock and cleans candidate" "[[ ! -d '$T5_PR_CANDIDATE' ]]"
assert_true "T5: lock released after recovery run completes" "[[ ! -d '$T5_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Active-owner contention — running owner never overlapped even when aged
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 6: Active-owner contention — running owner never overlapped even when aged"

T6_ROOT="$TMP_TEST_ROOT/t6"
T6_STATE="$T6_ROOT/state"
T6_TMP="$T6_ROOT/tmp"
mkdir -p "$T6_STATE" "$T6_TMP"

T6_PR_CANDIDATE="$T6_TMP/pr-stale-t6"
T6_TMP_CANDIDATE="$T6_TMP/cli_validation_gemini_t6"
mkdir -p "$T6_PR_CANDIDATE" "$T6_TMP_CANDIDATE"
touch -t 202001010000 "$T6_PR_CANDIDATE" "$T6_TMP_CANDIDATE"

T6_PAUSE="$T6_ROOT/pause_pr"
T6_PAUSED="$T6_ROOT/paused_pr"
touch "$T6_PAUSE"

DISK_MAGICIAN_STATE_DIR="$T6_STATE" \
TEST_PAUSE_FILE="$T6_PAUSE" \
TEST_PAUSED_FILE="$T6_PAUSED" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T6_TMP" >"$T6_ROOT/pr_holder.out" 2>&1 &
T6_PID=$!

for _ in {1..100}; do
  [[ -f "$T6_PAUSED" ]] && break
  sleep 0.05
done

T6_LOCK_DIR="$T6_STATE/scratch_cleanup.lock"
assert_true "T6: cleanup_pr_scratch holds lock" "[[ -d '$T6_LOCK_DIR' ]]"

# Age the lock directory past TTL while the holder process is still actively running
touch -t 202001010000 "$T6_LOCK_DIR"
assert_true "T6: holder process is active" "kill -0 '$T6_PID' 2>/dev/null"

# Contender must be rejected because active owner is alive; active owner must never overlap
T6_CONTENDER_OUT="$T6_ROOT/tmp_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T6_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T6_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T6_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T6_CONTENDER_OUT" 2>&1
T6_RC=$?
set -e

assert_true "T6: contender rejected against active owner (rc=1)" "[[ $T6_RC -eq 1 ]]"
assert_contains "T6: contender diagnostic" "scratch lock held" "$(cat "$T6_CONTENDER_OUT")"
assert_true "T6: contender candidate intact" "[[ -d '$T6_TMP_CANDIDATE' ]]"
assert_true "T6: active owner lock preserved" "[[ -d '$T6_LOCK_DIR' ]]"

# Resume holder and wait for completion
rm -f "$T6_PAUSE"
wait "$T6_PID" || true

assert_true "T6: holder cleaned its candidate" "[[ ! -d '$T6_PR_CANDIDATE' ]]"
assert_true "T6: lock released when holder finished" "[[ ! -d '$T6_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Owner-marker write failure fails closed before scanning
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 7: Owner-marker write failure fails closed before scanning"

T7_ROOT="$TMP_TEST_ROOT/t7"
T7_STATE="$T7_ROOT/state"
T7_TMP="$T7_ROOT/tmp"
mkdir -p "$T7_STATE" "$T7_TMP"

T7_CANDIDATE="$T7_TMP/cli_validation_gemini_t7"
mkdir -p "$T7_CANDIDATE"
touch -t 202001010000 "$T7_CANDIDATE"

# Under umask 0222, mkdir creates the lock dir with 0555 (read-only), causing
# writing to $lock_dir/pid to fail. The helper must fail-closed, reject before scanning,
# and leave the candidate directory intact.
T7_OUT="$T7_ROOT/write_fail.out"
set +e
(
  umask 0222
  DISK_MAGICIAN_STATE_DIR="$T7_STATE" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T7_TMP" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T7_TMP" \
  bash "$CLEANUP_TMP_BIN" --clean
) >"$T7_OUT" 2>&1
T7_RC=$?
set -e

assert_true "T7: rejected before scan on write failure (rc=1)" "[[ $T7_RC -eq 1 ]]"
assert_contains "T7: diagnostic logs marker write failure" "failed to write lock owner marker" "$(cat "$T7_OUT")"
assert_true "T7: candidate left intact" "[[ -d '$T7_CANDIDATE' ]]"
assert_true "T7: lock marker file not present" "[[ ! -f '$T7_STATE/scratch_cleanup.lock/pid' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Caller exit status propagation
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 8: Caller exit status propagation"

T8_ROOT="$TMP_TEST_ROOT/t8"
T8_STATE="$T8_ROOT/state"
mkdir -p "$T8_STATE"

# Test explicit nonzero exit code propagation through EXIT trap
set +e
bash -c '
  source "'"$REPO_ROOT"'/scripts/lib/scratch_lock.sh"
  DISK_MAGICIAN_STATE_DIR="'"$T8_STATE"'"
  scratch_lock_acquire "test_caller" || exit 1
  exit 42
' >/dev/null 2>&1
T8_RC=$?
set -e

assert_true "T8: exit code 42 preserved through EXIT trap" "[[ $T8_RC -eq 42 ]]"
assert_true "T8: lock released on exit 42" "[[ ! -d '$T8_STATE/scratch_cleanup.lock' ]]"

# Test errexit propagation through EXIT trap
set +e
bash -c '
  set -e
  source "'"$REPO_ROOT"'/scripts/lib/scratch_lock.sh"
  DISK_MAGICIAN_STATE_DIR="'"$T8_STATE"'"
  scratch_lock_acquire "test_caller_errexit" || exit 1
  (exit 17)
' >/dev/null 2>&1
T8_ERREXIT_RC=$?
set -e

assert_true "T8: errexit status 17 preserved through EXIT trap" "[[ $T8_ERREXIT_RC -eq 17 ]]"
assert_true "T8: lock released on errexit" "[[ ! -d '$T8_STATE/scratch_cleanup.lock' ]]"

echo ""
echo "=== Test Results: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
  exit 1
fi
echo "All scratch cleanup lock integration tests passed."


#!/usr/bin/env bash
# test_scratch_cleanup_lock.sh — Concurrency and mutual exclusion integration tests
# for scratch sweepers (cleanup_tmp.sh and cleanup_pr_scratch.sh).
#
# Shared Lock Invariant:
# Both cleanup_tmp.sh and cleanup_pr_scratch.sh inspect overlapping scratch roots
# (/private/tmp, /tmp, and Darwin user temp dirs) and can target identical candidates.
# They share a mutual exclusion lock to serialize destructive passes and prevent TOCTOU
# deletion/archival races. Contention must fail closed before candidate scanning.
# Dry-run (--dry-run) is strictly read-only and does not acquire or block on the lock.
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

# Create pause/barrier shim for `find` so we can hold a real script inside its
# locked critical section while a second real script contends.
SHIM_BIN="$TMP_TEST_ROOT/shim_bin"
mkdir -p "$SHIM_BIN"
REAL_FIND="$(command -v find)"
cat > "$SHIM_BIN/find" <<EOF
#!/usr/bin/env bash
if [[ -n "\${TEST_PAUSE_FILE:-}" && -f "\${TEST_PAUSE_FILE}" && -n "\${TEST_SIGNAL_FILE:-}" && ! -f "\${TEST_SIGNAL_FILE}" ]]; then
  touch "\${TEST_SIGNAL_FILE}"
  while [[ -f "\${TEST_PAUSE_FILE}" ]]; do
    sleep 0.05
  done
fi
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM_BIN/find"

# Setup standard confined environment variables
export PATH="$SHIM_BIN:$PATH"
export DISK_MAGICIAN_TEST_SANDBOX="$TMP_TEST_ROOT"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_DELETION_LOG="$TMP_TEST_ROOT/deletions.log"

echo "=== Running scratch cleanup lock concurrency integration tests ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Ordering 1 — cleanup_tmp holds lock, cleanup_pr_scratch contends
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: Ordering 1 — cleanup_tmp holds lock, cleanup_pr_scratch contends"

T1_ROOT="$TMP_TEST_ROOT/t1"
T1_STATE="$T1_ROOT/state"
T1_TMP="$T1_ROOT/tmp"
mkdir -p "$T1_STATE" "$T1_TMP"

T1_TMP_CANDIDATE="$T1_TMP/cli_validation_gemini_t1"
T1_PR_CANDIDATE="$T1_TMP/pr-stale-t1"
mkdir -p "$T1_TMP_CANDIDATE" "$T1_PR_CANDIDATE"
touch -t 202001010000 "$T1_TMP_CANDIDATE" "$T1_PR_CANDIDATE"

T1_PAUSE="$T1_ROOT/pause_tmp"
T1_SIGNAL="$T1_ROOT/signaled_tmp"
touch "$T1_PAUSE"

# Launch cleanup_tmp --clean in background to hold lock
DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_TMP" \
TEST_PAUSE_FILE="$T1_PAUSE" \
TEST_SIGNAL_FILE="$T1_SIGNAL" \
bash "$CLEANUP_TMP_BIN" --clean >"$T1_ROOT/tmp_holder.out" 2>&1 &
T1_HOLDER_PID=$!

# Wait for cleanup_tmp to acquire lock and signal hold
for _ in {1..100}; do
  [[ -f "$T1_SIGNAL" ]] && break
  sleep 0.05
done

LOCK_DIR="$T1_STATE/scratch_cleanup.lock"
assert_true "T1: cleanup_tmp holds scratch lock" "[[ -d '$LOCK_DIR' ]]"
assert_contains "T1: lock owner is cleanup_tmp" "cleanup_tmp" "$(cat "$LOCK_DIR/caller" 2>/dev/null || true)"

# Invoke cleanup_pr_scratch --clean which must contend and fail closed before scanning
T1_CONTENDER_OUT="$T1_ROOT/pr_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T1_TMP" >"$T1_CONTENDER_OUT" 2>&1
T1_CONTENDER_RC=$?
set -e

assert_contains "T1: contender logs clear lock contention diagnostic" "scratch lock held by caller 'cleanup_tmp'" "$(cat "$T1_CONTENDER_OUT")"
assert_true "T1: contender exits cleanly on skip (rc=0)" "[[ $T1_CONTENDER_RC -eq 0 ]]"
assert_true "T1: contender candidate left completely intact" "[[ -d '$T1_PR_CANDIDATE' ]]"

# Resume cleanup_tmp holder
rm -f "$T1_PAUSE"
wait "$T1_HOLDER_PID" || true

assert_true "T1: cleanup_tmp cleaned its candidate" "[[ ! -d '$T1_TMP_CANDIDATE' ]]"
assert_true "T1: lock released after holder exited" "[[ ! -d '$LOCK_DIR' ]]"

# Now run cleanup_pr_scratch again: it should acquire lock, succeed, and delete candidate
T1_SUCCESS_OUT="$T1_ROOT/pr_success.out"
DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T1_TMP" >"$T1_SUCCESS_OUT" 2>&1

assert_true "T1: pr_scratch succeeds after lock released" "[[ ! -d '$T1_PR_CANDIDATE' ]]"
assert_true "T1: lock released after pr_scratch completion" "[[ ! -d '$LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Ordering 2 — cleanup_pr_scratch holds lock, cleanup_tmp contends
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: Ordering 2 — cleanup_pr_scratch holds lock, cleanup_tmp contends"

T2_ROOT="$TMP_TEST_ROOT/t2"
T2_STATE="$T2_ROOT/state"
T2_TMP="$T2_ROOT/tmp"
mkdir -p "$T2_STATE" "$T2_TMP"

T2_PR_CANDIDATE="$T2_TMP/pr-stale-t2"
T2_TMP_CANDIDATE="$T2_TMP/cli_validation_gemini_t2"
mkdir -p "$T2_PR_CANDIDATE" "$T2_TMP_CANDIDATE"
touch -t 202001010000 "$T2_PR_CANDIDATE" "$T2_TMP_CANDIDATE"

T2_PAUSE="$T2_ROOT/pause_pr"
T2_SIGNAL="$T2_ROOT/signaled_pr"
touch "$T2_PAUSE"

# Launch cleanup_pr_scratch --clean in background to hold lock
DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
TEST_PAUSE_FILE="$T2_PAUSE" \
TEST_SIGNAL_FILE="$T2_SIGNAL" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T2_TMP" >"$T2_ROOT/pr_holder.out" 2>&1 &
T2_HOLDER_PID=$!

# Wait for cleanup_pr_scratch to acquire lock and signal hold
for _ in {1..100}; do
  [[ -f "$T2_SIGNAL" ]] && break
  sleep 0.05
done

T2_LOCK_DIR="$T2_STATE/scratch_cleanup.lock"
assert_true "T2: cleanup_pr_scratch holds scratch lock" "[[ -d '$T2_LOCK_DIR' ]]"
assert_contains "T2: lock owner is cleanup_pr_scratch" "cleanup_pr_scratch" "$(cat "$T2_LOCK_DIR/caller" 2>/dev/null || true)"

# Invoke cleanup_tmp --clean which must contend and fail closed before scanning
T2_CONTENDER_OUT="$T2_ROOT/tmp_contender.out"
set +e
DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T2_CONTENDER_OUT" 2>&1
T2_CONTENDER_RC=$?
set -e

assert_contains "T2: contender logs clear lock contention diagnostic" "scratch lock held by caller 'cleanup_pr_scratch'" "$(cat "$T2_CONTENDER_OUT")"
assert_true "T2: contender exits cleanly on skip (rc=0)" "[[ $T2_CONTENDER_RC -eq 0 ]]"
assert_true "T2: contender candidate left completely intact" "[[ -d '$T2_TMP_CANDIDATE' ]]"

# Resume cleanup_pr_scratch holder
rm -f "$T2_PAUSE"
wait "$T2_HOLDER_PID" || true

assert_true "T2: cleanup_pr_scratch cleaned its candidate" "[[ ! -d '$T2_PR_CANDIDATE' ]]"
assert_true "T2: lock released after holder exited" "[[ ! -d '$T2_LOCK_DIR' ]]"

# Now run cleanup_tmp again: it should acquire lock, succeed, and delete candidate
T2_SUCCESS_OUT="$T2_ROOT/tmp_success.out"
DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T2_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T2_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T2_SUCCESS_OUT" 2>&1

assert_true "T2: cleanup_tmp succeeds after lock released" "[[ ! -d '$T2_TMP_CANDIDATE' ]]"
assert_true "T2: lock released after cleanup_tmp completion" "[[ ! -d '$T2_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Dry-run is lock-free and strictly read-only
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Dry-run is lock-free and strictly read-only"

T3_ROOT="$TMP_TEST_ROOT/t3"
T3_STATE="$T3_ROOT/state"
T3_TMP="$T3_ROOT/tmp"
mkdir -p "$T3_STATE" "$T3_TMP"

T3_TMP_CANDIDATE="$T3_TMP/cli_validation_gemini_t3"
T3_PR_CANDIDATE="$T3_TMP/pr-stale-t3"
mkdir -p "$T3_TMP_CANDIDATE" "$T3_PR_CANDIDATE"
touch -t 202001010000 "$T3_TMP_CANDIDATE" "$T3_PR_CANDIDATE"

# Part A: Foreign lock is held: dry-run must NOT block, contend, or fail
T3_LOCK_DIR="$T3_STATE/scratch_cleanup.lock"
mkdir -p "$T3_LOCK_DIR"
echo 999999 > "$T3_LOCK_DIR/pid"
echo "foreign_process" > "$T3_LOCK_DIR/caller"
echo "foreign_token" > "$T3_LOCK_DIR/owner"

T3_TMP_OUT="$T3_ROOT/tmp_dry.out"
DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_TMP" \
bash "$CLEANUP_TMP_BIN" --dry-run >"$T3_TMP_OUT" 2>&1

assert_contains "T3: cleanup_tmp dry-run previews removal" "DRY RUN: would remove" "$(cat "$T3_TMP_OUT")"
assert_true "T3: cleanup_tmp candidate preserved in dry-run" "[[ -d '$T3_TMP_CANDIDATE' ]]"

T3_PR_OUT="$T3_ROOT/pr_dry.out"
DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --dry-run --tmp-dir "$T3_TMP" >"$T3_PR_OUT" 2>&1

assert_contains "T3: cleanup_pr_scratch dry-run previews removal" "DRY RUN: would remove" "$(cat "$T3_PR_OUT")"
assert_true "T3: cleanup_pr_scratch candidate preserved in dry-run" "[[ -d '$T3_PR_CANDIDATE' ]]"
assert_true "T3: foreign lock left intact by dry-run" "[[ -d '$T3_LOCK_DIR' && \$(cat '$T3_LOCK_DIR/caller') == 'foreign_process' ]]"

# Part B: When no lock exists, dry-run must NOT create a lock
rm -rf "$T3_LOCK_DIR"
DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_TMP" \
bash "$CLEANUP_TMP_BIN" --dry-run >/dev/null 2>&1
assert_true "T3: cleanup_tmp dry-run does not create lock dir" "[[ ! -d '$T3_LOCK_DIR' ]]"

DISK_MAGICIAN_STATE_DIR="$T3_STATE" \
bash "$CLEANUP_PR_SCRATCH_BIN" --dry-run --tmp-dir "$T3_TMP" >/dev/null 2>&1
assert_true "T3: cleanup_pr_scratch dry-run does not create lock dir" "[[ ! -d '$T3_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Signals (SIGTERM / SIGINT) release owned lock without leaking
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Signals (SIGTERM / SIGINT) release owned lock without leaking"

T4_ROOT="$TMP_TEST_ROOT/t4"
T4_STATE="$T4_ROOT/state"
T4_TMP="$T4_ROOT/tmp"
mkdir -p "$T4_STATE" "$T4_TMP"

T4_PAUSE="$T4_ROOT/pause"
T4_SIGNAL="$T4_ROOT/signal"
touch "$T4_PAUSE"

# Launch cleanup_tmp in background
DISK_MAGICIAN_STATE_DIR="$T4_STATE" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T4_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T4_TMP" \
TEST_PAUSE_FILE="$T4_PAUSE" \
TEST_SIGNAL_FILE="$T4_SIGNAL" \
bash "$CLEANUP_TMP_BIN" --clean >/dev/null 2>&1 &
T4_PID=$!

for _ in {1..100}; do
  [[ -f "$T4_SIGNAL" ]] && break
  sleep 0.05
done

T4_LOCK_DIR="$T4_STATE/scratch_cleanup.lock"
assert_true "T4: lock acquired by holder" "[[ -d '$T4_LOCK_DIR' ]]"

# Send SIGTERM
kill -TERM "$T4_PID" 2>/dev/null || true
rm -f "$T4_PAUSE"
wait "$T4_PID" 2>/dev/null || true

assert_true "T4: SIGTERM cleanly releases owned lock" "[[ ! -d '$T4_LOCK_DIR' ]]"

# Repeat for cleanup_pr_scratch with SIGINT
rm -f "$T4_SIGNAL"
touch "$T4_PAUSE"

DISK_MAGICIAN_STATE_DIR="$T4_STATE" \
TEST_PAUSE_FILE="$T4_PAUSE" \
TEST_SIGNAL_FILE="$T4_SIGNAL" \
bash "$CLEANUP_PR_SCRATCH_BIN" --clean --tmp-dir "$T4_TMP" >/dev/null 2>&1 &
T4_PR_PID=$!

for _ in {1..100}; do
  [[ -f "$T4_SIGNAL" ]] && break
  sleep 0.05
done

assert_true "T4: lock acquired by pr_scratch holder" "[[ -d '$T4_LOCK_DIR' ]]"

# Send SIGINT
kill -INT "$T4_PR_PID" 2>/dev/null || true
rm -f "$T4_PAUSE"
wait "$T4_PR_PID" 2>/dev/null || true

assert_true "T4: SIGINT cleanly releases owned lock" "[[ ! -d '$T4_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Foreign / Unowned lock is never deleted on uncertain ownership
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Foreign / Unowned lock is never deleted on uncertain ownership"

T5_ROOT="$TMP_TEST_ROOT/t5"
T5_STATE="$T5_ROOT/state"
mkdir -p "$T5_STATE"

T5_LOCK_DIR="$T5_STATE/scratch_cleanup.lock"
mkdir -p "$T5_LOCK_DIR"
echo 11111 > "$T5_LOCK_DIR/pid"
echo "other_caller" > "$T5_LOCK_DIR/caller"
echo "other_owner_token" > "$T5_LOCK_DIR/owner"

# Run scratch_lock_release from another process (with no token or different token)
bash -c '
source "'"$REPO_ROOT"'/scripts/lib/scratch_lock.sh"
SCRATCH_LOCK_DIR="'"$T5_LOCK_DIR"'"
SCRATCH_LOCK_OWNER_TOKEN="different_token"
SCRATCH_LOCK_PID="$$"
scratch_lock_release
'
assert_true "T5: foreign lock preserved when token mismatches" "[[ -d '$T5_LOCK_DIR' ]]"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: State directory unavailable fails closed before scanning
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 6: State directory unavailable fails closed before scanning"

T6_ROOT="$TMP_TEST_ROOT/t6"
T6_TMP="$T6_ROOT/tmp"
mkdir -p "$T6_TMP"

T6_CANDIDATE="$T6_TMP/cli_validation_gemini_t6"
mkdir -p "$T6_CANDIDATE"
touch -t 202001010000 "$T6_CANDIDATE"

# /dev/null/state is impossible to create as a directory
T6_ERR_OUT="$T6_ROOT/err.out"
set +e
DISK_MAGICIAN_STATE_DIR="/dev/null/impossible_state_dir" \
DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T6_TMP" \
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T6_TMP" \
bash "$CLEANUP_TMP_BIN" --clean >"$T6_ERR_OUT" 2>&1
T6_RC=$?
set -e

assert_true "T6: fails closed with nonzero exit when state dir unavailable" "[[ $T6_RC -ne 0 ]]"
assert_contains "T6: logs error message for state directory" "cannot create state directory" "$(cat "$T6_ERR_OUT")"
assert_true "T6: candidate preserved when state dir fails closed" "[[ -d '$T6_CANDIDATE' ]]"

echo ""
echo "=== Test Results: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
  exit 1
fi
echo "All scratch cleanup lock concurrency tests passed."

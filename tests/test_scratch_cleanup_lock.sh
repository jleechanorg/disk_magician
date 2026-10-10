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

echo ""
echo "=== Test Results: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
  exit 1
fi
echo "All scratch cleanup lock integration tests passed."

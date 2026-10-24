#!/usr/bin/env bash
# test_cleanup_code_sign_clones.sh — Unit & safety tests for cleanup_code_sign_clones.sh
#
# Asserts:
# 1. Defaults to dry-run mode (no files deleted).
# 2. Refuses deletion when --clean is passed without CODE_SIGN_CLONES_APPROVED=1.
# 3. Preserves a candidate that has a live open file descriptor.
# 4. Preserves candidates younger than CODE_SIGN_CLONE_MIN_AGE_SEC.
# 5. Successfully deletes stale, inactive candidate directories when approved.
# 6. Fails closed when DISK_MAGICIAN_CODE_SIGN_X_DIR is missing.
# 7. A clone dir with no live fd and no live pid is ELIGIBLE (dry-run candidate):
#    the regression that blocked 327 of 396 real clone dirs from reclaim.
# 8. A stale recorded pid is not evidence of a live handle, so it does not
#    preserve the clone.
# 9. An unverifiable probe preserves the candidate but reports `unverified`,
#    never ACTIVE.
# 10. Liveness costs one bounded lsof pass for the whole scan, not one per clone.
#
# Every assertion drives a stub `lsof` on PATH: the real one walks each clone's
# tree (`lsof +D`) and takes seconds to minutes per directory on a real host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_code_sign_clones.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_DIR=$(mktemp -d /tmp/test_code_sign_clones.XXXXXX) || exit 1
[[ "$TMP_DIR" == /tmp/test_code_sign_clones.* && -d "$TMP_DIR" && ! -L "$TMP_DIR" ]] || exit 1
export HOME="$TMP_DIR/home" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/bin"
MOCK_X_DIR="$TMP_DIR/X"
mkdir -p "$MOCK_BIN" "$MOCK_X_DIR"
MOCK_CALL_LOG="$TMP_DIR/lsof-calls.log"
: >"$MOCK_CALL_LOG"

# Stub lsof. Contract:
#   * `+D <dir>`  — C14 open-file probe: no holder (rc 1, empty streams), so an
#                   eligible candidate can be removed.
#   * `-d cwd`    — C14 live-cwd probe: a synthetic cwd outside every fixture.
#   * no path arg — the script's single global liveness enumeration
#                   (`-w -n -P -F pcn`): emit an fd record for each dir in
#                   MOCK_LIVE_FD_DIRS (live holder pid) and MOCK_STALE_FD_DIRS
#                   (pid that no longer exists).
MOCK_LSOF_PID_DIR="$TMP_DIR/lsof-pids"
mkdir -p "$MOCK_LSOF_PID_DIR"
cat > "$MOCK_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
[[ -n "${MOCK_LSOF_CALL_LOG:-}" ]] && printf '%s\n' "$*" >>"$MOCK_LSOF_CALL_LOG"
if [[ "${MOCK_LSOF_FAIL:-0}" == "1" ]]; then
  echo "lsof: simulated failure" >&2
  exit 2
fi
if [[ -n "${MOCK_LSOF_SLEEP:-}" ]]; then
  sleep "$MOCK_LSOF_SLEEP"
fi
if [[ " $* " == *" +D "* ]]; then
  exit 1
fi
if [[ " $* " == *" -d cwd "* ]]; then
  printf 'p%s\nfcwd\nn/\n' "1"
  exit 0
fi
emit() { printf 'p%s\nc%s\nf12\nn%s/Contents/MacOS/app\n' "$1" "$2" "$3"; }
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  emit "${MOCK_LIVE_PID:-1}" "${MOCK_LIVE_COMMAND:-StubApp}" "$d"
done <<<"${MOCK_LIVE_FD_DIRS:-}"
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  emit "${MOCK_STALE_PID:-999999}" "${MOCK_STALE_COMMAND:-DeadApp}" "$d"
done <<<"${MOCK_STALE_FD_DIRS:-}"
exit 0
EOF
chmod +x "$MOCK_BIN/lsof"

export CODE_SIGN_CLONE_MIN_KB=10
export PATH="$MOCK_BIN:$PATH"

OLD_STAMP=202610041200
create_candidate() {
  local dir="$1"
  mkdir -p "$dir/Contents/MacOS"
  dd if=/dev/zero of="$dir/Contents/MacOS/binary" bs=1024 count=120 2>/dev/null
}

# Age a fixture tree (files, dirs, and the clone parent) past MIN_AGE_SEC.
age_candidate() {
  local dir="$1"
  find "$dir" -exec touch -t "$OLD_STAMP" {} + 2>/dev/null
  touch -t "$OLD_STAMP" "$(dirname "$dir")" "$dir"
}

CLONE_PARENT="$MOCK_X_DIR/com.google.Chrome.code_sign_clone"
CLONE_DIR="$CLONE_PARENT/code_sign_clone.1234"
create_candidate "$CLONE_DIR"
age_candidate "$CLONE_DIR"

mock_env() {
  env DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" \
    MOCK_LSOF_CALL_LOG="$MOCK_CALL_LOG" \
    CODE_SIGN_CLONE_MIN_KB="$CODE_SIGN_CLONE_MIN_KB" "$@"
}

echo "Test 1: Default dry-run mode does not delete files"
: >"$MOCK_CALL_LOG"
OUTPUT1=$(mock_env bash "$SCRIPT" 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: dry-run deleted candidate directory" >&2
  exit 1
fi
if ! grep -q "DRY RUN" <<<"$OUTPUT1"; then
  echo "FAIL: expected DRY RUN log in output" >&2
  exit 1
fi
echo "  PASS  Test 1"

echo "Test 2: --clean without CODE_SIGN_CLONES_APPROVED=1 refuses deletion"
OUTPUT2=$(mock_env CODE_SIGN_CLONES_APPROVED=0 bash "$SCRIPT" --clean 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: --clean deleted candidate without approval" >&2
  exit 1
fi
if ! grep -q "Refusing code_sign_clone deletion" <<<"$OUTPUT2"; then
  echo "FAIL: expected refusal message" >&2
  exit 1
fi
echo "  PASS  Test 2"

echo "Test 3: Preserves candidate that has a live open file descriptor"
OUTPUT3=$(mock_env MOCK_LIVE_FD_DIRS="$CLONE_DIR" MOCK_LIVE_COMMAND=StubApp \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  bash "$SCRIPT" --clean 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: deleted candidate while a live fd was reported" >&2
  exit 1
fi
if ! grep -q "ACTIVE — preserving: $CLONE_DIR" <<<"$OUTPUT3"; then
  echo "FAIL: expected 'ACTIVE — preserving' in output" >&2
  echo "$OUTPUT3" >&2
  exit 1
fi
if ! grep -q "pid=1 command=StubApp" <<<"$OUTPUT3"; then
  echo "FAIL: expected the live holder's pid/command in the ACTIVE line" >&2
  echo "$OUTPUT3" >&2
  exit 1
fi
echo "  PASS  Test 3"

echo "Test 4: Preserves young candidate (within MIN_AGE_SEC)"
YOUNG_CLONE="$CLONE_PARENT/code_sign_clone.young"
create_candidate "$YOUNG_CLONE"
touch "$YOUNG_CLONE"
OUTPUT4=$(mock_env CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=3600 \
  bash "$SCRIPT" --dry-run 2>&1)
if [[ ! -d "$YOUNG_CLONE" ]]; then
  echo "FAIL: deleted candidate that was younger than min age" >&2
  exit 1
fi
if ! grep -q "Too young" <<<"$OUTPUT4"; then
  echo "FAIL: expected 'Too young' in output" >&2
  echo "$OUTPUT4" >&2
  exit 1
fi
echo "  PASS  Test 4"

# Remove the young clone so Test 5 cleanly operates on the stale candidate
rm -rf "$YOUNG_CLONE"
age_candidate "$CLONE_DIR"

echo "Test 5: Successfully cleans stale, inactive candidate with approval"
OUTPUT5=$(mock_env CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  bash "$SCRIPT" --clean 2>&1)
if [[ -d "$CLONE_DIR" ]]; then
  echo "FAIL: stale inactive candidate was not deleted" >&2
  echo "$OUTPUT5" >&2
  exit 1
fi
if ! grep -q "Dirs removed: 1" <<<"$OUTPUT5"; then
  echo "FAIL: expected deletion confirmation in output" >&2
  echo "$OUTPUT5" >&2
  exit 1
fi
echo "  PASS  Test 5"

echo "Test 6: Fails closed when DISK_MAGICIAN_CODE_SIGN_X_DIR is a non-existent path"
OUTPUT6=$(mock_env DISK_MAGICIAN_CODE_SIGN_X_DIR="/nonexistent/test_x_dir_12345" \
  bash "$SCRIPT" --dry-run 2>&1 || true)
if ! grep -q "ERROR: DISK_MAGICIAN_CODE_SIGN_X_DIR is not a directory" <<<"$OUTPUT6"; then
  echo "FAIL: expected error message for non-existent X dir" >&2
  echo "$OUTPUT6" >&2
  exit 1
fi
echo "  PASS  Test 6"

# ─────────────────────────────────────────────────────────────────────────────
# Regression fixtures for the bounded-liveness fix.
IDLE_PARENT="$MOCK_X_DIR/at.studio.Idle.code_sign_clone"
IDLE_DIR="$IDLE_PARENT/code_sign_clone.IDLE"
create_candidate "$IDLE_DIR"
age_candidate "$IDLE_DIR"
STALE_PARENT="$MOCK_X_DIR/com.example.StaleHolder.code_sign_clone"
STALE_DIR="$STALE_PARENT/code_sign_clone.STALE"
create_candidate "$STALE_DIR"
age_candidate "$STALE_DIR"
mkdir -p "$MOCK_X_DIR/com.tiny.code_sign_clone"
printf 'x' >"$MOCK_X_DIR/com.tiny.code_sign_clone/x"

echo "Test 7: Clone with no live fd and no live pid is ELIGIBLE (reclaim unblocked)"
OUTPUT7=$(mock_env CODE_SIGN_CLONE_MIN_AGE_SEC=60 bash "$SCRIPT" --dry-run 2>&1)
if ! grep -q "DRY RUN: INACTIVE candidate: $IDLE_DIR" <<<"$OUTPUT7"; then
  echo "FAIL: expected idle clone listed as an INACTIVE candidate" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if grep -q "ACTIVE — preserving: $IDLE_DIR" <<<"$OUTPUT7"; then
  echo "FAIL: idle clone was still reported ACTIVE" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
echo "  PASS  Test 7"

echo "Test 8: A stale recorded pid does not preserve the clone"
if ps -p 999999 >/dev/null 2>&1; then
  echo "FAIL: fixture pid 999999 exists; choose a dead pid" >&2
  exit 1
fi
OUTPUT8=$(mock_env MOCK_STALE_FD_DIRS="$STALE_DIR" MOCK_STALE_PID=999999 \
  CODE_SIGN_CLONE_MIN_AGE_SEC=60 bash "$SCRIPT" --dry-run 2>&1)
if grep -q "ACTIVE — preserving: $STALE_DIR" <<<"$OUTPUT8"; then
  echo "FAIL: dead pid still reported as ACTIVE" >&2
  echo "$OUTPUT8" >&2
  exit 1
fi
if ! grep -q "DRY RUN: INACTIVE candidate: $STALE_DIR" <<<"$OUTPUT8"; then
  echo "FAIL: expected the stale-holder clone to be an INACTIVE candidate" >&2
  echo "$OUTPUT8" >&2
  exit 1
fi
if ! grep -q "ignoring stale holders (pid gone): 999999" <<<"$OUTPUT8"; then
  echo "FAIL: expected the stale pid to be reported for diagnosis" >&2
  echo "$OUTPUT8" >&2
  exit 1
fi
echo "  PASS  Test 8"

echo "Test 9: An unverifiable probe preserves the clone but reports unverified"
OUTPUT9=$(mock_env MOCK_LSOF_SLEEP=6 CODE_SIGN_CLONE_LSOF_TIMEOUT_SEC=1 \
  CODE_SIGN_CLONE_MIN_AGE_SEC=60 bash "$SCRIPT" --dry-run 2>&1)
if [[ ! -d "$IDLE_DIR" ]]; then
  echo "FAIL: candidate deleted by an unverifiable probe" >&2
  exit 1
fi
if grep -q "ACTIVE — preserving: $IDLE_DIR" <<<"$OUTPUT9"; then
  echo "FAIL: unverifiable probe reported as ACTIVE" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
if ! grep -q "UNVERIFIED — preserving: $IDLE_DIR  (.*kept:unverified" <<<"$OUTPUT9"; then
  echo "FAIL: expected 'UNVERIFIED — preserving' with kept:unverified" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
if ! grep -Eq "unverified: [1-9]" <<<"$OUTPUT9"; then
  echo "FAIL: expected the summary line to count unverified candidates" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
if grep -q "DRY RUN: INACTIVE candidate:" <<<"$OUTPUT9"; then
  echo "FAIL: unverified candidates must not be counted as removable" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
echo "  PASS  Test 9"

echo "Test 10: One bounded lsof pass for the whole scan, not one per clone"
BULK_ROOT="$TMP_DIR/bulk"
mkdir -p "$BULK_ROOT/X"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  d="$BULK_ROOT/X/com.example.Bulk$n.code_sign_clone"
  create_candidate "$d"
  age_candidate "$d"
done
: >"$MOCK_CALL_LOG"
OUTPUT10=$(env DISK_MAGICIAN_CODE_SIGN_X_DIR="$BULK_ROOT/X" \
  MOCK_LSOF_CALL_LOG="$MOCK_CALL_LOG" CODE_SIGN_CLONE_MIN_KB=10 \
  CODE_SIGN_CLONE_MIN_AGE_SEC=60 bash "$SCRIPT" --dry-run 2>&1)
CALLS=$(wc -l <"$MOCK_CALL_LOG" | tr -d ' ')
CANDIDATES=$(grep -c "DRY RUN: INACTIVE candidate" <<<"$OUTPUT10" || true)
if [[ "$CANDIDATES" -ne 12 ]]; then
  echo "FAIL: expected 12 idle candidates, got $CANDIDATES" >&2
  echo "$OUTPUT10" >&2
  exit 1
fi
if [[ "$CALLS" -gt 3 ]]; then
  echo "FAIL: lsof ran $CALLS times for 12 clones; expected O(1) (<=3)" >&2
  cat "$MOCK_CALL_LOG" >&2
  exit 1
fi
echo "  PASS  Test 10 (lsof invocations: $CALLS for 12 clones)"

echo "ALL CHECKS PASSED: test_cleanup_code_sign_clones.sh"
exit 0

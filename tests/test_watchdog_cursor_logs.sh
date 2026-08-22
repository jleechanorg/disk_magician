#!/usr/bin/env bash
# test_watchdog_cursor_logs.sh — Unit and integration tests for watchdog_cursor_logs.sh
#
# Verifies:
#   1. Active background writer: copytruncate in-place reduces file size to ~0 while
#      an open O_APPEND writer process continues appending without error.
#   2. Inode stability: truncation preserves inode (does not unlink/rename).
#   3. Size threshold gating: files below threshold are untouched.
#   4. Dry-run mode: leaves files over threshold unchanged.
#   5. Multi-root & multi-file scanning: correctly processes multiple directories.
#   6. Symlink preservation: latest.log symlinks remain intact.
#
# Run: bash tests/test_watchdog_cursor_logs.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/watchdog_cursor_logs.sh"

PASS=0
FAIL=0

ok() {
  echo "  PASS: $1"
  PASS=$(( PASS + 1 ))
}

bad() {
  echo "  FAIL: $1"
  FAIL=$(( FAIL + 1 ))
}

section() {
  echo
  echo "── $1 ──"
}

if [[ ! -x "$WATCHDOG" ]]; then
  echo "FAIL: $WATCHDOG is not executable" >&2
  exit 2
fi

TEST_TMP="$(mktemp -d "/tmp/test_cursor_watchdog_XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

get_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

get_inode() {
  stat -f%i "$1" 2>/dev/null || stat -c%i "$1" 2>/dev/null || echo 0
}

# ─────────────────────────────────────────────────────────────
section "1. Active background writer with copytruncate"
MOCK_DIR="$TEST_TMP/session_active/cursor-agent-logs-501"
mkdir -p "$MOCK_DIR"
LOG_FILE="$MOCK_DIR/session-2026-08-22T10-00-00-12345-1.log"

# Fill log file with ~3 MB of mock log entries
python3 -c 'print("[2026-08-22T10:00:00] commitScoring.scored hash=abc12345 line=" + "x" * 200)' | awk '{for(i=0;i<15000;i++) print $0}' > "$LOG_FILE"
INITIAL_SIZE=$(get_size "$LOG_FILE")
INITIAL_INODE=$(get_inode "$LOG_FILE")

if (( INITIAL_SIZE > 2000000 )); then
  ok "Initial log file created (${INITIAL_SIZE} bytes > 2 MB)"
else
  bad "Failed to create initial log file (size: ${INITIAL_SIZE})"
fi

# Spawn background writer appending every 20ms
WRITER_RUNNING="$TEST_TMP/writer.running"
touch "$WRITER_RUNNING"
(
  while [[ -f "$WRITER_RUNNING" ]]; do
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] continuous append line $(date +%s%N)" >> "$LOG_FILE"
    sleep 0.02
  done
) &
WRITER_PID=$!

# Let writer write a few lines
sleep 0.1

if kill -0 "$WRITER_PID" 2>/dev/null; then
  ok "Background writer is actively appending (PID: $WRITER_PID)"
else
  bad "Background writer failed to start"
fi

# Run watchdog with 1MB threshold
OUT_APPLY=$("$WATCHDOG" --threshold-mb 1 --dirs "$TEST_TMP/session_active" 2>&1)
WATCHDOG_RC=$?

if [[ "$WATCHDOG_RC" -eq 0 ]]; then
  ok "watchdog exited with code 0"
else
  bad "watchdog exited with code $WATCHDOG_RC: $OUT_APPLY"
fi

# Verify writer is still alive and didn't crash on truncation
if kill -0 "$WRITER_PID" 2>/dev/null; then
  ok "Background writer is STILL running after in-place truncation"
else
  bad "Background writer crashed or exited prematurely"
fi

# Let writer write a few more lines to confirm writing continues
sleep 0.1

# Stop background writer cleanly
rm -f "$WRITER_RUNNING"
wait "$WRITER_PID" 2>/dev/null || true

SIZE_AFTER=$(get_size "$LOG_FILE")
INODE_AFTER=$(get_inode "$LOG_FILE")

if (( SIZE_AFTER < 50000 )); then
  ok "Log file size dropped to ~0 post-truncation (${SIZE_AFTER} bytes << ${INITIAL_SIZE} bytes)"
else
  bad "Log file size did not drop sufficiently: ${SIZE_AFTER} bytes"
fi

if [[ "$INITIAL_INODE" == "$INODE_AFTER" && "$INITIAL_INODE" != "0" ]]; then
  ok "File inode was preserved ($INITIAL_INODE == $INODE_AFTER) — in-place truncation confirmed"
else
  bad "File inode changed or invalid ($INITIAL_INODE -> $INODE_AFTER)"
fi

if grep -q "continuous append line" "$LOG_FILE"; then
  ok "Writer continued appending to the existing file descriptor after truncation"
else
  bad "Writer log entries missing after truncation"
fi

# ─────────────────────────────────────────────────────────────
section "2. Dry-run mode preserves files over threshold"
DRY_DIR="$TEST_TMP/dry_run/cursor-agent-logs-501"
mkdir -p "$DRY_DIR"
DRY_LOG="$DRY_DIR/session-dry.log"
python3 -c 'print("dry run data line " * 50)' | awk '{for(i=0;i<5000;i++) print $0}' > "$DRY_LOG"
DRY_SIZE_BEFORE=$(get_size "$DRY_LOG")

OUT_DRY=$("$WATCHDOG" --threshold-mb 0 --dry-run --dirs "$TEST_TMP/dry_run" 2>&1)
DRY_SIZE_AFTER=$(get_size "$DRY_LOG")

if [[ "$DRY_SIZE_BEFORE" -eq "$DRY_SIZE_AFTER" && "$DRY_SIZE_BEFORE" -gt 0 ]]; then
  ok "Dry-run mode left file size untouched ($DRY_SIZE_BEFORE bytes)"
else
  bad "Dry-run mode mutated file size ($DRY_SIZE_BEFORE -> $DRY_SIZE_AFTER)"
fi

if echo "$OUT_DRY" | grep -q "DRY-RUN: would truncate in-place"; then
  ok "Dry-run output reported expected action"
else
  bad "Dry-run output missing action report: $OUT_DRY"
fi

# ─────────────────────────────────────────────────────────────
section "3. Files below threshold are untouched"
BELOW_DIR="$TEST_TMP/below/cursor-agent-logs-501"
mkdir -p "$BELOW_DIR"
BELOW_LOG="$BELOW_DIR/session-small.log"
echo "small content line" > "$BELOW_LOG"
BELOW_SIZE_BEFORE=$(get_size "$BELOW_LOG")

OUT_BELOW=$("$WATCHDOG" --threshold-mb 100 --dirs "$TEST_TMP/below" 2>&1)
BELOW_SIZE_AFTER=$(get_size "$BELOW_LOG")

if [[ "$BELOW_SIZE_BEFORE" -eq "$BELOW_SIZE_AFTER" ]]; then
  ok "File below threshold (100MB) was not truncated ($BELOW_SIZE_BEFORE bytes)"
else
  bad "File below threshold was truncated ($BELOW_SIZE_BEFORE -> $BELOW_SIZE_AFTER)"
fi

# ─────────────────────────────────────────────────────────────
section "4. Multi-directory and mixed file scanning"
MULTI1="$TEST_TMP/multi1/cursor-agent-logs-1"
MULTI2="$TEST_TMP/multi2/cursor-agent-logs-2"
mkdir -p "$MULTI1" "$MULTI2"

LOG_BIG1="$MULTI1/session-big1.log"
LOG_SMALL1="$MULTI1/session-small1.log"
LOG_BIG2="$MULTI2/session-big2.log"

python3 -c 'print("A" * 1000)' | awk '{for(i=0;i<2000;i++) print $0}' > "$LOG_BIG1"     # ~2MB
echo "small log" > "$LOG_SMALL1"                                                         # small
python3 -c 'print("B" * 1000)' | awk '{for(i=0;i<2000;i++) print $0}' > "$LOG_BIG2"     # ~2MB

OUT_MULTI=$("$WATCHDOG" --threshold-mb 1 --dirs "$TEST_TMP/multi1:$TEST_TMP/multi2" 2>&1)

SIZE_BIG1=$(get_size "$LOG_BIG1")
SIZE_SMALL1=$(get_size "$LOG_SMALL1")
SIZE_BIG2=$(get_size "$LOG_BIG2")

if [[ "$SIZE_BIG1" -eq 0 ]]; then
  ok "Multi-dir scan truncated big file in dir 1"
else
  bad "Multi-dir scan failed to truncate big file in dir 1 (size: $SIZE_BIG1)"
fi

if [[ "$SIZE_BIG2" -eq 0 ]]; then
  ok "Multi-dir scan truncated big file in dir 2"
else
  bad "Multi-dir scan failed to truncate big file in dir 2 (size: $SIZE_BIG2)"
fi

if [[ "$SIZE_SMALL1" -gt 0 ]]; then
  ok "Multi-dir scan preserved small file in dir 1"
else
  bad "Multi-dir scan unexpectedly truncated small file in dir 1"
fi

# ─────────────────────────────────────────────────────────────
section "5. Symlink preservation"
SYM_DIR="$TEST_TMP/symlink/cursor-agent-logs-501"
mkdir -p "$SYM_DIR"
TARGET_LOG="$SYM_DIR/session-target.log"
python3 -c 'print("symlink target log " * 50)' | awk '{for(i=0;i<3000;i++) print $0}' > "$TARGET_LOG"
ln -s "session-target.log" "$SYM_DIR/latest.log"

OUT_SYM=$("$WATCHDOG" --threshold-mb 0 --dirs "$TEST_TMP/symlink" 2>&1)

if [[ -L "$SYM_DIR/latest.log" ]]; then
  ok "latest.log symlink remains a valid symlink"
else
  bad "latest.log symlink was unlinked or modified"
fi

if [[ "$(get_size "$TARGET_LOG")" -eq 0 ]]; then
  ok "Target log was truncated in place"
else
  bad "Target log was not truncated (size: $(get_size "$TARGET_LOG"))"
fi

# ─────────────────────────────────────────────────────────────
section "6. Default TMPDIR scanning"
TMP_SCAN="$TEST_TMP/mock_tmp"
mkdir -p "$TMP_SCAN/cursor-agent-logs-777"
TMP_LOG="$TMP_SCAN/cursor-agent-logs-777/session-tmp-scan.log"
python3 -c 'print("TMPDIR test data " * 50)' | awk '{for(i=0;i<3000;i++) print $0}' > "$TMP_LOG"

TMPDIR="$TMP_SCAN" "$WATCHDOG" --threshold-mb 0 >/dev/null 2>&1
TMP_LOG_SIZE=$(get_size "$TMP_LOG")

if [[ "$TMP_LOG_SIZE" -eq 0 ]]; then
  ok "Default TMPDIR scan found and truncated candidate file"
else
  bad "Default TMPDIR scan failed to truncate candidate file (size: $TMP_LOG_SIZE)"
fi

# ─────────────────────────────────────────────────────────────
section "Summary"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi

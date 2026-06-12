#!/usr/bin/env bash
# test_sweeper_health.sh — Behavioral tests for sweeper_health_check.sh
#
# Builds a self-contained mock launchd layout under a temp dir:
#   - One "fresh" sweeper (recent log write, no errors)
#   - One "stale" sweeper (log older than threshold)
#   - One "missing-log" sweeper (plist exists, log file does not)
#   - One "empty-log" sweeper (plist exists, log file is 0 bytes)
#   - One "warn" sweeper (recent log, but contains ERROR/Traceback)
#
# Then runs the script against the mock dir and asserts:
#   - exit code is 1 (some sweepers are bad)
#   - MISS lines are emitted for stale and missing-log
#   - WARN line is emitted for the warn sweeper
#   - OK count includes only the fresh sweeper
#
# Run: bash tests/test_sweeper_health.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sweeper_health_check.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_DIR=$(mktemp -d -t sweeper_health_test.XXXXXX)
LOG_DIR="$TMP_DIR/logs"
PLIST_DIR="$TMP_DIR/launchd"
mkdir -p "$LOG_DIR" "$PLIST_DIR"

# Mock helper: write a plist pointing at a synthetic log path under LOG_DIR.
write_plist() {
  local label="$1" log_path="$2"
  cat > "$PLIST_DIR/${label}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/true</string></array>
  <key>StandardOutPath</key>
  <string>${log_path}</string>
  <key>StandardErrorPath</key>
  <string>${log_path}</string>
</dict>
</plist>
EOF
}

# Mock log: write a single line with a given mtime (epoch seconds).
write_log_at() {
  local log_path="$1" epoch="$2" content="$3"
  echo "$content" > "$log_path"
  touch -t "$(date -r "$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || echo unknown)" "$log_path" 2>/dev/null \
    || touch -d "@$epoch" "$log_path" 2>/dev/null \
    || true
}

NOW=$(date +%s)
ONE_DAY=$(( 86400 ))
TEN_DAYS_AGO=$(( NOW - 10 * ONE_DAY ))
ONE_HOUR_AGO=$(( NOW - 3600 ))

# 1. Fresh sweeper: 1 hour ago, no errors.
write_plist "com.jleechan.cleanup-fresh" "$LOG_DIR/cleanup-fresh.log"
write_log_at "$LOG_DIR/cleanup-fresh.log" "$ONE_HOUR_AGO" "[$(date)] Sweep complete: 1.2G freed."

# 2. Stale sweeper: 10 days ago.
write_plist "com.jleechan.cleanup-stale" "$LOG_DIR/cleanup-stale.log"
write_log_at "$LOG_DIR/cleanup-stale.log" "$TEN_DAYS_AGO" "[$(date)] Sweep complete: 0.5G freed."

# 3. Missing log: plist present, no log file.
write_plist "com.jleechan.cleanup-missing" "$LOG_DIR/cleanup-missing.log"

# 4. Empty log: plist present, log is 0 bytes.
write_plist "com.jleechan.cleanup-empty" "$LOG_DIR/cleanup-empty.log"
: > "$LOG_DIR/cleanup-empty.log"
touch -d "@$ONE_HOUR_AGO" "$LOG_DIR/cleanup-empty.log" 2>/dev/null || \
  touch -t "$(date -r "$ONE_HOUR_AGO" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$LOG_DIR/cleanup-empty.log"

# 5. Warn sweeper: recent log, but contains ERROR.
write_plist "com.jleechan.cleanup-warn" "$LOG_DIR/cleanup-warn.log"
write_log_at "$LOG_DIR/cleanup-warn.log" "$ONE_HOUR_AGO" "[$(date)] ERROR: permission denied on /foo"

# Run the script. Threshold=7d so the 10-day-old log is stale.
set +e
OUT=$("$SCRIPT" --plist-dir "$PLIST_DIR" --threshold-days 7 --verbose 2>&1)
RC=$?
set -e

PASS=0
FAIL=0
expect() {
  local name="$1" needle="$2"
  if grep -qF "$needle" <<<"$OUT"; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name  (expected: $needle)"
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "=== sweeper_health_check.sh test ==="
echo "exit code: $RC  (expected 1)"
echo "output:"
sed 's/^/    /' <<<"$OUT"
echo

[[ $RC -eq 1 ]] && { echo "  PASS  exit code 1 on degraded sweepers"; PASS=$(( PASS + 1 )); } \
                || { echo "  FAIL  exit code was $RC, expected 1"; FAIL=$(( FAIL + 1 )); }

expect "stale sweeper flagged MISS"    "[MISS] com.jleechan.cleanup-stale"
expect "missing log flagged MISS"      "[MISS] com.jleechan.cleanup-missing"
expect "empty log flagged MISS"        "[MISS] com.jleechan.cleanup-empty"
expect "warn sweeper flagged WARN"     "[WARN] com.jleechan.cleanup-warn"
expect "fresh sweeper reported OK"     "[OK]   com.jleechan.cleanup-fresh"
expect "summary line present"          "Summary: 1 OK, 1 WARN, 3 MISS"
expect "FAIL message present"          "FAIL: 3 sweeper(s) appear silent"

# Test the happy path: all sweepers healthy → exit 0.
ALL_FRESH_DIR=$(mktemp -d -t sweeper_health_happy.XXXXXX)
mkdir -p "$ALL_FRESH_DIR/logs" "$ALL_FRESH_DIR/launchd"
write_plist "com.jleechan.cleanup-healthy-a" "$ALL_FRESH_DIR/logs/a.log"
write_plist "com.jleechan.cleanup-healthy-b" "$ALL_FRESH_DIR/logs/b.log"
write_log_at "$ALL_FRESH_DIR/logs/a.log" "$ONE_HOUR_AGO" "ok"
write_log_at "$ALL_FRESH_DIR/logs/b.log" "$ONE_HOUR_AGO" "ok"

set +e
OUT_HAPPY=$("$SCRIPT" --plist-dir "$ALL_FRESH_DIR/launchd" --threshold-days 7 2>&1)
RC_HAPPY=$?
set -e

if [[ $RC_HAPPY -eq 0 ]] && grep -q "All sweepers healthy." <<<"$OUT_HAPPY"; then
  echo "  PASS  healthy system exits 0"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  healthy system: rc=$RC_HAPPY"
  FAIL=$(( FAIL + 1 ))
fi

# Cleanup
rm -rf "$TMP_DIR" "$ALL_FRESH_DIR"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

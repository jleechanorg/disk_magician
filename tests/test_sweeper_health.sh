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

# 6. Fresh com.jleechanorg.disk-magician-* control-loop sweeper: regression
# guard for the glob-pattern bug where this family (drilldown, frontier-
# nightly, pressure-sweep, downloads-evidence, observer, tmp-scratch — the
# "org" naming) was silently invisible to the health check because the find
# pattern only matched "com.jleechan.disk-magician-*" (missing "org").
write_plist "com.jleechanorg.disk-magician-fresh" "$LOG_DIR/disk-magician-fresh.log"
write_log_at "$LOG_DIR/disk-magician-fresh.log" "$ONE_HOUR_AGO" "[$(date)] Sweep complete."

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
expect "jleechanorg family matched"    "[OK]   com.jleechanorg.disk-magician-fresh"
expect "summary line present"          "Summary: 2 OK, 1 WARN, 3 MISS"
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

# Regression test for beads disk_magician-zwb and disk_magician-dzm:
# Malformed / bare-array plists, cmux notify alerting, and auto-repair flow.
CORRUPT_TEST_DIR=$(mktemp -d -t sweeper_health_corrupt.XXXXXX)
mkdir -p "$CORRUPT_TEST_DIR/logs" "$CORRUPT_TEST_DIR/launchd"

# Invalid XML plist
cat > "$CORRUPT_TEST_DIR/launchd/com.jleechan.cleanup-badxml.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jleechan.cleanup-badxml</string>
</plist>
EOF

# Bare array plist (missing dict wrapper)
cat > "$CORRUPT_TEST_DIR/launchd/com.jleechan.cleanup-barearray.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>Label</key>
    <string>com.jleechan.cleanup-barearray</string>
  </dict>
</array>
</plist>
EOF

# Mock cmux to capture notification calls
MOCK_CMUX_DIR=$(mktemp -d -t mock_cmux.XXXXXX)
export MOCK_CMUX_LOG="$MOCK_CMUX_DIR/cmux_notify.log"
cat > "$MOCK_CMUX_DIR/cmux" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_CMUX_LOG"
exit 0
EOF
chmod +x "$MOCK_CMUX_DIR/cmux"

set +e
OUT_CORRUPT=$(PATH="$MOCK_CMUX_DIR:$PATH" "$SCRIPT" --plist-dir "$CORRUPT_TEST_DIR/launchd" 2>&1)
RC_CORRUPT=$?
set -e

[[ $RC_CORRUPT -eq 1 ]] && { echo "  PASS  corrupt plists exit 1"; PASS=$(( PASS + 1 )); } \
                        || { echo "  FAIL  corrupt plists exit rc=$RC_CORRUPT"; FAIL=$(( FAIL + 1 )); }

if grep -q "\[CORRUPT\] com.jleechan.cleanup-badxml.*fails plutil -lint" <<<"$OUT_CORRUPT"; then
  echo "  PASS  bad XML plist flagged CORRUPT (fails plutil -lint)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  bad XML plist not flagged CORRUPT"
  FAIL=$(( FAIL + 1 ))
fi

if grep -q "\[CORRUPT\] com.jleechan.cleanup-barearray.*missing top-level Label" <<<"$OUT_CORRUPT"; then
  echo "  PASS  bare array plist flagged CORRUPT (missing top-level Label)"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  bare array plist not flagged CORRUPT"
  FAIL=$(( FAIL + 1 ))
fi

# Notification assertion (disk_magician-dzm)
if [[ -f "$MOCK_CMUX_LOG" ]] && grep -q "Sweeper health degraded" "$MOCK_CMUX_LOG"; then
  echo "  PASS  cmux notify triggered on degraded sweeper"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  cmux notify was not triggered on degraded sweeper"
  FAIL=$(( FAIL + 1 ))
fi

# Auto-repair assertion (disk_magician-dzm)
MOCK_INSTALLER="$CORRUPT_TEST_DIR/mock_installer.sh"
export MOCK_INSTALLER_LOG="$CORRUPT_TEST_DIR/installer_invocations.log"
cat > "$MOCK_INSTALLER" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_INSTALLER_LOG"
exit 0
EOF
chmod +x "$MOCK_INSTALLER"

set +e
OUT_REPAIR=$(DISK_MAGICIAN_INSTALLER="$MOCK_INSTALLER" PATH="$MOCK_CMUX_DIR:$PATH" \
  "$SCRIPT" --plist-dir "$CORRUPT_TEST_DIR/launchd" --auto-repair 2>&1)
set -e

if [[ -f "$MOCK_INSTALLER_LOG" ]] && grep -q "com.jleechan.cleanup-badxml" "$MOCK_INSTALLER_LOG" && grep -q "com.jleechan.cleanup-barearray" "$MOCK_INSTALLER_LOG"; then
  echo "  PASS  auto-repair invoked installer for corrupted plists"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  auto-repair did not invoke installer for corrupted plists"
  FAIL=$(( FAIL + 1 ))
fi

# Cleanup
rm -rf "$TMP_DIR" "$ALL_FRESH_DIR" "$CORRUPT_TEST_DIR" "$MOCK_CMUX_DIR"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

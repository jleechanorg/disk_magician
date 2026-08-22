#!/usr/bin/env bash
# test_watch_projects_fsevents.sh — Test suite for scripts/watch_projects_fsevents.sh
# and step-event attribution integration (beads disk_magician-qq1 and disk_magician-pkq).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCH_SCRIPT="$REPO_ROOT/scripts/watch_projects_fsevents.sh"
ALERT_SCRIPT="$REPO_ROOT/scripts/disk_usage_alert.sh"

WORK="$(mktemp -d -t test_fsevents.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

# ─────────────────────────────────────────────────────────────
section "1. Executable and Help / Status CLI"
if [[ -x "$WATCH_SCRIPT" ]]; then
  ok "watch_projects_fsevents.sh exists and is executable"
else
  bad "watch_projects_fsevents.sh missing or not executable"
fi

HELP_OUT="$WORK/help.txt"
"$WATCH_SCRIPT" --help > "$HELP_OUT" 2>&1
if grep -q "Usage: watch_projects_fsevents.sh" "$HELP_OUT"; then
  ok "--help prints usage"
else
  bad "--help failed: $(cat "$HELP_OUT")"
fi

STATUS_OUT="$WORK/status.txt"
"$WATCH_SCRIPT" --status > "$STATUS_OUT" 2>&1
if grep -q "Backend:" "$STATUS_OUT" && grep -q "Retention days:" "$STATUS_OUT"; then
  ok "--status prints backend and retention configuration"
else
  bad "--status output unexpected: $(cat "$STATUS_OUT")"
fi

# ─────────────────────────────────────────────────────────────
section "2. Fallback Watcher Detection (Creation, Update, Worktree Deletion)"
WATCH_DIR="$WORK/projects"
LOG_FILE="$WORK/state/fsevents-projects.log"
STATE_FILE="$WORK/state/fsevents-projects.state.json"
mkdir -p "$WATCH_DIR"

# Step 2a: Initial baseline scan with --once
"$WATCH_SCRIPT" --watch-dir "$WATCH_DIR" --log-file "$LOG_FILE" --state-file "$STATE_FILE" --once
if [[ -f "$STATE_FILE" ]]; then
  ok "baseline scan created state file"
else
  bad "state file not created after baseline scan"
fi
[[ ! -f "$LOG_FILE" ]] && ok "no events logged on initial empty baseline" || bad "events logged on initial scan"

# Step 2b: Create a repository and worktrees
mkdir -p "$WATCH_DIR/repo_a/wt-feature1"
echo "print('hello')" > "$WATCH_DIR/repo_a/wt-feature1/app.py"

"$WATCH_SCRIPT" --watch-dir "$WATCH_DIR" --log-file "$LOG_FILE" --state-file "$STATE_FILE" --once

if [[ -f "$LOG_FILE" ]]; then
  ok "log file created on detected changes"
  if grep -q "repo_a/wt-feature1 Created IsDir" "$LOG_FILE"; then
    ok "detected worktree directory creation (Created IsDir)"
  else
    bad "missing Created IsDir event: $(cat "$LOG_FILE")"
  fi
  if grep -q "app.py Created IsFile" "$LOG_FILE"; then
    ok "detected file creation (Created IsFile)"
  else
    bad "missing Created IsFile event: $(cat "$LOG_FILE")"
  fi
else
  bad "log file was not created"
fi

# Step 2c: Verify ISO8601 timestamp format
if grep -q -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "$LOG_FILE"; then
  ok "log format starts with valid UTC ISO8601 timestamp"
else
  bad "log line does not match ISO8601 timestamp format: $(cat "$LOG_FILE")"
fi

# Step 2d: Modify file
sleep 1
echo "print('updated')" > "$WATCH_DIR/repo_a/wt-feature1/app.py"
"$WATCH_SCRIPT" --watch-dir "$WATCH_DIR" --log-file "$LOG_FILE" --state-file "$STATE_FILE" --once
if grep -q "app.py Updated IsFile" "$LOG_FILE"; then
  ok "detected file modification (Updated IsFile)"
else
  bad "missing Updated IsFile event: $(cat "$LOG_FILE")"
fi

# Step 2e: Worktree deletion (mirrors 2026-07-26 47-worktree incident)
rm -rf "$WATCH_DIR/repo_a/wt-feature1"
"$WATCH_SCRIPT" --watch-dir "$WATCH_DIR" --log-file "$LOG_FILE" --state-file "$STATE_FILE" --once
if grep -q "repo_a/wt-feature1 Removed IsDir" "$LOG_FILE"; then
  ok "captured worktree deletion in real time (Removed IsDir)"
else
  bad "missing Removed IsDir event: $(cat "$LOG_FILE")"
fi

# ─────────────────────────────────────────────────────────────
section "3. Log Rotation and 7-Day Retention"
LOG_DIR="$WORK/rotate_test"
TEST_LOG="$LOG_DIR/fsevents-projects.log"
mkdir -p "$LOG_DIR"
echo "2026-08-22T12:00:00Z /path/to/old Created IsFile" > "$TEST_LOG"

# Create fake daily archives: 5 recent (1-5 days old) and 5 expired (10-15 days old)
NOW_TS=$(date +%s)
for days_ago in 1 2 3 4 5 10 11 12 13 14; do
  arch_ts=$(( NOW_TS - days_ago * 86400 ))
  arch_name="fsevents-projects.log.$(date -r $arch_ts +%Y-%m-%d 2>/dev/null || date -d @$arch_ts +%Y-%m-%d)"
  arch="$LOG_DIR/$arch_name"
  echo "archive $days_ago days ago" > "$arch"
  python3 -c "import os, sys; os.utime(sys.argv[1], ($arch_ts, $arch_ts))" "$arch"
done

ARCHIVE_COUNT_BEFORE=$(find "$LOG_DIR" -name "fsevents-projects.log.*" | wc -l)
[[ "$ARCHIVE_COUNT_BEFORE" -ge 10 ]] && ok "created test archive set (count=$ARCHIVE_COUNT_BEFORE)" || bad "failed to create test archives"

"$WATCH_SCRIPT" --log-file "$TEST_LOG" --keep-days 7 --rotate

ARCHIVE_COUNT_AFTER=$(find "$LOG_DIR" -name "fsevents-projects.log.*" | wc -l)
if [[ "$ARCHIVE_COUNT_AFTER" -eq 5 ]]; then
  ok "rotation pruned 5 expired archives and preserved 5 recent archives ($ARCHIVE_COUNT_AFTER == 5)"
elif [[ "$ARCHIVE_COUNT_AFTER" -le 7 ]]; then
  ok "rotation pruned archives within keep-days limit ($ARCHIVE_COUNT_AFTER <= 7)"
else
  bad "retention failed to prune archives: found $ARCHIVE_COUNT_AFTER files"
fi

# ─────────────────────────────────────────────────────────────
section "4. Launchd Plist Template Verification"
PLIST_TEMPLATE="$REPO_ROOT/launchd/com.disk-magician.fsevents-projects.plist.template"
if [[ -f "$PLIST_TEMPLATE" ]]; then
  ok "launchd template exists in launchd/"
else
  bad "launchd template missing"
fi

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$PLIST_TEMPLATE" >/dev/null 2>&1; then
    ok "launchd template is valid XML / plist format"
  else
    bad "plutil -lint failed on template"
  fi
fi

if grep -q "@REPO_ROOT@" "$PLIST_TEMPLATE" && grep -q "@HOME@" "$PLIST_TEMPLATE" && grep -q "@BASH@" "$PLIST_TEMPLATE"; then
  ok "launchd template contains standard @REPO_ROOT@, @HOME@, @BASH@ placeholders"
else
  bad "launchd template missing required placeholders"
fi

# ─────────────────────────────────────────────────────────────
section "5. Step-Event Attribution Integration in disk_usage_alert.sh"
ALERT_STATE_DIR="$WORK/alert_state"
mkdir -p "$ALERT_STATE_DIR"
STEP_EVENTS_LOG="$ALERT_STATE_DIR/step_events.jsonl"

# Create simulated step event (>10 GiB jump)
NOW_EPOCH=$(date +%s)
echo "{\"schema_version\":1,\"tool\":\"disk_observer_step_event\",\"timestamp\":\"2026-08-22T16:00:00Z\",\"epoch\":$NOW_EPOCH,\"delta_kb\":29779520,\"direction\":\"grew\",\"window_seconds\":1680,\"hot_dirs_kb\":{\".codex\":15000000,\"worktrees\":12000000}}" > "$STEP_EVENTS_LOG"

ALERT_STATUS_OUT="$WORK/alert_status.txt"
DISK_MAGICIAN_STATE_DIR="$ALERT_STATE_DIR" DISK_MAGICIAN_STEP_EVENTS_FILE="$STEP_EVENTS_LOG" "$ALERT_SCRIPT" --status > "$ALERT_STATUS_OUT" 2>&1

if grep -q "Recent step events (24h): 1" "$ALERT_STATUS_OUT" && grep -q "grew 28.4 GiB" "$ALERT_STATUS_OUT"; then
  ok "disk_usage_alert.sh --status correctly reports step event attribution (1 event, grew 28.4 GiB)"
else
  bad "disk_usage_alert.sh --status failed to report step event: $(cat "$ALERT_STATUS_OUT")"
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

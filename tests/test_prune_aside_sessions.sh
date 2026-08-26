#!/usr/bin/env bash
# test_prune_aside_sessions.sh — End-to-end shell integration test for prune_aside_sessions.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_aside_prune_XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_ASIDE="$TEST_TMP/.aside"
MOCK_SESSIONS="$MOCK_ASIDE/u/0/sessions"
mkdir -p "$MOCK_SESSIONS"

# 1. Create stale session (>14 days old: 2026-07-20)
OLD_SID="2026-07-20_old123"
mkdir -p "$MOCK_SESSIONS/$OLD_SID/tmp"
echo '{"msg": "old"}' > "$MOCK_SESSIONS/$OLD_SID/messages.jsonl"
echo "sample png data" > "$MOCK_SESSIONS/$OLD_SID/tmp/screenshot.png"

# 2. Create recent session (recent: 2026-08-22)
RECENT_SID="2026-08-22_recent456"
mkdir -p "$MOCK_SESSIONS/$RECENT_SID"
echo '{"msg": "recent"}' > "$MOCK_SESSIONS/$RECENT_SID/messages.jsonl"

# 3. Create non-date session with old mtime
CUSTOM_OLD_SID="custom_old_session"
mkdir -p "$MOCK_SESSIONS/$CUSTOM_OLD_SID"
echo "custom data" > "$MOCK_SESSIONS/$CUSTOM_OLD_SID/data.txt"
touch -t 202607200000 "$MOCK_SESSIONS/$CUSTOM_OLD_SID/data.txt"
touch -t 202607200000 "$MOCK_SESSIONS/$CUSTOM_OLD_SID"

# Test --help
"$REPO_ROOT/scripts/prune_aside_sessions.sh" --help >/dev/null

# Test Dry Run mode
echo "Testing dry-run mode..."
OUTPUT_DRY=$("$REPO_ROOT/scripts/prune_aside_sessions.sh" --dry-run --days 14 --aside-dir "$MOCK_ASIDE")
if ! echo "$OUTPUT_DRY" | grep -q "DRY-RUN"; then
  echo "FAIL: Expected DRY-RUN in output"
  exit 1
fi
if [[ ! -d "$MOCK_SESSIONS/$OLD_SID" ]]; then
  echo "FAIL: Dry run deleted old session directory!"
  exit 1
fi
if [[ ! -d "$MOCK_SESSIONS/$RECENT_SID" ]]; then
  echo "FAIL: Dry run deleted recent session directory!"
  exit 1
fi

# Test Clean mode
echo "Testing clean mode..."
OUTPUT_CLEAN=$("$REPO_ROOT/scripts/prune_aside_sessions.sh" --clean --days 14 --aside-dir "$MOCK_ASIDE")
if ! echo "$OUTPUT_CLEAN" | grep -q "CLEAN / APPLY"; then
  echo "FAIL: Expected CLEAN / APPLY in output"
  exit 1
fi

# Verify old date-prefixed session was pruned
if [[ -d "$MOCK_SESSIONS/$OLD_SID" ]]; then
  echo "FAIL: Clean mode failed to delete stale session $OLD_SID"
  exit 1
fi

# Verify old mtime-based session was pruned
if [[ -d "$MOCK_SESSIONS/$CUSTOM_OLD_SID" ]]; then
  echo "FAIL: Clean mode failed to delete stale custom session $CUSTOM_OLD_SID"
  exit 1
fi

# Verify recent session is retained intact
if [[ ! -d "$MOCK_SESSIONS/$RECENT_SID" ]]; then
  echo "FAIL: Clean mode deleted recent session $RECENT_SID!"
  exit 1
fi
if [[ ! -f "$MOCK_SESSIONS/$RECENT_SID/messages.jsonl" ]]; then
  echo "FAIL: Clean mode modified or deleted recent session files!"
  exit 1
fi

# Test JSON output mode
OUTPUT_JSON=$("$REPO_ROOT/scripts/prune_aside_sessions.sh" --json --days 14 --aside-dir "$MOCK_ASIDE")
if ! echo "$OUTPUT_JSON" | grep -q '"sessions_scanned"'; then
  echo "FAIL: Expected JSON structure in output"
  exit 1
fi

echo "ALL SHELL INTEGRATION TESTS PASSED"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMP="$(mktemp -d "/tmp/test_brain_cleanup_XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_BRAIN="$TEST_TMP/brain"
mkdir -p "$MOCK_BRAIN"

# 1. Create old session
OLD_SID="old-session-1"
mkdir -p "$MOCK_BRAIN/$OLD_SID/.system_generated/logs"
mkdir -p "$MOCK_BRAIN/$OLD_SID/.system_generated/tasks"
mkdir -p "$MOCK_BRAIN/$OLD_SID/scratch"

python3 -c 'print("Standard command output line\n" * 100)' > "$MOCK_BRAIN/$OLD_SID/.system_generated/logs/transcript_full.jsonl"
echo "Truncated transcript..." > "$MOCK_BRAIN/$OLD_SID/.system_generated/logs/transcript.jsonl"
python3 -c 'print("Standard task log output\n" * 100)' > "$MOCK_BRAIN/$OLD_SID/.system_generated/tasks/task-1.log"
echo "Scratch dump..." > "$MOCK_BRAIN/$OLD_SID/scratch/dump.json"
echo "# Final Report" > "$MOCK_BRAIN/$OLD_SID/report.md"

# Set mtime to 20 days ago (2026-08-02)
touch -t 202608020000 "$MOCK_BRAIN/$OLD_SID"
find "$MOCK_BRAIN/$OLD_SID" -exec touch -t 202608020000 {} +

# 2. Test Dry Run mode
echo "Testing dry-run mode..."
OUTPUT_DRY=$("$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --dry-run --days 14 --brain-dir "$MOCK_BRAIN")
if ! echo "$OUTPUT_DRY" | grep -q "DRY-RUN"; then
  echo "FAIL: Expected DRY-RUN in output"
  exit 1
fi
if [[ ! -f "$MOCK_BRAIN/$OLD_SID/scratch/dump.json" ]]; then
  echo "FAIL: Dry run deleted scratch file"
  exit 1
fi

# 3. Test Clean mode
echo "Testing clean mode..."
OUTPUT_CLEAN=$("$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean --days 14 --brain-dir "$MOCK_BRAIN")
if ! echo "$OUTPUT_CLEAN" | grep -q "CLEAN"; then
  echo "FAIL: Expected CLEAN in output"
  exit 1
fi

# Verify scratch file is removed
if [[ -f "$MOCK_BRAIN/$OLD_SID/scratch/dump.json" ]]; then
  echo "FAIL: Clean mode failed to delete scratch file"
  exit 1
fi

# Verify task log is compressed
if [[ ! -f "$MOCK_BRAIN/$OLD_SID/.system_generated/tasks/task-1.log.gz" ]]; then
  echo "FAIL: Clean mode failed to compress task log"
  exit 1
fi

# Verify markdown artifact is preserved intact
if [[ ! -f "$MOCK_BRAIN/$OLD_SID/report.md" ]]; then
  echo "FAIL: Clean mode deleted markdown artifact!"
  exit 1
fi

# 4. Test default threshold (7 days) without --days flag on a 9-day-old session
echo "Testing default 7-day threshold without --days flag..."
DEFAULT_SID="default-session-9d"
mkdir -p "$MOCK_BRAIN/$DEFAULT_SID/.system_generated/tasks"
mkdir -p "$MOCK_BRAIN/$DEFAULT_SID/scratch"
python3 -c 'print("Default task log line output\n" * 100)' > "$MOCK_BRAIN/$DEFAULT_SID/.system_generated/tasks/task-1.log"
echo "Scratch data..." > "$MOCK_BRAIN/$DEFAULT_SID/scratch/dump.json"
echo "# Default Report" > "$MOCK_BRAIN/$DEFAULT_SID/report.md"

# Set mtime to 9 days ago
NINE_DAYS_AGO="$(python3 -c 'import time; t = time.localtime(time.time() - 9*86400); print(time.strftime("%Y%m%d%H%M", t))')"
touch -t "$NINE_DAYS_AGO" "$MOCK_BRAIN/$DEFAULT_SID"
find "$MOCK_BRAIN/$DEFAULT_SID" -exec touch -t "$NINE_DAYS_AGO" {} +

OUTPUT_DEF_DRY=$("$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --dry-run --brain-dir "$MOCK_BRAIN")
if ! echo "$OUTPUT_DEF_DRY" | grep -q "DRY-RUN"; then
  echo "FAIL: Expected DRY-RUN in default output"
  exit 1
fi
if [[ ! -f "$MOCK_BRAIN/$DEFAULT_SID/scratch/dump.json" ]]; then
  echo "FAIL: Dry run without --days deleted scratch file"
  exit 1
fi

OUTPUT_DEF_CLEAN=$("$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean --brain-dir "$MOCK_BRAIN")
if ! echo "$OUTPUT_DEF_CLEAN" | grep -q "CLEAN"; then
  echo "FAIL: Expected CLEAN in default output"
  exit 1
fi
if [[ -f "$MOCK_BRAIN/$DEFAULT_SID/scratch/dump.json" ]]; then
  echo "FAIL: Clean mode without --days failed to delete scratch file"
  exit 1
fi
if [[ ! -f "$MOCK_BRAIN/$DEFAULT_SID/.system_generated/tasks/task-1.log.gz" ]]; then
  echo "FAIL: Clean mode without --days failed to compress task log"
  exit 1
fi
if [[ ! -f "$MOCK_BRAIN/$DEFAULT_SID/report.md" ]]; then
  echo "FAIL: Clean mode without --days deleted markdown artifact!"
  exit 1
fi

echo "ALL BASH TESTS PASSED"

#!/usr/bin/env bash
# Verifies disk_history.sh honors DISK_SNAPSHOT_JSON when snapshot history lives
# in a backup git repo outside this source checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HISTORY_SCRIPT="$REPO_ROOT/scripts/disk_history.sh"

WORK="$(mktemp -d -t disk_history_env.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

BACKUP_REPO="$WORK/backup_repo"
SNAPSHOT="$BACKUP_REPO/backup/test-host/disk_snapshot.json"
mkdir -p "$(dirname "$SNAPSHOT")"
git -C "$WORK" init -q backup_repo
git -C "$BACKUP_REPO" config user.name "Disk History Test"
git -C "$BACKUP_REPO" config user.email "test@disk-magician.invalid"

timestamp_days_ago() {
    python3 - "$1" <<'PY'
import datetime
import sys

days = int(sys.argv[1])
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).isoformat())
PY
}

write_snapshot() {
    local value="$1"
    local timestamp="$2"
    python3 - "$SNAPSHOT" "$value" "$timestamp" <<'PY'
import json
import sys

path, value, timestamp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
snap = {
    "timestamp": timestamp.replace("+00:00", "Z"),
    "hostname": "test-host",
    "disk_total_gb": 100,
    "disk_used_gb": 50,
    "disk_free_gb": 50,
    "disk_pct": 50,
    "directories": {
        "codex_sessions": value,
    },
}
with open(path, "w") as fh:
    json.dump(snap, fh)
PY
}

commit_snapshot() {
    local value="$1"
    local days_ago="$2"
    local timestamp
    timestamp="$(timestamp_days_ago "$days_ago")"
    write_snapshot "$value" "$timestamp"
    git -C "$BACKUP_REPO" add backup/test-host/disk_snapshot.json
    GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" \
        git -C "$BACKUP_REPO" commit -q -m "snapshot $value"
}

commit_snapshot 1000 3
commit_snapshot 2000 2
commit_snapshot 3000 1

OUTPUT="$(DISK_SNAPSHOT_JSON="$SNAPSHOT" timeout 30 python3 "$HISTORY_SCRIPT" --growth-rate --growth-window 7 --limit 10 2>&1)"
echo "$OUTPUT"

grep -q "growth_rate_kb_per_day" <<<"$OUTPUT"
grep -q "codex_sessions" <<<"$OUTPUT"
grep -q "Source: git log -- backup/test-host/disk_snapshot.json" <<<"$OUTPUT"

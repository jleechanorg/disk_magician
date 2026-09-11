#!/usr/bin/env bash
# test_resolve_snapshot_json.sh — snapshot path resolver (disk_magician-qon)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/resolve_snapshot_json.sh
source "$REPO_ROOT/scripts/lib/resolve_snapshot_json.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "OK: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

section() { echo ""; echo "=== $* ==="; }

section "explicit DISK_MAGICIAN_SNAPSHOT_FILE wins"
export DISK_MAGICIAN_SNAPSHOT_FILE="$WORK/explicit.json"
got="$(resolve_snapshot_json)"
[[ "$got" == "$WORK/explicit.json" ]] && ok "explicit override" || bad "expected explicit, got $got"
unset DISK_MAGICIAN_SNAPSHOT_FILE

section "new layout preferred over legacy"
STATE_REPO="$WORK/state_repo"
mkdir -p "$STATE_REPO/snapshots"
echo '{}' > "$STATE_REPO/snapshots/disk_snapshot.json"
LEGACY_HOST="$WORK/backup_host"
mkdir -p "$LEGACY_HOST/backup/testhost"
echo '{}' > "$LEGACY_HOST/backup/testhost/disk_snapshot.json"

export DISK_MAGICIAN_STATE_REPO="$STATE_REPO"
export DISK_MAGICIAN_BACKUP_DIR="$LEGACY_HOST"
# hostname for legacy path — use testhost file we created
export HOME="$WORK/fakehome"
mkdir -p "$HOME"
# resolve_state_repo_path honors DISK_MAGICIAN_STATE_REPO
got="$(resolve_snapshot_json)"
[[ "$got" == "$STATE_REPO/snapshots/disk_snapshot.json" ]] && ok "new layout path" || bad "expected new layout, got $got"

section "legacy fallback when new layout missing"
rm -f "$STATE_REPO/snapshots/disk_snapshot.json"
rmdir "$STATE_REPO/snapshots" 2>/dev/null || true
# Fake hostname via legacy path: script uses hostname -s; create matching legacy file
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
mkdir -p "$LEGACY_HOST/backup/$HOST_SHORT"
echo '{}' > "$LEGACY_HOST/backup/$HOST_SHORT/disk_snapshot.json"
got="$(resolve_snapshot_json)"
[[ "$got" == "$LEGACY_HOST/backup/$HOST_SHORT/disk_snapshot.json" ]] && ok "legacy fallback" || bad "expected legacy, got $got"

section "disk_usage_alert --status exposes snapshot path"
ALERT_OUT="$WORK/alert_status.txt"
DISK_MAGICIAN_STATE_REPO="$STATE_REPO"
mkdir -p "$STATE_REPO/snapshots"
echo '{"timestamp":"2026-09-11T12:00:00Z","snapshot_coverage_pct":19.6}' > "$STATE_REPO/snapshots/disk_snapshot.json"
DISK_MAGICIAN_STATE_DIR="$WORK/alert_state" "$REPO_ROOT/scripts/disk_usage_alert.sh" --status > "$ALERT_OUT" 2>&1
if grep -q "Snapshot file: $STATE_REPO/snapshots/disk_snapshot.json" "$ALERT_OUT"; then
  ok "alert --status shows new-layout snapshot path"
else
  bad "alert --status missing snapshot path: $(cat "$ALERT_OUT")"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

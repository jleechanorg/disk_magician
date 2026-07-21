#!/usr/bin/env bash
# test_grandfather_live.sh — exit criterion 5: on THIS machine, prove the real
# ~/.disk_magician_backup adopts the new layout with backup/<host>/ untouched.
# GUARDED: no-op unless DM_LIVE_GRANDFATHER=1 (protects the real repo in CI).
set -uo pipefail
if [[ "${DM_LIVE_GRANDFATHER:-0}" != "1" ]]; then
  echo "SKIP: set DM_LIVE_GRANDFATHER=1 to run the live grandfather check"; exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BK="$HOME/.disk_magician_backup"
[[ -d "$BK/.git" ]] || { echo "FAIL: $BK is not a git repo"; exit 1; }
HOST="$(hostname -s)"
before="$(git -C "$BK" rev-parse HEAD)"
legacy_before="$(cat "$BK/backup/$HOST/disk_snapshot.json" 2>/dev/null | shasum | cut -d' ' -f1)"
mkdir -p "$HOME/.config/disk-magician"
printf '{"state_repo_path": "%s"}\n' "$BK" > "$HOME/.config/disk-magician/config.json"
bash "$REPO_ROOT/scripts/snapshot_commit.sh"
[[ -f "$BK/snapshots/disk_snapshot.json" ]] || { echo "FAIL: new-layout snapshot not created"; exit 1; }
legacy_after="$(cat "$BK/backup/$HOST/disk_snapshot.json" 2>/dev/null | shasum | cut -d' ' -f1)"
[[ "$legacy_before" == "$legacy_after" ]] || { echo "FAIL: legacy backup/$HOST/ changed"; exit 1; }
echo "PASS: grandfathered in place, legacy layout untouched (was $before)"

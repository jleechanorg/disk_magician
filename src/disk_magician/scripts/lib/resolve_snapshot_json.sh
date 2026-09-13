#!/usr/bin/env bash
# resolve_snapshot_json.sh — print path to the live disk_snapshot.json (new layout
# first, legacy backup/<host>/ fallback). Shared by disk_magician.sh and
# disk_usage_alert.sh (bead disk_magician-qon / disk_magician-q9x).
resolve_snapshot_json() {
  if [[ -n "${DISK_MAGICIAN_SNAPSHOT_FILE:-}" ]]; then
    printf '%s\n' "$DISK_MAGICIAN_SNAPSHOT_FILE"
    return 0
  fi
  local lib_dir scripts_dir state_dir new_layout legacy repo_root
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scripts_dir="$(cd "$lib_dir/.." && pwd)"
  repo_root="${DISK_MAGICIAN_BACKUP_DIR:-$HOME/.disk_magician_backup}"
  state_dir="$(python3 "$scripts_dir/resolve_state_repo_path.py" 2>/dev/null || true)"
  new_layout="$state_dir/snapshots/disk_snapshot.json"
  legacy="$repo_root/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
  if [[ -n "$state_dir" && -f "$new_layout" ]]; then
    printf '%s\n' "$new_layout"
  else
    printf '%s\n' "$legacy"
  fi
}

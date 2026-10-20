#!/usr/bin/env bash
# cleanup-apfs-snapshots.sh — Delete local APFS snapshots older than 1 day.
#
# macOS creates local Time Machine snapshots automatically. They are not shown
# by `du` but do consume disk space visible to APFS. Deleting them reclaims
# hidden disk space immediately.
#
# Usage:
#   ./scripts/cleanup_apfs_snapshots.sh --clean   # delete old snapshots (default: dry-run)
#   ./scripts/cleanup_apfs_snapshots.sh --dry-run # list without deleting
#
# Non-fatal: exits 0 if tmutil is unavailable or returns no snapshots.
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

  --clean     Actually delete/prune (default: dry-run preview).
  --dry-run   List snapshots that would be deleted without actually deleting.
  -h|--help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Pre-flight: tmutil must exist ─────────────────────────────────────────────

if ! command -v tmutil &>/dev/null; then
  log "tmutil not found — APFS snapshot cleanup not applicable, skipping"
  exit 0
fi

# ── List local snapshots ──────────────────────────────────────────────────────

log "Listing local APFS snapshots on / ..."

SNAPSHOT_RAW=$(tmutil listlocalsnapshots / 2>/dev/null || true)

if [[ -z "$SNAPSHOT_RAW" ]]; then
  log "No local snapshots found"
  log "=== Done ==="
  exit 0
fi

log "All current snapshots:"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  log "  $line"
done <<< "$SNAPSHOT_RAW"

# ── Parse and filter snapshots older than 1 day ───────────────────────────────
#
# Snapshot name format: com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local
# We extract the embedded timestamp, convert to epoch, and compare against
# NOW - 86400 (1 day ago).

NOW_EPOCH=$(date '+%s')
CUTOFF_EPOCH=$(( NOW_EPOCH - 86400 ))

DELETE_LIST=()

while IFS= read -r snapshot; do
  [[ -z "$snapshot" ]] && continue

  # Extract the YYYY-MM-DD-HHMMSS portion from the snapshot name.
  date_part=$(echo "$snapshot" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true)

  if [[ -z "$date_part" ]]; then
    log "  SKIP (cannot parse date): $snapshot"
    continue
  fi

  # date_part = 2024-03-15-143022
  year="${date_part:0:4}"
  month="${date_part:5:2}"
  day="${date_part:8:2}"
  hour="${date_part:11:2}"
  min="${date_part:13:2}"
  sec="${date_part:15:2}"

  # macOS date -j -f for epoch conversion
  snap_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' \
    "${year}-${month}-${day} ${hour}:${min}:${sec}" '+%s' 2>/dev/null || echo 0)

  if [[ "$snap_epoch" -eq 0 ]]; then
    log "  SKIP (date parse failed): $snapshot"
    continue
  fi

  age_seconds=$(( NOW_EPOCH - snap_epoch ))
  age_hours=$(( age_seconds / 3600 ))

  if [[ "$snap_epoch" -lt "$CUTOFF_EPOCH" ]]; then
    log "  OLD (${age_hours}h): $snapshot — queued for deletion"
    DELETE_LIST+=("$date_part")
  else
    log "  RECENT (${age_hours}h): $snapshot — keeping"
  fi
done <<< "$SNAPSHOT_RAW"

# ── Delete (or dry-run) ───────────────────────────────────────────────────────

if [[ ${#DELETE_LIST[@]} -eq 0 ]]; then
  log "No snapshots older than 1 day — nothing to delete"
else
  log "Snapshots to delete: ${#DELETE_LIST[@]}"
  DELETED_COUNT=0

  for date_str in "${DELETE_LIST[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would delete snapshot: $date_str"
    else
      log "  Deleting snapshot: $date_str"
      if tmutil deletelocalsnapshots "$date_str" 2>/dev/null; then
        log "  Deleted: $date_str"
        DELETED_COUNT=$(( DELETED_COUNT + 1 ))
      else
        log "  WARNING: deletion failed for $date_str (may have already been purged)"
      fi
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    log "Dry-run complete — ${#DELETE_LIST[@]} snapshot(s) would have been deleted"
  else
    log "Deleted $DELETED_COUNT of ${#DELETE_LIST[@]} snapshot(s)"
  fi
fi

# ── Show remaining snapshots ──────────────────────────────────────────────────

echo
log "Remaining local snapshots after cleanup:"
REMAINING=$(tmutil listlocalsnapshotdates / 2>/dev/null || true)
if [[ -z "$REMAINING" ]]; then
  log "  (none)"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "  $line"
  done <<< "$REMAINING"
fi

log "=== Done ==="

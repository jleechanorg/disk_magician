#!/usr/bin/env bash
# cleanup_apfs_snapshots.sh — Delete local APFS snapshots older than 1 day.
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

  --clean     Actually delete (default: dry-run preview).
  -h|--help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v tmutil &>/dev/null; then
  log "tmutil not found — APFS snapshot cleanup not applicable, skipping"
  exit 0
fi

log "Listing local APFS snapshots on / ..."
SNAPSHOT_RAW=$(tmutil listlocalsnapshots / 2>/dev/null || true)

if [[ -z "$SNAPSHOT_RAW" ]]; then
  log "No local snapshots found"
  exit 0
fi

log "All current snapshots:"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  log "  $line"
done <<< "$SNAPSHOT_RAW"

NOW_EPOCH=$(date '+%s')
CUTOFF_EPOCH=$(( NOW_EPOCH - 86400 ))
DELETE_LIST=()

while IFS= read -r snapshot; do
  [[ -z "$snapshot" ]] && continue

  date_part=$(echo "$snapshot" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true)
  if [[ -z "$date_part" ]]; then
    log "  SKIP (cannot parse date): $snapshot"
    continue
  fi

  year="${date_part:0:4}"
  month="${date_part:5:2}"
  day="${date_part:8:2}"
  hour="${date_part:11:2}"
  min="${date_part:13:2}"
  sec="${date_part:15:2}"

  snap_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S'     "${year}-${month}-${day} ${hour}:${min}:${sec}" '+%s' 2>/dev/null || echo 0)

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
        log "  WARNING: deletion failed for $date_str"
      fi
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    log "Dry-run complete — ${#DELETE_LIST[@]} snapshot(s) would have been deleted"
  else
    log "Deleted $DELETED_COUNT of ${#DELETE_LIST[@]} snapshot(s)"
  fi
fi

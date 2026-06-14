#!/usr/bin/env bash
# cleanup_apfs_snapshots.sh — Delete local APFS snapshots older than 1 day.
#
# Defaults to dry-run (use --clean to actually delete).
#
# Snapshot sources handled:
#   - Legacy com.apple.TimeMachine-YYYY-MM-DD-HHMMSS (has date in name)
#   - New    com.apple.os.update-<HEX or suffix>        (no date in name;
#                                                        age inferred from the
#                                                        active-mount reference
#                                                        time)
#
# Primary trigger: a non-active snapshot with LimitingContainerShrink=true
# is the "anchoring" snapshot that pins the APFS container's minimum size
# (the regrowth-prevention README Section A1 failure mode). Those are
# reaped past the retention threshold.
#
# Secondary trigger: any non-active, non-TimeMachine snapshot whose
# estimated creation time is older than the retention threshold.
#
# NEVER delete:
#   - The active mounted root snapshot (the one mounted at /)
#   - com.apple.TimeMachine.* snapshots (those are Time Machine's, not OS update)
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

  --clean     Actually delete (default: dry-run preview).
  -h|--help   Show this help.

Environment:
  RETENTION_SECONDS  Override the 1-day retention threshold (in seconds).
                     Default: 86400 (1 day).
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

RETENTION_SECONDS="${RETENTION_SECONDS:-86400}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v diskutil &>/dev/null || ! command -v tmutil &>/dev/null; then
  log "diskutil/tmutil not found — APFS snapshot cleanup not applicable, skipping"
  exit 0
fi

# 1. Identify the active mounted root snapshot (never delete this one).
ACTIVE_SNAPSHOT_NAME=""
ACTIVE_DEV_NODE=""
TMP_ACTIVE=$(mktemp -t apfs_active.XXXXXX)
TMP_SNAP=$(mktemp -t apfs_snap.XXXXXX)
trap 'rm -f "$TMP_ACTIVE" "$TMP_SNAP"' EXIT

if diskutil info -plist / > "$TMP_ACTIVE" 2>/dev/null; then
  ACTIVE_SNAPSHOT_NAME=$(/usr/bin/plutil -extract APFSSnapshotName raw "$TMP_ACTIVE" 2>/dev/null || true)
  ACTIVE_DEV_NODE=$(/usr/bin/plutil -extract DeviceNode raw "$TMP_ACTIVE" 2>/dev/null || true)
fi
if [[ -n "$ACTIVE_SNAPSHOT_NAME" ]]; then
  log "Active mounted root snapshot: $ACTIVE_SNAPSHOT_NAME (${ACTIVE_DEV_NODE:-unknown dev node})"
else
  log "WARN: could not determine active mounted root snapshot — will rely on the LimitingContainerShrink trigger and skip the active by default"
fi

# 2. Reference time for age calculations: prefer the device node mtime of
#    the active snapshot (when the system booted from it). Fall back to 'now'.
NOW_EPOCH=$(date '+%s')
REF_EPOCH=$NOW_EPOCH
if [[ -n "$ACTIVE_DEV_NODE" && -e "$ACTIVE_DEV_NODE" ]]; then
  ACTIVE_MOUNT_EPOCH=$(stat -f '%m' "$ACTIVE_DEV_NODE" 2>/dev/null || echo 0)
  if [[ "$ACTIVE_MOUNT_EPOCH" -gt 0 ]]; then
    REF_EPOCH=$ACTIVE_MOUNT_EPOCH
    log "Active snapshot reference time: $(date -r "$REF_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  fi
fi

# 3. Pull the canonical snapshot list as plist.
log "Listing APFS snapshots on / ..."
if ! diskutil apfs listSnapshots -plist / > "$TMP_SNAP" 2>/dev/null; then
  log "diskutil apfs listSnapshots failed"
  exit 0
fi

# 4. Parse the snapshot list with python (cleanest way to handle plist XML).
#    Output columns: name \t uuid \t xid \t limiting
mapfile -t SNAPSHOT_LINES < <(python3 -c "
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
for s in data.get('Snapshots', []):
    name = s.get('SnapshotName', '')
    uuid = s.get('SnapshotUUID', '')
    xid  = s.get('SnapshotXID', 0)
    lim  = int(bool(s.get('LimitingContainerShrink', False)))
    print(f'{name}\t{uuid}\t{xid}\t{lim}')
" < "$TMP_SNAP" 2>/dev/null)

if [[ ${#SNAPSHOT_LINES[@]} -eq 0 ]]; then
  log "No snapshots found"
  exit 0
fi

# 5. Compute max XID.
MAX_XID=0
for line in "${SNAPSHOT_LINES[@]}"; do
  IFS=$'\t' read -r _ _ xid _ <<< "$line"
  xid="${xid:-0}"
  if [[ "$xid" =~ ^[0-9]+$ ]] && (( xid > MAX_XID )); then
    MAX_XID=$xid
  fi
done
log "Highest XID observed: $MAX_XID"

log "All current snapshots:"
for line in "${SNAPSHOT_LINES[@]}"; do
  IFS=$'\t' read -r nm _ xid lim <<< "$line"
  if [[ "${lim:-0}" -eq 1 ]]; then
    log "  $nm  (XID=$xid, LIMITS_CONTAINER_SHRINK)"
  else
    log "  $nm  (XID=$xid)"
  fi
done

CUTOFF_EPOCH=$(( NOW_EPOCH - RETENTION_SECONDS ))
DELETE_LIST=()  # entries: "<name>|<uuid>|<reason>"

# Hard floor: never delete a snapshot that was created within the last
# LIM_HARD_RECENT_SECONDS, regardless of LimitingContainerShrink.
# This protects an in-flight MSUPrepareUpdate from being reaped mid-update.
LIM_HARD_RECENT_SECONDS="${LIM_HARD_RECENT_SECONDS:-3600}"  # 1 hour
HARD_RECENT_FLOOR=$(( NOW_EPOCH - LIM_HARD_RECENT_SECONDS ))

for line in "${SNAPSHOT_LINES[@]}"; do
  IFS=$'\t' read -r snap_name snap_uuid snap_xid snap_lim <<< "$line"
  [[ -z "$snap_name" ]] && continue

  # Never delete the active mounted root snapshot.
  if [[ -n "$ACTIVE_SNAPSHOT_NAME" && "$snap_name" == "$ACTIVE_SNAPSHOT_NAME" ]]; then
    log "  KEEP (active mounted): $snap_name"
    continue
  fi

  # Never touch Time Machine's own snapshots (they're not "stale update" snapshots).
  if [[ "$snap_name" =~ ^com.apple.TimeMachine. ]]; then
    log "  KEEP (Time Machine): $snap_name"
    continue
  fi

  is_os_update=0
  if [[ "$snap_name" =~ ^com.apple.os.update. ]]; then
    is_os_update=1
  fi

  # Compute a creation epoch for this snapshot.
  snap_epoch=0
  age_source=""

  # Strategy 1: legacy TimeMachine-YYYY-MM-DD-HHMMSS form still works
  #             for any cross-OS snapshots that predate the os.update-* form.
  if [[ "$snap_name" =~ com.apple.TimeMachine.([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    y=${BASH_REMATCH[1]}; mo=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
    h=${BASH_REMATCH[4]}; mi=${BASH_REMATCH[5]}; s=${BASH_REMATCH[6]}
    snap_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "${y}-${mo}-${d} ${h}:${mi}:${s}" '+%s' 2>/dev/null || echo 0)
    age_source="embedded-date"
  fi

  # Strategy 2: for com.apple.os.update-* snapshots, no date in name. Use
  #             the active-mount reference time as a lower bound: any
  #             non-active os.update snapshot was created at or before the
  #             active one booted.
  if [[ "$snap_epoch" -eq 0 && "$is_os_update" -eq 1 ]]; then
    snap_epoch=$REF_EPOCH
    age_source="active-mount-ref"
  fi

  if [[ "$snap_epoch" -eq 0 ]]; then
    log "  SKIP (no age signal): $snap_name"
    continue
  fi

  age_seconds=$(( NOW_EPOCH - snap_epoch ))
  age_hours=$(( age_seconds / 3600 ))

  is_old=0
  reason=""

  # The LimitingContainerShrink snapshot is the "anchoring" regrowth-prevention
  # failure mode — reap it whenever the hard-recent floor is past.
  if [[ "${snap_lim:-0}" -eq 1 && "$snap_epoch" -lt "$HARD_RECENT_FLOOR" ]]; then
    is_old=1
    reason="limits-container-shrink anchor (${age_hours}h old)"
  elif [[ "$snap_epoch" -lt "$CUTOFF_EPOCH" ]]; then
    is_old=1
    reason="${age_hours}h old (past retention)"
  fi

  if [[ "$is_old" -eq 1 ]]; then
    log "  OLD ($reason) [src=$age_source, xid=$snap_xid]: $snap_name — queued for deletion"
    DELETE_LIST+=("$snap_name|$snap_uuid|$reason")
  else
    log "  RECENT (${age_hours}h) [src=$age_source, xid=$snap_xid]: $snap_name — keeping"
  fi
done

if [[ ${#DELETE_LIST[@]} -eq 0 ]]; then
  log "No snapshots older than ${RETENTION_SECONDS}s — nothing to delete"
  exit 0
fi

log "Snapshots to delete: ${#DELETE_LIST[@]}"
DELETED_COUNT=0

for entry in "${DELETE_LIST[@]}"; do
  snap_name="${entry%%|*}"
  rest="${entry#*|}"
  snap_uuid="${rest%%|*}"
  reason="${rest#*|}"
  if [[ "$DRY_RUN" == true ]]; then
    log "  [dry-run] would delete snapshot: $snap_name  (uuid=$snap_uuid, $reason)"
  else
    log "  Deleting snapshot: $snap_name  (uuid=$snap_uuid, $reason)"
    # For the new com.apple.os.update-* UUID form, tmutil deletelocalsnapshots
    # rejects the name. Use `diskutil apfs deleteSnapshot <vol> -uuid <UUID>`
    # which is the documented API for both legacy and UUID forms. Falls back
    # to tmutil for any TM-style snapshot.
    deleted=0
    if [[ -n "$snap_uuid" ]]; then
      if diskutil apfs deleteSnapshot disk3s1 -uuid "$snap_uuid" 2>/dev/null; then
        deleted=1
      elif tmutil deletelocalsnapshots "$snap_name" 2>/dev/null; then
        deleted=1
      fi
    elif tmutil deletelocalsnapshots "$snap_name" 2>/dev/null; then
      deleted=1
    fi
    if [[ "$deleted" -eq 1 ]]; then
      log "  Deleted: $snap_name"
      DELETED_COUNT=$(( DELETED_COUNT + 1 ))
    else
      log "  WARNING: deletion failed for $snap_name — likely needs sudo (re-run with elevated privileges)"
    fi
  fi
done

if [[ "$DRY_RUN" == true ]]; then
  log "Dry-run complete — ${#DELETE_LIST[@]} snapshot(s) would have been deleted"
else
  log "Deleted $DELETED_COUNT of ${#DELETE_LIST[@]} snapshot(s)"
fi

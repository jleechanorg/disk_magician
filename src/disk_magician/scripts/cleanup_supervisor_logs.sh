#!/usr/bin/env bash
# cleanup_supervisor_logs.sh — Delete stale rotated launchd logs from ~/.claude/supervisor.
#
# The cmux-codex-launchd plist rotates its stdout log to a timestamped file
# (cmux-codex-launchd.YYYYMMDDTHHMMSS.log) when the active log hits its size
# cap (50 MB). Without intervention, those rotated files accumulate forever —
# we measured 91 × 50 MB = 4.55 GB across 19 days on 2026-06-13.
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

SUPERVISOR_DIR="$HOME/.claude/supervisor"
ACTIVE_LOG="$SUPERVISOR_DIR/cmux-codex-launchd.log"
ACTIVE_ERR_LOG="$SUPERVISOR_DIR/cmux-codex-launchd.stderr.log"
STATE_FILE="$SUPERVISOR_DIR/cmux-codex-launchd-state.json"

# 7 days. The launchd plist rotates ~3x/day, so 7d = ~21 rotated files.
# Active log (cmux-codex-launchd.log) and stderr are NEVER touched — only
# timestamped rotations. State file (2 bytes) is never touched.
AGE_THRESHOLD_DAYS=7

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

Options:
  --clean      Actually delete rotated launchd logs older than ${AGE_THRESHOLD_DAYS}d.
  --dry-run    Preview cleanup without deleting.
  -h, --help   Show this help.
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

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }

if [[ ! -d "$SUPERVISOR_DIR" ]]; then
  log "No supervisor dir at $SUPERVISOR_DIR — nothing to do."
  exit 0
fi

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
log "Threshold: rotated logs older than ${AGE_THRESHOLD_DAYS} days"
log ""

# Match only the timestamped rotation files, never the active log.
# Pattern: cmux-codex-launchd.YYYYMMDDTHHMMSS.log
ROTATION_PATTERN='cmux-codex-launchd.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].log'

deleted=0
freed_kb=0

while IFS= read -r -d '' f; do
  kb=$(du -sk "$f" 2>/dev/null | awk '{print $1+0}')
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN would remove: $f  (${kb} KB)"
  else
    log "Removing: $f  (${kb} KB)"
    if ! _safety_reason="$(safety_gate "$f" 2>/dev/null)"; then
      echo "SAFETY-SKIP "$f" ($_safety_reason)"
    else
      rm -f "$f"
    fi
  fi
  deleted=$(( deleted + 1 ))
  freed_kb=$(( freed_kb + kb ))
done < <(find "$SUPERVISOR_DIR" -maxdepth 1 -type f -name "$ROTATION_PATTERN" -mtime "+${AGE_THRESHOLD_DAYS}" -print0 2>/dev/null)

log ""
log "Done. Files removed: $deleted  Total freed: $(( freed_kb / 1024 )) MB"

# Always confirm the active log and state file are still present
log ""
log "Post-check (must all exist):"
for f in "$ACTIVE_LOG" "$ACTIVE_ERR_LOG" "$STATE_FILE"; do
  if [[ -e "$f" ]]; then
    log "  OK   $f"
  else
    log "  MISSING  $f"
  fi
done

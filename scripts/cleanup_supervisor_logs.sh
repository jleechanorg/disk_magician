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

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
log "Threshold: rotated logs older than ${AGE_THRESHOLD_DAYS} days"
log ""

deleted=0
freed_kb=0

# Section 1: Supervisor rotated logs
if [[ -d "$SUPERVISOR_DIR" ]]; then
  log "=== Section 1: Rotated supervisor logs ($SUPERVISOR_DIR) ==="
  # Match only the timestamped rotation files, never the active log.
  # Pattern: cmux-codex-launchd.YYYYMMDDTHHMMSS.log
  ROTATION_PATTERN='cmux-codex-launchd.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].log'

  while IFS= read -r -d '' f; do
    kb=$(du -sk "$f" 2>/dev/null | awk '{print $1+0}')
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY-RUN would remove: $f  (${kb} KB)"
    else
      log "Removing: $f  (${kb} KB)"
      if ! _safety_reason="$(safety_gate "$f" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$f" ($_safety_reason)"
        continue
      else
        rm -f "$f"
        deletion_log "cleanup_supervisor_logs.sh" "remove" "$kb" "$f"
      fi
    fi
    deleted=$(( deleted + 1 ))
    freed_kb=$(( freed_kb + kb ))
  done < <(find "$SUPERVISOR_DIR" -maxdepth 1 -type f -name "$ROTATION_PATTERN" -mtime "+${AGE_THRESHOLD_DAYS}" -print0 2>/dev/null)

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
else
  log "No supervisor dir at $SUPERVISOR_DIR — skipping Section 1."
fi

# Section 2: Dark Factory logs in ~/Library/Logs/dark-factory
DARK_FACTORY_LOGS_DIR="$HOME/Library/Logs/dark-factory"
DF_AGE_DAYS=14

if [[ -d "$DARK_FACTORY_LOGS_DIR" ]]; then
  log ""
  log "=== Section 2: Dark Factory logs ($DARK_FACTORY_LOGS_DIR, older than ${DF_AGE_DAYS}d) ==="
  df_deleted=0
  df_freed_kb=0

  while IFS= read -r -d '' item; do
    [[ -e "$item" ]] || continue
    [[ -n "$item" && "$item" == "$DARK_FACTORY_LOGS_DIR/"* ]] || continue

    # Check age: older than 14 days
    if [[ -d "$item" ]]; then
      if find "$item" -type f -mtime "-${DF_AGE_DAYS}" -print -quit 2>/dev/null | grep -q .; then
        log "Skipping recent dark-factory log dir (<${DF_AGE_DAYS}d): $item"
        continue
      fi
    else
      now_sec="$(date +%s)"
      mtime_sec="$(stat -f '%m' "$item" 2>/dev/null || stat -c '%Y' "$item" 2>/dev/null || echo "$now_sec")"
      age_d=$(( (now_sec - mtime_sec) / 86400 ))
      if (( age_d < DF_AGE_DAYS )); then
        log "Skipping recent dark-factory log file (<${DF_AGE_DAYS}d): $item"
        continue
      fi
    fi

    # Check open files via lsof
    if command -v lsof >/dev/null 2>&1; then
      if lsof +w +D "$item" >/dev/null 2>&1; then
        log "Skipping in-use dark-factory log (open files): $item"
        continue
      fi
    fi

    kb=$(du -sk "$item" 2>/dev/null | awk '{print $1+0}')

    if [[ "$DRY_RUN" == true ]]; then
      log "DRY-RUN would remove: $item  (${kb} KB)"
      df_deleted=$(( df_deleted + 1 ))
      df_freed_kb=$(( df_freed_kb + kb ))
    else
      if ! _safety_reason="$(safety_gate "$item" 2>/dev/null)"; then
        echo "SAFETY-SKIP $item ($_safety_reason)"
        continue
      fi
      log "Removing: $item  (${kb} KB)"
      chmod -R u+w "$item" 2>/dev/null || true
      if rm -rf "$item" 2>/dev/null; then
        df_deleted=$(( df_deleted + 1 ))
        df_freed_kb=$(( df_freed_kb + kb ))
        deletion_log "cleanup_supervisor_logs.sh" "remove" "$kb" "$item"
      else
        echo "SKIP (rm failed): $item"
      fi
    fi
  done < <(find "$DARK_FACTORY_LOGS_DIR" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0 2>/dev/null || true)

  log "Dark Factory logs removed: $df_deleted  Total freed: $(( df_freed_kb / 1024 )) MB"
  deleted=$(( deleted + df_deleted ))
  freed_kb=$(( freed_kb + df_freed_kb ))
fi

log ""
log "Done. Items removed: $deleted  Total freed: $(( freed_kb / 1024 )) MB"

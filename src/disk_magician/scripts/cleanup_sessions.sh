#!/usr/bin/env bash
# cleanup_sessions.sh — Clean stale agent session directories from ~/.ao-sessions/
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

DEFAULT_DAYS=1
if [[ -f "$CONFIG_FILE" ]]; then
  DEFAULT_DAYS=$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo 1
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("cleanup_thresholds", {}).get("dead_sessions_days", 1))
PY
)
fi

THRESHOLD_DAYS="${DEFAULT_DAYS}"
DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--days N] [--help]

Delete stale agent worker session directories.
Dead tmux sessions older than N days are removed.

Options:
  --clean       Actually delete (default: dry-run preview)
  --dry-run     Run in dry-run/preview mode
  --days N      Age threshold in days (default: ${DEFAULT_DAYS})
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --days)    shift; THRESHOLD_DAYS="${1:?--days requires a number}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

AO_SESSIONS_DIR="${HOME}/.ao-sessions"
TMP_DIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "/tmp/")

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
dry_tag() { [[ "$DRY_RUN" == true ]] && echo "DRY-RUN: " || echo ""; }

session_is_active() {
  local sid="$1"
  tmux list-windows -a -F "#{window_name} #{pane_current_path}" 2>/dev/null \
    | grep -q "$sid" && return 0
  return 1
}

dir_age_days() {
  local path="$1"
  local mtime now
  mtime=$(stat -f '%m' "$path" 2>/dev/null) || return 1
  now=$(date +%s)
  echo $(( (now - mtime) / 86400 ))
}

size_human() {
  du -sh "$1" 2>/dev/null | cut -f1
}

if [[ ! -d "$AO_SESSIONS_DIR" ]]; then
  log "No ~/.ao-sessions directory — nothing to do."
  exit 0
fi

pruned_count=0
skipped_count=0

if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN mode (pass --clean to actually delete)"
fi
log "Age threshold: ${THRESHOLD_DAYS} days"
log ""

total_reclaimable_kb=0

for session_dir in "${AO_SESSIONS_DIR}"/*/; do
  [[ -d "$session_dir" ]] || continue
  sid=$(basename "$session_dir")

  age=$(dir_age_days "$session_dir") || { log "SKIP $sid: cannot stat"; skipped_count=$(( skipped_count + 1 )); continue; }

  if (( age < THRESHOLD_DAYS )); then
    log "SKIP $sid: ${age}d old (threshold ${THRESHOLD_DAYS}d) — too recent"
    skipped_count=$(( skipped_count + 1 ))
    continue
  fi

  if session_is_active "$sid"; then
    log "SKIP $sid: active tmux session detected"
    skipped_count=$(( skipped_count + 1 ))
    continue
  fi

  session_size_kb=$(du -sk "$session_dir" 2>/dev/null | cut -f1 || echo 0)
  session_size_h=$(size_human "$session_dir")
  
  session_tmp="${TMP_DIR}ao-${sid}"
  tmp_size_kb=0
  if [[ -d "$session_tmp" ]]; then
    tmp_size_kb=$(du -sk "$session_tmp" 2>/dev/null | cut -f1 || echo 0)
  fi

  total_session_kb=$(( session_size_kb + tmp_size_kb ))
  total_reclaimable_kb=$(( total_reclaimable_kb + total_session_kb ))
  total_session_gb=$(awk "BEGIN {printf \"%.1f\", $total_session_kb / 1048576}")

  log "CANDIDATE $sid: ${age}d old, ${session_size_h} (plus ${total_session_gb} GB in tmp)"

  if [[ "$DRY_RUN" == false ]]; then
    rm -rf "$session_dir"
    if [[ -d "$session_tmp" ]]; then
      rm -rf "$session_tmp"
    fi
    log "  DELETED $sid (freed ${total_session_gb} GB)"
    pruned_count=$(( pruned_count + 1 ))
  else
    log "  DRY-RUN: would delete $sid and its temp files (would free ${total_session_gb} GB)"
    pruned_count=$(( pruned_count + 1 ))
  fi
done

echo ""
total_reclaimable_gb=$(awk "BEGIN {printf \"%.1f\", $total_reclaimable_kb / 1048576}")

if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN SUMMARY: ${pruned_count} sessions would be removed, ~${total_reclaimable_gb} GB reclaimable"
  log "  Skipped ${skipped_count} sessions (too recent or active tmux)"
  log "  Run with --clean to proceed."
else
  log "DONE: ${pruned_count} sessions removed, ~${total_reclaimable_gb} GB freed"
  log "  Skipped ${skipped_count} sessions"
fi

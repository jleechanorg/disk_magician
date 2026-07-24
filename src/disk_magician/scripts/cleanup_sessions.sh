#!/usr/bin/env bash
# cleanup_sessions.sh — Clean stale agent session directories from ~/.ao-sessions/
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

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
    if ! _safety_reason="$(safety_gate "$session_dir" 2>/dev/null)"; then
      echo "SAFETY-SKIP "$session_dir" ($_safety_reason)"
    else
      rm -rf "$session_dir"
    fi
    if [[ -d "$session_tmp" ]]; then
      if ! _safety_reason="$(safety_gate "$session_tmp" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$session_tmp" ($_safety_reason)"
      else
        rm -rf "$session_tmp"
      fi
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

# ────────────────────────────────────────────────────────────────────────────
# Hermes cron output rotation (Fix #7a)
#
# Per the standing leave-codex-sessions-alone rule, ~/.codex JSONL session
# files are OFF LIMITS. The same rule does NOT cover ~/.hermes — Hermes
# session files are a different domain, owned by the Hermes daemon (not by
# the user), and Hermes regenerates them on every restart. The cron output
# dir is debug noise only (stderr/stdout captures from cron-scheduled jobs);
# it has high churn and is safe to rotate aggressively (14 days).
#
# Pattern: walk top-level entries of ~/.hermes/cron/output/ and delete any
# whose mtime is older than 14 days. Both files and subdirectories are
# in scope (cron output mixes one-shot captures with per-job subdirs).
# ────────────────────────────────────────────────────────────────────────────
HERMES_CRON_OUTPUT_DIR="$HOME/.hermes/cron/output"
HERMES_CRON_OUTPUT_DAYS=14

if [[ ! -d "$HERMES_CRON_OUTPUT_DIR" ]]; then
  log "No ~/.hermes/cron/output directory — nothing to do."
else
  log "=== Section: ~/.hermes/cron/output/ (${HERMES_CRON_OUTPUT_DAYS}d mtime) ==="
  cron_pruned=0
  cron_freed_kb=0
  while IFS= read -r -d '' entry; do
    [[ -e "$entry" ]] || continue
    entry_size_kb=$(du -sk "$entry" 2>/dev/null | cut -f1 || echo 0)
    entry_age=$(dir_age_days "$entry") || continue
    if (( entry_age < HERMES_CRON_OUTPUT_DAYS )); then
      continue
    fi
    entry_size_h=$(size_human "$entry")
    if [[ "$DRY_RUN" == true ]]; then
      log "$(dry_tag)would delete $entry (${entry_age}d old, ${entry_size_h})"
    else
      log "deleting $entry (${entry_age}d old, ${entry_size_h})"
      if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$entry" ($_safety_reason)"
      else
        rm -rf "$entry"
      fi
    fi
    cron_pruned=$(( cron_pruned + 1 ))
    cron_freed_kb=$(( cron_freed_kb + entry_size_kb ))
  done < <(find "$HERMES_CRON_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  cron_freed_gb=$(awk "BEGIN {printf \"%.2f\", $cron_freed_kb / 1048576}")
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: ${cron_pruned} hermes cron entries older than ${HERMES_CRON_OUTPUT_DAYS}d would be removed (~${cron_freed_gb} GB reclaimable)"
  else
    log "DONE: ${cron_pruned} hermes cron entries removed (~${cron_freed_gb} GB freed)"
  fi
  pruned_count=$(( pruned_count + cron_pruned ))
  total_reclaimable_kb=$(( total_reclaimable_kb + cron_freed_kb ))
fi

# ────────────────────────────────────────────────────────────────────────────
# Hermes sessions JSONL rotation (Fix #7a)
#
# 4592 *.jsonl files, 5.2 GB total. Hermes daemon writes one JSONL per
# session; old sessions are debug/audit trails, not user-owned working data.
# 30-day mtime gate keeps ~30 days of recent history (matches the rolling
# window most operators expect) while still reaping the long tail of stale
# captures. Files ONLY (no directories) — sessions/*.jsonl is a flat dir
# of session files; adjacent session_*.json + request_dump_*.json are
# metadata sidecars, intentionally NOT rotated by this script (smaller,
# different access patterns; revisit if size shows up in audit later).
# ────────────────────────────────────────────────────────────────────────────
HERMES_SESSIONS_DIR="$HOME/.hermes/sessions"
HERMES_SESSIONS_DAYS=30

if [[ ! -d "$HERMES_SESSIONS_DIR" ]]; then
  log "No ~/.hermes/sessions directory — nothing to do."
else
  log "=== Section: ~/.hermes/sessions/*.jsonl (${HERMES_SESSIONS_DAYS}d mtime) ==="
  sess_pruned=0
  sess_freed_kb=0
  while IFS= read -r -d '' entry; do
    [[ -e "$entry" ]] || continue
    entry_size_kb=$(du -sk "$entry" 2>/dev/null | cut -f1 || echo 0)
    entry_age=$(dir_age_days "$entry") || continue
    if (( entry_age < HERMES_SESSIONS_DAYS )); then
      continue
    fi
    entry_size_h=$(size_human "$entry")
    if [[ "$DRY_RUN" == true ]]; then
      log "$(dry_tag)would delete $entry (${entry_age}d old, ${entry_size_h})"
    else
      log "deleting $entry (${entry_age}d old, ${entry_size_h})"
      if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$entry" ($_safety_reason)"
      else
        rm -f "$entry"
      fi
    fi
    sess_pruned=$(( sess_pruned + 1 ))
    sess_freed_kb=$(( sess_freed_kb + entry_size_kb ))
  done < <(find "$HERMES_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

  sess_freed_gb=$(awk "BEGIN {printf \"%.2f\", $sess_freed_kb / 1048576}")
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: ${sess_pruned} hermes session JSONLs older than ${HERMES_SESSIONS_DAYS}d would be removed (~${sess_freed_gb} GB reclaimable)"
  else
    log "DONE: ${sess_pruned} hermes session JSONLs removed (~${sess_freed_gb} GB freed)"
  fi
  pruned_count=$(( pruned_count + sess_pruned ))
  total_reclaimable_kb=$(( total_reclaimable_kb + sess_freed_kb ))
fi

echo ""
total_reclaimable_gb=$(awk "BEGIN {printf \"%.1f\", $total_reclaimable_kb / 1048576}")

if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN SUMMARY: ${pruned_count} entries would be removed, ~${total_reclaimable_gb} GB reclaimable"
  log "  Skipped ${skipped_count} sessions (too recent or active tmux)"
  log "  Run with --clean to proceed."
else
  log "DONE: ${pruned_count} entries removed, ~${total_reclaimable_gb} GB freed"
  log "  Skipped ${skipped_count} sessions"
fi

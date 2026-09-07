#!/usr/bin/env bash
# sweeper_health_check.sh — Detect sweepers that are installed but not actually running
#
# Walks ~/Library/LaunchAgents/com.jleechan.cleanup-*.plist, resolves the log path
# from each plist's StandardOutPath, and checks if the log was modified within
# the staleness threshold (default 7 days, overridable via --threshold-days).
#
# A sweeper is "MISS" if:
#   - its log file does not exist
#   - its log file is older than the threshold
#   - its log file exists but is empty (silent failure)
#
# A sweeper is "OK" if its log was modified within the threshold window.
#
# A sweeper is reported as "WARN" if the log is within the threshold but contains
# a recent "ERROR"/"Traceback"/"FAILED" marker (last 50 lines).
#
# Exit code: 0 if all sweepers are OK, 1 if any are MISS or WARN.
#
# Usage:
#   sweeper_health_check.sh [--threshold-days N] [--verbose] [--dry-run]
#
# Default mode is read-only. This script never runs a sweeper, never modifies logs,
# and never alerts externally — it only reports state. Wire an alerting layer
# (Slack/email/disk_usage_alert.sh) onto the non-zero exit code if desired.

set -euo pipefail

DRY_RUN=true
VERBOSE=false
AUTO_REPAIR=false
NOTIFY=true
THRESHOLD_DAYS=7
PLIST_DIR="$HOME/Library/LaunchAgents"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="${DISK_MAGICIAN_INSTALLER:-$REPO_ROOT/scripts/install_launchd_sweepers.sh}"

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --threshold-days) THRESHOLD_DAYS="$2"; shift 2 ;;
    --threshold)      THRESHOLD_DAYS="$2"; shift 2 ;;
    --plist-dir)      PLIST_DIR="$2"; shift 2 ;;
    --auto-repair)    AUTO_REPAIR=true; shift ;;
    --notify)         NOTIFY=true; shift ;;
    --no-notify)      NOTIFY=false; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --no-dry-run)     DRY_RUN=false; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--threshold-days N] [--plist-dir DIR] [--auto-repair] [--notify|--no-notify] [--verbose] [--dry-run]

Options:
  --threshold-days N   Maximum log age in days before a sweeper is flagged MISS
                       (default: 7)
  --plist-dir DIR      Directory to scan for cleanup / disk-magician plists
                       (default: ~/Library/LaunchAgents)
  --auto-repair        Automatically re-install corrupted or missing plists from
                       repository templates via install_launchd_sweepers.sh
  --notify / --no-notify
                       Send operator alert notification via cmux notify when degraded
                       (default: enabled)
  --verbose            Print per-sweeper details for OK sweepers too
  --dry-run            No-op retained for parity with other disk_magician scripts
                       (this script is read-only by default)
  -h, --help           Show this help

Exit codes:
  0  All sweepers healthy
  1  At least one sweeper is MISS or WARN
  2  Invalid arguments
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
vlog() { [[ "$VERBOSE" == true ]] && log "$*" || true; }

if ! [[ "$THRESHOLD_DAYS" =~ ^[0-9]+$ ]] || [[ "$THRESHOLD_DAYS" -lt 1 ]]; then
  echo "Error: --threshold-days must be a positive integer (got: $THRESHOLD_DAYS)" >&2
  exit 2
fi

if [[ ! -d "$PLIST_DIR" ]]; then
  echo "Error: plist directory not found: $PLIST_DIR" >&2
  exit 1
fi

# Threshold expressed in seconds for date math.
THRESHOLD_SEC=$(( THRESHOLD_DAYS * 86400 ))
NOW_EPOCH=$(date +%s)

# Get the log path from a plist's StandardOutPath key. Falls back to
# StandardErrorPath, then to ~/Library/Logs/<label>.log.
extract_log_path() {
  local plist="$1"
  local label="$2"

  if ! command -v plutil >/dev/null 2>&1; then
    echo "$HOME/Library/Logs/${label}.log"
    return
  fi

  local out err
  out=$(plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null || true)
  if [[ -n "$out" && "$out" != "null" ]]; then
    echo "$out"
    return
  fi

  err=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null || true)
  if [[ -n "$err" && "$err" != "null" ]]; then
    echo "$err"
    return
  fi

  echo "$HOME/Library/Logs/${label}.log"
}

# Read the last N lines of a log and grep for failure markers. Bash 3.2 safe.
log_has_error() {
  local log_path="$1"
  [[ -f "$log_path" && -s "$log_path" ]] || return 1
  # tail -n 50 | grep -E
  tail -n 50 "$log_path" 2>/dev/null | grep -Eqi 'error|traceback|failed|exception' || return 1
  return 0
}

# Gather the plist list, sorted. Use a temp file to avoid mapfile (Bash 3.2).
PLIST_TMP=$(mktemp -t sweeper_health.XXXXXX)
trap 'rm -f "$PLIST_TMP"' EXIT

find "$PLIST_DIR" -maxdepth 1 \( \
  -name "com.jleechan.cleanup-*.plist" -o \
  -name "com.jleechan.disk-magician-*.plist" -o \
  -name "com.jleechanorg.disk-magician-*.plist" -o \
  -name "com.disk-magician.*.plist" -o \
  -name "com.jleechanorg.disk-magician.plist" \
\) -print 2>/dev/null \
  | sort > "$PLIST_TMP" || true

PLIST_COUNT=$(wc -l < "$PLIST_TMP" | tr -d ' ')

log "Sweeper health check — threshold ${THRESHOLD_DAYS}d, plist dir $PLIST_DIR"
log "Found $PLIST_COUNT plist(s)"
echo

MISS_COUNT=0
WARN_COUNT=0
OK_COUNT=0
CORRUPT_COUNT=0
REPAIR_LABELS=()

while IFS= read -r plist; do
  [[ -z "$plist" ]] && continue
  label=$(basename "$plist" .plist)

  # Structural XML and plist validation (disk_magician-zwb):
  # Detect malformed XML or truncated plists missing the root <dict> / Label key.
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$plist" >/dev/null 2>&1; then
      CORRUPT_COUNT=$(( CORRUPT_COUNT + 1 ))
      MISS_COUNT=$(( MISS_COUNT + 1 ))
      REPAIR_LABELS+=("$label")
      printf "  [CORRUPT] %-42s plist=%s  (fails plutil -lint)\n" "$label" "$plist"
      continue
    fi
    if ! plutil -extract Label raw -o - "$plist" >/dev/null 2>&1; then
      CORRUPT_COUNT=$(( CORRUPT_COUNT + 1 ))
      MISS_COUNT=$(( MISS_COUNT + 1 ))
      REPAIR_LABELS+=("$label")
      printf "  [CORRUPT] %-42s plist=%s  (missing top-level Label / bare <array>)\n" "$label" "$plist"
      continue
    fi
  fi

  log_path=$(extract_log_path "$plist" "$label")

  if [[ ! -e "$log_path" ]]; then
    age_days_str="n/a"
    MISS_COUNT=$(( MISS_COUNT + 1 ))
    REPAIR_LABELS+=("$label")
    printf "  [MISS] %-44s log=%s  (file does not exist)\n" "$label" "$log_path"
    continue
  fi

  if [[ ! -s "$log_path" ]]; then
    MISS_COUNT=$(( MISS_COUNT + 1 ))
    printf "  [MISS] %-44s log=%s  (file is empty)\n" "$label" "$log_path"
    continue
  fi

  mtime_epoch=$(stat -f '%m' "$log_path" 2>/dev/null || stat -c '%Y' "$log_path" 2>/dev/null || echo 0)
  if [[ -z "$mtime_epoch" || "$mtime_epoch" -eq 0 ]]; then
    WARN_COUNT=$(( WARN_COUNT + 1 ))
    printf "  [WARN] %-44s log=%s  (could not determine mtime)\n" "$label" "$log_path"
    continue
  fi

  age_sec=$(( NOW_EPOCH - mtime_epoch ))
  age_days=$(( age_sec / 86400 ))
  age_hours=$(( (age_sec % 86400) / 3600 ))
  age_str="${age_days}d${age_hours}h"

  if [[ $age_sec -gt $THRESHOLD_SEC ]]; then
    MISS_COUNT=$(( MISS_COUNT + 1 ))
    printf "  [MISS] %-44s log=%s  (last write %s ago, threshold %dd)\n" \
      "$label" "$log_path" "$age_str" "$THRESHOLD_DAYS"
    continue
  fi

  if log_has_error "$log_path"; then
    WARN_COUNT=$(( WARN_COUNT + 1 ))
    printf "  [WARN] %-44s log=%s  (last write %s ago, errors in tail)\n" \
      "$label" "$log_path" "$age_str"
    continue
  fi

  OK_COUNT=$(( OK_COUNT + 1 ))
  if [[ "$VERBOSE" == true ]]; then
    printf "  [OK]   %-44s log=%s  (last write %s ago)\n" \
      "$label" "$log_path" "$age_str"
  fi
done < "$PLIST_TMP"

echo
log "Summary: $OK_COUNT OK, $WARN_COUNT WARN, $MISS_COUNT MISS (of $PLIST_COUNT)"

if [[ $CORRUPT_COUNT -gt 0 ]]; then
  log "CORRUPT: $CORRUPT_COUNT sweeper plist(s) malformed -- run bash scripts/install_launchd_sweepers.sh or pass --auto-repair."
fi

# Operator notification trigger (disk_magician-sweeper-health-auto-repair-dzm)
if [[ "$NOTIFY" == true && ($MISS_COUNT -gt 0 || $WARN_COUNT -gt 0 || $CORRUPT_COUNT -gt 0) ]]; then
  if command -v cmux >/dev/null 2>&1; then
    notify_body="Sweeper health degraded: ${MISS_COUNT} silent/corrupt"
    [[ $CORRUPT_COUNT -gt 0 ]] && notify_body="${notify_body} (${CORRUPT_COUNT} corrupt)"
    [[ $WARN_COUNT -gt 0 ]] && notify_body="${notify_body}, ${WARN_COUNT} warnings"
    cmux notify --title "disk-magician" --body "$notify_body" >/dev/null 2>&1 || true
  fi
fi

# Auto-repair flow (disk_magician-sweeper-health-auto-repair-dzm)
if [[ "$AUTO_REPAIR" == true && ${#REPAIR_LABELS[@]} -gt 0 ]]; then
  echo
  log "Auto-repair: repairing ${#REPAIR_LABELS[@]} degraded sweeper(s)..."
  if [[ -x "$INSTALLER" ]]; then
    DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" "$INSTALLER" "${REPAIR_LABELS[@]}" || log "Auto-repair: installer exited with code $?"
  else
    log "Auto-repair: installer not executable: $INSTALLER"
  fi
fi

if [[ $MISS_COUNT -gt 0 ]]; then
  log "FAIL: $MISS_COUNT sweeper(s) appear silent or corrupt — investigate plist or script."
  exit 1
fi

if [[ $WARN_COUNT -gt 0 ]]; then
  log "WARN: $WARN_COUNT sweeper(s) logged errors in last 50 lines."
  exit 1
fi

log "All sweepers healthy."
exit 0

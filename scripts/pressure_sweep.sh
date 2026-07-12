#!/usr/bin/env bash
# pressure_sweep.sh — Free-space-gated sweep runner.
#
# Addresses beads jleechan-6xzf (/tmp scratch sawtooths to 97G/day against a
# daily 04:05 sweep) and jleechan-etjw (Colima re-inflates ~30G/hr against
# sparse prunes): a cadence gap between how fast these two trees grow and how
# often the existing daily/weekly sweepers run. This script is a THRESHOLD
# trigger meant to run frequently (every 2h via launchd) — it only does real
# work when free space has actually dropped below threshold, so idle fires
# are a single log line.
#
# Never runs anything beyond cleanup_tmp.sh --clean and cleanup_colima.sh
# --clean — both scripts own their own safety semantics (mtime thresholds,
# docker-prune semantics preserving in-use containers/volumes). This script
# adds no destructive logic of its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THRESHOLD_GB="${DISK_MAGICIAN_PRESSURE_THRESHOLD_GB:-40}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK_DIR="$STATE_DIR/pressure_sweep.lock"
LOCK_TTL_SEC=3600
LOG_FILE="${DISK_MAGICIAN_PRESSURE_LOG:-$HOME/Library/Logs/disk-magician-pressure-sweep.log}"
STEP_TIMEOUT=600
DRY_RUN=false
# Testing hook: skip the real `df` read and use a fabricated free-GB value
# instead, so the triggered path can be exercised deterministically without
# depending on the box's actual disk state at test time.
FREE_GB_OVERRIDE="${DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--threshold-gb N] [--dry-run]

Free-space-gated sweep: if free space (df /System/Volumes/Data) is >=
--threshold-gb (default: ${THRESHOLD_GB}; env DISK_MAGICIAN_PRESSURE_THRESHOLD_GB),
exit immediately (one log line, no work). Otherwise run, in order:
  1. scripts/cleanup_tmp.sh --clean    (mtime-thresholded; its own safety layer)
  2. scripts/cleanup_colima.sh --clean (docker-prune semantics + fstrim)
each under a ${STEP_TIMEOUT}s timeout, logging free-GB before/after to
${LOG_FILE}.

Options:
  --threshold-gb N  Free-space threshold in GB (default: ${THRESHOLD_GB})
  --dry-run         Pass --dry-run (not --clean) to both sub-scripts instead —
                     lets the triggered path be verified with zero deletions.
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-gb) THRESHOLD_GB="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

free_gb() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    echo "$FREE_GB_OVERRIDE"
    return
  fi
  local check_path="/"
  if [[ "$OSTYPE" == "darwin"* ]] && df "/System/Volumes/Data" >/dev/null 2>&1; then
    check_path="/System/Volumes/Data"
  fi
  df -kP "$check_path" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}'
}

TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then TIMEOUT_CMD="gtimeout"; fi
run_step_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$STEP_TIMEOUT" "$@"
  else
    "$@"
  fi
}

current_free_gb="$(free_gb)"

if [[ -z "$current_free_gb" ]]; then
  log "pressure_sweep: could not read free space — no-op (fail safe, no cleanup attempted)."
  exit 0
fi

below_threshold=$(awk -v f="$current_free_gb" -v t="$THRESHOLD_GB" 'BEGIN{print (f < t) ? "1" : "0"}')
if [[ "$below_threshold" != "1" ]]; then
  log "pressure_sweep: free ${current_free_gb} GB >= threshold ${THRESHOLD_GB} GB — no-op."
  exit 0
fi

log "pressure_sweep: free ${current_free_gb} GB < threshold ${THRESHOLD_GB} GB — sweep triggered (dry_run=${DRY_RUN})."

# ────────── LOCK (mkdir-based, TTL 60min) — overlapping fires skip ──────────
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    date -u +%s > "$LOCK_DIR/acquired_at"
    return 0
  fi
  local lock_ts now age
  lock_ts="$(cat "$LOCK_DIR/acquired_at" 2>/dev/null || echo 0)"
  now="$(date -u +%s)"
  age=$(( now - lock_ts ))
  if (( age > LOCK_TTL_SEC )); then
    log "pressure_sweep: stale lock (${age}s old, TTL ${LOCK_TTL_SEC}s) — reclaiming."
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && date -u +%s > "$LOCK_DIR/acquired_at" && return 0
    return 1
  fi
  return 1
}

if ! acquire_lock; then
  log "pressure_sweep: lock held by another run (< ${LOCK_TTL_SEC}s old) — skipping this fire."
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

clean_flag="--clean"
[[ "$DRY_RUN" == true ]] && clean_flag="--dry-run"

# ────────── STEP 1: cleanup_tmp.sh ──────────
before_gb="$(free_gb)"
log "pressure_sweep: step 1/2 cleanup_tmp.sh ${clean_flag} — free before: ${before_gb} GB"
if run_step_timeout "$REPO_ROOT/scripts/cleanup_tmp.sh" "$clean_flag" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 1/2 cleanup_tmp.sh done — free after: ${after_gb} GB"
else
  rc=$?
  log "pressure_sweep: step 1/2 cleanup_tmp.sh FAILED or timed out (rc=${rc}) — continuing to step 2."
fi

# ────────── STEP 2: cleanup_colima.sh ──────────
before_gb="$(free_gb)"
log "pressure_sweep: step 2/2 cleanup_colima.sh ${clean_flag} — free before: ${before_gb} GB"
if run_step_timeout "$REPO_ROOT/scripts/cleanup_colima.sh" "$clean_flag" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 2/2 cleanup_colima.sh done — free after: ${after_gb} GB"
else
  rc=$?
  log "pressure_sweep: step 2/2 cleanup_colima.sh FAILED or timed out (rc=${rc})."
fi

log "pressure_sweep: sweep complete."

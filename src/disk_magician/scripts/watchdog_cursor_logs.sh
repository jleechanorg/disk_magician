#!/usr/bin/env bash
# watchdog_cursor_logs.sh — Size-gated truncate-in-place watchdog for cursor-agent debug logs.
#
# Addresses incident disk_magician-ax0 (findings_wiki/cursor-agent-debug-log-unbounded-growth.md):
# Headless cursor-agent processes can continuously append debug output to session logs
# without native rotation, compounding to tens of gigabytes (e.g. 45GB single file).
#
# Active writers hold open file descriptors in append mode (O_APPEND). Standard rename-and-recreate
# rotation (like newsyslog) fails because active processes never reopen the file descriptor,
# leaving the unlinked/renamed file open and consuming disk space until the process exits.
#
# This script performs copytruncate in place (`: > "$file"`):
#   - Scans $TMPDIR/cursor-agent-logs-*/session-*.log and /private/tmp/cursor-agent-logs-*/session-*.log
#   - Checks each file's size against the threshold (default: 2048 MB = 2 GB)
#   - Truncates qualifying files in place without renaming or unlinking
#   - Active writers continue writing to their open fd at offset 0 without error
#   - Disk blocks are immediately reclaimed on APFS / local storage
#
# Usage:
#   watchdog_cursor_logs.sh [--threshold-mb N] [--threshold-bytes N] [--dirs DIR1[:DIR2...]] [--dry-run] [--apply]
set -euo pipefail

THRESHOLD_MB="${CURSOR_LOG_THRESHOLD_MB:-2048}"
THRESHOLD_BYTES="${CURSOR_LOG_THRESHOLD_BYTES:-}"
DRY_RUN=false
CUSTOM_DIRS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [FILE/DIR...]

Size-gated truncate-in-place watchdog for cursor-agent debug logs.

Options:
  --threshold-mb N      Size threshold in MB (default: ${THRESHOLD_MB}; env CURSOR_LOG_THRESHOLD_MB)
  --threshold-bytes N   Size threshold in bytes (exact override; env CURSOR_LOG_THRESHOLD_BYTES)
  --dirs DIRS           Colon-separated list of directories to scan (env CURSOR_LOG_DIRS)
  --dry-run             Preview which files would be truncated without mutating them
  --apply               Apply truncation in place (default)
  -h, --help            Show this help

Defaults:
  Scans \$TMPDIR/cursor-agent-logs-*/session-*.log and /private/tmp/cursor-agent-logs-*/session-*.log.
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --threshold-mb)
      THRESHOLD_MB="$2"
      shift 2
      ;;
    --threshold-bytes)
      THRESHOLD_BYTES="$2"
      shift 2
      ;;
    --dirs)
      CUSTOM_DIRS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --apply)
      DRY_RUN=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"
}

# Calculate threshold in bytes
if [[ -n "$THRESHOLD_BYTES" ]]; then
  if ! [[ "$THRESHOLD_BYTES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --threshold-bytes must be a non-negative integer (got: $THRESHOLD_BYTES)" >&2
    exit 2
  fi
else
  if ! [[ "$THRESHOLD_MB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --threshold-mb must be a non-negative integer (got: $THRESHOLD_MB)" >&2
    exit 2
  fi
  THRESHOLD_BYTES=$(( THRESHOLD_MB * 1024 * 1024 ))
fi

# Determine search directories
SEARCH_DIRS=()
if [[ -n "$CUSTOM_DIRS" ]]; then
  IFS=':' read -r -a _custom_arr <<< "$CUSTOM_DIRS"
  for d in "${_custom_arr[@]}"; do
    [[ -n "$d" ]] && SEARCH_DIRS+=("$d")
  done
elif [[ -n "${CURSOR_LOG_DIRS:-}" ]]; then
  IFS=':' read -r -a _custom_arr <<< "$CURSOR_LOG_DIRS"
  for d in "${_custom_arr[@]}"; do
    [[ -n "$d" ]] && SEARCH_DIRS+=("$d")
  done
elif [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  for p in "${POSITIONAL[@]}"; do
    [[ -n "$p" ]] && SEARCH_DIRS+=("$p")
  done
else
  # Default search roots: $TMPDIR and /private/tmp and /tmp
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    SEARCH_DIRS+=("${TMPDIR%/}")
  fi
  if [[ -d "/private/tmp" ]]; then
    SEARCH_DIRS+=("/private/tmp")
  fi
  if [[ -d "/tmp" && "/tmp" != "/private/tmp" ]]; then
    SEARCH_DIRS+=("/tmp")
  fi
fi

get_file_size() {
  local f="$1"
  stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null || echo 0
}

get_file_id() {
  local f="$1"
  stat -f "%d:%i" "$f" 2>/dev/null || stat -c "%d:%i" "$f" 2>/dev/null || echo "$f"
}

# Collect candidate files
shopt -s nullglob
CANDIDATE_FILES=()
for target in "${SEARCH_DIRS[@]}"; do
  if [[ -f "$target" ]]; then
    CANDIDATE_FILES+=("$target")
    continue
  fi
  [[ -d "$target" ]] || continue

  # 1. Standard pattern: $target/cursor-agent-logs-*/session-*.log
  for f in "$target"/cursor-agent-logs-*/session-*.log; do
    [[ -f "$f" ]] && CANDIDATE_FILES+=("$f")
  done

  # 2. Pattern if target is already cursor-agent-logs-* directory
  for f in "$target"/session-*.log; do
    [[ -f "$f" ]] && CANDIDATE_FILES+=("$f")
  done

  # 3. Direct log files under target if explicit custom target directory provided
  if [[ -n "$CUSTOM_DIRS" || ${#POSITIONAL[@]} -gt 0 || -n "${CURSOR_LOG_DIRS:-}" ]]; then
    for f in "$target"/*.log; do
      [[ -f "$f" ]] && CANDIDATE_FILES+=("$f")
    done
  fi
done

# De-duplicate candidate files by filesystem device:inode
SEEN_IDS=()
UNIQUE_FILES=()

is_seen() {
  local fid="$1"
  for s in "${SEEN_IDS[@]:-}"; do
    if [[ "$s" == "$fid" ]]; then
      return 0
    fi
  done
  return 1
}

for f in "${CANDIDATE_FILES[@]}"; do
  [[ -e "$f" ]] || continue
  # Skip symlinks (e.g. latest.log symlinks) so we only operate on real log files
  [[ -h "$f" || -L "$f" ]] && continue

  fid="$(get_file_id "$f")"
  if ! is_seen "$fid"; then
    SEEN_IDS+=("$fid")
    UNIQUE_FILES+=("$f")
  fi
done

mode_label="APPLY"
if [[ "$DRY_RUN" == true ]]; then
  mode_label="DRY-RUN"
fi

threshold_mb_disp=$(awk "BEGIN {printf \"%.2f\", $THRESHOLD_BYTES / 1048576}")
log "Cursor log watchdog ($mode_label) — threshold: ${threshold_mb_disp} MB (${THRESHOLD_BYTES} bytes)"
log "Scanning ${#UNIQUE_FILES[@]} candidate log file(s)..."

scanned_count=0
truncated_count=0
reclaimed_bytes=0

for f in "${UNIQUE_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  scanned_count=$(( scanned_count + 1 ))

  fsize="$(get_file_size "$f")"
  if (( fsize >= THRESHOLD_BYTES )); then
    size_mb=$(awk "BEGIN {printf \"%.2f\", $fsize / 1048576}")
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY-RUN: would truncate in-place: $f (${size_mb} MB >= ${threshold_mb_disp} MB)"
      truncated_count=$(( truncated_count + 1 ))
      reclaimed_bytes=$(( reclaimed_bytes + fsize ))
    else
      log "TRUNCATING in-place: $f (${size_mb} MB >= ${threshold_mb_disp} MB)"
      if [[ -w "$f" ]]; then
        # Copytruncate in place: zero the file without unlinking or changing inode
        : > "$f"
        after_size="$(get_file_size "$f")"
        after_mb=$(awk "BEGIN {printf \"%.2f\", $after_size / 1048576}")
        log "TRUNCATED: $f (freed ${size_mb} MB, new size: ${after_mb} MB)"
        truncated_count=$(( truncated_count + 1 ))
        reclaimed_bytes=$(( reclaimed_bytes + (fsize - after_size) ))
      else
        log "ERROR: cannot truncate $f (permission denied / not writable)"
      fi
    fi
  fi
done

freed_mb_disp=$(awk "BEGIN {printf \"%.2f\", $reclaimed_bytes / 1048576}")
log "Done. Scanned: ${scanned_count} file(s), Truncated: ${truncated_count} file(s), Reclaimed: ${freed_mb_disp} MB."
exit 0

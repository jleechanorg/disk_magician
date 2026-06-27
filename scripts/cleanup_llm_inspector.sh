#!/usr/bin/env bash
# cleanup_llm_inspector.sh — Rotate ~/.llm-inspector/captures/ to prevent unbounded growth.
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

CAPTURES_DIR="$HOME/.llm-inspector/captures"
INSPECTOR_DIR="$HOME/.llm-inspector"

AGE_THRESHOLD_DAYS=3
SIZE_CAP_KB=$(( 2 * 1024 * 1024 ))  # 2 GB cap

LAUNCHD_LOG="$INSPECTOR_DIR/launchd.log"
LAUNCHD_ERR_LOG="$INSPECTOR_DIR/launchd.err.log"
LAUNCHD_LOG_MAX_MB=50
LAUNCHD_ERR_LOG_MAX_MB=10
LAUNCHD_LOG_KEEP_LINES=10000

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

Options:
  --clean      Actually execute cleanup (default: dry-run).
  --dry-run    Preview cleanup without deleting.
  -h, --help   Show this help
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
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

path_size_kb() {
  local path="$1"
  du -sk "$path" 2>/dev/null | awk '{print $1+0}' || echo 0
}

file_size_bytes() {
  local path="$1"
  stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path" 2>/dev/null || echo 0
}

remove_file() {
  local f="$1"
  local kb
  kb=$(path_size_kb "$f")

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove: $f  (${kb} KB)"
  else
    log "Removing: $f  (${kb} KB)"
    rm -f "$f"
  fi
  echo "$kb"
}

log "$(dry_prefix)cleanup_llm_inspector.sh starting"

FILES_DELETED=0
TOTAL_KB=0

if [[ -d "$CAPTURES_DIR" ]]; then
  log "Phase 1: removing files older than ${AGE_THRESHOLD_DAYS} days in ${CAPTURES_DIR} ..."

  while IFS= read -r -d '' f; do
    kb=$(remove_file "$f")
    TOTAL_KB=$(( TOTAL_KB + kb ))
    FILES_DELETED=$(( FILES_DELETED + 1 ))
  done < <(find "$CAPTURES_DIR" -maxdepth 1 -type f               \( -name "capture-*.json" -o -name "*.summary.json" \)               -mtime "+${AGE_THRESHOLD_DAYS}" -print0 2>/dev/null || true)

  log "Phase 1 complete. Files removed: ${FILES_DELETED}  KB freed: ${TOTAL_KB}"
else
  log "Captures dir missing, skipping age-based phase."
fi

if [[ -d "$CAPTURES_DIR" ]]; then
  current_kb=$(path_size_kb "$CAPTURES_DIR")
  log "Phase 2: size check — current: ${current_kb} KB  cap: ${SIZE_CAP_KB} KB"

  if (( current_kb > SIZE_CAP_KB )); then
    log "Dir exceeds cap, removing oldest files first ..."

    # macOS and Linux compatible stat sorting
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      current_kb=$(path_size_kb "$CAPTURES_DIR")
      if (( current_kb <= SIZE_CAP_KB )); then
        log "Now under cap (${current_kb} KB). Stopping."
        break
      fi

      kb=$(remove_file "$f")
      TOTAL_KB=$(( TOTAL_KB + kb ))
      FILES_DELETED=$(( FILES_DELETED + 1 ))
    done < <(find "$CAPTURES_DIR" -maxdepth 1 -type f                 \( -name "capture-*.json" -o -name "*.summary.json" \)                 -print0 2>/dev/null               | xargs -0 stat -f '%m %N' 2>/dev/null               | sort -n               | awk '{print $2}'               || true)

    final_kb=$(path_size_kb "$CAPTURES_DIR")
    log "Phase 2 complete. Dir size after cap enforcement: ${final_kb} KB"
  else
    log "Dir is within cap (${current_kb} KB <= ${SIZE_CAP_KB} KB). No cap enforcement needed."
  fi
fi

if [[ ! -d "$CAPTURES_DIR" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would recreate missing dir: ${CAPTURES_DIR}"
  else
    log "Recreating missing dir: ${CAPTURES_DIR}"
    mkdir -p "$CAPTURES_DIR"
  fi
fi

rotate_log() {
  local logfile="$1"
  local max_mb="$2"
  local keep_lines="$3"

  [[ -f "$logfile" ]] || return 0

  local size_bytes
  size_bytes=$(file_size_bytes "$logfile")
  local max_bytes=$(( max_mb * 1024 * 1024 ))

  if (( size_bytes > max_bytes )); then
    local size_mb=$(( size_bytes / 1024 / 1024 ))
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would truncate ${logfile} (${size_mb} MB > ${max_mb} MB) to last ${keep_lines} lines"
    else
      log "Rotating ${logfile} (${size_mb} MB > ${max_mb} MB) — keeping last ${keep_lines} lines"
      local tmp_file
      tmp_file=$(mktemp)
      tail -n "$keep_lines" "$logfile" > "$tmp_file"
      mv "$tmp_file" "$logfile"
      log "Rotation complete. New size: $(file_size_bytes "$logfile") bytes"
    fi
  else
    local size_mb=$(( size_bytes / 1024 / 1024 ))
    log "Log ${logfile} is ${size_mb} MB — under ${max_mb} MB threshold, no rotation needed"
  fi
}

rotate_log "$LAUNCHD_LOG"     "$LAUNCHD_LOG_MAX_MB"     "$LAUNCHD_LOG_KEEP_LINES"
rotate_log "$LAUNCHD_ERR_LOG" "$LAUNCHD_ERR_LOG_MAX_MB" "$LAUNCHD_LOG_KEEP_LINES"

log "$(dry_prefix)Done. Files removed: ${FILES_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"

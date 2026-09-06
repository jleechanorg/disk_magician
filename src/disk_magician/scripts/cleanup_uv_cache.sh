#!/usr/bin/env bash
# cleanup_uv_cache.sh — Prune disk-magician's own stale uv-cache footprint.
#
# Every `uv tool install --force --reinstall` (the deploy step documented in
# CLAUDE.md's "commit is NOT deploy" section) leaves the PREVIOUS version's
# extracted build behind forever under ~/.cache/uv/archive-v0/<hash>/ and
# ~/.cache/uv/sdists-v9/.../*.whl — uv never prunes these on its own. Found
# 2026-09-05: 14+ orphaned disk_magician archive-v0 dirs (0.2.77 .. 0.2.90,
# ~880KB-924KB each) plus matching stale sdist wheels, none reachable from
# the live installed venv.
#
# Age (>=AGE_THRESHOLD_DAYS old, mtime) is reported per-item for visibility,
# but the actual removal is delegated to `uv cache prune`: it is uv's own
# reference-tracking prune (removes only entries unreachable from every
# installed environment on disk), so it is correct regardless of age and
# safer than this script re-deriving "which hash is still in use" itself.
#
# Defaults to dry-run (use --clean to actually prune).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

AGE_THRESHOLD_DAYS="${DISK_MAGICIAN_UV_CACHE_MIN_AGE_DAYS:-30}"
if [[ "$AGE_THRESHOLD_DAYS" =~ ^[0-9]+$ ]]; then
  AGE_THRESHOLD_DAYS=$((10#$AGE_THRESHOLD_DAYS))
else
  AGE_THRESHOLD_DAYS=30
fi

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

Options:
  --clean      Actually run 'uv cache prune' to reclaim orphaned uv cache entries.
  --dry-run    List disk-magician cache entries older than ${AGE_THRESHOLD_DAYS}d without pruning.
  -h, --help   Show this help.

Env:
  DISK_MAGICIAN_UV_CACHE_MIN_AGE_DAYS   Override the ${AGE_THRESHOLD_DAYS}-day reporting floor.
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

if ! command -v uv >/dev/null 2>&1; then
  log "uv not on PATH — nothing to do."
  exit 0
fi

UV_CACHE_DIR="$(uv cache dir 2>/dev/null || true)"
if [[ -z "$UV_CACHE_DIR" || ! -d "$UV_CACHE_DIR" ]]; then
  log "No uv cache dir found — nothing to do."
  exit 0
fi

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
log "Reporting floor: disk-magician cache entries older than ${AGE_THRESHOLD_DAYS} days"
log "Cache dir: $UV_CACHE_DIR"
log ""

before_kb=$(du -sk "$UV_CACHE_DIR" 2>/dev/null | awk '{print $1+0}')

stale_count=0
while IFS= read -r -d '' d; do
  kb=$(du -sk "$d" 2>/dev/null | awk '{print $1+0}')
  log "STALE (>=${AGE_THRESHOLD_DAYS}d): $d  (${kb} KB)"
  stale_count=$(( stale_count + 1 ))
done < <(find "$UV_CACHE_DIR/archive-v0" -maxdepth 1 -mindepth 1 -type d -mtime "+${AGE_THRESHOLD_DAYS}" \
            -exec sh -c 'ls "$1"/disk_magician* >/dev/null 2>&1' _ {} \; -print0 2>/dev/null)

log ""
log "disk-magician cache entries at/over the reporting floor: $stale_count"

if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN: would run 'uv cache prune' (safe — removes only entries unreachable"
  log "from every installed uv environment, cache-wide, not just disk-magician)."
  exit 0
fi

log "Running: uv cache prune"
if ! uv cache prune; then
  log "uv cache prune failed (non-fatal) — leaving cache untouched."
  exit 0
fi

after_kb=$(du -sk "$UV_CACHE_DIR" 2>/dev/null | awk '{print $1+0}')
freed_kb=$(( before_kb - after_kb ))
[[ "$freed_kb" -lt 0 ]] && freed_kb=0
log ""
log "Done. uv cache: $(( before_kb / 1024 )) MB -> $(( after_kb / 1024 )) MB (freed ~$(( freed_kb / 1024 )) MB)"

#!/usr/bin/env bash
# symlink-shared-gemini.sh
# Retired compatibility entrypoint. Agent Orchestrator owns per-session
# .gemini materialization; this script only retains safety-gated backup cleanup.
set -euo pipefail

DRY_RUN=true
DELETE_BACKUPS=false
AO_SESSIONS_DIR="$HOME/.ao-sessions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/safety_lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--delete-backups] [-h|--help]

The whole-root symlink mode is retired. Agent Orchestrator owns per-session
.gemini materialization.

Options:
  --clean                Actually perform the actions (default: dry-run).
  --dry-run              Print what would happen (default).
  --delete-backups       Delete the .gemini.bak.<timestamp> directories.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --delete-backups) DELETE_BACKUPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [[ "$DELETE_BACKUPS" == true ]]; then
  log "=== DELETE .gemini BACKUPS ==="
  if [[ "$DRY_RUN" == true ]]; then
    log "Mode: dry-run (use --clean to actually delete)"
  else
    log "Mode: CLEAN"
  fi
  [[ ! -d "$AO_SESSIONS_DIR" ]] && { log "Nothing to do."; exit 0; }
  deleted_count=0; deleted_bytes=0; skipped_protected=0
  while IFS= read -r bak_dir; do
    [[ -d "$bak_dir" ]] || continue
    if reason="$(safety_gate "$bak_dir")"; then
      :
    else
      log "  skip protected: $bak_dir ($reason)"
      skipped_protected=$((skipped_protected + 1))
      continue
    fi
    size_kb=$(du -sk "$bak_dir" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would delete: $bak_dir (~$((size_kb / 1024)) MB)"
    else
      rm -rf "$bak_dir"; log "  deleted: $bak_dir (~$((size_kb / 1024)) MB)"
    fi
    deleted_count=$((deleted_count + 1)); deleted_bytes=$((deleted_bytes + size_kb))
  done < <(find "$AO_SESSIONS_DIR" -maxdepth 2 -type d -name '.gemini.bak.*' 2>/dev/null)
  log "Deleted backup dirs: $deleted_count; protected skips: $skipped_protected; reclaimed $((deleted_bytes / 1024)) MB"
  exit 0
fi

log "Gemini whole-root dedup is retired; Agent Orchestrator owns per-session .gemini materialization."
log "No session data changed. Use --delete-backups for safety-gated legacy backup cleanup."

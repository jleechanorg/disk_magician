#!/usr/bin/env bash
# symlink-shared-gemini.sh
# Replace per-session .gemini copies in ~/.ao-sessions/ with symlinks to the host
# canonical ~/.gemini. Dry-run by default; --clean to apply.
set -euo pipefail

DRY_RUN=true
DELETE_BACKUPS=false
CANONICAL_GEMINI="$HOME/.gemini"
AO_SESSIONS_DIR="$HOME/.ao-sessions"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--delete-backups] [-h|--help]

Replace per-session .gemini trees with symlinks to the host canonical ~/.gemini.

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

relpath() {
  local target="$1" base="$2"
  if command -v realpath >/dev/null 2>&1 && realpath --relative-to="$base" "$target" >/dev/null 2>&1; then
    realpath --relative-to="$base" "$target"
  else
    python3 -c "import os.path,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$target" "$base"
  fi
}

if [[ "$DELETE_BACKUPS" == true ]]; then
  log "=== DELETE .gemini BACKUPS ==="
  [[ "$DRY_RUN" == true ]] && log "Mode: dry-run (use --clean to actually delete)" || log "Mode: CLEAN"
  [[ ! -d "$AO_SESSIONS_DIR" ]] && { log "Nothing to do."; exit 0; }
  deleted_count=0; deleted_bytes=0
  while IFS= read -r bak_dir; do
    [[ -d "$bak_dir" ]] || continue
    size_kb=$(du -sk "$bak_dir" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would delete: $bak_dir (~$((size_kb / 1024)) MB)"
    else
      rm -rf "$bak_dir"; log "  deleted: $bak_dir (~$((size_kb / 1024)) MB)"
    fi
    deleted_count=$((deleted_count + 1)); deleted_bytes=$((deleted_bytes + size_kb))
  done < <(find "$AO_SESSIONS_DIR" -maxdepth 2 -type d -name '.gemini.bak.*' 2>/dev/null)
  log "Deleted backup dirs: $deleted_count; reclaimed $((deleted_bytes / 1024)) MB"
  exit 0
fi

log "=== SYMLINK SHARED .gemini CONFIG ==="
[[ "$DRY_RUN" == true ]] && log "Mode: dry-run" || log "Mode: CLEAN"
log "Canonical: $CANONICAL_GEMINI"
[[ ! -d "$CANONICAL_GEMINI" ]] && { log "ERROR: canonical .gemini missing" >&2; exit 1; }
[[ ! -d "$AO_SESSIONS_DIR" ]] && { log "Nothing to do."; exit 0; }

replaced=0; skipped_link=0; skipped_missing=0
for session_dir in "$AO_SESSIONS_DIR"/*; do
  [[ -d "$session_dir" ]] || continue
  target_gemini="$session_dir/.gemini"
  if [[ ! -d "$target_gemini" && ! -L "$target_gemini" ]]; then skipped_missing=$((skipped_missing+1)); continue; fi
  if [[ -L "$target_gemini" ]]; then log "  skip (already symlink): $target_gemini"; skipped_link=$((skipped_link+1)); continue; fi
  size_kb=$(du -sk "$target_gemini" 2>/dev/null | awk '{print $1+0}' || echo 0)
  rel_target="$(relpath "$CANONICAL_GEMINI" "$session_dir")"
  bak="${target_gemini}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" == true ]]; then
    log "  [dry-run] would rename $target_gemini → $bak (~$((size_kb/1024)) MB)"
    log "  [dry-run] would ln -sfn '$rel_target' '$target_gemini'"
  else
    mv "$target_gemini" "$bak"; ln -sfn "$rel_target" "$target_gemini"
    log "  linked: $target_gemini → $rel_target (~$((size_kb/1024)) MB, backup: $bak)"
  fi
  replaced=$((replaced+1))
done
log "Replaced: $replaced; already symlinked: $skipped_link; missing: $skipped_missing"

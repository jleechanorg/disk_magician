#!/usr/bin/env bash
# symlink-shared-playwright-cache.sh
# Replace per-session playwright browser caches in ~/.ao-sessions/ with symlinks to a single
# canonical playwright cache (on the host at ~/Library/Caches/ms-playwright-go).
# Dry-run by default; --clean to apply.
#
# Strategy: We use the host's existing playwright cache as canonical,
# rename the session ones to <name>.bak.<timestamp>, and put symlinks
# at the original paths pointing to the canonical.
#
# Safety invariants:
#   - Dry-run by default; --clean required to actually modify
#   - Real caches are renamed to <name>.bak.<timestamp> (NEVER deleted)
#   - Already-symlinked caches are skipped (idempotent)
set -euo pipefail

DRY_RUN=true
DELETE_BACKUPS=false
CANONICAL_CACHE_VERSION="${PLAYWRIGHT_CANONICAL_VERSION:-1.57.0}"
CANONICAL_CACHE_BASE="$HOME/Library/Caches/ms-playwright-go"
CANONICAL_CACHE="$CANONICAL_CACHE_BASE/$CANONICAL_CACHE_VERSION"
CANONICAL_VERSION="$CANONICAL_CACHE_VERSION"
AO_SESSIONS_DIR="$HOME/.ao-sessions"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--delete-backups] [-h|--help]

Replace per-session playwright caches with symlinks to the host canonical cache.

Options:
  --clean                Actually perform the actions (default: dry-run).
  --dry-run              Print what would happen (default).
  --delete-backups       Delete the .bak.<timestamp> directories.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)
      DRY_RUN=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --delete-backups)
      DELETE_BACKUPS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

bootstrap_canonical_cache_from_host() {
  local candidate=""
  if [[ -d "$CANONICAL_CACHE_BASE" ]]; then
    candidate="$(find "$CANONICAL_CACHE_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
      sort -V | tail -1 || true)"
    if [[ -n "$candidate" ]]; then
      CANONICAL_CACHE="$candidate"
      CANONICAL_VERSION="$(basename "$CANONICAL_CACHE")"
      return 0
    fi
  fi
  return 1
}

select_largest_session_cache() {
  local chosen=""
  local max_kb=0
  local current_kb=0
  while IFS= read -r -d '' candidate; do
    [[ -d "$candidate" ]] || continue
    current_kb=$(du -sk "$candidate" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if (( current_kb > max_kb )); then
      max_kb=$current_kb
      chosen="$candidate"
    fi
  done < <(find "$AO_SESSIONS_DIR" -type d -path '*/Library/Caches/ms-playwright-go/*' -print0 2>/dev/null || true)
  printf '%s\n' "$chosen"
}

ensure_canonical_cache() {
  if [[ -d "$CANONICAL_CACHE" ]]; then
    CANONICAL_VERSION="$(basename "$CANONICAL_CACHE")"
    return 0
  fi

  if bootstrap_canonical_cache_from_host; then
    log "Canonical version missing; using existing host cache: $CANONICAL_CACHE"
    return 0
  fi

  local session_cache
  session_cache="$(select_largest_session_cache)"
  if [[ -z "$session_cache" ]]; then
    return 1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "Canonical cache missing and none exists under $CANONICAL_CACHE_BASE"
    log "  [dry-run] would use existing AO session cache as canonical: $session_cache"
  else
    CANONICAL_CACHE="$session_cache"
  fi
  CANONICAL_VERSION="$(basename "$CANONICAL_CACHE")"

  return 0
}

if [[ "$DELETE_BACKUPS" == true ]]; then
  if ! ensure_canonical_cache; then
    log "ERROR: Canonical playwright cache unavailable under $CANONICAL_CACHE_BASE and no AO session cache fallback was found." >&2
    exit 1
  fi
  log "=== DELETE PLAYWRIGHT CACHE BACKUPS ==="
  if [[ "$DRY_RUN" == true ]]; then
    log "Mode: dry-run (use --clean to actually delete)"
  else
    log "Mode: CLEAN (will delete existing backups)"
  fi
  log "Sessions dir: $AO_SESSIONS_DIR"
  log ""

  if [[ ! -d "$AO_SESSIONS_DIR" ]]; then
    log "Sessions dir $AO_SESSIONS_DIR does not exist. Nothing to do."
    exit 0
  fi

  deleted_count=0
  deleted_bytes=0

  while IFS= read -r bak_dir; do
    [[ -d "$bak_dir" ]] || continue
    size_kb=$(du -sk "$bak_dir" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would delete: $bak_dir (~$((size_kb / 1024)) MB)"
    else
      rm -rf "$bak_dir"
      log "  deleted: $bak_dir (~$((size_kb / 1024)) MB)"
    fi
    deleted_count=$((deleted_count + 1))
    deleted_bytes=$((deleted_bytes + size_kb))
  done < <(find "$AO_SESSIONS_DIR" -type d -path '*/Library/Caches/ms-playwright-go/*.bak.*' 2>/dev/null)

  log ""
  log "=== Summary ==="
  log "Deleted backup dirs: $deleted_count"
  log "Reclaimed space:     $((deleted_bytes / 1024)) MB"
  if [[ "$DRY_RUN" == true ]]; then
    log "This was a DRY-RUN. Re-run with --clean to apply."
  fi
  exit 0
fi

log "=== SYMLINK SHARED PLAYWRIGHT CACHE ==="
if [[ "$DRY_RUN" == true ]]; then
  log "Mode: dry-run (use --clean to actually replace)"
else
  log "Mode: CLEAN (will rename existing caches to .bak.<ts>)"
fi
log "Canonical cache path: $CANONICAL_CACHE"
log "Sessions dir: $AO_SESSIONS_DIR"
log ""

if ! ensure_canonical_cache; then
  log "ERROR: Canonical playwright cache not found at $CANONICAL_CACHE_BASE and no AO session fallback was found." >&2
  exit 1
fi
log "Canonical cache version in use: $CANONICAL_VERSION"

if [[ ! -d "$AO_SESSIONS_DIR" ]]; then
  log "Sessions dir $AO_SESSIONS_DIR does not exist. Nothing to do."
  exit 0
fi

relpath() {
  local target="$1" base="$2"
  if command -v realpath >/dev/null 2>&1 && realpath --relative-to="$base" "$target" >/dev/null 2>&1; then
    realpath --relative-to="$base" "$target"
  else
    python3 -c "import os.path,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$target" "$base"
  fi
}

replaced=0
skipped_link=0
skipped_no_cache=0

# Scan all directories in ~/.ao-sessions/ matching the common prefixes
for session_dir in "$AO_SESSIONS_DIR"/*; do
  [[ -d "$session_dir" ]] || continue
  
  target_cache_dir="$session_dir/Library/Caches/ms-playwright-go/$CANONICAL_VERSION"
  
  # Check if the session has a playwright cache directory
  if [[ ! -d "$target_cache_dir" && ! -L "$target_cache_dir" ]]; then
    skipped_no_cache=$((skipped_no_cache + 1))
    continue
  fi

  if [[ -L "$target_cache_dir" ]]; then
    log "  skip (already symlink): $target_cache_dir"
    skipped_link=$((skipped_link+1))
    continue
  fi

  # Compute size of the cache we are replacing
  size_kb=$(du -sk "$target_cache_dir" 2>/dev/null | awk '{print $1+0}' || echo 0)
  size_mb=$((size_kb / 1024))

  # Compute relative path from the cache's parent dir to the canonical cache.
  cache_parent_dir="$(dirname "$target_cache_dir")"
  rel_target="$(relpath "$CANONICAL_CACHE" "$cache_parent_dir")"
  bak="${target_cache_dir}.bak.$(date +%Y%m%d-%H%M%S)"

  if [[ "$DRY_RUN" == true ]]; then
    log "  [dry-run] would rename $target_cache_dir → $bak (~$size_mb MB)"
    log "  [dry-run] would ln -sfn '$rel_target' '$target_cache_dir'"
  else
    # Make sure parent directory exists before symlinking (should always exist)
    mkdir -p "$cache_parent_dir"
    mv "$target_cache_dir" "$bak"
    ln -sfn "$rel_target" "$target_cache_dir"
    log "  linked: $target_cache_dir → $rel_target (~$size_mb MB, backup: $bak)"
  fi
  replaced=$((replaced+1))
done

log ""
log "=== Summary ==="
log "Replaced/Linked:  $replaced"
log "Already symlinked: $skipped_link"
log "No cache present:  $skipped_no_cache"
if [[ "$DRY_RUN" == true ]]; then
  log "This was a DRY-RUN. Re-run with --clean to apply."
fi

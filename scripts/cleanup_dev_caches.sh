#!/usr/bin/env bash
# cleanup_dev_caches.sh — Cleanup dev tool caches that rebuild automatically.
#
# Defaults to actually deleting (use --dry-run to preview).
set -euo pipefail

DRY_RUN=false
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [-h|--help]

Options:
  --dry-run   Print what would be deleted without actually deleting
  -h|--help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  if [[ ! -e "$path" ]]; then echo 0; return; fi
  du -sk "$path" 2>/dev/null | awk '{print $1+0}'
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
    else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
    else                  printf \"%dK\", $kb
  }"
}

TOTAL_FREED_KB=0

clean_dir_contents() {
  local label="$1" path="$2" recreate="${3:-false}"

  if [[ ! -d "$path" ]]; then
    log "$label: directory not found, skipping"
    return
  fi

  local before_kb
  before_kb=$(size_kb "$path")
  log "$label: before $(fmt_kb "$before_kb") ($path)"

  if [[ "$DRY_RUN" == true ]]; then
    log "$label: [dry-run] would delete contents of $path"
    return
  fi

  find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  if [[ "$recreate" == true ]]; then
    mkdir -p "$path"
  fi

  local after_kb freed_kb
  after_kb=$(size_kb "$path")
  freed_kb=$(( before_kb - after_kb ))
  [[ $freed_kb -lt 0 ]] && freed_kb=0
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
  log "$label: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
}

# 1. ~/.gemini/tmp/
log "=== Section 1: ~/.gemini/tmp/ ==="
clean_dir_contents "gemini tmp" "$HOME/.gemini/tmp" true

# 2. ~/.cache/uv/
log "=== Section 2: ~/.cache/uv/ ==="
clean_dir_contents "uv cache" "$HOME/.cache/uv" false

# 3. ~/.cache/pre-commit/
log "=== Section 3: ~/.cache/pre-commit/ ==="
clean_dir_contents "pre-commit cache" "$HOME/.cache/pre-commit" false

# 4. opencode safe subdirs
log "=== Section 4: ~/.local/share/opencode/ (safe cache subdirs only) ==="
OPENCODE_DIR="$HOME/.local/share/opencode"
OPENCODE_SAFE_SUBDIRS=("repos" "log" "tool-output" "snapshot")
if [[ ! -d "$OPENCODE_DIR" ]]; then
  log "opencode data dir: not found, skipping"
else
  before_kb=$(size_kb "$OPENCODE_DIR")
  log "opencode data dir: before $(fmt_kb "$before_kb") ($OPENCODE_DIR)"

  for subdir in "${OPENCODE_SAFE_SUBDIRS[@]}"; do
    target="$OPENCODE_DIR/$subdir"
    [[ ! -d "$target" ]] && continue
    mapfile -d '' OLD_ENTRIES < <(
      find "$target" -mindepth 1 -maxdepth 1 -mtime +14 -print0 2>/dev/null
    )
    for entry in "${OLD_ENTRIES[@]}"; do
      if [[ "$DRY_RUN" == true ]]; then
        log "opencode $subdir/: [dry-run] would delete $entry"
      else
        log "opencode $subdir/: deleting $entry"
        rm -rf "$entry"
      fi
    done
  done

  if [[ "$DRY_RUN" != true ]]; then
    after_kb=$(size_kb "$OPENCODE_DIR")
    freed_kb=$(( before_kb - after_kb ))
    [[ $freed_kb -lt 0 ]] && freed_kb=0
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
    log "opencode data dir: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
  fi
fi

# 5. cursor-agent old versions
log "=== Section 5: cursor-agent old versions ==="
CURSOR_VERSIONS_DIR="$HOME/.local/share/cursor-agent/versions"
if [[ ! -d "$CURSOR_VERSIONS_DIR" ]]; then
  log "cursor-agent versions: directory not found, skipping"
else
  before_kb=$(size_kb "$CURSOR_VERSIONS_DIR")
  log "cursor-agent versions: before $(fmt_kb "$before_kb") ($CURSOR_VERSIONS_DIR)"

  mapfile -t ALL_VERSIONS < <(
    find "$CURSOR_VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort || true
  )

  KEEP=2
  TOTAL_VERSIONS=${#ALL_VERSIONS[@]}

  if [[ $TOTAL_VERSIONS -le $KEEP ]]; then
    log "cursor-agent versions: only $TOTAL_VERSIONS version(s) present, nothing to delete"
  else
    DELETE_COUNT=$(( TOTAL_VERSIONS - KEEP ))
    KEPT_VERSIONS=("${ALL_VERSIONS[@]:$DELETE_COUNT}")

    for (( i=0; i<DELETE_COUNT; i++ )); do
      entry="${ALL_VERSIONS[$i]}"
      if [[ "$DRY_RUN" == true ]]; then
        log "cursor-agent versions: [dry-run] would delete $entry"
      else
        log "cursor-agent versions: deleting $entry"
        rm -rf "$entry"
      fi
    done

    if [[ "$DRY_RUN" != true ]]; then
      after_kb=$(size_kb "$CURSOR_VERSIONS_DIR")
      freed_kb=$(( before_kb - after_kb ))
      [[ $freed_kb -lt 0 ]] && freed_kb=0
      TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
      log "cursor-agent versions: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
    fi
  fi
fi

# 6. ~/.npm/_cacache
log "=== Section 6: ~/.npm/_cacache ==="
clean_dir_contents "npm _cacache" "$HOME/.npm/_cacache" false

echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — no files deleted ==="
else
  log "=== Cleanup complete — total freed: $(fmt_kb "$TOTAL_FREED_KB") ==="
fi

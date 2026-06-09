#!/usr/bin/env bash
# cleanup_antigravity_brain.sh — Age-based sweeper for Google Antigravity task state.
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

  --clean     Actually execute cleanup (default: dry-run).
  -h|--help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

AG_BRAIN="$HOME/.gemini/antigravity/brain"
AGCLI_BRAIN="$HOME/.gemini/antigravity-cli/brain"
AG_WORKTREES="$HOME/.gemini/antigravity/worktrees"
AG_BACKUPS=(
  "$HOME/.gemini/antigravity/brain.backup"
  "$HOME/.gemini/antigravity/implicit.backup"
)

BRAIN_AGE_DAYS=21
WORKTREE_AGE_DAYS=14
BACKUP_AGE_DAYS=30

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  if [[ ! -e "$path" ]]; then echo 0; return; fi
  du -sk "$path" 2>/dev/null | awk '{print $1+0}'
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf "%.1fG", $kb / 1048576
    else if ($kb >= 1024) printf "%.0fM", $kb / 1024
    else                  printf "%dK", $kb
  }"
}

TOTAL_FREED_KB=0
DELETED_COUNT=0

delete_entry() {
  local label="$1" entry="$2"
  local base_name
  base_name=$(basename "$entry")
  case "$base_name" in
    conversations|settings.json|oauth_creds.json|knowledge|trustedFolders.json|mcp*)
      log "SAFEGUARD: skipping protected path $entry"
      return 0
      ;;
  esac
  local kb
  kb=$(size_kb "$entry")
  if [[ "$DRY_RUN" == true ]]; then
    log "$label: [dry-run] would delete $(basename "$entry") ($(fmt_kb "$kb"))"
  else
    log "$label: deleting $(basename "$entry") ($(fmt_kb "$kb"))"
    rm -rf "$entry"
  fi
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + kb ))
  DELETED_COUNT=$(( DELETED_COUNT + 1 ))
}

prune_old_children() {
  local label="$1" base="$2" age_days="$3"
  if [[ ! -d "$base" ]]; then
    log "$label: $base not found, skipping"
    return
  fi
  local before_kb; before_kb=$(size_kb "$base")
  log "$label: scanning $base (before $(fmt_kb "$before_kb"), cutoff >${age_days}d)"
  local entry
  while IFS= read -r -d '' entry; do
    delete_entry "$label" "$entry"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -mtime +"$age_days" -print0 2>/dev/null)
}

log "=== Section 1: Antigravity brain dirs (>${BRAIN_AGE_DAYS}d) ==="
prune_old_children "IDE brain"  "$AG_BRAIN"    "$BRAIN_AGE_DAYS"
prune_old_children "CLI brain"  "$AGCLI_BRAIN" "$BRAIN_AGE_DAYS"

log "=== Section 2: Antigravity idle worktrees (>${WORKTREE_AGE_DAYS}d) ==="
if [[ ! -d "$AG_WORKTREES" ]]; then
  log "worktrees: $AG_WORKTREES not found, skipping"
else
  while IFS= read -r -d '' entry; do
    delete_entry "worktree" "$entry"
  done < <(find "$AG_WORKTREES" -mindepth 2 -maxdepth 2 -type d -mtime +"$WORKTREE_AGE_DAYS" -print0 2>/dev/null)
fi

log "=== Section 3: stale .backup migration leftovers (>${BACKUP_AGE_DAYS}d) ==="
for bak in "${AG_BACKUPS[@]}"; do
  [[ -e "$bak" ]] || continue
  if [[ -n "$(find "$bak" -maxdepth 0 -mtime +"$BACKUP_AGE_DAYS" 2>/dev/null)" ]]; then
    delete_entry "backup leftover" "$bak"
  else
    log "backup leftover: $(basename "$bak") newer than ${BACKUP_AGE_DAYS}d, keeping"
  fi
done

echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — $DELETED_COUNT entrie(s), $(fmt_kb "$TOTAL_FREED_KB") reclaimable, nothing deleted ==="
else
  log "=== Cleanup complete — deleted $DELETED_COUNT entrie(s), freed $(fmt_kb "$TOTAL_FREED_KB") ==="
fi

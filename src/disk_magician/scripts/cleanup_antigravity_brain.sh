#!/usr/bin/env bash
# cleanup-antigravity-brain.sh — Age-based sweeper for Google Antigravity task state.
#
# Root cause this addresses:
#   Google Antigravity has NO built-in retention / TTL / max-disk / garbage-collection
#   control (verified 2026-06-09 against official Google AI Dev Forum + Gemini Apps
#   Community + on-disk config). Every agent task appends a persistent `brain/<uuid>/`
#   dir (memory + checkpoints) and, for PR work, a full repo `worktrees/` checkout.
#   Nothing ever cleans them up — 821 brain dirs accumulated over 5 months. The
#   `sessionRetention`/`maxAge` block some configs carry is FABRICATED and inert
#   (no Antigravity binary reads it). The only real bound is an external age-based
#   sweeper that WE control — never the agent (it once `rmdir /q`-wiped a user's
#   whole drive in Turbo mode), so paths here are pinned constants, never arguments.
#
# Usage:
#   ./scripts/cleanup_antigravity_brain.sh --clean    # apply cleanup (default: dry-run)
#   ./scripts/cleanup_antigravity_brain.sh --dry-run  # preview only
#
# What it prunes (by mtime — recently-touched/in-flight state is always preserved):
#   1. brain/<uuid>/ older than 21 days   (~/.gemini/antigravity + antigravity-cli)
#   2. worktrees/<project>/<branch>/ idle >14 days  (honors the 14-day worktree rule)
#   3. brain.backup / implicit.backup migration leftovers older than 30 days
#
# NEVER touched (hard-coded — not even considered):
#   - conversations/  (the .pb recovery source of truth — history rebuild depends on it)
#   - settings.json, oauth_creds.json, mcp*.json, knowledge/, trustedFolders.json,
#     installation_id, machineid, or any in-flight (recent-mtime) brain uuid.
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

  --clean     Actually delete/prune (default: dry-run preview).
  --dry-run   Print what would be deleted without deleting.
  -h|--help   Show this help.
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

# ── Pinned paths (constants — this script NEVER accepts a path argument) ───────
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

# ── Helpers ───────────────────────────────────────────────────────────────────

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
DELETED_COUNT=0

# Delete a single entry, tallying freed space. Honors dry-run.
delete_entry() {
  local label="$1" entry="$2"
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

# Prune immediate child dirs older than N days under a pinned base.
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

# ── Worktree recency helper (canonical fail-closed 14-day floor) ───────────────
_WT_RECENCY_PRUNE_NAMES=(.git node_modules venv .venv __pycache__ .pytest_cache .ruff_cache)

worktree_last_activity_epoch() {
    local wt="${1:-}" now newest=0 candidate
    now="$(date +%s)"
    [[ -n "$wt" && -d "$wt" ]] && [[ -r "$wt" ]] || { printf '%s\n' "$now"; return 0; }

    local prune_expr=() name first=true
    for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
        if [[ "$first" == true ]]; then
            prune_expr=(-name "$name")
            first=false
        else
            prune_expr+=(-o -name "$name")
        fi
    done
    candidate="$(find "$wt" \( "${prune_expr[@]}" \) -prune \
        -o -type f -exec stat -f '%m' {} + 2>/dev/null \
        | awk '$1+0>m{m=$1+0} END{if (m>0) print m}')" || candidate=""
    [[ -n "$candidate" ]] && (( candidate > newest )) && newest="$candidate"

    if (( newest <= 0 )); then
        printf '%s\n' "$now"
        return 0
    fi
    (( newest > now )) && newest="$now"
    printf '%s\n' "$newest"
}

worktree_age_days() {
    local now last
    now="$(date +%s)"
    last="$(worktree_last_activity_epoch "$1")"
    printf '%s\n' "$(( (now - last) / 86400 ))"
}

worktree_is_recently_active() {
    local wt="${1:-}" min_days="${2:-14}" age
    age="$(worktree_age_days "$wt")"
    (( age < min_days ))
}

# ── Section 1: brain/<uuid> dirs older than 21 days ──────────────────────────
log "=== Section 1: Antigravity brain dirs (>${BRAIN_AGE_DAYS}d) ==="
prune_old_children "IDE brain"  "$AG_BRAIN"    "$BRAIN_AGE_DAYS"
prune_old_children "CLI brain"  "$AGCLI_BRAIN" "$BRAIN_AGE_DAYS"

# ── Section 2: idle worktree branch checkouts older than 14 days ─────────────
# Layout: worktrees/<project>/<branch>/  → prune the depth-2 <branch> checkouts.
log "=== Section 2: Antigravity idle worktrees (>${WORKTREE_AGE_DAYS}d) ==="
if [[ ! -d "$AG_WORKTREES" ]]; then
  log "worktrees: $AG_WORKTREES not found, skipping"
else
  while IFS= read -r -d '' entry; do
    if worktree_is_recently_active "$entry" "$WORKTREE_AGE_DAYS"; then
      age_label="$(worktree_age_days "$entry" 2>/dev/null || echo 0)"
      log "worktree: skipping $(basename "$entry") (${age_label}d < ${WORKTREE_AGE_DAYS}d, active/protected)"
      continue
    fi
    delete_entry "worktree" "$entry"
  done < <(find "$AG_WORKTREES" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
fi

# ── Section 3: stale migration .backup leftovers older than 30 days ──────────
log "=== Section 3: stale .backup migration leftovers (>${BACKUP_AGE_DAYS}d) ==="
for bak in "${AG_BACKUPS[@]}"; do
  [[ -e "$bak" ]] || continue
  if [[ -n "$(find "$bak" -maxdepth 0 -mtime +"$BACKUP_AGE_DAYS" 2>/dev/null)" ]]; then
    delete_entry "backup leftover" "$bak"
  else
    log "backup leftover: $(basename "$bak") newer than ${BACKUP_AGE_DAYS}d, keeping"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — $DELETED_COUNT entrie(s), $(fmt_kb "$TOTAL_FREED_KB") reclaimable, nothing deleted ==="
else
  log "=== Cleanup complete — deleted $DELETED_COUNT entrie(s), freed $(fmt_kb "$TOTAL_FREED_KB") ==="
fi

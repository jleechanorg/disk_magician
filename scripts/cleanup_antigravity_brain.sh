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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Descendant recency helper (canonical fail-closed activity check) ───────────
brain_dir_last_activity_epoch() {
    local dir="${1:-}" now newest=0 candidate
    now="$(date +%s)"
    [[ -n "$dir" && -d "$dir" && -r "$dir" ]] || { printf '%s\n' "$now"; return 0; }

    local stat_mtime=(stat -f '%m')
    stat -f '%m' / >/dev/null 2>&1 || stat_mtime=(stat -c '%Y')

    local dir_mtime
    dir_mtime="$("${stat_mtime[@]}" "$dir" 2>/dev/null || echo 0)"
    (( dir_mtime > newest )) && newest="$dir_mtime"

    local mtimes
    if ! mtimes="$(find "$dir" -type f -exec "${stat_mtime[@]}" {} + 2>/dev/null)"; then
        # Traversal failed or incomplete -> fail closed (treat as active right now)
        printf '%s\n' "$now"
        return 0
    fi

    candidate="$(awk '$1+0>m{m=$1+0} END{if (m>0) print m}' <<<"$mtimes")"
    [[ -n "$candidate" ]] && (( candidate > newest )) && newest="$candidate"

    if (( newest <= 0 )); then
        printf '%s\n' "$now"
        return 0
    fi
    (( newest > now )) && newest="$now"
    printf '%s\n' "$newest"
}

brain_dir_age_days() {
    local now last
    now="$(date +%s)"
    last="$(brain_dir_last_activity_epoch "$1")"
    printf '%s\n' "$(( (now - last) / 86400 ))"
}

brain_dir_is_recently_active() {
    local dir="${1:-}" min_days="${2:-21}" age
    age="$(brain_dir_age_days "$dir")"
    (( age < min_days ))
}

# Prune immediate child dirs whose newest descendant is older than N days.
prune_old_children() {
  local label="$1" base="$2" age_days="$3"
  if [[ ! -d "$base" ]]; then
    log "$label: $base not found, skipping"
    return
  fi
  local real_base
  real_base="$(cd "$base" 2>/dev/null && pwd -P || true)"
  local before_kb; before_kb=$(size_kb "$base")
  log "$label: scanning $base (before $(fmt_kb "$before_kb"), cutoff >${age_days}d)"
  local entry
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" ]]; then
      log "$label: skipping symlink $(basename "$entry") (symlink-candidate)"
      continue
    fi
    local real_entry
    real_entry="$(cd "$entry" 2>/dev/null && pwd -P || true)"
    if [[ -z "$real_entry" || -z "$real_base" || "$real_entry" != "$real_base"/* ]]; then
      log "$label: skipping entry outside root $(basename "$entry")"
      continue
    fi
    if brain_dir_is_recently_active "$entry" "$age_days"; then
      local age_lbl
      age_lbl="$(brain_dir_age_days "$entry" 2>/dev/null || echo 0)"
      log "$label: skipping $(basename "$entry") (${age_lbl}d < ${age_days}d, active/protected)"
      continue
    fi
    delete_entry "$label" "$entry"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

# ── Section 1: brain/<uuid> dirs older than 21 days ──────────────────────────
log "=== Section 1: Antigravity brain dirs (>${BRAIN_AGE_DAYS}d) ==="
prune_old_children "IDE brain"  "$AG_BRAIN"    "$BRAIN_AGE_DAYS"
prune_old_children "CLI brain"  "$AGCLI_BRAIN" "$BRAIN_AGE_DAYS"

# ── Section 2: Antigravity idle worktrees (canonical guarded cleanup) ─────────
# Worktrees are strictly safety-gated: they must NEVER be deleted without
# WORKTREE_APPROVED=1, recency checks (>=7d floor), dirty/untracked/unpushed
# checks, live-process checks, and #110 squash-merge safeguards.
# Route worktree cleanup through the canonical guarded cleanup script.
log "=== Section 2: Antigravity worktrees (canonical cleanup_worktrees.sh) ==="
if [[ -f "$SCRIPT_DIR/cleanup_worktrees.sh" ]]; then
  WT_ARGS=(--min-age "$WORKTREE_AGE_DAYS" --repos none)
  if [[ "$DRY_RUN" == true ]]; then
    WT_ARGS+=(--dry-run)
  else
    WT_ARGS+=(--clean)
  fi
  bash "$SCRIPT_DIR/cleanup_worktrees.sh" "${WT_ARGS[@]}"
fi

# ── Section 3: stale migration .backup leftovers older than 30 days ──────────
log "=== Section 3: stale .backup migration leftovers (>${BACKUP_AGE_DAYS}d) ==="
for bak in "${AG_BACKUPS[@]}"; do
  [[ -e "$bak" ]] || continue
  if brain_dir_is_recently_active "$bak" "$BACKUP_AGE_DAYS"; then
    log "backup leftover: $(basename "$bak") newer than ${BACKUP_AGE_DAYS}d, keeping"
  else
    delete_entry "backup leftover" "$bak"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — $DELETED_COUNT entrie(s), $(fmt_kb "$TOTAL_FREED_KB") reclaimable, nothing deleted ==="
else
  log "=== Cleanup complete — deleted $DELETED_COUNT entrie(s), freed $(fmt_kb "$TOTAL_FREED_KB") ==="
fi

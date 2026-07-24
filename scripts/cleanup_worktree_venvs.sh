#!/usr/bin/env bash
# cleanup_worktree_venvs.sh — Strip Python venvs from dormant Git worktrees.
#
# Walks configured roots (default: ~/projects) and removes venv/.venv directories
# whose parent worktree is older than --min-age days (default 14, per the
# project worktree safety rule). The worktree shell (source + .git) is preserved;
# only the venv is removed. Re-create with `python -m venv .venv && pip install -r
# requirements.txt` if the worktree is revisited.
#
# Defaults to dry-run. To actually strip, the safety rule requires the literal
# `WORKTREE APPROVED` env var in addition to --clean, matching the worktree
# cleanup policy in the repo CLAUDE.md.
#
# Safety invariants:
#   - Never strips a venv whose parent worktree mtime is < --min-age
#   - Never strips a venv inside a base repo (only inside worktrees, detected
#     by the .git file pointer that `git worktree add` creates)
#   - Never strips a venv that is itself a symlink (already centralized)
#   - Never strips a venv whose parent lacks a readable .git pointer
#   - Refuses to run --clean without WORKTREE APPROVED=1 in the environment
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=true
MIN_AGE_DAYS=14
ROOTS=("$HOME/projects")

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--min-age N] [--roots p1,p2,...] [-h|--help]

Strip Python venvs from dormant Git worktrees.

Options:
  --clean                Actually strip the venvs (default: dry-run).
                         Requires WORKTREE APPROVED=1 in env.
  --dry-run              Print what would be stripped without touching disk.
  --min-age N            Minimum worktree age in days to qualify (default: 14).
  --roots p1,p2,...      Comma-separated root dirs to scan (default: $HOME/projects).
  -h, --help             Show this help.

Environment:
  WORKTREE APPROVED=1    Required to permit --clean. Aligns with the
                         worktree-safety rule in CLAUDE.md.

Examples:
  $(basename "$0") --dry-run
  $(basename "$0") --min-age 30 --dry-run
  WORKTREE APPROVED=1 $(basename "$0") --clean
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
    --min-age)
      [[ $# -ge 2 ]] || { echo "--min-age requires a value" >&2; exit 2; }
      MIN_AGE_DAYS="$2"
      shift 2
      ;;
    --roots)
      [[ $# -ge 2 ]] || { echo "--roots requires a value" >&2; exit 2; }
      IFS=',' read -ra ROOTS <<<"$2"
      shift 2
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

# Returns 0 if the path looks like a Git worktree (has a .git *file*, the
# marker `git worktree add` creates). Returns 1 if the path is a regular
# repo (has a .git *directory*) or not a Git checkout at all.
#
# We deliberately do NOT require the gitdir target directory to still exist.
# A long-dormant worktree whose parent repo has pruned its `.git/worktrees/`
# metadata will have a .git file pointing at a missing dir — but the file's
# presence is itself the signal that this dir was created as a worktree and
# the 14d age gate is the real safety check. Demanding the gitdir also exist
# would cause us to skip exactly the worktrees we most want to drain.
is_likely_worktree() {
  local p="$1"
  local git_path="$p/.git"

  # A regular repo has a .git directory; worktrees have a .git file.
  [[ -f "$git_path" ]] || return 1

  return 0
}

# Returns the worktree's "user activity" age in days (integer), or empty
# if stat fails. The proxy we use is the mtime of the `.git` *file* in the
# worktree, NOT the parent directory's mtime.
#
# Rationale: the parent dir's mtime updates on ANY change inside it,
# including our own `rm -rf venv` calls. After one cleanup pass, every
# worktree reports age=0 and the next pass classifies everything as
# "too young," silently skipping the actual dormant pool. The `.git` file
# pointer is only touched by git operations (checkout, merge, rebase,
# status, worktree repair) — i.e. actual user activity — so its mtime is
# a much cleaner signal of "when was this worktree last used?"
#
# Falls back to the parent dir mtime if the .git file is missing (shouldn't
# happen for anything that passed is_likely_worktree, but defense-in-depth).
worktree_age_days() {
  local p="$1"
  local mtime_epoch
  # Prefer the .git file mtime; fall back to parent dir mtime.
  mtime_epoch=$(stat -f '%m' "$p/.git" 2>/dev/null || true)
  if [[ -z "$mtime_epoch" ]]; then
    mtime_epoch=$(stat -f '%m' "$p" 2>/dev/null || true)
  fi
  [[ -n "$mtime_epoch" ]] || { echo ""; return; }
  local now
  now=$(date +%s)
  echo $(( (now - mtime_epoch) / 86400 ))
}

# Detects venv dirs that are already centralized (symlinks) or are broken
# symlinks. Returns 0 if the venv should be skipped from stripping.
is_already_centralized_or_broken() {
  local venv_path="$1"

  # -L follows the symlink; if it does not resolve, the link is broken.
  if [[ -L "$venv_path" ]]; then
    if [[ -e "$venv_path" ]]; then
      log "  skip (symlink to existing target — already centralized): $venv_path"
    else
      log "  skip (broken symlink): $venv_path"
    fi
    return 0
  fi
  return 1
}

# Gate: refuse --clean without the explicit approval token, matching the
# repo worktree-safety rule (which guards against accidental mass deletion).
if [[ "$DRY_RUN" == false ]]; then
  if [[ "${WORKTREE_APPROVED:-}" != "1" ]]; then
    echo "ERROR: --clean requires WORKTREE APPROVED=1 in the environment." >&2
    echo "       This script strips files inside Git worktrees, which the" >&2
    echo "       repo CLAUDE.md flags as requiring explicit approval." >&2
    echo "" >&2
    echo "Re-run as:" >&2
    echo "  WORKTREE APPROVED=1 $0 --clean" >&2
    exit 3
  fi
fi

log "=== STRIP DORMANT WORKTREE VENVS ==="
if [[ "$DRY_RUN" == true ]]; then
  log "Mode: dry-run (use WORKTREE APPROVED=1 $0 --clean to actually strip)"
else
  log "Mode: CLEAN (destructive)"
fi
log "Min age:    ${MIN_AGE_DAYS} days"
log "Roots:      ${ROOTS[*]}"
log ""

# Candidate venv dirnames. Covers both `venv` and `.venv` (the dominant
# conventions across the 156 worktrees in ~/projects).
VENV_NAMES=(venv .venv)

# Per-venv safety: we only strip a venv whose *parent* is a worktree (not
# a base repo) AND whose parent is older than MIN_AGE_DAYS. The find is
# bounded to depth 6 to catch nested patterns like
#   <root>/<repo>/.claude/worktrees/<branch>/.venv
# without descending into the venv itself (which we are about to measure).
TOTAL_FREED_KB=0
STRIPPED_COUNT=0
SKIPPED_NOT_WORKTREE=0
SKIPPED_TOO_YOUNG=0
SKIPPED_ALREADY_CENTRALIZED=0
SKIPPED_NO_VENV=0
INSPECTED=0

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || { log "Root missing, skipping: $root"; continue; }
  log "Scanning $root ..."

  for venv_name in "${VENV_NAMES[@]}"; do
    # Find every venv dir directly; the parent is the worktree candidate.
    while IFS= read -r -d '' venv_path; do
      INSPECTED=$(( INSPECTED + 1 ))
      parent="$(dirname "$venv_path")"

      # Defensive: refuse if parent is not a worktree (e.g. venv inside the
      # base repo, where the user is actively working).
      if ! is_likely_worktree "$parent"; then
        SKIPPED_NOT_WORKTREE=$(( SKIPPED_NOT_WORKTREE + 1 ))
        continue
      fi

      # Skip symlinked / broken venvs.
      if is_already_centralized_or_broken "$venv_path"; then
        SKIPPED_ALREADY_CENTRALIZED=$(( SKIPPED_ALREADY_CENTRALIZED + 1 ))
        continue
      fi

      # Age gate: parent worktree must be older than the threshold.
      age_days="$(worktree_age_days "$parent")"
      if [[ -z "$age_days" ]]; then
        log "  skip (could not stat parent): $venv_path"
        continue
      fi
      if (( age_days < MIN_AGE_DAYS )); then
        SKIPPED_TOO_YOUNG=$(( SKIPPED_TOO_YOUNG + 1 ))
        continue
      fi

      venv_kb=$(size_kb "$venv_path")
      venv_pretty=$(fmt_kb "$venv_kb")

      if [[ "$DRY_RUN" == true ]]; then
        log "  [dry-run] would strip $venv_path (${venv_pretty}, parent ${age_days}d old)"
        TOTAL_FREED_KB=$(( TOTAL_FREED_KB + venv_kb ))
        STRIPPED_COUNT=$(( STRIPPED_COUNT + 1 ))
      else
        log "  stripping $venv_path (${venv_pretty}, parent ${age_days}d old)"
        if ! _safety_reason="$(safety_gate "$venv_path" 2>/dev/null)"; then
          echo "SAFETY-SKIP $venv_path ($_safety_reason)"
        elif rm -rf "$venv_path" 2>/dev/null; then
          TOTAL_FREED_KB=$(( TOTAL_FREED_KB + venv_kb ))
          STRIPPED_COUNT=$(( STRIPPED_COUNT + 1 ))
        else
          log "    FAILED to remove $venv_path"
        fi
      fi
    done < <(find "$root" -mindepth 2 -maxdepth 6 -type d -name "$venv_name" -print0 2>/dev/null || true)
  done
done

log ""
log "=== Summary ==="
log "  Inspected venv dirs:    $INSPECTED"
log "  Stripped:               $STRIPPED_COUNT  ($(fmt_kb "$TOTAL_FREED_KB"))"
log "  Skipped (not worktree): $SKIPPED_NOT_WORKTREE"
log "  Skipped (too young):    $SKIPPED_TOO_YOUNG  (< ${MIN_AGE_DAYS} days old)"
log "  Skipped (centralized):  $SKIPPED_ALREADY_CENTRALIZED  (symlink / broken)"
if [[ "$DRY_RUN" == true ]]; then
  log ""
  log "This was a DRY-RUN. Re-run with WORKTREE APPROVED=1 $0 --clean to apply."
fi

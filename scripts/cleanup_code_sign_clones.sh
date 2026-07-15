#!/usr/bin/env bash
# cleanup_code_sign_clones.sh — Remove stale macOS app code_sign_clone caches.
#
# Apps (Aside, Chrome, Codex, etc.) extract signed bundles into
# $DARWIN_USER_TEMP_DIR/../X/*.code_sign_clone during launch. Safe to
# delete when the app is quit; they rebuild on next launch.
#
# Defaults to DRY-RUN; pass --clean to delete (requires CODE_SIGN_CLONES_APPROVED=1).
set -euo pipefail

DRY_RUN=true
MIN_KB="${CODE_SIGN_CLONE_MIN_KB:-102400}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Delete stale *.code_sign_clone directories under the user's var/folders X cache.

Options:
  --clean      Actually delete (requires CODE_SIGN_CLONES_APPROVED=1)
  --dry-run    Preview only (default)
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && "${CODE_SIGN_CLONES_APPROVED:-0}" != "1" ]]; then
  echo "Refusing code_sign_clone deletion: set CODE_SIGN_CLONES_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

path_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0}' || echo 0
}

path_identity() {
  stat -f '%d:%i:%u' "$1" 2>/dev/null || stat -c '%d:%i:%u' "$1" 2>/dev/null
}

path_mtime() {
  stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$1" 2>/dev/null \
    || stat -c '%y' "$1" 2>/dev/null \
    || echo unknown
}

lsof_state() {
  local candidate="$1" output rc=0 pid command
  output=$(lsof -Fpcn +D "$candidate" 2>/dev/null) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pid=$(awk '/^p/{sub(/^p/, ""); print; exit}' <<<"$output")
    command=$(awk '/^c/{sub(/^c/, ""); print; exit}' <<<"$output")
    LSOF_DETAIL="pid=${pid:-unknown} command=${command:-unknown}"
    return 0
  fi
  [[ "$rc" -eq 1 ]] && return 1
  LSOF_DETAIL="rc=$rc"
  return 2
}

resolve_x_dir() {
  local user_tmp
  user_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "")
  [[ -n "$user_tmp" ]] || return 1
  user_tmp=$(cd "$user_tmp" && pwd -P 2>/dev/null) || return 1
  local x_dir
  x_dir="$(dirname "$user_tmp")/X"
  [[ -d "$x_dir" ]] || return 1
  printf '%s\n' "$x_dir"
}

X_DIR=""
X_DIR=$(resolve_x_dir) || {
  log "code_sign_clone: DARWIN_USER_TEMP_DIR X parent not found — nothing to do."
  exit 0
}

log "$(dry_prefix)code_sign_clone cleanup starting (scan: $X_DIR)"

if ! command -v lsof >/dev/null 2>&1; then
  log "lsof unavailable — preserving all candidates; open handles cannot be proven absent."
  exit 0
fi

CURRENT_UID=$(id -u)
X_IDENTITY=$(path_identity "$X_DIR") || {
  log "Unsafe scan root identity — preserving all candidates: $X_DIR"
  exit 0
}
if [[ "${X_IDENTITY##*:}" != "$CURRENT_UID" ]]; then
  log "Unsafe scan root owner uid=${X_IDENTITY##*:}, expected uid=$CURRENT_UID — preserving all candidates: $X_DIR"
  exit 0
fi

# Freeze both the candidate paths and their filesystem identities before any
# lsof checks. Revalidation below prevents a replaced path from being removed.
CANDIDATES=()
CANDIDATE_IDENTITIES=()
while IFS= read -r -d '' candidate; do
  candidate_identity=$(path_identity "$candidate") || continue
  CANDIDATES[${#CANDIDATES[@]}]="$candidate"
  CANDIDATE_IDENTITIES[${#CANDIDATE_IDENTITIES[@]}]="$candidate_identity"
done < <(find -P "$X_DIR" -mindepth 1 -maxdepth 1 -type d -name '*code_sign_clone' -print0 2>/dev/null || true)

DIRS_REMOVED=0
TOTAL_KB=0

for i in "${!CANDIDATES[@]}"; do
  d="${CANDIDATES[$i]}"
  frozen_identity="${CANDIDATE_IDENTITIES[$i]}"
  kb=$(path_size_kb "$d")
  if [[ "$kb" -lt "$MIN_KB" ]]; then
    continue
  fi

  current_identity=$(path_identity "$d" 2>/dev/null || true)
  if [[ -z "$current_identity" || "$current_identity" != "$frozen_identity" \
        || "${current_identity##*:}" != "$CURRENT_UID" \
        || -L "$d" || "$(dirname "$d")" != "$X_DIR" ]]; then
    log "Unsafe candidate ownership or identity changed — preserving: $d"
    continue
  fi

  LSOF_DETAIL=""
  if lsof_state "$d"; then
    log "ACTIVE — preserving: $d  (${kb} KB, mtime=$(path_mtime "$d"), $LSOF_DETAIL)"
    continue
  else
    lsof_rc=$?
  fi
  if [[ "$lsof_rc" -ne 1 ]]; then
    log "Skipping code_sign_clones: lsof failed for $d  (${LSOF_DETAIL:-unknown})"
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: INACTIVE candidate: $d  (${kb} KB, mtime=$(path_mtime "$d"))"
  else
    # Recheck handles immediately before removal, then verify that neither the
    # candidate nor its trusted parent changed while lsof was running.
    LSOF_DETAIL=""
    if lsof_state "$d"; then
      log "ACTIVE on final recheck — preserving: $d  (${kb} KB, $LSOF_DETAIL)"
      continue
    else
      lsof_rc=$?
    fi
    if [[ "$lsof_rc" -ne 1 ]]; then
      log "Skipping code_sign_clones: final lsof failed for $d  (${LSOF_DETAIL:-unknown})"
      continue
    fi
    final_identity=$(path_identity "$d" 2>/dev/null || true)
    final_x_identity=$(path_identity "$X_DIR" 2>/dev/null || true)
    if [[ "$final_identity" != "$frozen_identity" || "$final_x_identity" != "$X_IDENTITY" ]]; then
      log "Candidate changed after lsof recheck — preserving: $d"
      continue
    fi
    log "Removing: $d  (${kb} KB)"
    rm -rf "$d"
  fi
  TOTAL_KB=$(( TOTAL_KB + kb ))
  DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
done

log "$(dry_prefix)Done. Dirs removed: ${DIRS_REMOVED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"

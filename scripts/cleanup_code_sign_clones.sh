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

DIRS_REMOVED=0
TOTAL_KB=0

while IFS= read -r -d '' d; do
  kb=$(path_size_kb "$d")
  if [[ "$kb" -lt "$MIN_KB" ]]; then
    continue
  fi

  if [[ "$DRY_RUN" != true ]] && command -v lsof >/dev/null 2>&1; then
    lsof_rc=0
    lsof +D "$d" >/dev/null 2>&1 || lsof_rc=$?
    if [[ "${lsof_rc:-0}" -eq 0 ]]; then
      log "Skipping in-use code_sign_clone: $d  (${kb} KB)"
      unset -v lsof_rc
      continue
    elif [[ "${lsof_rc:-0}" -ne 1 ]]; then
      log "Skipping code_sign_clones: lsof failed for $d  (${lsof_rc:-0})"
      unset -v lsof_rc
      continue
    fi
    unset -v lsof_rc
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove: $d  (${kb} KB)"
  else
    log "Removing: $d  (${kb} KB)"
    rm -rf "$d"
  fi
  TOTAL_KB=$(( TOTAL_KB + kb ))
  DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
done < <(find "$X_DIR" -mindepth 1 -maxdepth 1 -type d -name '*code_sign_clone' -print0 2>/dev/null || true)

log "$(dry_prefix)Done. Dirs removed: ${DIRS_REMOVED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"

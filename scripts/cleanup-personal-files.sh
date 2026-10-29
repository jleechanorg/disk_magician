#!/usr/bin/env bash
# cleanup-personal-files.sh — preview or remove large personal download files
# and old screenshot files without recursively touching user directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/safety_lib.sh"

DOWNLOADS_ROOT="${DISK_MAGICIAN_DOWNLOADS_ROOT:-$HOME/Downloads}"
SCREENSHOT_ROOT="${DISK_MAGICIAN_SCREENSHOT_ROOT:-$HOME/Pictures/Screenshots}"
DESKTOP_ROOT="${DISK_MAGICIAN_DESKTOP_ROOT:-$HOME/Desktop}"
DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Preview or remove top-level regular Downloads files >=100 MiB and screenshot
files in Pictures/Screenshots or Desktop. Directories and symlinks are kept.
--clean requires PERSONAL_FILES_APPROVED=1.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --clean) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$DRY_RUN" == false && "${PERSONAL_FILES_APPROVED:-0}" != 1 ]]; then
  echo "Refusing personal-file deletion: set PERSONAL_FILES_APPROVED=1 after reviewing dry-run output." >&2
  exit 2
fi

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

file_mtime() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' -- "$1" 2>/dev/null
}

is_open() {
  local path="$1" output rc=0
  if [[ -d /proc ]] && command -v timeout >/dev/null 2>&1; then
    output="$(timeout -k 1 5 find /proc/[0-9]*/fd -maxdepth 1 -lname "$path" -print -quit 2>/dev/null)" || rc=$?
    if [[ "$rc" -gt 1 ]]; then
      log "Open-file check timed out or failed; preserving: $path"
      return 0
    fi
    [[ -n "$output" ]] && { log "Open-file holder found; preserving: $path"; return 0; }
    return 1
  fi
  log "Open-file check unavailable; preserving: $path"
  return 0
}

protected_name() {
  local base="${1##*/}"
  [[ "$base" =~ (^|\.)\.env($|\.) || "$base" =~ (credentials|secret|token|password|private|\.pem$|\.key$|\.p12$|\.pfx$) ]]
}

newest_screenshot=""
newest_mtime=-1
for root in "$SCREENSHOT_ROOT" "$DESKTOP_ROOT"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    [[ "$base" =~ [Ss]creenshot|[Ss]creen[[:space:]_-]*[Ss]hot ]] || continue
    mtime="$(file_mtime "$path")" || continue
    if (( mtime > newest_mtime )); then
      newest_mtime=$mtime
      newest_screenshot="$path"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
done

consider() {
  local path="$1" reason="$2" size=0
  [[ -f "$path" && ! -L "$path" ]] || return 0
  if ! safety_gate "$path" >/dev/null 2>&1; then
    log "Safety policy denied; preserving: $path"
    return 0
  fi
  protected_name "$path" && { log "Preserving protected filename: $path"; return 0; }
  if is_open "$path"; then return 0; fi
  size="$(stat -c '%s' -- "$path" 2>/dev/null || stat -f '%z' -- "$path" 2>/dev/null || echo 0)"
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove $reason ($size bytes): $path"
  else
    log "Removing $reason ($size bytes): $path"
    rm_logged "$path" --file
  fi
}

log "$( [[ "$DRY_RUN" == true ]] && echo 'DRY RUN:' || echo 'APPLY:' ) personal-file cleanup"
if [[ -d "$DOWNLOADS_ROOT" ]]; then
  while IFS= read -r -d '' path; do
    consider "$path" "large download"
  done < <(find "$DOWNLOADS_ROOT" -mindepth 1 -maxdepth 1 -type f -size +100M -print0 2>/dev/null)
fi

for root in "$SCREENSHOT_ROOT" "$DESKTOP_ROOT"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    [[ "$base" =~ [Ss]creenshot|[Ss]creen[[:space:]_-]*[Ss]hot ]] || continue
    [[ "$path" == "$newest_screenshot" ]] && { log "Keeping newest screenshot: $path"; continue; }
    consider "$path" "old screenshot"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
done

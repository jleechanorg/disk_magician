#!/usr/bin/env bash
# cleanup_dirs_cleaner.sh — Safe remediation for /private/var/dirs_cleaner accumulation.
#
# Remediation for Apple CacheDelete.framework / deleted_helper ENAMETOOLONG bug
# where staged purgeable content accumulates under /private/var/dirs_cleaner/.
# Uses find -delete (fd-relative) to avoid Apple's removefile ENAMETOOLONG bug.
set -euo pipefail

CLEAN=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=true; DRY_RUN=false; shift ;;
    --dry-run) CLEAN=false; DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--clean|--dry-run]"
      echo "Safely cleans contents of /private/var/dirs_cleaner after verifying deleted_helper is idle."
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TARGET_DIR="${DISK_MAGICIAN_DIRS_CLEANER_TARGET:-/private/var/dirs_cleaner}"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Target directory $TARGET_DIR does not exist. No-op."
  exit 0
fi

# Pre-check: verify deleted_helper or dirs_cleaner daemon processes are NOT running
if [[ "${DISK_MAGICIAN_SKIP_PS_CHECK:-0}" != "1" ]]; then
  if ps aux | grep -v grep | grep -v "cleanup_dirs_cleaner" | grep -v "test_cleanup_dirs_cleaner" | grep -E "deleted_helper|/usr/libexec/dirs_cleaner" >/dev/null 2>&1; then
    echo "ERROR: deleted_helper or dirs_cleaner process is active. Deferring cleanup." >&2
    exit 1
  fi
fi

SIZE_MB="$(sudo -n du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}' || du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}' || echo "0")"
echo "Found $TARGET_DIR size: ${SIZE_MB} MB"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] Would clean contents of $TARGET_DIR using find -delete per batch."
  exit 0
fi

echo "Cleaning contents of $TARGET_DIR..."
# Delete contents batch by batch (mindepth 1)
sudo -n find "$TARGET_DIR" -mindepth 1 -delete 2>&1 || find "$TARGET_DIR" -mindepth 1 -delete 2>&1 || true

AFTER_SIZE_MB="$(sudo -n du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}' || du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}' || echo "0")"
echo "Done. $TARGET_DIR new size: ${AFTER_SIZE_MB} MB"

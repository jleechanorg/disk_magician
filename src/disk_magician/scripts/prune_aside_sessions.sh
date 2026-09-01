#!/usr/bin/env bash
# prune_aside_sessions.sh — Prune stale Aside browser sessions and deduplicate static assets.
#
# Defaults to dry-run (pass --clean or --apply to actually delete/dedup).
#
# Policy (bead disk_magician-18q):
#   - Signal A: Session folder age >= max_age_days (via date prefix YYYY-MM-DD or mtime).
#   - Signal B: lsof confirms no active browser/aside processes hold open handles.
#   - Dedup duplicate static assets across retained sessions via hardlinks.
#   - Safety check: never delete non-session folders or root/system directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source safety_lib if present
# shellcheck source=scripts/safety_lib.sh
if [[ -f "$SCRIPT_DIR/safety_lib.sh" ]]; then
  source "$SCRIPT_DIR/safety_lib.sh"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean|--apply] [--dry-run] [--max-age-days N] [--days N]
                       [--aside-dir PATH] [--sessions-dir PATH] [--no-dedup]
                       [--json] [-v|--verbose] [-h|--help]

Prune stale Aside browser sessions (~/.aside/u/*/sessions/) and deduplicate assets.

Options:
  --clean, --apply     Execute actual deletion of stale sessions and deduplication (default: dry-run)
  --dry-run            Preview actions without modifying or deleting files (default)
  --max-age-days N     Age threshold in days for session pruning (default: 7)
  --days N             Alias for --max-age-days
  --aside-dir PATH     Override path to ~/.aside directory
  --sessions-dir PATH  Override path to a specific sessions directory (repeatable)
  --no-dedup           Disable static asset deduplication across retained sessions
  --json               Output summary in JSON format
  -v, --verbose        Enable verbose per-session logging
  -h, --help           Show this help message
EOF
}

# Pass all arguments through to python implementation
PYTHON_BIN="$(command -v python3 || echo "python3")"
if ! command -v "$PYTHON_BIN" &>/dev/null; then
  echo "Error: python3 is required to run prune_aside_sessions." >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

exec "$PYTHON_BIN" "$SCRIPT_DIR/prune_aside_sessions.py" "$@"

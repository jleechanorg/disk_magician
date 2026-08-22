#!/usr/bin/env bash
# cleanup_antigravity_brain.sh — Safe compaction and retention tool for Antigravity brain.
#
# Defaults to dry-run (use --clean to actually compact).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=true
THRESHOLD_DAYS=14
BRAIN_DIR="${HOME}/.gemini/antigravity-cli/brain"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--days N] [--brain-dir PATH] [-h|--help]

Safe compaction and retention tool for Antigravity brain:
  - Losslessly compresses stale task-*.log and transcript_full.jsonl (>N days)
  - Cleans stale scratch files in completed sessions (>N days)
  - Prunes empty 0-byte abandoned session dirs (>N days)
  - Preserves 100% of active sessions (<24h), user-facing markdown artifacts, and recent logs

Options:
  --clean           Actually apply compaction (default: dry-run preview)
  --dry-run         Run in preview mode without modifying files (default)
  --days N          Age threshold in days (default: 14)
  --brain-dir PATH  Override brain directory path
  -h, --help        Show this help message
EOF
}

EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --days)    shift; THRESHOLD_DAYS="${1:?--days requires a number}" ;;
    --brain-dir) shift; BRAIN_DIR="${1:?--brain-dir requires a path}" ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA_ARGS+=("$1") ;;
  esac
  shift
done

if [[ ! -d "$BRAIN_DIR" ]]; then
  echo "No brain directory at $BRAIN_DIR — nothing to do."
  exit 0
fi

CMD=(python3 "$SCRIPT_DIR/cleanup_antigravity_brain.py" --days "$THRESHOLD_DAYS" --brain-dir "$BRAIN_DIR")
if [[ "$DRY_RUN" == false ]]; then
  CMD+=(--clean)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

"${CMD[@]}"

#!/usr/bin/env bash
# cleanup_docker.sh — Prune Docker objects while preserving active containers and volumes.
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Options:
  --clean     Run docker system prune -a -f.
  --dry-run   Show docker system df and planned prune command.
  -h, --help  Show this help.
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

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"

if ! command -v docker >/dev/null 2>&1; then
  log "docker not found; skipping."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "docker daemon not reachable; skipping."
  exit 0
fi

log "Current docker usage:"
docker system df 2>/dev/null || true

if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] would run: docker system prune -a -f"
  log "Volumes are not pruned by this script."
else
  log "running: docker system prune -a -f"
  docker system prune -a -f || true
fi

log "Docker usage after planned/applied cleanup:"
docker system df 2>/dev/null || true

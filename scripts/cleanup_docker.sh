#!/usr/bin/env bash
# cleanup_docker.sh — Docker build cache + image prune and VM disk TRIM.
#
# Defaults to dry-run (use --clean to actually execute).
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

  --clean     Actually execute prune and TRIM (default: dry-run).
  -h|--help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
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
    if ($kb >= 1048576)  printf "%.1fG", $kb / 1048576
    else if ($kb >= 1024) printf "%.0fM", $kb / 1024
    else                  printf "%dK", $kb
  }"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@" || log "WARNING: command failed: $*"
  fi
}

DOCKER_RAW="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found on PATH — nothing to do. Exiting."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "Docker daemon not running (or wedged) — skipping prune/TRIM. Exiting 0."
  exit 0
fi

before_kb=$(size_kb "$DOCKER_RAW")
log "Docker.raw before: $(fmt_kb "$before_kb") ($DOCKER_RAW)"
log "=== docker system df (before) ==="
docker system df || true

log "=== Section 1: docker builder prune ==="
# Using the non-deprecated --reserved-space option
if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] docker builder prune -af --reserved-space 5g (or --keep-storage 5g)"
else
  log "+ docker builder prune"
  docker builder prune -af --reserved-space 5g 2>/dev/null || docker builder prune -af --keep-storage 5g || log "WARNING: builder prune failed"
fi

log "=== Section 2: docker image prune ==="
run docker image prune -af

log "=== Section 3: reclaim/TRIM Docker.raw ==="
run docker run --rm --privileged --pid=host docker/desktop-reclaim-space

echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — nothing pruned ==="
else
  after_kb=$(size_kb "$DOCKER_RAW")
  freed_kb=$(( before_kb - after_kb ))
  [[ $freed_kb -lt 0 ]] && freed_kb=0
  log "Docker.raw after: $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
  log "=== docker system df (after) ==="
  docker system df || true
  log "=== Cleanup complete ==="
fi

#!/usr/bin/env bash
# cleanup-docker.sh — Weekly Docker build-cache + dangling-image prune and VM disk TRIM.
#
# Root cause this addresses:
#   Docker.raw is a sparse VM disk image with a high-water mark. The self-hosted
#   GitHub Actions runners on this machine do `docker build` / `docker compose`
#   across ~10 repos; Docker never auto-prunes, so build cache and dangling images
#   pile up inside the VM and the host Docker.raw grows monotonically and never
#   shrinks on its own (132 GiB had to be reclaimed manually on 2026-06-09).
#
# Usage:
#   ./scripts/cleanup_docker.sh --clean    # apply prune + TRIM (default: dry-run)
#   ./scripts/cleanup_docker.sh --dry-run  # preview the commands only
#
# What it does (ONLY when the Docker daemon is healthy):
#   1. docker builder prune -af --keep-storage 5g  — drop build cache, keep 5g hot
#   2. docker image prune -af                       — remove dangling/unreferenced images
#   3. docker/desktop-reclaim-space TRIM            — shrink the host Docker.raw
#
# Safe by design:
#   - If the Docker daemon is not running (or `docker` is absent), it exits 0
#     without doing anything. A wedged daemon must never block this job, and there
#     is nothing to prune when the daemon is down.
#   - Never passes --volumes, so named volumes (persistent data) always survive.
#   - --dry-run prints the planned commands without executing them.
set -euo pipefail

DRY_RUN=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

  --clean     Actually delete/prune (default: dry-run preview).
  --dry-run   Print what would run without pruning or TRIMming.
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

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Allocated size in KB for a (possibly sparse) path; 0 if missing.
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

# Run a docker command, honoring dry-run.
run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@" || log "WARNING: command failed (continuing): $*"
  fi
}

DOCKER_RAW="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"

# ── Pre-flight: docker binary + healthy daemon ────────────────────────────────

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

# ── Section 1: build cache prune (keep 5g hot) ───────────────────────────────

log "=== Section 1: docker builder prune ==="
run docker builder prune -af --keep-storage 5g

# ── Section 2: dangling/unreferenced image prune ─────────────────────────────

log "=== Section 2: docker image prune ==="
run docker image prune -af

# ── Section 3: TRIM the host Docker.raw (shrink the sparse high-water mark) ───
# Pruning frees blocks INSIDE the VM ext4, but the host Docker.raw does not shrink
# without an explicit TRIM. docker/desktop-reclaim-space is the official mechanism.

log "=== Section 3: reclaim/TRIM Docker.raw ==="
run docker run --rm --privileged --pid=host docker/desktop-reclaim-space

# ── Summary ───────────────────────────────────────────────────────────────────

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

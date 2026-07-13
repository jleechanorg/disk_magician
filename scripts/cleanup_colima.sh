#!/usr/bin/env bash
# cleanup_colima.sh — Reclaim Colima VM disk (~/.colima/_lima) via Docker prune.
#
# Colima hosts the Docker fleet; pip wheel caches and Playwright browser layers
# accumulate in container/image/volume storage inside the VM disk image.
# Prune unused images, dangling volumes, and builder cache. Active containers
# and named volumes in use are preserved by docker prune semantics.
#
# Defaults to dry-run (use --clean to apply).
set -euo pipefail

DRY_RUN=true
PRUNE_VOLUMES=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--prune-volumes] [-h|--help]

Options:
  --clean           Apply prune (default: dry-run).
  --dry-run         Preview only.
  --prune-volumes   Also run docker volume prune -f (requires DOCKER_VOLUMES_APPROVED=1 when --clean).
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)         DRY_RUN=false ;;
    --dry-run)       DRY_RUN=true ;;
    --prune-volumes) PRUNE_VOLUMES=true ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
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

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $*"
  else
    log "+ $*"
    "$@" || log "WARNING: command failed: $*"
  fi
}

COLIMA_LIMA="$HOME/.colima/_lima"
COLIMA_WEDGE_RECOVERY=true

fstrim_colima_disk() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] colima ssh -- sudo fstrim -av"
    return 0
  fi

  log "+ colima ssh -- sudo fstrim -av (compact VM sparse disk)"
  if colima ssh -- sudo fstrim -av 2>/dev/null; then
    return 0
  fi

  return 1
}

recover_colima_wedge_once() {
  if [[ "$COLIMA_WEDGE_RECOVERY" != true ]]; then
    return 1
  fi

  log "WARNING: fstrim failed; attempting Colima restart recovery"
  if ! colima stop >/dev/null 2>&1; then
    log "WARNING: colima stop failed"
  fi
  if ! colima start >/dev/null 2>&1; then
    log "WARNING: colima start failed"
    return 1
  fi
  sleep 2
  if colima status >/dev/null 2>&1; then
    fstrim_colima_disk
    return $?
  fi
  log "WARNING: colima status unhealthy after restart"
  return 1
}

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found — skipping Colima cleanup."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "Docker daemon not reachable (start colima?) — skipping."
  exit 0
fi

before_kb=$(size_kb "$COLIMA_LIMA")
log "Colima _lima before: $(fmt_kb "$before_kb") ($COLIMA_LIMA)"
log "Docker context: $(docker context show 2>/dev/null || echo unknown)"
log "=== docker system df (before) ==="
docker system df 2>/dev/null || true

log "=== builder prune (cap 5g reserved) ==="
if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] docker builder prune -af --reserved-space 5g"
else
  docker builder prune -af --reserved-space 5g 2>/dev/null \
    || docker builder prune -af --keep-storage 5g 2>/dev/null \
    || log "WARNING: builder prune failed"
fi

log "=== image prune (unused) ==="
run_cmd docker image prune -af

log "=== system prune (dangling containers/networks) ==="
run_cmd docker system prune -f

if [[ "$PRUNE_VOLUMES" == true ]]; then
  if [[ "$DRY_RUN" != true && "${DOCKER_VOLUMES_APPROVED:-0}" != "1" ]]; then
    log "Skipping volume prune: set DOCKER_VOLUMES_APPROVED=1 after reviewing dry-run."
  else
    log "=== volume prune (unused only) ==="
    run_cmd docker volume prune -f
    # Named volumes with zero container references (stale org-runner-* work dirs)
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would remove orphaned volumes (0 container refs)"
    else
      while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        refs=$(docker ps -a --filter "volume=$vol" -q 2>/dev/null | wc -l | tr -d ' ')
        [[ "$refs" != "0" ]] && continue
        log "+ docker volume rm $vol"
        docker volume rm "$vol" 2>/dev/null || log "WARNING: could not remove $vol"
      done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
    fi
  fi
fi

if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — nothing pruned ==="
else
  after_kb=$(size_kb "$COLIMA_LIMA")
  freed_kb=$(( before_kb - after_kb ))
  [[ $freed_kb -lt 0 ]] && freed_kb=0
  log "Colima _lima after: $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
  log "=== docker system df (after) ==="
  docker system df 2>/dev/null || true
  if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
    if ! fstrim_colima_disk; then
      recover_colima_wedge_once || log "WARNING: fstrim recovery failed"
    fi
  fi
fi

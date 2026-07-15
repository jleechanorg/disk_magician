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
COLIMA_DOCKER_SOCKET="$HOME/.colima/default/docker.sock"
COLIMA_SSH_DIR="$COLIMA_LIMA/colima"

path_owner_uid() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

prove_colima_docker_backend() {
  local context endpoint
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint="$DOCKER_HOST"
  else
    context=$(docker context show 2>/dev/null) || return 1
    endpoint=$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 1
  fi
  if [[ "$endpoint" != "unix://$COLIMA_DOCKER_SOCKET" ]]; then
    log "Docker endpoint $endpoint does not match the expected Colima socket unix://$COLIMA_DOCKER_SOCKET — skipping."
    return 1
  fi
  if [[ ! -e "$COLIMA_DOCKER_SOCKET" || -L "$COLIMA_DOCKER_SOCKET" \
        || "$(path_owner_uid "$COLIMA_DOCKER_SOCKET" 2>/dev/null || echo unknown)" != "$(id -u)" ]]; then
    log "Expected Colima Docker socket is missing, symlinked, or not user-owned — skipping: $COLIMA_DOCKER_SOCKET"
    return 1
  fi
  return 0
}

select_colima_docker_backend() {
  local context endpoint

  if [[ -n "${DOCKER_HOST:-}" ]]; then
    prove_colima_docker_backend
    return
  fi

  context=$(docker context show 2>/dev/null) || context=""
  endpoint=$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || endpoint=""
  if [[ "$endpoint" == "unix://$COLIMA_DOCKER_SOCKET" ]]; then
    prove_colima_docker_backend
    return
  fi

  if [[ ! -e "$COLIMA_DOCKER_SOCKET" || -L "$COLIMA_DOCKER_SOCKET" \
        || "$(path_owner_uid "$COLIMA_DOCKER_SOCKET" 2>/dev/null || echo unknown)" != "$(id -u)" ]]; then
    log "Docker endpoint ${endpoint:-unknown} is not Colima, and the expected Colima socket is missing, symlinked, or not user-owned — skipping."
    return 1
  fi

  export DOCKER_HOST="unix://$COLIMA_DOCKER_SOCKET"
  log "Selected proven Colima Docker socket because Docker context ${context:-unknown} points to ${endpoint:-unknown}."
  prove_colima_docker_backend
}

fstrim_via_active_lima_mux() {
  local ssh_config="$COLIMA_SSH_DIR/ssh.config"
  local mux_socket="$COLIMA_SSH_DIR/ssh.sock"
  local current_uid
  current_uid=$(id -u)

  command -v ssh >/dev/null 2>&1 || return 1
  for trusted_path in "$ssh_config" "$mux_socket"; do
    [[ -e "$trusted_path" && ! -L "$trusted_path" ]] || return 1
    [[ "$(path_owner_uid "$trusted_path" 2>/dev/null || echo unknown)" == "$current_uid" ]] || return 1
  done
  grep -qF "ControlPath \"$mux_socket\"" "$ssh_config" || return 1
  ssh -S "$mux_socket" -F "$ssh_config" -O check lima-colima >/dev/null 2>&1 || return 1

  log "+ fstrim via active Lima SSH control master (Colima CLI control plane unavailable)"
  ssh -S "$mux_socket" -F "$ssh_config" lima-colima sudo fstrim -av
}

fstrim_colima_disk() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] colima ssh -- sudo fstrim -av; if unavailable, use the verified active Lima SSH control master"
    return 0
  fi

  log "+ colima ssh -- sudo fstrim -av (compact VM sparse disk)"
  if colima ssh -- sudo fstrim -av 2>/dev/null; then
    return 0
  fi
  fstrim_via_active_lima_mux
}

recover_colima_wedge_once() {
  local running_containers

  if [[ "${VACATE_CI_RUNNERS_APPROVED:-0}" != "1" ]]; then
    log "WARNING: trim backends unavailable; restart recovery requires VACATE_CI_RUNNERS_APPROVED=1."
    return 1
  fi

  if ! running_containers=$(docker ps -q 2>/dev/null); then
    log "WARNING: refusing Colima restart because Docker could not prove that no containers are running."
    return 1
  fi
  if [[ -n "$running_containers" ]]; then
    log "WARNING: refusing Colima restart because running containers remain."
    return 1
  fi

  log "WARNING: trim failed; attempting approved Colima restart recovery"
  if ! colima stop >/dev/null 2>&1; then
    log "WARNING: colima stop failed"
  fi
  if ! colima start >/dev/null 2>&1; then
    log "WARNING: colima start failed"
    return 1
  fi
  sleep 2
  if docker info >/dev/null 2>&1 && prove_colima_docker_backend; then
    fstrim_colima_disk
    return $?
  fi
  log "WARNING: Docker backend unhealthy after restart"
  return 1
}

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found — skipping Colima cleanup."
  exit 0
fi

if ! select_colima_docker_backend; then
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "Docker daemon not reachable — checking guarded Colima recovery."
  if [[ "$DRY_RUN" == true ]]; then
    log "Dry-run: guarded Colima restart recovery was not attempted."
    exit 0
  fi
  if command -v colima >/dev/null 2>&1; then
    recover_colima_wedge_once || log "WARNING: initial Docker recovery failed"
  fi
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
  if command -v colima >/dev/null 2>&1; then
    if ! fstrim_colima_disk; then
      recover_colima_wedge_once || log "WARNING: fstrim recovery failed"
    fi
  fi
fi

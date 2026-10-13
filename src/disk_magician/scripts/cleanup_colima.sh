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

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# shellcheck source=scripts/lib/docker_probe.sh
if [[ -f "$SCRIPT_DIR/lib/docker_probe.sh" ]]; then
  source "$SCRIPT_DIR/lib/docker_probe.sh"
elif [[ -f "$SCRIPT_DIR/../scripts/lib/docker_probe.sh" ]]; then
  source "$SCRIPT_DIR/../scripts/lib/docker_probe.sh"
fi

DRY_RUN=true
PRUNE_VOLUMES=false
TRIM_ONLY=false
TRIM_GB="${DISK_MAGICIAN_COLIMA_TRIM_GB:-8}"
TRIM_TIMEOUT_SEC="${DISK_MAGICIAN_COLIMA_TRIM_TIMEOUT:-300}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--prune-volumes] [--trim-only] [-h|--help]

Options:
  --clean           Apply prune (default: dry-run).
  --dry-run         Preview only.
  --prune-volumes   Also run docker volume prune -f (requires DOCKER_VOLUMES_APPROVED=1 when --clean).
  --trim-only       Only in-VM fstrim, and only when the host datadisk exceeds
                    DISK_MAGICIAN_COLIMA_TRIM_GB (default 8; 0 disables). No prune,
                    no restart; unreachable VM is logged DEGRADED and exits 0.
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)         DRY_RUN=false ;;
    --dry-run)       DRY_RUN=true ;;
    --prune-volumes) PRUNE_VOLUMES=true ;;
    --trim-only)     TRIM_ONLY=true ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"; fi
}

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

colima_socket_is_trusted() {
  [[ -S "$COLIMA_DOCKER_SOCKET" && ! -L "$COLIMA_DOCKER_SOCKET" \
     && "$(path_owner_uid "$COLIMA_DOCKER_SOCKET" 2>/dev/null || echo unknown)" == "$(id -u)" ]]
}

prove_colima_docker_backend() {
  local context endpoint
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    context="$DOCKER_CONTEXT"
    if ! endpoint=$(docker_probe context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || [[ -z "$endpoint" ]]; then
      log "DEGRADED / SKIPPED: Docker context inspect failed, timed out, or returned empty endpoint for context '$context'."
      return 10
    fi
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint="$DOCKER_HOST"
  else
    if ! context=$(docker_probe context show 2>/dev/null) || [[ -z "$context" ]]; then
      log "DEGRADED / SKIPPED: Docker context show failed, timed out, or returned empty context."
      return 10
    fi
    if ! endpoint=$(docker_probe context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || [[ -z "$endpoint" ]]; then
      log "DEGRADED / SKIPPED: Docker context inspect failed, timed out, or returned empty endpoint for context '$context'."
      return 10
    fi
  fi
  if [[ "$endpoint" != "unix://$COLIMA_DOCKER_SOCKET" ]]; then
    log "Docker endpoint $endpoint does not match the expected Colima socket unix://$COLIMA_DOCKER_SOCKET — skipping."
    return 1
  fi
  if ! colima_socket_is_trusted; then
    log "Expected Colima Docker socket is missing, not a socket, symlinked, or not user-owned — skipping: $COLIMA_DOCKER_SOCKET"
    # Endpoint is provably the expected Colima socket but the socket is absent/
    # untrusted — a Stopped VM has no socket, so signal 2 to let main route to
    # the guarded recovery path instead of silently skipping.
    return 2
  fi
  return 0
}

select_colima_docker_backend() {
  local context endpoint

  if [[ -n "${DOCKER_CONTEXT:-}" || -n "${DOCKER_HOST:-}" ]]; then
    # Explicit selection: an endpoint matching the expected Colima socket but
    # with the socket absent/untrusted returns 2 (Stopped VM) from prove; an
    # unrelated endpoint returns 1 and main stays refused.
    prove_colima_docker_backend
    return $?
  fi

  if ! context=$(docker_probe context show 2>/dev/null) || [[ -z "$context" ]]; then
    log "DEGRADED / SKIPPED: Docker backend identity probe timed out, failed, or returned empty context (docker context show)."
    return 10
  fi
  if ! endpoint=$(docker_probe context inspect "$context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || [[ -z "$endpoint" ]]; then
    log "DEGRADED / SKIPPED: Docker backend identity probe timed out, failed, or returned empty endpoint (docker context inspect)."
    return 10
  fi

  if [[ "$endpoint" == "unix://$COLIMA_DOCKER_SOCKET" ]]; then
    if prove_colima_docker_backend; then
      return 0
    fi
    # Expected Colima socket path, but absent/untrusted: the VM may simply be
    # Stopped (a Stopped VM has no socket). Signal 2 so main can still reach
    # the guarded recovery path instead of silently skipping.
    return 2
  fi

  if ! colima_socket_is_trusted; then
    log "Docker endpoint $endpoint is not Colima, and the expected Colima socket is missing, not a socket, symlinked, or not user-owned — skipping."
    return 1
  fi

  export DOCKER_HOST="unix://$COLIMA_DOCKER_SOCKET"
  log "Selected proven Colima Docker socket because Docker context $context points to $endpoint."
  prove_colima_docker_backend
  return $?
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
  bounded "$TRIM_TIMEOUT_SEC" ssh -S "$mux_socket" -F "$ssh_config" lima-colima sudo fstrim -av
}

fstrim_colima_disk() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] colima ssh -- sudo fstrim -av; if unavailable, use the verified active Lima SSH control master"
    return 0
  fi

  log "+ colima ssh -- sudo fstrim -av (compact VM sparse disk)"
  if bounded "$TRIM_TIMEOUT_SEC" colima ssh -- sudo fstrim -av 2>/dev/null; then
    return 0
  fi
  fstrim_via_active_lima_mux
}

# True only when the status probe itself succeeds and reports the profile Stopped.
# A Stopped VM has zero running containers; any probe failure stays not-proven.
colima_vm_is_stopped() {
  local out
  command -v colima >/dev/null 2>&1 || return 1
  # Lock paths/instance name/socket are pinned to the default profile.
  [[ "${COLIMA_PROFILE:-default}" == "default" ]] || return 1
  out=$(bounded 15 colima list 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '$1=="default" && $2=="Stopped" {f=1} END {exit !f}'
}

# Inspect one candidate path with lsof and classify holder state:
#   holder    -> a live process holds a file under the path (authoritative)
#   clear     -> no holder and no diagnostics; path may be considered free
#   unproven  -> lsof missing/errored/timed out, or exit 1 carried a stderr
#                diagnostic (incomplete scan) -> caller must fail closed
# $1 = dir|file, $2 = path. Mirrors the fail-closed inspection pattern in
# cleanup_code_sign_clones.sh (lsof_state): keep stdout records separate from
# stderr diagnostics, and trust a numeric PID column over the exit code because
# macOS lsof returns 1 even when +D emitted valid matches.
colima_lsof_holder_state() {
  local mode="$1" target="$2" err_file out diagnostics rc=0
  err_file=$(mktemp "${TMPDIR:-/tmp}/dm-colima-lsof.XXXXXX" 2>/dev/null) || { printf 'unproven\n'; return 0; }
  if [[ "$mode" == "dir" ]]; then
    out=$(bounded 15 lsof -nP +D "$target" 2>"$err_file") || rc=$?
  else
    # +D requires a directory; a bare path lists holders of that exact file.
    out=$(bounded 15 lsof -nP "$target" 2>"$err_file") || rc=$?
  fi
  diagnostics=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  if printf '%s\n' "$out" | awk '$2 ~ /^[0-9]+$/ {f=1} END {exit !f}'; then
    printf 'holder\n'; return 0
  fi
  if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    printf 'unproven\n'; return 0
  fi
  if [[ -z "$out" && -z "$diagnostics" ]]; then
    printf 'clear\n'; return 0
  fi
  printf 'unproven\n'
}

# Stale lima disk lock: disk "colima" IN-USE-BY the colima instance while no
# hostagent/VZ/QEMU/unknown process or live pid file holds the datadisk.
# lsof is authoritative: it lists ANY process (VZ's Virtualization VM has no
# "colima" token in its cmdline). Missing/erroring lsof means holder state is
# unproven -> fail closed. Live -> not stale.
colima_disk_lock_is_stale() {
  local lima_home="$COLIMA_LIMA" listing pidf pid psout spec mode cand state probed=0
  [[ "${COLIMA_PROFILE:-default}" == "default" ]] || return 1
  command -v limactl >/dev/null 2>&1 || return 1
  listing=$(LIMA_HOME="$lima_home" bounded 15 limactl disk list colima 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk '$1=="colima" && NF==5 && $NF=="colima" {f=1} END {exit !f}' || return 1
  for pidf in "$lima_home"/colima/*.pid; do
    [[ -f "$pidf" ]] || continue
    pid=$(tr -dc '0-9' < "$pidf" 2>/dev/null) || return 1
    [[ -n "$pid" ]] || return 1   # unreadable/empty pid file: not proven stale
    if kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
  done
  # Any process holding the datadisk dir OR the live VZ diffdisk sibling keeps
  # the lock live. A scan error or diagnostic is unproven -> fail closed.
  for spec in "dir:$lima_home/_disks/colima" "file:$lima_home/colima/diffdisk"; do
    mode="${spec%%:*}"; cand="${spec#*:}"
    [[ -e "$cand" ]] || continue
    probed=1
    state=$(colima_lsof_holder_state "$mode" "$cand")
    [[ "$state" == "clear" ]] || return 1   # holder OR unproven
  done
  [[ "$probed" -eq 1 ]] || return 1          # no disk path existed to prove absence
  psout=$(ps -axo command 2>/dev/null) || return 1
  [[ -n "$psout" ]] || return 1
  if printf '%s\n' "$psout" | grep -E 'limactl.*hostagent|lima.*hostagent|qemu-system|qemu-kvm|Virtualization.*colima|limactl.*(start|hostagent).*colima' | grep -v grep >/dev/null; then
    return 1
  fi
  return 0
}

colima_start_with_stale_lock_retry() {
  if colima start >/dev/null 2>&1; then
    return 0
  fi
  log "WARNING: colima start failed"
  if ! colima_disk_lock_is_stale; then
    log "WARNING: no provably stale Lima disk lock (live hostagent/pid, lock absent, or probe failed) — failing closed, not unlocking."
    return 1
  fi
  # Re-probe immediately before the named unlock. Another Colima/Lima process
  # may have acquired the datadisk after the first check; never unlock if the
  # holder state changed or can no longer be proven stale.
  if ! colima_disk_lock_is_stale; then
    log "WARNING: Lima disk lock state changed before unlock (live holder appeared or probe failed) — failing closed, not unlocking."
    return 1
  fi
  log "Stale Lima disk lock on 'colima' (in-use-by self, no live hostagent/limactl/VZ process) — unlocking and retrying start once."
  if ! LIMA_HOME="$COLIMA_LIMA" bounded 30 limactl disk unlock colima >/dev/null 2>&1; then
    log "WARNING: limactl disk unlock colima failed — failing closed."
    return 1
  fi
  if colima start >/dev/null 2>&1; then
    return 0
  fi
  log "WARNING: colima start failed again after disk unlock"
  return 1
}

recover_colima_wedge_once() {
  local running_containers

  if [[ "${VACATE_CI_RUNNERS_APPROVED:-0}" != "1" ]]; then
    log "WARNING: trim backends unavailable; restart recovery requires VACATE_CI_RUNNERS_APPROVED=1."
    return 1
  fi

  local vm_stopped=false
  if colima_vm_is_stopped; then
    vm_stopped=true
    log "Colima VM reports Stopped — zero running containers by definition; restart guard satisfied."
  else
    if ! running_containers=$(docker_probe ps -q 2>/dev/null); then
      log "WARNING: refusing Colima restart because Docker could not prove that no containers are running."
      return 1
    fi
    if [[ -n "$running_containers" ]]; then
      log "WARNING: refusing Colima restart because running containers remain."
      return 1
    fi
  fi

  log "WARNING: trim failed; attempting approved Colima restart recovery"
  if [[ "$vm_stopped" != true ]] && ! colima stop >/dev/null 2>&1; then
    log "WARNING: colima stop failed"
  fi
  if ! colima_start_with_stale_lock_retry; then
    return 1
  fi
  sleep 2
  if docker_probe info >/dev/null 2>&1 && prove_colima_docker_backend; then
    fstrim_colima_disk
    return $?
  fi
  log "WARNING: Docker backend unhealthy after restart"
  return 1
}

# Shared guarded-recovery entry point. Reached both when the Docker daemon is
# unreachable on a proven Colima backend and when the Colima socket is simply
# absent because the VM is Stopped. Approval + dry-run gates still apply.
attempt_guarded_colima_recovery() {
  if [[ "$DRY_RUN" == true ]]; then
    log "DEGRADED / SKIPPED: guarded Colima restart recovery was not attempted in dry-run."
    return 1
  fi
  if command -v colima >/dev/null 2>&1; then
    if recover_colima_wedge_once; then
      log "Colima restart recovery succeeded."
      return 0
    fi
    log "WARNING: initial Docker recovery failed"
  fi
  return 1
}

if [[ "$TRIM_ONLY" == true ]]; then
  # Bead disk_magician-mux: cheap scheduled trim so the sparse datadisk never
  # balloons. Never prunes, never restarts, never fails the caller.
  datadisk="$HOME/.colima/_lima/_disks/colima"
  if [[ ! "$TRIM_GB" =~ ^[0-9]+$ || "$TRIM_GB" -eq 0 ]]; then
    log "trim-only: disabled (DISK_MAGICIAN_COLIMA_TRIM_GB=$TRIM_GB)."
    exit 0
  fi
  [[ -d "$datadisk" ]] || { log "trim-only: no Colima datadisk at $datadisk — skipping."; exit 0; }
  disk_kb=$(bounded 60 du -sk "$datadisk" 2>/dev/null | awk '{print $1+0}') || disk_kb=""
  if [[ ! "$disk_kb" =~ ^[0-9]+$ ]]; then
    log "DEGRADED: trim-only could not measure $datadisk (du failed or timed out) — skipping trim."
    exit 0
  fi
  if (( disk_kb <= TRIM_GB * 1048576 )); then
    log "trim-only: datadisk $(fmt_kb "$disk_kb") <= ${TRIM_GB}G — no trim."
    exit 0
  fi
  if colima_vm_is_stopped; then
    log "trim-only: Colima VM is Stopped — nothing to trim until it is started (guarded recovery: VACATE_CI_RUNNERS_APPROVED=1 cleanup_colima.sh --clean)."
    exit 0
  fi
  log "trim-only: datadisk $(fmt_kb "$disk_kb") > ${TRIM_GB}G — in-VM fstrim (timeout ${TRIM_TIMEOUT_SEC}s)."
  if ! command -v colima >/dev/null 2>&1 || ! fstrim_colima_disk; then
    log "DEGRADED: trim-only fstrim failed (Colima/ssh unreachable or timed out) — no restart from this path."
  fi
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found — skipping Colima cleanup."
  exit 0
fi

backend_rc=0
select_colima_docker_backend || backend_rc=$?
if [[ "$backend_rc" -eq 10 ]]; then
  log "DEGRADED / SKIPPED: Docker backend identity probe failed or timed out."
  exit 1
elif [[ "$backend_rc" -eq 2 ]] && colima_vm_is_stopped; then
  # Colima socket absent/untrusted but the default profile is provably Stopped:
  # a Stopped VM has no socket, so recovery must not depend on one.
  log "DEGRADED / SKIPPED: Colima backend expected but socket absent; default profile is Stopped — checking guarded Colima recovery."
  if attempt_guarded_colima_recovery; then
    exit 0
  fi
  exit 1
elif [[ "$backend_rc" -ne 0 ]]; then
  exit 0
fi

if ! docker_probe info >/dev/null 2>&1; then
  log "DEGRADED / SKIPPED: Docker daemon unreachable or probe timed out — checking guarded Colima recovery."
  if attempt_guarded_colima_recovery; then
    exit 0
  fi
  exit 1
fi

before_kb=$(size_kb "$COLIMA_LIMA")
log "Colima _lima before: $(fmt_kb "$before_kb") ($COLIMA_LIMA)"
log "Docker context: $(docker_probe context show 2>/dev/null || echo unknown)"
report_status=0
log "=== docker system df (before) ==="
if ! docker_probe system df; then
  log "DEGRADED: docker system df probe failed or timed out."
  report_status=1
fi

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

prune_orphaned_volumes() {
  local vol_list vol ps_out refs
  if ! vol_list=$(docker_probe volume ls --format '{{.Name}}' 2>/dev/null); then
    log "WARNING: docker volume ls probe failed or timed out; skipping orphaned volume prune"
    return 1
  fi
  while IFS= read -r vol; do
    [[ -n "$vol" ]] || continue
    if ! ps_out=$(docker_probe ps -a --filter "volume=$vol" -q 2>/dev/null); then
      log "WARNING: docker ps -a probe failed or timed out for volume $vol; preserving volume"
      continue
    fi
    refs=$(printf "%s\n" "$ps_out" | grep -c . || true)
    [[ "$refs" -ne 0 ]] && continue
    log "+ docker volume rm $vol"
    docker volume rm "$vol" 2>/dev/null || log "WARNING: could not remove $vol"
  done <<< "$vol_list"
}

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
      prune_orphaned_volumes || true
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
  if ! docker_probe system df; then
    log "DEGRADED: post-prune docker system df probe failed or timed out."
    report_status=1
  fi
  if command -v colima >/dev/null 2>&1; then
    if ! fstrim_colima_disk; then
      recover_colima_wedge_once || log "WARNING: fstrim recovery failed"
    fi
  fi
fi
exit "$report_status"

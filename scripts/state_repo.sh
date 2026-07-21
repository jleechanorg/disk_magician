#!/usr/bin/env bash
# state_repo.sh — per-machine state-repo lifecycle (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md).
# Subcommands: init | status | remote <url> | push
set -euo pipefail

STATE_DIR="${DISK_MAGICIAN_STATE_REPO:-${XDG_STATE_HOME:-$HOME/.local/state}/disk-magician}"
log() { echo "[state_repo] $*"; }

git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

cmd_init() {
  if [[ -f "$STATE_DIR/MACHINE" ]]; then
    log "adopted existing state repo: $STATE_DIR"
  else
    mkdir -p "$STATE_DIR"
    [[ -d "$STATE_DIR/.git" ]] || git -C "$STATE_DIR" init -q
    printf 'hostname: %s\ncreated: %s\ntool: disk-magician\n' \
      "$(hostname -s 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/MACHINE"
    mkdir -p "$STATE_DIR/config" "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/evidence"
    git_id add -A
    git_id commit -q -m "state repo initialized ($(hostname -s 2>/dev/null || echo unknown))"
    log "initialized state repo: $STATE_DIR"
  fi
  offer_remote
}

offer_remote() {
  if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
    log "remote: $(git -C "$STATE_DIR" remote get-url origin)"; return 0
  fi
  log "running local-only (no remote configured)"
}

case "${1:-}" in
  init) cmd_init ;;
  *) echo "usage: state_repo.sh init|status|remote <url>|push" >&2; exit 2 ;;
esac

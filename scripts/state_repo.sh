#!/usr/bin/env bash
# state_repo.sh — per-machine state-repo lifecycle (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md).
# Subcommands: init | status | remote <url> | push
set -euo pipefail

STATE_DIR="${DISK_MAGICIAN_STATE_REPO:-${XDG_STATE_HOME:-$HOME/.local/state}/disk-magician}"
log() { echo "[state_repo] $*"; }

git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

cmd_init() {
  if [[ -f "$STATE_DIR/MACHINE" && -d "$STATE_DIR/.git" ]]; then
    log "adopted existing state repo: $STATE_DIR"
  elif [[ -f "$STATE_DIR/MACHINE" ]]; then
    # MACHINE marker without .git (partial/corrupt state) — re-init in place.
    git -C "$STATE_DIR" init -q -b main 2>/dev/null \
      || { git -C "$STATE_DIR" init -q && git -C "$STATE_DIR" symbolic-ref HEAD refs/heads/main; }
    git_id add -A
    git_id commit -q -m "re-init: recovered state dir without .git"
    log "re-initialized git in existing state dir: $STATE_DIR"
  else
    mkdir -p "$STATE_DIR"
    # Pin the branch name: default-branch differs by git config/vendor
    # (env -i sandboxes see the compiled default), which broke CI when the
    # state repo (master) pushed to a bare whose HEAD was unborn main.
    [[ -d "$STATE_DIR/.git" ]] || git -C "$STATE_DIR" init -q -b main 2>/dev/null \
      || { git -C "$STATE_DIR" init -q && git -C "$STATE_DIR" symbolic-ref HEAD refs/heads/main; }
    printf 'hostname: %s\ncreated: %s\ntool: disk-magician\n' \
      "$(hostname -s 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/MACHINE"
    mkdir -p "$STATE_DIR/config" "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/evidence"
    git_id add -A
    git_id commit -q -m "state repo initialized ($(hostname -s 2>/dev/null || echo unknown))"
    if ! git -C "$STATE_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      # CI diagnostics (2026-07-21): a runner produced an empty initial commit
      # state; fail loudly with the facts instead of cascading downstream.
      {
        echo "[state_repo] FATAL: initial commit produced no HEAD"
        git --version
        git -C "$STATE_DIR" status
        git -C "$STATE_DIR" config -l | head -20
      } >&2
      exit 1
    fi
    log "initialized state repo: $STATE_DIR"
  fi
  offer_remote
}

offer_remote() {
  if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
    log "remote: $(git -C "$STATE_DIR" remote get-url origin)"; return 0
  fi
  if [[ -f "$STATE_DIR/.offer-declined" ]]; then
    log "remote offer declined earlier — running local-only (state_repo.sh remote <url> to wire one)"; return 0
  fi
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    log "running local-only (no gh auth; state_repo.sh remote <url> to wire one)"; return 0
  fi
  local host reply repo
  host="$(hostname -s 2>/dev/null || echo unknown)"
  repo="disk-magician-state-${host}"
  if [[ "${DISK_MAGICIAN_ASSUME_YES:-0}" == "1" ]]; then reply=y
  elif [[ "${DISK_MAGICIAN_ASSUME_NO:-0}" == "1" ]]; then reply=n
  else read -r -p "Create private GitHub repo ${repo} for snapshot history? [y/N] " reply || reply=n
  fi
  if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
    local login=""
    login=$(gh api user --jq .login 2>/dev/null || true)
    if gh repo create "$repo" --private --source "$STATE_DIR" --remote origin --push >/dev/null 2>&1; then
      log "origin wired to ${repo}"
    elif [[ -n "$login" ]] && gh repo create "$repo" --private >/dev/null 2>&1; then
      git -C "$STATE_DIR" remote add origin "https://github.com/${login}/${repo}.git"
      log "origin wired to ${repo}"
    else
      log "gh repo create failed — running local-only"
    fi
  else
    touch "$STATE_DIR/.offer-declined"
    git_id add .offer-declined && git_id commit -q -m "record remote-offer decline" || true
    log "declined — running local-only"
  fi
}

cmd_status() {
  [[ -f "$STATE_DIR/MACHINE" ]] || { log "no state repo at $STATE_DIR (run: state init)"; exit 1; }
  log "state repo: $STATE_DIR"
  log "commits: $(git -C "$STATE_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
  local r; r=$(git -C "$STATE_DIR" remote get-url origin 2>/dev/null || true)
  log "remote: ${r:-none}"
}

cmd_remote() {
  [[ -n "${1:-}" ]] || { echo "usage: state_repo.sh remote <url>" >&2; exit 2; }
  git -C "$STATE_DIR" remote remove origin 2>/dev/null || true
  git -C "$STATE_DIR" remote add origin "$1"
  rm -f "$STATE_DIR/.offer-declined"
  log "origin set: $1"
}
cmd_push() {
  git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1 || { log "no remote configured"; exit 1; }
  local branch; branch=$(git -C "$STATE_DIR" branch --show-current)
  [[ -n "$branch" ]] || { log "ERROR: not on a branch (mid-rebase/detached?) — resolve manually in $STATE_DIR"; exit 1; }
  git -C "$STATE_DIR" fetch -q origin "$branch" 2>/dev/null || true
  if git -C "$STATE_DIR" rev-parse --verify -q "origin/$branch" >/dev/null; then
    if ! git -C "$STATE_DIR" merge-base --is-ancestor "origin/$branch" HEAD; then
      # Diverged: try a rebase; on ANY failure, abort cleanly and stop.
      if ! git_id rebase -q "origin/$branch" 2>/dev/null; then
        git -C "$STATE_DIR" rebase --abort 2>/dev/null || true
        log "ERROR: diverged from origin/$branch with conflicts — resolve manually in $STATE_DIR (nothing was lost or pushed)"
        exit 1
      fi
    fi
  fi
  git -C "$STATE_DIR" push -q -u origin "$branch"
  log "pushed $branch"
}

case "${1:-}" in
  init) cmd_init ;;
  status) cmd_status ;;
  remote) shift; cmd_remote "$@" ;;
  push) cmd_push ;;
  *) echo "usage: state_repo.sh init|status|remote <url>|push" >&2; exit 2 ;;
esac

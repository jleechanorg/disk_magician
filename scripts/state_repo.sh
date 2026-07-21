#!/usr/bin/env bash
# state_repo.sh — per-machine state-repo lifecycle (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md).
# Subcommands: init | status | remote <url> | push
set -euo pipefail

SR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(python3 "$SR_SCRIPT_DIR/resolve_state_repo_path.py")"
log() { echo "[state_repo] $*"; }

git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

# Pre-push safety guard (relocated from disk_magician.sh's legacy inline
# run_snapshot commit/push path — design bright line: the state repo owns
# everything about its own push, so all pushers, old and new, funnel through
# this ONE guard instead of each dispatch site re-implementing it). Message
# text is unchanged from the original so tests/test_snapshot_git_guard.sh's
# grep assertions keep matching without edits.
find_gitleaks() {
  local candidate
  if [[ -n "${DISK_MAGICIAN_GITLEAKS_BIN:-}" ]]; then
    if [[ -x "${DISK_MAGICIAN_GITLEAKS_BIN}" ]]; then
      printf '%s\n' "${DISK_MAGICIAN_GITLEAKS_BIN}"
      return 0
    fi
    return 1
  fi
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks
    return 0
  fi
  for candidate in \
    "${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/bin/gitleaks}" \
    /opt/homebrew/bin/gitleaks \
    /usr/local/bin/gitleaks \
    "$HOME/.local/bin/gitleaks"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

remote_has_embedded_credentials() {
  local remote_url="$1"
  python3 -c '
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.stdin.read().strip())
sys.exit(0 if url.scheme in {"http", "https"} and (url.username or url.password) else 1)
' <<<"$remote_url"
}

guard_state_repo_push() {
  local branch remote_url remote_exists=false remote_ref="" scan_range gitleaks_bin
  branch="$(git -C "$STATE_DIR" symbolic-ref --quiet --short HEAD)" || {
    echo "Snapshot history guard: detached HEAD is not safe to push." >&2
    return 1
  }
  remote_url="$(git -C "$STATE_DIR" remote get-url origin)" || {
    echo "Snapshot history guard: origin has no usable URL." >&2
    return 1
  }
  if remote_has_embedded_credentials "$remote_url"; then
    echo "Snapshot history guard: origin URL contains embedded credentials; refusing to push." >&2
    return 1
  fi

  if git -C "$STATE_DIR" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    remote_exists=true
  else
    local ls_remote_rc=$?
    if [[ "$ls_remote_rc" -ne 2 ]]; then
      echo "Snapshot history guard: could not verify origin/$branch." >&2
      return 1
    fi
  fi

  if [[ "$remote_exists" == true ]]; then
    remote_ref="refs/remotes/origin/$branch"
    git -C "$STATE_DIR" fetch --quiet origin \
      "refs/heads/$branch:$remote_ref" || {
      echo "Snapshot history guard: could not refresh origin/$branch." >&2
      return 1
    }
    if ! git -C "$STATE_DIR" merge-base --is-ancestor "$remote_ref" HEAD; then
      echo "Snapshot history guard: local $branch does not descend from origin/$branch; refusing history rewrite." >&2
      return 1
    fi
    scan_range="$remote_ref..HEAD"
  else
    scan_range="HEAD"
  fi

  if git -C "$STATE_DIR" show-ref --verify --quiet refs/heads/archive/pre-reset-20260711 && \
     ! git -C "$STATE_DIR" merge-base --is-ancestor refs/heads/archive/pre-reset-20260711 HEAD; then
    echo "Snapshot history guard: main no longer contains archive/pre-reset-20260711; refusing history loss." >&2
    return 1
  fi

  gitleaks_bin="$(find_gitleaks)" || {
    echo "Snapshot history guard: gitleaks is unavailable; refusing unscanned push." >&2
    return 1
  }
  if ! "$gitleaks_bin" git --no-banner --no-color --redact=100 \
      --log-opts="$scan_range" "$STATE_DIR" >/dev/null 2>&1; then
    echo "Snapshot history guard: secret scan rejected outgoing snapshot history." >&2
    return 1
  fi

  echo "Snapshot history guard passed for origin/$branch."
}

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
  guard_state_repo_push || exit 1
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

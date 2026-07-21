#!/usr/bin/env bash
# snapshot_commit.sh — orchestrate a state-repo snapshot commit (design:
# roadmap/2026-07-21-generic-split-state-repo-design.md §Snapshot/commit flow).
# Auto-inits the state repo local-only, writes snapshots/disk_snapshot.json,
# refreshes the 5G ledger + evidence retention, writes back resolved config,
# commits, then a FAIL-SAFE push (a push failure never aborts — the commit
# already landed locally; this fixes the latent set -euo pipefail abort in the
# legacy inline path).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="$(python3 "$SCRIPT_DIR/resolve_state_repo_path.py")"
SNAP_BIN="${DISK_MAGICIAN_SNAPSHOT_BIN:-$SCRIPT_DIR/disk_snapshot.sh}"
FRONTIER="${DISK_MAGICIAN_FRONTIER_JSON:-$HOME/.disk_magician_state/frontier_last.json}"
KEEP="${DISK_MAGICIAN_EVIDENCE_KEEP:-4}"
log() { echo "[snapshot_commit] $*"; }
git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

# Concurrency guard (relocated from disk_magician.sh's legacy run_snapshot,
# bead jleechan-q9mu): mkdir-based lock, stale-lock TTL 90 min (dead pid +
# old enough -> steal), contention = log + exit 0 (skip this run, never
# queue). This orchestrator is now the only path a 35-min tick reaches, so
# the lock has to live here rather than in the now-bypassed caller.
SNAPSHOT_LOCK_DIR="${HOME}/.disk_magician_state/snapshot.lock"
SNAPSHOT_LOCK_TTL_SEC=5400
acquire_snapshot_lock() {
  mkdir -p "$(dirname "$SNAPSHOT_LOCK_DIR")"
  if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
    echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
    trap 'rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
    return 0
  fi
  local held_pid age
  held_pid=$(cat "$SNAPSHOT_LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f%m "$SNAPSHOT_LOCK_DIR" 2>/dev/null || stat -c%Y "$SNAPSHOT_LOCK_DIR" 2>/dev/null || date +%s) ))
  if [[ "$age" -gt "$SNAPSHOT_LOCK_TTL_SEC" ]] && { [[ -z "$held_pid" ]] || ! kill -0 "$held_pid" 2>/dev/null; }; then
    rm -rf "$SNAPSHOT_LOCK_DIR"
    if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
      echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
      trap 'rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
      return 0
    fi
  fi
  echo "snapshot: lock held by pid ${held_pid:-?} (age ${age}s) — skipping this run"
  return 1
}
acquire_snapshot_lock || exit 0

# 1. Ensure the state repo exists (local-only auto-init).
if [[ ! -f "$STATE_DIR/MACHINE" || ! -d "$STATE_DIR/.git" ]]; then
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" init >/dev/null 2>&1 || {
    log "ERROR: state repo init failed for $STATE_DIR"; exit 1; }
fi
mkdir -p "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/config" "$STATE_DIR/evidence"

# 2. Write the snapshot.
if ! bash "$SNAP_BIN" --output "$STATE_DIR/snapshots/disk_snapshot.json"; then
  log "ERROR: snapshot writer failed"; exit 1
fi

# 3. Refresh the 5G ledger (fail-open) and evidence retention.
python3 "$SCRIPT_DIR/render_topdown_ledger.py" --frontier "$FRONTIER" \
  --out-dir "$STATE_DIR/ledger" 2>/dev/null || true
python3 "$SCRIPT_DIR/retain_evidence.py" --frontier "$FRONTIER" \
  --evidence-dir "$STATE_DIR/evidence" --keep "$KEEP" 2>/dev/null || true

# 4. Write back the resolved config.
CFG="$(python3 "$SCRIPT_DIR/resolve_config.py" 2>/dev/null || true)"
[[ -n "$CFG" && -f "$CFG" ]] && cp "$CFG" "$STATE_DIR/config/config.json"

# 5. Commit. Always commit (no diff-skip): each 35-min tick is a time-series
# data point, and skipping identical-content ticks would silently break
# history continuity (e.g. "disk free was still 100G at 14:35" is itself
# meaningful, not noise) — deviation from an earlier draft that skipped
# no-op commits, corrected by tests/test_snapshot_commit.sh Test 2 (history
# must accrue every run).
git_id add -A
git_id commit -q -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty
log "committed snapshot"

# 6. Fail-safe push (never fatal). Capture (don't discard) the push guard's
# output: a rejected push is often security-relevant (secret scan, credential
# URL, history rewrite) and swallowing the reason would turn a real rejection
# into an indistinguishable "will retry next run" — the guard's whole point
# is to be visible when it fires.
if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
  PUSH_OUT="$(DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" push 2>&1)"
  PUSH_RC=$?
  if [[ $PUSH_RC -eq 0 ]]; then
    log "pushed to origin"
  else
    log "push failed — commit kept local, will retry next run"
  fi
  [[ -n "$PUSH_OUT" ]] && log "$PUSH_OUT"
else
  log "local-only (no remote)"
fi
exit 0

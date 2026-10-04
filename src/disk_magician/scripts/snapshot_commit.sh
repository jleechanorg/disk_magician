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
RECEIPT_STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
FRONTIER="$(python3 "$SCRIPT_DIR/frontier_selection.py" \
  --root "/var/db/disk-magician/frontier_last.json" \
  --state "$RECEIPT_STATE_DIR/frontier_last.json" 2>/dev/null || true)"
KEEP="${DISK_MAGICIAN_EVIDENCE_KEEP:-4}"
log() { echo "[snapshot_commit] $*"; }
git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

# Concurrency guard: Use receipt STATE dir for snapshot lock override, distinct from state repository dir.
SNAPSHOT_LOCK_DIR="${RECEIPT_STATE_DIR}/snapshot.lock"
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

if ! acquire_snapshot_lock; then
  if ! python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit \
    --outcome skipped_lock \
    --reason "lock held by another run" \
    --lock '{"held": true, "reason": "contention"}' \
    --safety '{"status": "not_applicable", "reason": "lock_contention_no_mutation", "delegated": false}' >/dev/null 2>&1; then
    log "ERROR: failed to record skipped_lock receipt"
  fi
  exit 0
fi

# Record started before work
RECEIPT_RUN_ID=$(python3 "$SCRIPT_DIR/job_receipt.py" begin --job snapshot_commit \
  --trigger "${DISK_MAGICIAN_TRIGGER:-scheduled}" \
  --safety '{"status": "not_applicable", "reason": "read_and_commit_only", "delegated": false}') || {
  log "ERROR: failed to record receipt begin"
  exit 1
}

# 1. Ensure the state repo exists (local-only auto-init).
if [[ ! -f "$STATE_DIR/MACHINE" || ! -d "$STATE_DIR/.git" ]]; then
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" init >/dev/null 2>&1 || {
    log "ERROR: state repo init failed for $STATE_DIR"
    python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
      --outcome error --reason "state repo init failed" >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
    exit 1
  }
fi
mkdir -p "$STATE_DIR/snapshots" "$STATE_DIR/ledger" "$STATE_DIR/config" "$STATE_DIR/evidence"

# 2. Write the snapshot.
if ! bash "$SNAP_BIN" --output "$STATE_DIR/snapshots/disk_snapshot.json"; then
  log "ERROR: snapshot writer failed"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error --reason "snapshot writer failed" >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi

SNAP_FILE="$STATE_DIR/snapshots/disk_snapshot.json"
if [[ ! -f "$SNAP_FILE" ]] || ! python3 - "$SNAP_FILE" <<'EOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    if not isinstance(data, dict) or "disk_free_gb" not in data:
        sys.exit(1)
except Exception:
    sys.exit(1)
EOF
then
  log "ERROR: snapshot artifact invalid or missing"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error --reason "snapshot artifact invalid or missing" >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi

# 3. Refresh the 5G ledger (fail-open) and evidence retention.
python3 "$SCRIPT_DIR/render_topdown_ledger.py" --frontier "$FRONTIER" \
  --out-dir "$STATE_DIR/ledger" 2>/dev/null || true
python3 "$SCRIPT_DIR/retain_evidence.py" --frontier "$FRONTIER" \
  --evidence-dir "$STATE_DIR/evidence" --keep "$KEEP" 2>/dev/null || true

# 4. Write back the resolved config.
CFG="$(python3 "$SCRIPT_DIR/resolve_config.py" 2>/dev/null || true)"
[[ -n "$CFG" && -f "$CFG" ]] && cp "$CFG" "$STATE_DIR/config/config.json"

# Capture actual snapshot and renderer publication status
RENDER_STATUS="unknown"
SIDECAR="$STATE_DIR/ledger/topdown-5g.status.json"
if [[ -f "$SIDECAR" ]]; then
  RENDER_STATUS=$(python3 - "$SIDECAR" <<'EOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("status", "unknown"))
except Exception:
    print("unknown")
EOF
)
fi

# 5. Commit.
git_id update-index --no-assume-unchanged \
  ledger/topdown-5g.json ledger/topdown-5g.md ledger/topdown-5g.status.json \
  2>/dev/null || true

if ! git_id add -A; then
  log "ERROR: git add failed"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error \
    --reason "git add failed" \
    --publication '{"committed": false, "pushed": false, "status": "add_failed"}' >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi

if ! git_id commit -q -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty; then
  log "ERROR: git commit failed"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error \
    --reason "git commit failed" \
    --publication '{"committed": false, "pushed": false, "status": "commit_failed"}' >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi

# Confirm expected snapshot content is present in new commit
if ! git_id rev-parse HEAD:snapshots/disk_snapshot.json >/dev/null 2>&1; then
  log "ERROR: snapshots/disk_snapshot.json missing from committed HEAD"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error \
    --reason "snapshot file missing in committed HEAD" \
    --publication '{"committed": false, "pushed": false, "status": "verification_failed"}' >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi
log "committed snapshot"

# 6. Fail-safe push (never fatal).
PUSHED=false
PUSH_STATUS="local_only"
PUSH_OUT=""
if git -C "$STATE_DIR" remote get-url origin >/dev/null 2>&1; then
  PUSH_OUT="$(DISK_MAGICIAN_STATE_REPO="$STATE_DIR" bash "$SCRIPT_DIR/state_repo.sh" push 2>&1)"
  PUSH_RC=$?
  if [[ $PUSH_RC -eq 0 ]]; then
    log "pushed to origin"
    PUSHED=true
    PUSH_STATUS="pushed"
  else
    log "push failed — commit kept local, will retry next run"
    PUSHED=false
    PUSH_STATUS="push_failed"
  fi
  [[ -n "$PUSH_OUT" ]] && log "$PUSH_OUT"
else
  log "local-only (no remote)"
fi

POSTCONDITION="{\"renderer_status\": \"$RENDER_STATUS\", \"freed_bytes\": null}"
PUBLICATION="{\"committed\": true, \"pushed\": $PUSHED, \"status\": \"$PUSH_STATUS\"}"
SAFETY='{"status": "not_applicable", "reason": "read_and_commit_only", "delegated": false}'

python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit \
  --run-id "$RECEIPT_RUN_ID" \
  --outcome success \
  --safety "$SAFETY" \
  --postcondition "$POSTCONDITION" \
  --publication "$PUBLICATION" || {
  log "ERROR: failed to write terminal success receipt"
  exit 1
}

exit 0

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

# Validate before state resolution, receipt creation or snapshot mutation. The
# public dispatcher forwards arguments unchanged to this single orchestrator.
INVENTORY_MAX_AGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-inventory-if-stale=*)
      age="${1#*=}"
      if [[ -n "$INVENTORY_MAX_AGE" || ! "$age" =~ ^[1-9][0-9]*[smhd]$ || ${#age} -gt 10 ]]; then
        echo "snapshot: invalid stale age: $age (expected positive integer plus s, m, h or d)" >&2
        exit 2
      fi
      INVENTORY_MAX_AGE="$age"
      shift
      ;;
    -h|--help)
      echo "Usage: diskm snapshot [--refresh-inventory-if-stale=24h]"
      exit 0
      ;;
    *) echo "snapshot: invalid option: $1" >&2; exit 2 ;;
  esac
done

STATE_DIR="$(python3 "$SCRIPT_DIR/resolve_state_repo_path.py")"
SNAP_BIN="${DISK_MAGICIAN_SNAPSHOT_BIN:-$SCRIPT_DIR/disk_snapshot.sh}"
RECEIPT_STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
KEEP="${DISK_MAGICIAN_EVIDENCE_KEEP:-4}"
log() { echo "[snapshot_commit] $*"; }
git_id() { git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost "$@"; }

# Concurrency guard: Use receipt STATE dir for snapshot lock override, distinct from state repository dir.
SNAPSHOT_LOCK_DIR="${RECEIPT_STATE_DIR}/snapshot.lock"
SNAPSHOT_LOCK_TTL_SEC=5400
TRANSACTION_DIR=""
cleanup_frontier_pin() {
  if [[ -n "$TRANSACTION_DIR" ]]; then
    rm -f -- "$TRANSACTION_DIR/frontier.json"
    rmdir -- "$TRANSACTION_DIR"
  fi
}
acquire_snapshot_lock() {
  mkdir -p "$(dirname "$SNAPSHOT_LOCK_DIR")"
  if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
    echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
    trap 'cleanup_frontier_pin; rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
    return 0
  fi
  local held_pid age now lock_mtime is_alive=0
  held_pid=$(cat "$SNAPSHOT_LOCK_DIR/pid" 2>/dev/null || echo "")
  lock_mtime=$(stat -f%m "$SNAPSHOT_LOCK_DIR" 2>/dev/null || stat -c%Y "$SNAPSHOT_LOCK_DIR" 2>/dev/null || date +%s)
  now=$(date +%s)
  age=$(( now - lock_mtime ))
  if [[ -n "$held_pid" && "$held_pid" =~ ^[0-9]+$ ]]; then
    if ps -p "$held_pid" -o pid= >/dev/null 2>&1; then
      is_alive=1
    fi
  fi
  if [[ "$age" -gt "$SNAPSHOT_LOCK_TTL_SEC" && "$is_alive" -eq 0 ]]; then
    local reclaim_gate="${SNAPSHOT_LOCK_DIR}.reclaim_gate"
    if mkdir "$reclaim_gate" 2>/dev/null; then
      local recheck_pid recheck_mtime recheck_alive=0
      recheck_pid=$(cat "$SNAPSHOT_LOCK_DIR/pid" 2>/dev/null || echo "")
      recheck_mtime=$(stat -f%m "$SNAPSHOT_LOCK_DIR" 2>/dev/null || stat -c%Y "$SNAPSHOT_LOCK_DIR" 2>/dev/null || echo 0)
      if [[ -n "$recheck_pid" && "$recheck_pid" =~ ^[0-9]+$ ]]; then
        if ps -p "$recheck_pid" -o pid= >/dev/null 2>&1; then
          recheck_alive=1
        fi
      fi
      if [[ "$(( now - recheck_mtime ))" -gt "$SNAPSHOT_LOCK_TTL_SEC" && "$recheck_alive" -eq 0 ]]; then
        rm -rf "$SNAPSHOT_LOCK_DIR"
        if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
          echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
          rmdir "$reclaim_gate" 2>/dev/null || true
          trap 'cleanup_frontier_pin; rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
          return 0
        fi
      fi
      rmdir "$reclaim_gate" 2>/dev/null || true
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
  if [[ -n "$INVENTORY_MAX_AGE" ]]; then
    python3 "$SCRIPT_DIR/job_receipt.py" finish --job directory_inventory \
      --outcome skipped_lock --reason "snapshot_lock_contention" \
      --lock '{"held": true, "reason": "contention"}' >/dev/null 2>&1 || log "ERROR: failed to record inventory skip receipt"
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

# This is orchestration only. The core codec owns validation, durable copying,
# quota, publication locks and immutable dependencies; no second scanner/importer.
if [[ -n "$INVENTORY_MAX_AGE" ]]; then
  python3 - "$SCRIPT_DIR" "$INVENTORY_MAX_AGE" "$RECEIPT_STATE_DIR" <<'PY'
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from job_receipt import JobReceiptStore, parse_iso

age_spec, state_dir = sys.argv[2:]
max_age = int(age_spec[:-1]) * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[age_spec[-1]]
store = JobReceiptStore(state_dir)
run = store.begin('directory_inventory', trigger='snapshot_refresh',
                  safety={'status': 'not_applicable', 'reason': 'metadata_collection_only', 'delegated': False})

def finish(outcome, reason, publication=None):
    store.finish('directory_inventory', run, outcome, reason=reason,
                 lock={'held': outcome == 'skipped_lock', 'reason': 'contention' if outcome == 'skipped_lock' else None},
                 postcondition={'manifest_sha256': (publication or {}).get('pointer', {}).get('manifest_sha256'),
                                'complete': (publication or {}).get('manifest', {}).get('complete'), 'freed_bytes': None})

def fresh(publication):
    try:
        when = parse_iso(publication['manifest']['published_at'])
        age = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds()
        digest = publication['pointer']['manifest_sha256']
        return 0 <= age <= max_age and isinstance(digest, str) and re.fullmatch('[a-f0-9]{64}', digest)
    except (KeyError, TypeError, ValueError):
        return False

try:
    from directory_inventory import read_current, import_root_publication
except ImportError:
    finish('blocked_safety', 'privileged_collector_unavailable: inventory API unavailable')
    print('snapshot: privileged_collector_unavailable (inventory API unavailable)', file=sys.stderr)
    raise SystemExit(1)

try:
    current = read_current(state_dir, verify=True)
except (OSError, ValueError, RuntimeError):
    current = None
if fresh(current):
    finish('success_noop', 'fresh_inventory_no_collector_requested', current)
    raise SystemExit(0)

if sys.platform.startswith('linux'):
    root_parent = Path('/var/lib/disk-magician')
    command = ['systemctl', '--system', '--no-ask-password', 'start', 'disk-magician-inventory-root.service']
elif sys.platform == 'darwin':
    root_parent = Path('/var/db/disk-magician')
    command = ['launchctl', 'kickstart', 'system/com.jleechanorg.disk-magician-frontier-root']
else:
    finish('blocked_safety', 'privileged_collector_unavailable: unsupported platform')
    raise SystemExit(1)

try:
    # A bounded request, not a change to the collector's scan deadline. A timeout
    # never stops/restarts the root collector or falls back to an unprivileged walk.
    requested = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
except (OSError, subprocess.TimeoutExpired):
    finish('blocked_safety', 'privileged_collector_unavailable: request unavailable or timed out')
    raise SystemExit(1)
if requested.returncode:
    finish('blocked_safety', 'privileged_collector_unavailable: fixed collector request failed')
    raise SystemExit(1)

try:
    with (root_parent / 'inventory-root-receipt.json').open() as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError('root receipt exceeds bound')
    receipt = json.loads(raw)
    if receipt.get('status') == 'skipped_lock':
        finish('skipped_lock', 'root_collector_lock_contention')
        raise SystemExit(75)
    if receipt.get('status') not in ('success', 'success_noop', 'partial'):
        raise ValueError('root collector has no successful receipt')
    source = read_current(str(root_parent), verify=True)
    if not fresh(source) or source['pointer']['manifest_sha256'] != receipt.get('manifest_sha256') or source['manifest']['published_at'] != receipt.get('published_at'):
        raise ValueError('root receipt does not identify a fresh verified publication')
    # source_root is the fixed root state parent; core adds inventory internally.
    import_root_publication(str(root_parent), state_dir=state_dir, retries=3)
    imported = read_current(state_dir, verify=True)
    if not fresh(imported) or imported['pointer']['manifest_sha256'] != source['pointer']['manifest_sha256']:
        raise ValueError('import did not yield the verified fresh root publication')
except BlockingIOError:
    finish('skipped_lock', 'inventory_publication_lock_contention')
    raise SystemExit(75)
except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
    finish('error', 'inventory_refresh_unavailable: ' + str(exc))
    raise SystemExit(1)
finish('success' if imported['manifest'].get('complete') is True else 'partial',
       'verified_root_handoff_imported', imported)
PY
  refresh_rc=$?
  if [[ $refresh_rc -ne 0 ]]; then
    refresh_outcome=error
    refresh_reason=inventory_refresh_unavailable
    [[ $refresh_rc -eq 75 ]] && { refresh_outcome=skipped_lock; refresh_reason=inventory_collector_lock_contention; }
    python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
      --outcome "$refresh_outcome" --reason "$refresh_reason" >/dev/null 2>&1 || log "ERROR: failed to record refresh failure"
    [[ $refresh_rc -eq 75 ]] && exit 0
    exit 1
  fi
fi

# Freeze the selected bytes once, after acquiring the transaction lock.
if ! { TRANSACTION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/disk_magician_snapshot.XXXXXX") &&
  FRONTIER=$(python3 "$SCRIPT_DIR/frontier_selection.py" \
    --root "/var/db/disk-magician/frontier_last.json" \
    --state "$RECEIPT_STATE_DIR/frontier_last.json" \
    --freeze-to "$TRANSACTION_DIR/frontier.json"); }; then
  log "ERROR: frontier freeze failed"
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job snapshot_commit --run-id "$RECEIPT_RUN_ID" \
    --outcome error --reason "frontier freeze failed" >/dev/null 2>&1 || log "ERROR: failed to record error receipt"
  exit 1
fi
export DISK_MAGICIAN_FRONTIER_JSON="$FRONTIER"

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

# 3. Write back the resolved config before consumers publish reports over it.
CFG="$(python3 "$SCRIPT_DIR/resolve_config.py" 2>/dev/null || true)"
if [[ -n "$CFG" && -f "$CFG" ]]; then
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'import config_mutator, sys; config_mutator.sync_state_config(sys.argv[1])' "$CFG" || \
    log "WARNING: resolved config could not be copied to the state repo"
fi

# 4. Refresh the 5G ledger (fail-open) and evidence retention.
python3 "$SCRIPT_DIR/render_topdown_ledger.py" --frontier "$FRONTIER" \
  --out-dir "$STATE_DIR/ledger" 2>/dev/null || true
python3 "$SCRIPT_DIR/retain_evidence.py" --frontier "$FRONTIER" \
  --evidence-dir "$STATE_DIR/evidence" --keep "$KEEP" 2>/dev/null || true
# Per-host reclaim ledger (fail-open; the `git add -A` below commits it).
python3 "$SCRIPT_DIR/reclaim_ledger.py" --state-dir "$STATE_DIR" --no-commit >/dev/null 2>&1 || true

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
  ledger/topdown-5g.partial.json \
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

#!/usr/bin/env bash
# Regression test for Defect 1: poisoned empty/partial .reuse-lock recovery in lease_reuse_lock_recover.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${CLAUDE_CODE_TMPDIR:-${DISKM_SCRATCH:-${TMPDIR:-/tmp}}}"
TMP="$(mktemp -d "${TMP_BASE%/}/test-poisoned-lease-lock.XXXXXX")"
cleanup_tmp() {
    python3 -c 'import os,shutil,sys; p=sys.argv[1]; p and os.path.isabs(p) and p != "/" and shutil.rmtree(p, ignore_errors=True)' "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT

export HOME="$TMP/home"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR/worktree_leases"

# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

set_old_mtime() {
    local target="$1" age_sec="${2:-7200}"
    python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$target" "$age_sec"
}

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "FATAL: timeout or gtimeout required" >&2
    exit 1
fi

echo "== 1. Empty lock dir with old mtime (> TTL) is recovered =="
LEASE1="$DISK_MAGICIAN_STATE_DIR/worktree_leases/empty-old.json"
LOCK1="${LEASE1}.reuse-lock"
mkdir -p "$LOCK1"
set_old_mtime "$LOCK1" 7200
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE1"; then
    if [[ ! -e "$LOCK1" && ! -e "${LOCK1}.reclaim_gate" ]]; then
        ok "old empty .reuse-lock recovered and removed cleanly"
    else
        bad "lease_reuse_lock_recover returned 0 but lock or gate remained"
    fi
else
    bad "lease_reuse_lock_recover failed to recover old empty .reuse-lock"
fi

echo "== 2. Reproduce empty-lock retry spin on .owner-mutation.reuse-lock =="
REG_LOCK="$DISK_MAGICIAN_STATE_DIR/worktree_leases/.owner-mutation.reuse-lock"
rm -f "$REG_LOCK/pid" "$REG_LOCK/acquired_at" 2>/dev/null || true
rmdir "$REG_LOCK" 2>/dev/null || true
mkdir -p "$REG_LOCK"
set_old_mtime "$REG_LOCK" 7200

spin_rc=0
"$TIMEOUT_BIN" 2s bash -c '
    set -euo pipefail
    source "$1"
    export LEASE_REUSE_LOCK_TTL_SEC=3600
    while ! lease_registry_mutation_lock_enter; do
        sleep 0.1
    done
    lease_registry_mutation_lock_exit
' bash "$REPO_ROOT/scripts/lib/worktree_lease.sh" || spin_rc=$?

if [[ "$spin_rc" -eq 0 && ! -e "$REG_LOCK" ]]; then
    ok "sleep 0.1 retry loop recovered poisoned empty registry lock without spinning"
else
    bad "sleep 0.1 retry loop spun on poisoned empty registry lock (rc=$spin_rc)"
fi
rmdir "$REG_LOCK" 2>/dev/null || true

echo "== 3. Young empty lock dir (< TTL) is NOT reaped =="
LEASE2="$DISK_MAGICIAN_STATE_DIR/worktree_leases/empty-young.json"
LOCK2="${LEASE2}.reuse-lock"
mkdir -p "$LOCK2"
set_old_mtime "$LOCK2" 60
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE2"; then
    bad "young empty .reuse-lock was prematurely reaped before TTL"
else
    if [[ -d "$LOCK2" ]]; then
        ok "young empty .reuse-lock preserved before TTL"
    else
        bad "young empty .reuse-lock disappeared"
    fi
fi

echo "== 4. Old lock with live pid and missing acquired_at is NOT reaped =="
LEASE3="$DISK_MAGICIAN_STATE_DIR/worktree_leases/live-pid-no-stamp.json"
LOCK3="${LEASE3}.reuse-lock"
mkdir -p "$LOCK3"
printf '%s\n' "$$" > "$LOCK3/pid"
set_old_mtime "$LOCK3" 7200
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE3"; then
    bad "lock with live PID was reaped"
else
    if [[ -d "$LOCK3" && "$(cat "$LOCK3/pid")" == "$$" ]]; then
        ok "lock with live PID and missing acquired_at preserved"
    else
        bad "lock with live PID was mutated"
    fi
fi

echo "== 5. Old lock with dead pid and missing acquired_at IS recovered =="
LEASE4="$DISK_MAGICIAN_STATE_DIR/worktree_leases/dead-pid-no-stamp.json"
LOCK4="${LEASE4}.reuse-lock"
mkdir -p "$LOCK4"
( exit 0 ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s\n' "$DEAD_PID" > "$LOCK4/pid"
set_old_mtime "$LOCK4" 7200
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE4"; then
    if [[ ! -e "$LOCK4" && ! -e "${LOCK4}.reclaim_gate" ]]; then
        ok "old dead-pid lock missing acquired_at recovered cleanly"
    else
        bad "dead-pid partial lock left residue"
    fi
else
    bad "old dead-pid lock missing acquired_at was not recovered"
fi

echo "== 6. Active reclaim_gate prevents concurrent reap =="
LEASE5="$DISK_MAGICIAN_STATE_DIR/worktree_leases/gated-empty.json"
LOCK5="${LEASE5}.reuse-lock"
GATE5="${LOCK5}.reclaim_gate"
mkdir -p "$LOCK5" "$GATE5"
set_old_mtime "$LOCK5" 7200
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE5"; then
    bad "recovered despite busy reclaim_gate"
else
    if [[ -d "$LOCK5" ]]; then
        ok "busy reclaim_gate blocks concurrent recovery"
    else
        bad "lock disappeared while reclaim_gate was busy"
    fi
fi

echo "== 7. Complete metadata, dead pid, FRESH stamp IS recovered immediately =="
LEASE6="$DISK_MAGICIAN_STATE_DIR/worktree_leases/dead-pid-fresh.json"
LOCK6="${LEASE6}.reuse-lock"
mkdir -p "$LOCK6"
printf '%s\n' "$DEAD_PID" > "$LOCK6/pid"
date +%s > "$LOCK6/acquired_at"
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE6" && [[ ! -e "$LOCK6" ]]; then
    ok "fresh complete lock with dead owner reaped without waiting for TTL"
else
    bad "fresh complete lock with dead owner was not reaped"
fi

echo "== 8. Complete metadata, live pid, fresh stamp is NOT reaped =="
LEASE7="$DISK_MAGICIAN_STATE_DIR/worktree_leases/live-pid-fresh.json"
LOCK7="${LEASE7}.reuse-lock"
mkdir -p "$LOCK7"
printf '%s\n' "$$" > "$LOCK7/pid"
date +%s > "$LOCK7/acquired_at"
if LEASE_REUSE_LOCK_TTL_SEC=3600 lease_reuse_lock_recover "$LEASE7"; then
    bad "live-owner fresh lock was reaped"
else
    [[ -d "$LOCK7" ]] && ok "live-owner fresh lock preserved" || bad "live-owner lock disappeared"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

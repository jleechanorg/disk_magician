#!/usr/bin/env bash
# test_lease_registration_diagnostics.sh — a failed lease registration must name
# the registry-lock holder and the remaining recovery window (disk_magician-p39b).
#
# Before this, worktree-new/scratch-new discarded the cause and printed only
# "lease write failed: <path>", while a live sweeper (observed 2026-10-30: the
# installed cleanup_dev_caches.sh, held >5 min) or a crashed holder blocked every
# registration for up to the 3600 s stale-lock gate.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-lease-diag.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1${2:+ ($2)}"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2"; }

state="$T/state"
leases="$state/worktree_leases"
mkdir -p "$leases"
export DISK_MAGICIAN_STATE_DIR="$state"

# run_lease_write <label> — attempt a real lease write in an isolated registry and
# print the diagnostic the callers now surface.
run_lease_write() {
  LEASE_TEST_PATH="$T/candidate-$1" bash -c '
source "'"$ROOT"'/scripts/lib/worktree_lease.sh"
if lease_write "$LEASE_TEST_PATH" "$LEASE_TEST_PATH" "" test-lease; then
  echo "write=ok"
else
  echo "write=failed failure=${LEASE_REGISTRATION_FAILURE:-<empty>}"
fi
' 2>&1
}

# 1. Free registry: the write succeeds and reports no lock diagnostic.
out="$(run_lease_write free)"
check "free registry: lease write succeeds" "write=ok" "$out"
[[ "$out" != *registry-lock-busy* ]] && ok "free registry: no lock diagnostic emitted" || \
  bad "free registry: no lock diagnostic emitted" "$out"

# 2. Live holder: the diagnostic names the holder, its liveness and the window.
sleep 120 &
holder=$!
mkdir -p "$leases/.owner-mutation.reuse-lock"
printf '%s\n' "$holder" > "$leases/.owner-mutation.reuse-lock/pid"
date +%s > "$leases/.owner-mutation.reuse-lock/acquired_at"
out="$(run_lease_write live)"
[[ -d "$leases/.owner-mutation.reuse-lock" ]] && ok "diagnostics never remove a live holder's lock" || \
  bad "diagnostics never remove a live holder's lock"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
check "live holder: the write fails" "write=failed" "$out"
check "live holder: diagnostic name is stable" "registry-lock-busy" "$out"
check "live holder: diagnostic names the holder pid" "holder_pid=$holder" "$out"
check "live holder: diagnostic reports a live holder" "holder_alive=true" "$out"
[[ "$out" =~ ttl_remaining_s=[0-9]+ ]] && ok "live holder: diagnostic reports a numeric recovery window" || \
  bad "live holder: diagnostic reports a numeric recovery window" "$out"

# 3. Crashed holder with complete metadata inside the old 3600 s gate: the dead
#    owner is reaped on contact (bead mc38), so the write succeeds without a
#    busy diagnostic. The pid must be a real, exited pid: ps rejects out-of-range
#    ids and the probe fails closed.
sleep 30 &
crashed=$!
kill "$crashed" 2>/dev/null
wait "$crashed" 2>/dev/null
rm -rf "${leases:?}/.owner-mutation.reuse-lock"
mkdir -p "$leases/.owner-mutation.reuse-lock"
printf '%s\n' "$crashed" > "$leases/.owner-mutation.reuse-lock/pid"
date +%s > "$leases/.owner-mutation.reuse-lock/acquired_at"
out="$(run_lease_write crashed)"
check "crashed holder: dead owner's lock is reaped and the write succeeds" "write=ok" "$out"
[[ "$out" != *registry-lock-busy* ]] && ok "crashed holder: no busy diagnostic after reaping" || \
  bad "crashed holder: no busy diagnostic after reaping" "$out"

# 4. Both user-facing callers interpolate the diagnostic.
for caller in worktree_new.sh scratch_new.sh; do
  grep -q 'lease write failed: .*LEASE_REGISTRATION_FAILURE' "$ROOT/scripts/$caller" && \
    ok "$caller surfaces the lease-registration diagnostic" || \
    bad "$caller surfaces the lease-registration diagnostic"
done

echo
echo "test_lease_registration_diagnostics: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

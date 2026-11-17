#!/usr/bin/env bash
# Lease-busy handling in scripts/cleanup_scratch_top_level.sh (bead disk_magician-0ahn):
# a registry lock released mid-pass lets later entries evict; a lock held for the
# whole pass stops after the streak limit and never reports safe-candidates-exhausted.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/cleanup_scratch_top_level.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-scratch-busy.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2 | got: $(printf '%s' "$3" | tr '\n' ' ' | tail -c 900)"; }

mkdir -p "$T/home" "$T/state/worktree_leases"; chmod 700 "$T/home"
FAKE_DISKM="$T/fake-diskm"
cat >"$FAKE_DISKM" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "volume status" ]] || exit 2
kb="$(du -sk "$FAKE_SCRATCH_ROOT" | awk '{print $1}')"
printf '{"volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":%s}]}\n' "$(( kb * 1024 ))" "$FAKE_QUOTA_BYTES"
FAKE
chmod +x "$FAKE_DISKM"

# `sleep` shim: instant, and (when RELEASE_AFTER is set) drops the held lock after
# that many calls, i.e. after the first entry exhausted its retry budget.
SHIM="$T/shim"; mkdir -p "$SHIM"
cat >"$SHIM/sleep" <<'EOF2'
#!/usr/bin/env bash
if [[ -n "${RELEASE_AFTER:-}" ]]; then
  n=$(( $(cat "$SLEEP_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$SLEEP_COUNT"
  (( n == RELEASE_AFTER )) && rm -rf "$LOCK_DIR"
fi
exit 0
EOF2
chmod +x "$SHIM/sleep"

LOCK_DIR="$T/state/worktree_leases/.owner-mutation.reuse-lock"
hold_lock() { rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"; echo "$$" >"$LOCK_DIR/pid"; date +%s >"$LOCK_DIR/acquired_at"; }

age() { python3 -c 'import os,sys,time
root=sys.argv[1]; t=time.time()-float(sys.argv[2])*60
for d,ds,fs in os.walk(root):
    for n in ds+fs: os.utime(os.path.join(d,n),(t,t),follow_symlinks=False)
os.utime(root,(t,t))' "$1" "$2"; }

run_case() { # extra env assignments...
  SANDBOX="$T/sandbox/r$RANDOM"; SCRATCH_ROOT="$SANDBOX/scratch"; mkdir -p "$SCRATCH_ROOT"
  for n in pr101 pr102 pr103 pr104 pr105 pr106; do
    mkdir -p "$SCRATCH_ROOT/$n"; head -c 1024000 /dev/urandom >"$SCRATCH_ROOT/$n/payload.bin"; age "$SCRATCH_ROOT/$n" 3000
  done
  env -i HOME="$T/home" PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" TMPDIR="$T" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
    DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" DISK_MAGICIAN_STATE_DIR="$T/state" \
    DISK_MAGICIAN_DELETION_LOG="$T/del.log" DISK_MAGICIAN_DISKM_BIN="$FAKE_DISKM" \
    FAKE_SCRATCH_ROOT="$SCRATCH_ROOT" FAKE_QUOTA_BYTES=$(( 10 * 1024 * 1024 )) \
    DISK_MAGICIAN_LEASE_BUSY_TRIES=5 SLEEP_COUNT="$T/sleepcount" LOCK_DIR="$LOCK_DIR" DISK_MAGICIAN_AGE_FLOOR_MINUTES=120 DISK_MAGICIAN_SCRATCH_AUTOMATIC=$AUTO SCRATCH_TOP_LEVEL_APPROVED=$((1-AUTO)) "$@" \
    bash "$SCRIPT" --clean $([[ "$AUTO" == 1 ]] || echo --budget-pct 5 --budget-floor-minutes 120) 2>&1
}

# Automatic mode needs a verified registered Scratch mount (not fixturable here)
# but shares this exact loop branch, so manual mode covers the streak logic.
for mode in manual; do
  AUTO=0
  echo "Test ($mode): lock released after the first entry's retries -> later entries evict, busy one deferred"
  rm -f "$T/sleepcount"; hold_lock
  out="$(run_case RELEASE_AFTER=5)"
  [[ "$out" != *" removed=0 "* && "$out" == *"removed=5 "* ]] && ok "$mode: later entries evicted" || bad "$mode: later entries evicted" "$(printf '%s' "$out" | tail -c 500)"
  check "$mode: deferred entries counted" "deferred_lease_busy=1" "$out"

  echo "Test ($mode): lock held for the whole pass -> stops at the streak limit, never 'exhausted'"
  rm -f "$T/sleepcount"; hold_lock
  out="$(run_case)"
  check "$mode: stops on lease-busy" "skipped:lease-busy" "$out"
  check "$mode: deferred count equals streak limit" "deferred_lease_busy=3" "$out"
  check "$mode: result unknown, not exhausted" "budget_unmet=unknown" "$out"
  [[ "$out" != *safe-candidates-exhausted* ]] && ok "$mode: not reported as exhausted" || bad "$mode: not reported as exhausted"
done
rm -rf "$LOCK_DIR"
echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" == 0 ]]

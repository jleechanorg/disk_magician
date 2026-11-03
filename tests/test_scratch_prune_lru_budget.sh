#!/usr/bin/env bash
# Tests for the LRU budget mode of scripts/cleanup_scratch_top_level.sh
# (diskm scratch-prune --budget-pct N, bead disk_magician-walx).
#
# Usage is measured through a fake diskm whose `volume status` reports the real
# du of the sandbox root against a fixed quota, so every eviction moves it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/cleanup_scratch_top_level.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-scratch-lru.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2 | got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-500)"; }
gone() { [[ ! -e "$SCRATCH_ROOT/$1" ]] && ok "$1 evicted" || bad "$1 evicted" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500)"; }
kept() { [[ -d "$SCRATCH_ROOT/$1" ]] && ok "$1 kept" || bad "$1 kept"; }

LOG="$T/deletions.log"
mkdir -p "$T/home" "$T/state"

FAKE_DISKM="$T/fake-diskm"
cat >"$FAKE_DISKM" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "volume status" ]] || exit 2
[[ -n "${FAKE_STATUS_FAIL:-}" ]] && exit 3
kb="$(du -sk "$FAKE_SCRATCH_ROOT" | awk '{print $1}')"
printf '{"volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":%s}]}\n' "$(( kb * 1024 ))" "$FAKE_QUOTA_BYTES"
FAKE
chmod +x "$FAKE_DISKM"

# Test-only PATH shim: content-mtime probes fail for paths named *unmeasurable*.
SHIM="$T/shim"
mkdir -p "$SHIM"
for tool in find stat; do
  real="$(command -v "$tool")"
  cat >"$SHIM/$tool" <<EOF
#!/usr/bin/env bash
case "\$*" in *unmeasurable*) exit 1 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$tool"
done

ROOT_SEQ=0
use_root() {
  ROOT_SEQ=$(( ROOT_SEQ + 1 ))
  SANDBOX="$T/sandbox/r${ROOT_SEQ}"
  SCRATCH_ROOT="$SANDBOX/scratch"
  mkdir -p "$SCRATCH_ROOT"
  : >"$LOG"
}

age() { python3 -c 'import os,sys,time
root=sys.argv[1]; t=time.time()-float(sys.argv[2])*60
for d,ds,fs in os.walk(root):
    for n in ds+fs: os.utime(os.path.join(d,n),(t,t),follow_symlinks=False)
os.utime(root,(t,t))' "$1" "$2"; }

make_tree() { # <name> <age_minutes>
  mkdir -p "$SCRATCH_ROOT/$1"
  head -c 1024000 /dev/urandom >"$SCRATCH_ROOT/$1/payload.bin"
  age "$SCRATCH_ROOT/$1" "$2"
}

# 10 MiB quota: five ~1 MiB trees are ~49% used.
run() {
  env -i HOME="$T/home" PATH="${RUN_PATH:-/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin}" TMPDIR="$T" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
    DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" DISK_MAGICIAN_STATE_DIR="$T/state" \
    DISK_MAGICIAN_DELETION_LOG="$LOG" DISK_MAGICIAN_DISKM_BIN="$FAKE_DISKM" \
    FAKE_SCRATCH_ROOT="$SCRATCH_ROOT" FAKE_QUOTA_BYTES=$(( 10 * 1024 * 1024 )) \
    "$@"
}

echo "Test 1: dry-run previews oldest-first eviction to the target and deletes nothing"
use_root
make_tree a 600; make_tree b 3000; make_tree c 1800; make_tree d 300; make_tree e 1200
out="$(run bash "$SCRIPT" --dry-run --budget-pct 35 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "dry-run exits 0" || bad "dry-run exits 0" "rc=$rc"
check "dry-run previews the oldest entry" "would-remove:kept:unproven-content $SCRATCH_ROOT/b" "$out"
check "dry-run previews the second-oldest entry" "would-remove:kept:unproven-content $SCRATCH_ROOT/c" "$out"
[[ "$out" != *"would-remove:kept:unproven-content $SCRATCH_ROOT/e"* ]] && ok "dry-run stops once the target would hold" || bad "dry-run stops once the target would hold" "$out"
check "dry-run reports the target stop" "lru: stop=target-reached would_evict=2" "$out"
for n in a b c d e; do kept "$n"; done
[[ ! -s "$LOG" ]] && ok "dry-run wrote no deletion-log row" || bad "dry-run wrote no deletion-log row"

echo "Test 2: --clean without approval refuses"
out="$(run bash "$SCRIPT" --clean --budget-pct 35 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "unapproved clean refuses with rc=2" || bad "unapproved clean refuses with rc=2" "rc=$rc"

echo "Test 3: approved clean evicts least-recently-used first and stops at the target"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 35 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "clean exits 0" || bad "clean exits 0" "rc=$rc"
gone b; gone c
kept e; kept a; kept d
b_line="$(printf '%s\n' "$out" | grep -n "^removed:.*/b " | cut -d: -f1)"
c_line="$(printf '%s\n' "$out" | grep -n "^removed:.*/c " | cut -d: -f1)"
[[ -n "$b_line" && -n "$c_line" && "$b_line" -lt "$c_line" ]] && ok "oldest entry is evicted first" || bad "oldest entry is evicted first" "b=$b_line c=$c_line"
check "clean reports the target stop" "lru: stop=target-reached evicted=2" "$out"
check "deletion log records the prior C14 verdict" "scratch-lru:kept:unproven-content" "$(cat "$LOG")"
check "summary tallies prior verdicts" "lru: prior_verdict kept:unproven-content=2" "$out"

echo "Test 4: under target is a no-op"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 90 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "no-op exits 0" || bad "no-op exits 0" "rc=$rc"
check "no-op names the met target" "skipped:budget-target-met" "$out"
kept a

echo "Test 5: the recency floor exempts young entries; the floor never drops below 60 minutes"
use_root
make_tree old 600; make_tree young 90; make_tree fresh 45
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 1 2>&1)"
gone old; kept young; kept fresh
check "young entry keeps as recent activity" "kept:recent-activity $SCRATCH_ROOT/young" "$out"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 1 --budget-floor-minutes 10 2>&1)"
gone young; kept fresh
check "a floor below 60 minutes is clamped up" "kept:recent-activity $SCRATCH_ROOT/fresh" "$out"

echo "Test 6: live lease, live cwd and open files are never evicted"
use_root
make_tree plain 600; make_tree leased 600; make_tree cwd-held 600; make_tree open-held 600
sleep 300 & lease_pid=$!
env DISK_MAGICIAN_STATE_DIR="$T/state" bash -c 'source "$1/scripts/lib/worktree_lease.sh"
lease_write "$2" "$2" "" scratch-lru-test --owner-pid "$3" >/dev/null' _ "$ROOT" "$SCRATCH_ROOT/leased" "$lease_pid"
( cd "$SCRATCH_ROOT/cwd-held" && exec sleep 300 ) & cwd_pid=$!
( exec 3<"$SCRATCH_ROOT/open-held/payload.bin"; exec sleep 300 ) & open_pid=$!
sleep 1
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 1 2>&1)"; rc=$?
kill "$lease_pid" "$cwd_pid" "$open_pid" 2>/dev/null; wait "$lease_pid" "$cwd_pid" "$open_pid" 2>/dev/null
gone plain; kept leased; kept cwd-held; kept open-held
check "live lease is the keep reason" "kept:live-owner $SCRATCH_ROOT/leased" "$out"
check "live cwd is the keep reason" "kept:live-cwd $SCRATCH_ROOT/cwd-held" "$out"
check "open file is the keep reason" "kept:open-file $SCRATCH_ROOT/open-held" "$out"
check "candidates ran out before the target" "lru: stop=candidates-exhausted" "$out"
[[ "$rc" == 4 ]] && ok "unmet target exits 4, not 0" || bad "unmet target exits 4, not 0" "rc=$rc"
check "unmet target is reported with target, achieved and reason" "budget: target_pct=1 achieved_pct=" "$out"
check "unmet target states target_reached=false and the reason" "target_reached=false reason=candidates-exhausted" "$out"
check "unmet target emits the partial marker" "partial:budget-target-unmet" "$out"

echo "Test 7: unmeasurable recency is kept"
use_root
make_tree unmeasurable-tree 600; make_tree measurable 600
out="$(RUN_PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 1 2>&1)"
kept unmeasurable-tree; gone measurable
check "unmeasurable entry reports its keep" "kept:mtime-unmeasurable $SCRATCH_ROOT/unmeasurable-tree" "$out"

echo "Test 8: a dirty repository is evicted and its prior verdict is logged and counted"
use_root
make_tree dirty-repo 600
git -C "$SCRATCH_ROOT/dirty-repo" init -q
printf 'change\n' >"$SCRATCH_ROOT/dirty-repo/tracked.txt"
git -C "$SCRATCH_ROOT/dirty-repo" add tracked.txt
age "$SCRATCH_ROOT/dirty-repo" 600
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --budget-pct 1 2>&1)"
gone dirty-repo
check "deletion log line carries the dirty verdict" "scratch-lru:kept:dirty" "$(grep -F "$SCRATCH_ROOT/dirty-repo" "$LOG")"
check "summary counts the dirty eviction" "not_pushed_or_dirty=1" "$out"
check "summary lists the prior verdict" "lru: prior_verdict kept:dirty=1" "$out"

echo "Test 9: usage that cannot be measured fails closed"
use_root
make_tree a 600
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 FAKE_STATUS_FAIL=1 bash "$SCRIPT" --clean --budget-pct 1 2>&1)"; rc=$?
[[ "$rc" == 75 ]] && ok "unmeasurable usage exits 75" || bad "unmeasurable usage exits 75" "rc=$rc"
check "unmeasurable usage is reported" "skipped:measurement-unavailable" "$out"
kept a

echo "Test 10: budget mode refuses the automatic and available-floor modes"
out="$(run env DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --dry-run --budget-pct 50 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "automatic + budget refuses" || bad "automatic + budget refuses" "rc=$rc"
out="$(run bash "$SCRIPT" --dry-run --available-floor --budget-pct 50 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "available-floor + budget refuses" || bad "available-floor + budget refuses" "rc=$rc"
out="$(run bash "$SCRIPT" --dry-run --budget-pct 100 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "budget percent above 99 refuses" || bad "budget percent above 99 refuses" "rc=$rc"

echo
echo "test_scratch_prune_lru_budget: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

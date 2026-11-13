#!/usr/bin/env bash
# Tests for `diskm emergency` (scripts/emergency_reclaim.sh): floor descent, early stop,
# target_unmet exit, single lock hold, dry-run, optional worktree step, dispatcher route.
# Cleaners and df are stubbed; nothing touches real /tmp or Scratch.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/emergency-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
chmod 700 "$W"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

GIB_KB=1048576
mkdir -p "$W/bin" "$W/cleaners" "$W/scratch" "$W/home"
chmod 700 "$W/home"

cat >"$W/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nstub 99999999 1 %s 1%% /\n' "$(cat "$STUB_FREE_FILE")"
EOF
chmod +x "$W/bin/df"

# Stub cleaner: logs its context, proves it can reuse the parent's lock hold, then frees
# the KiB the plan file lists for "<lane>:<floor-hours>".
for lane in tmp:cleanup_tmp.sh scratch:cleanup_scratch_top_level.sh worktrees:cleanup_worktrees.sh; do
  name="${lane%%:*}"; file="${lane#*:}"
  cat >"$W/cleaners/$file" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/scripts/lib/scratch_lock.sh"
mode=clean; for a in "\$@"; do [[ "\$a" == --dry-run ]] && mode=dry; done
hours=\$(( \${DISK_MAGICIAN_AGE_FLOOR_MINUTES:-0} / 60 ))
if [[ \$mode == clean ]]; then
  # Reuses the held lock; would exec the lock helper (and report skipped) if it could not.
  scratch_lock_acquire "$name-stub" "\$@" || exit \$?
fi
echo "$name mode=\$mode hours=\$hours lockfd=\${DISK_MAGICIAN_SCRATCH_LOCK_FD:-none} ltp=\${LARGE_TMP_APPROVED:-} stp=\${SCRATCH_TOP_LEVEL_APPROVED:-} wta=\${WORKTREE_APPROVED:-} args=\$*" >>"\$STUB_CALL_LOG"
kb=\$(awk -F= -v k="$name:\$hours" '\$1==k {print \$2}' "\$STUB_PLAN" 2>/dev/null)
kb=\${kb:-0}
if [[ \$mode == clean ]]; then
  echo \$(( \$(cat "\$STUB_FREE_FILE") + kb )) >"\$STUB_FREE_FILE"
  echo "removed \$kb KB"
else
  echo "scanned=1 kept=0 removable=1 removed=0 eligible_estimate=1 candidate_size_estimate_kb=\$kb deletion_size_estimate_kb=0"
fi
EOF
  chmod +x "$W/cleaners/$file"
done

# run_emergency FREE_GIB PLAN... -- ARGS... ; leaves OUT, RC; call log in $W/calls.log
run_emergency() {
  local free_gib="$1"; shift
  : >"$W/calls.log"; : >"$W/plan"
  while (($#)) && [[ "$1" != -- ]]; do echo "$1" >>"$W/plan"; shift; done
  shift
  echo $((free_gib * GIB_KB)) >"$W/free_kb"
  OUT="$(env -u LARGE_TMP_APPROVED -u SCRATCH_TOP_LEVEL_APPROVED -u WORKTREE_APPROVED \
    HOME="$W/home" PATH="$W/bin:$PATH" STUB_FREE_FILE="$W/free_kb" STUB_PLAN="$W/plan" STUB_CALL_LOG="$W/calls.log" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$W" DISKM_EMERGENCY_CLEANER_DIR="$W/cleaners" \
    DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$W/scratch" DISKM_EMERGENCY_DATA_ROOT="$W" \
    DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS="${LOCK_WAIT:-5}" \
    bash "$REPO_ROOT/disk_magician.sh" emergency "$@" 2>&1)"
  RC=$?
}

# 1. Early stop at the floor where the target is met; lower floors never run.
run_emergency 5 "tmp:24=$((2 * GIB_KB))" "scratch:24=$((1 * GIB_KB))" "tmp:12=$((3 * GIB_KB))" "scratch:12=$((9 * GIB_KB))" -- --target-gb 10
check "early stop exits 0 with target_met" '[[ $RC -eq 0 && "$OUT" == *"result: target_met"* ]]' "rc=$RC"
check "stops after tmp 12h; scratch 12h and 6h/2h never run" \
  '! grep -q "scratch mode=clean hours=12" "$W/calls.log" && ! grep -q "hours=6\|hours=2 " "$W/calls.log" && grep -q "tmp mode=clean hours=12" "$W/calls.log"'
check "prints running freed_so_far / target lines" '[[ "$OUT" == *"freed_so_far 2.00GiB / 10GiB"* && "$OUT" == *"freed_so_far 6.00GiB / 10GiB"* ]]'
check "receipt reports per-lane df bytes" '[[ "$OUT" == *"lane tmp=5.00GiB lane scratch=1.00GiB lane worktrees=0.00GiB"* ]]'
check "approval vars reach cleaners only" 'grep -q "ltp=1" "$W/calls.log" && grep -q "stp=1" "$W/calls.log" && [[ -z "${LARGE_TMP_APPROVED:-}${SCRATCH_TOP_LEVEL_APPROVED:-}" ]]'
check "floor passed as DISK_MAGICIAN_AGE_FLOOR_MINUTES" 'grep -q "tmp mode=clean hours=24" "$W/calls.log"'
check "one lock hold: every cleaner saw the same lock fd" \
  '[[ $(grep -o "lockfd=[0-9]*" "$W/calls.log" | sort -u | wc -l) -eq 1 && "$(grep -o "lockfd=[a-z0-9]*" "$W/calls.log" | head -1)" != lockfd=none ]]'

# 2. target_unmet: every floor runs, 0 B is never success, 2 h is the minimum.
run_emergency 5 -- --target-gb 50
check "target_unmet exits nonzero" '[[ $RC -ne 0 && "$OUT" == *"target_unmet"* ]]' "rc=$RC"
check "descends 24,12,6,2 then stops" \
  'for h in 24 12 6 2; do grep -q "tmp mode=clean hours=$h " "$W/calls.log" || exit 1; done; ! grep -q "hours=1 \|hours=0 " "$W/calls.log"'
check "receipt names the 2h floor" '[[ "$OUT" == *"floor_reached=2h"* ]]'

run_emergency 5 -- --target-gb 50 --max-age-hours 1
check "--max-age-hours below 2 is raised to 2" '[[ $(grep -c "tmp mode=clean" "$W/calls.log") -eq 1 ]] && grep -q "tmp mode=clean hours=2 " "$W/calls.log"'

run_emergency 5 -- --target-gb 50 --max-age-hours 6
check "--max-age-hours 6 runs 6 then 2" '[[ $(grep -c "tmp mode=clean" "$W/calls.log") -eq 2 ]]'

# 3. Already met: no cleaner runs.
run_emergency 100 -- --target-gb 10
check "already-met target runs no cleaner" '[[ $RC -eq 0 && ! -s "$W/calls.log" ]]'

# 4. Dry-run: dry-run args, no approvals, no lock, projections per floor, df unchanged.
run_emergency 5 "tmp:24=$((2 * GIB_KB))" "scratch:12=$((4 * GIB_KB))" -- --target-gb 50 --dry-run
check "dry-run exits 0 and leaves free space alone" '[[ $RC -eq 0 && "$(cat "$W/free_kb")" -eq $((5 * GIB_KB)) ]]'
check "dry-run cleaners get --dry-run, no approvals, no lock" \
  '! grep -q "mode=clean" "$W/calls.log" && ! grep -q "ltp=1\|stp=1\|wta=1" "$W/calls.log" && ! grep -q "lockfd=[0-9]" "$W/calls.log"'
check "dry-run prints projected bytes per floor" \
  '[[ "$OUT" == *"projected tmp 24h: 2.00GiB"* && "$OUT" == *"projected scratch 12h: 4.00GiB"* && "$OUT" == *"projected tmp 2h"* ]]'

# 5. Worktrees: only with the flag, only last, with WORKTREE_APPROVED.
run_emergency 5 "tmp:2=$((1 * GIB_KB))" -- --target-gb 50
check "worktrees not run without --include-worktrees" '! grep -q "^worktrees" "$W/calls.log"'
run_emergency 5 "worktrees:2=$((60 * GIB_KB))" -- --target-gb 50 --include-worktrees
check "--include-worktrees runs cleanup-worktrees last with WORKTREE_APPROVED=1" \
  'tail -1 "$W/calls.log" | grep -q "^worktrees mode=clean.*wta=1" && [[ $(grep -c "^worktrees" "$W/calls.log") -eq 1 ]] && [[ "$OUT" == *"result: target_met"* ]]'
run_emergency 100 -- --target-gb 10 --include-worktrees
check "worktrees skipped when the target is already met" '! grep -q "^worktrees" "$W/calls.log"'

# 6. Lock contention exits 75 instead of reporting success.
python3 -I - "$W/home" >"$W/holder.out" 2>&1 <<'PY' &
import fcntl, os, sys, time
d = os.path.join(sys.argv[1], ".disk_magician_locks"); os.makedirs(d, exist_ok=True)
fd = os.open(os.path.join(d, "scratch_cleanup.lock"), os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX); print("held", flush=True); time.sleep(8)
PY
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$W/holder.out" 2>/dev/null && break; sleep 0.3; done
LOCK_WAIT=1 run_emergency 5 -- --target-gb 50
check "lock held elsewhere -> exit 75, no cleaner ran" '[[ $RC -eq 75 && ! -s "$W/calls.log" ]]' "rc=$RC"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# 7. Guards and routing.
check "cleaner override refused outside the test sandbox" \
  '! env -u DISK_MAGICIAN_TEST_CONTEXT -u DISK_MAGICIAN_TEST_SANDBOX DISKM_EMERGENCY_CLEANER_DIR="$W/cleaners" bash "$REPO_ROOT/scripts/emergency_reclaim.sh" --dry-run >/dev/null 2>&1'
check "bad --target-gb is a usage error (2)" 'bash "$REPO_ROOT/scripts/emergency_reclaim.sh" --target-gb x >/dev/null 2>&1; [[ $? -eq 2 ]]'
check "dispatcher help lists emergency" 'h="$(bash "$REPO_ROOT/disk_magician.sh" help 2>&1)"; grep -q "^  emergency " <<<"$h"'
check "dispatcher routes emergency --help" 'h="$(bash "$REPO_ROOT/disk_magician.sh" emergency --help 2>&1)"; grep -q "Emergency reclaim" <<<"$h"'

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]

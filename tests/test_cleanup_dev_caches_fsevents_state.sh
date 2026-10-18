#!/usr/bin/env bash
# test_cleanup_dev_caches_fsevents_state.sh — the fsevents state-cache seam.
#
# Contract (bead disk_magician-cleanup-cli-gaps-v8kd,
# findings_wiki/2026-10-17-fsevents-state-cache-unbounded-growth.md):
# cleanup_dev_caches.sh owns ~/.local/state/fsevents-projects.state.json, the
# rotation-exempt polling snapshot of scripts/watch_projects_fsevents.sh. It
# drops that cache when it has not been written for the watcher's own KEEP_DAYS
# OR when it exceeds the watcher's own MAX_BYTES cap (a live watcher rewrites
# the mtime continuously, so an age-only gate never fires), and it keeps the
# file under a safety rule, when it is not a regular file, or when the path
# cannot be resolved. Nothing else in ~/.local/state is touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_dev_caches.sh"

WORK="$(cd "$(mktemp -d -t test_dev_caches_fsevents.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

backdate() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
t = time.time() - float(sys.argv[2]) * 86400
os.utime(sys.argv[1], (t, t))
PY
}

# mkhome <home> [<state_kb>]: state dir + a rotation-exempt cache file.
mkhome() {
  local h="$1" kb="${2:-4}"
  mkdir -p "$h/.local/state" "$h/.config/disk-magician"
  printf '{}\n' >"$h/.config/disk-magician/safety.local.json"
  python3 - "$h/.local/state/fsevents-projects.state.json" "$kb" <<'PY'
import sys
path, kb = sys.argv[1], int(sys.argv[2])
with open(path, "wb") as fh:
    fh.write(b"x" * (kb * 1024))
PY
}

run() {
  local h="$1"; shift
  HOME="$h" DISK_MAGICIAN_SAFETY_FILE="$h/.config/disk-magician/safety.local.json" \
    DISK_MAGICIAN_TEST_SANDBOX="$h" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dev_caches_fsevents \
    DISK_MAGICIAN_DELETION_LOG="$h/deletions.log" bash "$SCRIPT" "$@"
}

echo "Test 1: dry-run reports the stale state cache and deletes nothing"
H1="$WORK/h1"; mkhome "$H1"
backdate "$H1/.local/state/fsevents-projects.state.json" 10
rc=0; run "$H1" --dry-run >"$WORK/t1.out" 2>&1 || rc=$?
check "dry-run exits 0" '[[ "$rc" -eq 0 ]]'
check "dry-run keeps the state cache" '[[ -f "$H1/.local/state/fsevents-projects.state.json" ]]'
check "dry-run reports the would-drop" 'grep -q "would drop" "$WORK/t1.out"'
check "dry-run names the age gate" 'grep -q "untouched for 7d" "$WORK/t1.out"'

echo "Test 2: --clean drops the aged state cache and nothing else in ~/.local/state"
H2="$WORK/h2"; mkhome "$H2"
STATE2="$H2/.local/state/fsevents-projects.state.json"
printf 'rotated\n' >"$H2/.local/state/fsevents-projects.log.2026-10-01"
printf '{}\n' >"$H2/.local/state/other.state.json"
backdate "$STATE2" 10
backdate "$H2/.local/state/other.state.json" 10
rc=0; run "$H2" --clean >"$WORK/t2.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "--clean removes the aged state cache" '[[ ! -e "$STATE2" ]]'
check "rotated watcher log untouched" '[[ -f "$H2/.local/state/fsevents-projects.log.2026-10-01" ]]'
check "unrelated state file untouched" '[[ -f "$H2/.local/state/other.state.json" ]]'
check "removal is logged for the audit trail" 'grep -q "drop_fsevents_state_cache" "$H2/deletions.log"'
check "removal is reported" 'grep -q "dropped" "$WORK/t2.out"'

echo "Test 3: a recent, under-cap cache is retained"
H3="$WORK/h3"; mkhome "$H3"
rc=0; run "$H3" --clean >"$WORK/t3.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "recent under-cap cache kept" '[[ -f "$H3/.local/state/fsevents-projects.state.json" ]]'
check "retention is reported" 'grep -q "retained (recent and under the cap)" "$WORK/t3.out"'

echo "Test 4: a fresh cache over the watcher's MAX_BYTES cap is dropped (size gate)"
H4="$WORK/h4"; mkhome "$H4" 17408   # 17 MiB, mtime is now
rc=0; run "$H4" --clean >"$WORK/t4.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "over-cap cache dropped despite a fresh mtime" '[[ ! -e "$H4/.local/state/fsevents-projects.state.json" ]]'
check "size gate is named" 'grep -q "over the 16M cap" "$WORK/t4.out"'

echo "Test 5: a safety rule keeps an otherwise-droppable cache (fail closed)"
H5="$WORK/h5"; mkhome "$H5"
backdate "$H5/.local/state/fsevents-projects.state.json" 10
printf '{"never_delete": ["~/.local/state/fsevents-projects.state.json"]}\n' \
  >"$H5/.config/disk-magician/safety.local.json"
rc=0; run "$H5" --clean >"$WORK/t5.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "protected cache survives" '[[ -f "$H5/.local/state/fsevents-projects.state.json" ]]'
check "safety skip is reported" 'grep -q "SAFETY-SKIP" "$WORK/t5.out"'

echo "Test 6: unreadable safety file fails closed"
H6="$WORK/h6"; mkhome "$H6"
backdate "$H6/.local/state/fsevents-projects.state.json" 10
printf 'not json\n' >"$H6/.config/disk-magician/safety.local.json"
rc=0; run "$H6" --clean >"$WORK/t6.out" 2>&1 || rc=$?
check "unreadable safety file keeps the cache" '[[ -f "$H6/.local/state/fsevents-projects.state.json" ]]'

echo "Test 7: a directory at the cache path is not a candidate"
H7="$WORK/h7"; mkdir -p "$H7/.local/state/fsevents-projects.state.json" "$H7/.config/disk-magician"
printf '{}\n' >"$H7/.config/disk-magician/safety.local.json"
backdate "$H7/.local/state/fsevents-projects.state.json" 10
rc=0; run "$H7" --clean >"$WORK/t7.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "directory left in place" '[[ -d "$H7/.local/state/fsevents-projects.state.json" ]]'
check "non-regular file is reported" 'grep -q "not a regular file" "$WORK/t7.out"'

echo "Test 8: an absent cache is a no-op"
H8="$WORK/h8"; mkdir -p "$H8/.local/state" "$H8/.config/disk-magician"
printf '{}\n' >"$H8/.config/disk-magician/safety.local.json"
rc=0; run "$H8" --clean >"$WORK/t8.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "absence is reported" 'grep -q "fsevents state cache: not found, skipping" "$WORK/t8.out"'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

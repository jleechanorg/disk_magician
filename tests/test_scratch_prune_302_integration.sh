#!/usr/bin/env bash
# PR302 manual discovery/min-size filters preserve PR293's floor and lock policy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t test_scratch_302.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/scratch/worldai_frontend/build/fixture" "$WORK/state"
printf '{}\n' >"$WORK/config.json"
printf '{}\n' >"$WORK/safety.json"
printf 'fixture\n' >"$WORK/scratch/worldai_frontend/build/fixture/payload"
python3 - "$WORK/scratch" <<'PY'
import os, sys, time
stamp = time.time() - 13 * 3600
for root, dirs, files in os.walk(sys.argv[1]):
    for name in dirs + files:
        os.utime(os.path.join(root, name), (stamp, stamp))
PY
run() {
  env -i HOME="$WORK/home" PATH="$PATH" TMPDIR="$WORK" \
    DISK_MAGICIAN_CONFIG="$WORK/config.json" DISK_MAGICIAN_SAFETY_FILE="$WORK/safety.json" \
    DISK_MAGICIAN_STATE_DIR="$WORK/state" DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$WORK" DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$WORK/scratch" \
    "$@"
}
ENTRY="$WORK/scratch/worldai_frontend/build/fixture"
SCRIPT="$ROOT/scripts/cleanup_scratch_top_level.sh"
run env DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=1 bash "$SCRIPT" --dry-run >"$WORK/floor.log" 2>&1
cat "$WORK/floor.log"
grep -Fq "kept:recent-activity $ENTRY" "$WORK/floor.log"
grep -Fq '< 24h)' "$WORK/floor.log"
run env DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 bash "$SCRIPT" --dry-run >"$WORK/manual.log" 2>&1
cat "$WORK/manual.log"
grep -Fq "kept:no-proof $ENTRY" "$WORK/manual.log"
run env DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 DISK_MAGICIAN_SCRATCH_MIN_KB=1048576 bash "$SCRIPT" --dry-run >"$WORK/minsize.log" 2>&1
cat "$WORK/minsize.log"
if grep -Fq "kept:no-proof $ENTRY" "$WORK/minsize.log"; then
  echo 'FAIL: below-threshold entry reached C14 classification' >&2
  exit 1
fi
grep -Fq 'scanned=1 kept=1 removable=0 removed=0' "$WORK/minsize.log"
rc=0
run bash "$SCRIPT" --lock-held >"$WORK/lock.log" 2>&1 || rc=$?
[[ "$rc" == 2 ]]
[[ -f "$ENTRY/payload" ]]
echo 'PASS: nested manual discovery, min-size filter, 24h default / 12h manual floor, normal lock policy'

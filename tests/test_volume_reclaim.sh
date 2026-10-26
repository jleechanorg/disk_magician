#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/dm-volume-reclaim.XXXXXX)"
if [[ -d /dev/shm ]] && [[ "$(stat -c %d /dev/shm 2>/dev/null || echo x)" != "$(stat -c %d /tmp 2>/dev/null || echo y)" ]]; then
  DISK_MAGICIAN_STATE_DIR="$(mktemp -d /dev/shm/dm-volume-reclaim-state.XXXXXX)"
else
  DISK_MAGICIAN_STATE_DIR="$T/state"
fi
export DISK_MAGICIAN_STATE_DIR
export DISK_MAGICIAN_DISKM_BIN="$T/diskm"
export TEST_ROOT="$T/volume"
export DISK_MAGICIAN_CONFIG="$T/config.json"
export DISK_MAGICIAN_DISKUTIL_BIN="$ROOT/tests/lib/fake_diskutil.py"
export FAKE_DISKUTIL_STATE="$T/diskutil.json"
export FAKE_DISKUTIL_CALLS="$T/diskutil.calls"
export FAKE_DISKUTIL_MOUNTPOINT="$TEST_ROOT"
export DISK_MAGICIAN_DELETION_LOG="$T/deletions.log"
python3 -c 'import json,os,sys; cfg={"volumes":{"swap_headroom_gb":40,"alarm_floor_gb":20,"encryption":"none","encryption_acknowledged_at":"2026-10-25T00:00:00Z","classes":{"scratch":{"name":"diskm-scratch","quota_gb":30,"mountpoint":os.environ["TEST_ROOT"]}}}}; json.dump(cfg,open(sys.argv[1],"w")); state={"container":{"ref":"disk3","uuid":"CONTAINER-UUID","ceiling":1000*2**30,"free":100*2**30},"volumes":[{"uuid":"DATA-UUID","name":"Data","ref":"disk3s1","device":"disk3s1","used":100*2**30,"quota":0,"roles":["Data"],"mountpoint":"/System/Volumes/Data"},{"uuid":"SYSTEM-UUID","name":"System","ref":"disk3s5","device":"disk3s5","used":10*2**30,"quota":0,"roles":["System"],"mountpoint":"/"},{"uuid":"VM-UUID","name":"VM","ref":"disk3s6","device":"disk3s6","used":10*2**30,"quota":0,"roles":["VM"],"mountpoint":"/System/Volumes/VM"}]}; json.dump(state,open(os.environ["FAKE_DISKUTIL_STATE"],"w"))' "$DISK_MAGICIAN_CONFIG"
python3 "$ROOT/scripts/volume.py" create scratch --execute
export STATUS_CALLS_FILE="$T/status.calls"
mkdir -p "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger" "$TEST_ROOT/repo/evidence/fresh"
printf x > "$TEST_ROOT/repo/evidence/oldest/content"
printf x > "$TEST_ROOT/repo/build/younger/content"
printf x > "$TEST_ROOT/repo/evidence/fresh/content"
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-60*3600,)*2)' "$TEST_ROOT/repo/build/younger/content"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-47*3600,)*2)' "$TEST_ROOT/repo/evidence/fresh/content"
cat > "$DISK_MAGICIAN_DISKM_BIN" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'volume path scratch --for-reclaim') printf '%s\n' "$TEST_ROOT" ;;
  'volume status --json')
    if [[ -n "${TEST_STATUS_SEQUENCE:-}" ]]; then
      n=0; [[ -f "$STATUS_CALLS_FILE" ]] && n="$(cat "$STATUS_CALLS_FILE")"
      n=$((n+1)); printf '%s' "$n" >"$STATUS_CALLS_FILE"
      set -- $TEST_STATUS_SEQUENCE; idx=$((n>=$# ? $# : n)); eval "used=\${$idx}"
    else used="${TEST_USED:-900}"; fi
    printf '{"volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":1000}]}\n' "$used"
    if [[ -n "${TEST_STATUS_RC_SEQUENCE:-}" ]]; then
      set -- $TEST_STATUS_RC_SEQUENCE; idx=$((n>=$# ? $# : n)); eval "rc=\${$idx}"
    else rc="${TEST_STATUS_RC:-0}"; fi
    exit "$rc"
    ;;
  'volume verify-mount '*) exit 0 ;;
  'volume ballast release scratch') printf 'release\n' >> "$BALLAST_LOG"; exit "${TEST_RELEASE_RC:-0}" ;;
  'volume ballast ensure scratch')
    printf 'ensure\n' >> "$BALLAST_LOG"
    if [[ -n "${TEST_ENSURE_MIN_STATUS_CALLS:-}" ]]; then
      n=0; [[ -f "$STATUS_CALLS_FILE" ]] && n="$(cat "$STATUS_CALLS_FILE")"
      (( n >= TEST_ENSURE_MIN_STATUS_CALLS )) || exit 1
    fi
    exit "${TEST_ENSURE_RC:-0}"
    ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$DISK_MAGICIAN_DISKM_BIN"
OUT="$("$ROOT/scripts/volume_reclaim.sh")"
[[ "$OUT" == *"evidence/oldest"* && "$OUT" == *"build/younger"* ]]
[[ "$OUT" != *"evidence/fresh"* ]]
[[ "$(printf '%s\n' "$OUT" | grep -n 'oldest' | cut -d: -f1)" -lt "$(printf '%s\n' "$OUT" | grep -n 'younger' | cut -d: -f1)" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success_noop" and r["candidates"]["aged_scanned"]==2'
touch "$TEST_ROOT/repo/evidence/oldest/content" "$TEST_ROOT/repo/build/younger/content" "$TEST_ROOT/repo/evidence/fresh/content"
DISK_MAGICIAN_TRIGGER=zero-aged "$ROOT/scripts/volume_reclaim.sh" --clean >/dev/null
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["aged_scanned"]==0 and not r["postcondition"]["target_reached"]'
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
TEST_STATUS_RC=1 "$ROOT/scripts/volume_reclaim.sh" | grep -q 'would_check:'
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success_noop" and r["precondition"]["used_pct"]==90'
TEST_USED=899 "$ROOT/scripts/volume_reclaim.sh" | grep -q 'skipped:below-trigger'
# The real C14 path removes one whole artifact, remeasures, and stops at the low-water target.
: >"$STATUS_CALLS_FILE"
TEST_STATUS_SEQUENCE="900 800" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-real-remove.out"
[[ ! -e "$TEST_ROOT/repo/evidence/oldest" && -e "$TEST_ROOT/repo/build/younger" ]]
[[ ! -s "$T/c14-real-remove.out" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["postcondition"]["target_reached"] and r["candidates"]["removed"]==1'
# C14 ENOSPC must be typed through the real cleanup wrapper before ballast release.
BALLAST_LOG="$T/ballast.log"
export BALLAST_LOG
mkdir -p "$TEST_ROOT/repo/evidence/oldest"; printf x >"$TEST_ROOT/repo/evidence/oldest/content"
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
: >"$STATUS_CALLS_FILE"
BALLAST_LOG="$T/ballast.log" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-release-fails.out"
grep -q 'kept:intent-write-failed' "$T/c14-release-fails.out"
grep -q '^release$' "$BALLAST_LOG" && grep -q '^ensure$' "$BALLAST_LOG"
! grep -q '^removed:' "$T/c14-release-fails.out"
# A non-ENOSPC sidecar failure never releases ballast or retries the artifact.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=5 TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-eio.out"
grep -q 'kept:intent-write-failed' "$T/c14-eio.out"
[[ ! -s "$BALLAST_LOG" ]]
[[ -e "$TEST_ROOT/repo/evidence/oldest" ]]

# A failed reserve ensure after release + retry is surfaced as partial recovery.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_ENSURE_RC=1 TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-restore-fails.out"
grep -q 'kept:ballast-restore-failed' "$T/c14-restore-fails.out"
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 1 && "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["ballast_restore_failures"]==1'

# A failed in-pass status probe cannot strand released ballast: ensure precedes a
# fresh final measurement, which is the only measurement used for completion.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_STATUS_SEQUENCE="900 900 800" TEST_STATUS_RC_SEQUENCE="0 2 0" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-status-recovery.out"
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 1 && "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["postcondition"]["allocated_bytes_after"]==800 and r["postcondition"]["target_reached"]'

# Reserve reallocation can cross low-water after removals; the final measurement
# must therefore record a partial outcome instead of reporting stale success.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_STATUS_SEQUENCE="900 900 850" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-reserve-over-target.out"
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 1 && "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["postcondition"]["allocated_bytes_after"]==850 and not r["postcondition"]["target_reached"]'

# A one-shot typed ENOSPC must release, retry through C14, and defer reserve
# restoration until later removals have made room. The copied
# C14 fixture is test-only: production has no test hook or retry bypass.
touch "$TEST_ROOT/repo/evidence/oldest/content" "$TEST_ROOT/repo/build/younger/content"
mkdir -p "$TEST_ROOT/retry/evidence/first" "$TEST_ROOT/retry/build/second"
printf x > "$TEST_ROOT/retry/evidence/first/content"
printf x > "$TEST_ROOT/retry/build/second/content"
python3 -c 'import os,sys,time; from pathlib import Path; old=time.time()-72*3600; young=time.time()-60*3600; [os.utime(p, (old,old)) for p in [Path(sys.argv[1]), *Path(sys.argv[1]).rglob("*")]]; [os.utime(p, (young,young)) for p in [Path(sys.argv[2]), *Path(sys.argv[2]).rglob("*")] ]' "$TEST_ROOT/retry/evidence/first" "$TEST_ROOT/retry/build/second"
FIXTURE_SCRIPTS="$T/one-shot-scripts"
cp -R "$ROOT/scripts" "$FIXTURE_SCRIPTS"
python3 - "$FIXTURE_SCRIPTS/quarantine_rename.py" "$T/intent-once" <<'PY'
import sys
from pathlib import Path

path, marker = map(Path, sys.argv[1:])
source = path.read_text()
needle = 'if ENV.get("DISK_MAGICIAN_TEST_INTENT_ERRNO"): raise OSError(int(ENV["DISK_MAGICIAN_TEST_INTENT_ERRNO"]), "test")'
replacement = (
    f'if ENV.get("DISK_MAGICIAN_TEST_INTENT_ERRNO") and not Path({str(marker)!r}).exists():'
    f'\n                open({str(marker)!r}, "x").close()'
    f'\n                raise OSError(int(ENV["DISK_MAGICIAN_TEST_INTENT_ERRNO"]), "test")'
)
assert source.count(needle) == 1
path.write_text(source.replace(needle, replacement))
PY
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_ENSURE_MIN_STATUS_CALLS=3 TEST_STATUS_SEQUENCE="900 850 790 795" "$FIXTURE_SCRIPTS/volume_reclaim.sh" --clean >"$T/c14-final-restore.out"
[[ ! -e "$TEST_ROOT/retry/evidence/first" && ! -e "$TEST_ROOT/retry/build/second" ]]
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 1 && "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["postcondition"]["target_reached"] and r["postcondition"]["allocated_bytes_after"]==795 and r["candidates"]["ballast_restore_failures"]==0'
echo 'volume_reclaim: real C14 whole-artifact removal and stop threshold, typed ENOSPC wrapper, and reserve restoration passed'
TEST_ROOT="$T/unavailable" "$ROOT/scripts/volume_reclaim.sh" | grep -q 'skipped:unavailable'
echo 'volume_reclaim: dry-run boundary, no-aged terminal receipt, 48h filter, oldest-first, and unavailable path passed'

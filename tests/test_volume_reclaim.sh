#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/dm-volume-reclaim.XXXXXX)"
if [[ "$(uname -s)" == Darwin ]]; then
  # C14 diagnostics must live on a different device from the fake volume.
  # A small task-owned HFS+ image supplies that boundary on macOS, where
  # /tmp and /var/tmp both reside on the Data volume.
  DIAG_IMAGE="$T/diagnostic.dmg"
  DIAG_MOUNT="$T/diagnostic"
  mkdir -p "$DIAG_MOUNT"
  hdiutil create -quiet -size 64m -fs HFS+ -volname "dm-reclaim-$$" "$DIAG_IMAGE" >/dev/null
  hdiutil attach -quiet -nobrowse -owners off -mountpoint "$DIAG_MOUNT" "$DIAG_IMAGE" >/dev/null
  trap 'if hdiutil detach -quiet "$DIAG_MOUNT" >/dev/null 2>&1; then /bin/rm -f "$DIAG_IMAGE"; fi' EXIT
  DISK_MAGICIAN_STATE_DIR="$DIAG_MOUNT/state"
elif [[ -d /dev/shm ]] && [[ "$(stat -c %d /dev/shm 2>/dev/null || echo x)" != "$(stat -c %d /tmp 2>/dev/null || echo y)" ]]; then
  DISK_MAGICIAN_STATE_DIR="$(mktemp -d /dev/shm/dm-volume-reclaim-state.XXXXXX)"
else
  DISK_MAGICIAN_STATE_DIR="$T/state"
fi
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
python3 -c 'import os,sys; assert os.stat(sys.argv[1]).st_dev != os.stat(sys.argv[2]).st_dev' "$T" "$DISK_MAGICIAN_STATE_DIR"
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
# This reclaim fixture uses a temporary mount; the real Darwin mountpoint
# guard has its own volume.py test and must stay active in production.
python3 -c 'import sys; from unittest.mock import patch; sys.path.insert(0, sys.argv[1]); import volume; patch.object(sys, "platform", "linux").start(); raise SystemExit(volume.create_cmd("scratch", True))' "$ROOT/scripts"
export STATUS_CALLS_FILE="$T/status.calls"
export STATUS_COMMANDS_FILE="$T/status.commands"
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
  'volume status --json --snapshot')
    printf '%s\n' "$*" >>"$STATUS_COMMANDS_FILE"
    n=0; [[ -f "$STATUS_CALLS_FILE" ]] && n="$(cat "$STATUS_CALLS_FILE")"
    n=$((n+1)); printf '%s' "$n" >"$STATUS_CALLS_FILE"
    if [[ -n "${TEST_STATUS_SEQUENCE:-}" ]]; then
      set -- $TEST_STATUS_SEQUENCE; idx=$((n>=$# ? $# : n)); eval "used=\${$idx}"
    else used="${TEST_USED:-900}"; fi
    available="${TEST_BALLAST_AVAILABLE:-true}"
    if [[ -n "${TEST_BALLAST_AVAILABLE_SEQUENCE:-}" ]]; then
      set -- $TEST_BALLAST_AVAILABLE_SEQUENCE; idx=$((n>=$# ? $# : n)); eval "available=\${$idx}"
    fi
    printf '{"volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":1000,"available":%s}],"tmp_audit":{"status":"unknown","reason":"snapshot_unavailable"}}\n' "$used" "$available"
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
DISK_MAGICIAN_TRIGGER=zero-aged "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/zero-aged.out"
grep -q 'trim_target_not_reached before_bytes=900 after_bytes=900 quota_bytes=1000 target_pct=80' "$T/zero-aged.out"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["aged_scanned"]==0 and not r["postcondition"]["target_reached"]'
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
TEST_STATUS_RC=1 "$ROOT/scripts/volume_reclaim.sh" | grep -q 'would_check:'
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success_noop" and r["precondition"]["used_pct"]==90'
TEST_USED=899 "$ROOT/scripts/volume_reclaim.sh" | grep -q 'skipped:below-trigger'
# Snapshot audit failure is advisory: use the live APFS allocation and reclaim
# above high-water without running the unrelated tmp snapshot scan.
printf '{"directories":[null]}\n' >"$T/malformed-snapshot.json"
set +e
DISK_MAGICIAN_SNAPSHOT_FILE="$T/malformed-snapshot.json" python3 "$ROOT/scripts/volume.py" status >"$T/status-with-audit.out" 2>&1
AUDIT_STATUS_RC=$?
set -e
[[ "$AUDIT_STATUS_RC" -ne 0 ]]
DISK_MAGICIAN_SNAPSHOT_FILE="$T/malformed-snapshot.json" python3 "$ROOT/scripts/volume.py" status --snapshot >"$T/status-snapshot-only.json"
python3 - "$T/status-snapshot-only.json" <<'PY'
import json,sys
status=json.load(open(sys.argv[1])); scratch=next(row for row in status["volumes"] if row.get("class")=="scratch")
assert isinstance(scratch.get("allocated_bytes"),int) and "tmp_audit" not in status
PY
mkdir -p "$TEST_ROOT/repo/evidence/oldest"; printf x >"$TEST_ROOT/repo/evidence/oldest/content"
python3 -c 'import os,sys,time; from pathlib import Path; root=Path(sys.argv[1]); t=time.time()-72*3600; [os.utime(p,(t,t)) for p in [root,*root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
: >"$STATUS_CALLS_FILE"; : >"$STATUS_COMMANDS_FILE"
TEST_STATUS_SEQUENCE="900 800 800" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-snapshot-audit-unknown.out"
grep -q '^volume status --json --snapshot$' "$STATUS_COMMANDS_FILE"
[[ ! -e "$TEST_ROOT/repo/evidence/oldest" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["precondition"]["allocated_bytes"]==900 and r["postcondition"]["target_reached"] and r["candidates"]["removed"]==1'
# The real C14 path removes one whole artifact, remeasures, and stops at the low-water target.
mkdir -p "$TEST_ROOT/repo/evidence/oldest"; printf x >"$TEST_ROOT/repo/evidence/oldest/content"
python3 -c 'import os,sys,time; from pathlib import Path; root=Path(sys.argv[1]); t=time.time()-72*3600; [os.utime(p,(t,t)) for p in [root,*root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
: >"$STATUS_CALLS_FILE"
TEST_STATUS_SEQUENCE="900 800" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-real-remove.out"
[[ ! -e "$TEST_ROOT/repo/evidence/oldest" && -f "$TEST_ROOT/repo/build/younger/content" ]]
[[ ! -s "$T/c14-real-remove.out" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["postcondition"]["target_reached"] and r["candidates"]["removed"]==1'
# Two oldest-first removals are required: the first leaves usage above 80%,
# and only the second reaches the target.
mkdir -p "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger"
printf x >"$TEST_ROOT/repo/evidence/oldest/content"; printf x >"$TEST_ROOT/repo/build/younger/content"
python3 -c 'import os,sys,time; from pathlib import Path; now=time.time(); roots=[Path(sys.argv[1]),Path(sys.argv[2])]; ages=[72,60]; [[os.utime(p,(now-h*3600,now-h*3600)) for p in [root,*root.rglob("*")]] for root,h in zip(roots,ages)]' "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger"
: >"$STATUS_CALLS_FILE"; : >"$DISK_MAGICIAN_DELETION_LOG"
TEST_STATUS_SEQUENCE="900 850 790 790" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-multi-remove.out"
[[ ! -e "$TEST_ROOT/repo/evidence/oldest" && ! -e "$TEST_ROOT/repo/build/younger" ]]
OLD_LINE="$(grep -nF "$TEST_ROOT/repo/evidence/oldest" "$DISK_MAGICIAN_DELETION_LOG" | cut -d: -f1)"
YOUNG_LINE="$(grep -nF "$TEST_ROOT/repo/build/younger" "$DISK_MAGICIAN_DELETION_LOG" | cut -d: -f1)"
[[ -n "$OLD_LINE" && -n "$YOUNG_LINE" && "$OLD_LINE" -lt "$YOUNG_LINE" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["candidates"]["removed"]==2 and r["postcondition"]["allocated_bytes_after"]==790 and r["postcondition"]["target_reached"]'
# Protect every eligible artifact and prove a clean pass reports the unmet target.
mkdir -p "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger"
printf x >"$TEST_ROOT/repo/evidence/oldest/content"; printf x >"$TEST_ROOT/repo/build/younger/content"
python3 -c 'import json,os,sys,time; from pathlib import Path; roots=[Path(sys.argv[1]),Path(sys.argv[2])]; ages=[72,60]; [[os.utime(p,(time.time()-h*3600,)*2) for p in [root,*root.rglob("*")]] for root,h in zip(roots,ages)]; json.dump({"protected_live_paths":[{"path":str(root),"reason":"test protected candidate"} for root in roots]},open(sys.argv[3],"w"))' "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger" "$T/protected.json"
: >"$STATUS_CALLS_FILE"; : >"$DISK_MAGICIAN_DELETION_LOG"
DISK_MAGICIAN_SAFETY_FILE="$T/protected.json" TEST_STATUS_SEQUENCE="900 900 900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-all-protected.out"
grep -q 'trim_target_not_reached before_bytes=900 after_bytes=900 quota_bytes=1000 target_pct=80' "$T/c14-all-protected.out"
[[ "$(grep -c '^kept:protected:' "$T/c14-all-protected.out")" == 2 ]]
[[ -e "$TEST_ROOT/repo/evidence/oldest" && -e "$TEST_ROOT/repo/build/younger" && ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["aged_scanned"]==2 and r["candidates"]["removed"]==0 and not r["postcondition"]["target_reached"] and r["candidates"]["top_kept_reason"]=="protected"'
touch "$TEST_ROOT/repo/build/younger/content"
# A pre-expired governor deadline reaches the C14 preflight, preserves the
# current artifact, and leaves the cursor on that interrupted unit.
CURSOR="$T/volume-reclaim.cursor"
DEADLINE="$(python3 -c 'import time; print(time.monotonic()-1)')"
: >"$STATUS_CALLS_FILE"
ACT_DEADLINE_AT="$DEADLINE" ACT_CURSOR="$CURSOR" TEST_STATUS_SEQUENCE="900 900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-deadline.out"
grep -q 'deferred:deadline-before-unit' "$T/c14-deadline.out"
[[ -e "$TEST_ROOT/repo/evidence/oldest" ]]
python3 - "$CURSOR" "$TEST_ROOT/repo/evidence/oldest" <<'PY'
import json,sys
cursor=json.load(open(sys.argv[1])); assert cursor["next_index"]==0 and cursor["items"]==[sys.argv[2]]
PY
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and not r["postcondition"]["target_reached"] and r["candidates"]["top_kept_reason"]=="deadline-before-unit"'
# C14 ENOSPC must be typed through the real cleanup wrapper before ballast release.
BALLAST_LOG="$T/ballast.log"
export BALLAST_LOG
mkdir -p "$TEST_ROOT/repo/evidence/oldest"; printf x >"$TEST_ROOT/repo/evidence/oldest/content"
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
# A simulated scheduled below-trigger run still produces a fresh, correlated terminal receipt.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
PRIOR_RUN="$(python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); print((r or {}).get("run_id", ""))')"
DISK_MAGICIAN_TRIGGER=timer BALLAST_LOG="$BALLAST_LOG" TEST_USED=899 TEST_BALLAST_AVAILABLE_SEQUENCE="true true" TEST_STATUS_SEQUENCE="899 899" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/below-trigger-terminal-receipt.out"
grep -q 'skipped:below-trigger:89' "$T/below-trigger-terminal-receipt.out"
if grep -q 'trim_target_not_reached' "$T/below-trigger-terminal-receipt.out"; then exit 1; fi
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); previous=sys.argv[1]; assert r["outcome"]=="success_noop" and r["reason"]=="below-trigger"; assert r["trigger"]=="timer" and r["run_id"] and r["run_id"] != previous and r["id"]==r["run_id"]; assert r["precondition"]=={"allocated_bytes":899,"quota_bytes":1000,"used_pct":89,"reserve_available":True}; post=r["postcondition"]; assert post["allocated_bytes_after"]==899 and post["quota_bytes"]==1000 and not post["target_reached"] and post["reserve_available_before"] is True and post["reserve_available_after"] is True; assert r["candidates"]["aged_scanned"]==0 and r["candidates"]["removed"]==0; assert r["times"]["ended_at"] and r["outcome"]!="unknown"' "$PRIOR_RUN"
[[ "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
[[ -e "$TEST_ROOT/repo/evidence/oldest" ]]
# A below-trigger clean pass still repairs a missing reserve without trimming.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" TEST_USED=899 TEST_BALLAST_AVAILABLE_SEQUENCE="false true" TEST_STATUS_SEQUENCE="899 899" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/below-trigger-reserve-restored.out"
grep -q 'skipped:below-trigger:89' "$T/below-trigger-reserve-restored.out"
[[ "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
[[ -e "$TEST_ROOT/repo/evidence/oldest" ]]
# A failed ensure or a false post-ensure availability must never report healthy.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" TEST_USED=899 TEST_ENSURE_RC=1 TEST_BALLAST_AVAILABLE_SEQUENCE="false false" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/below-trigger-ensure-failed.out"
grep -q 'kept:ballast-restore-failed' "$T/below-trigger-ensure-failed.out"
! grep -q 'skipped:below-trigger' "$T/below-trigger-ensure-failed.out"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["reason"]=="ballast-restore-failed" and r["candidates"]["ballast_restore_failures"]==1; assert r["precondition"]["reserve_available"] is False and r["postcondition"]["reserve_available_after"] is False and r["postcondition"]["allocated_bytes_after"]==899'
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" TEST_USED=899 TEST_BALLAST_AVAILABLE_SEQUENCE="false false" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/below-trigger-reserve-still-missing.out"
grep -q 'kept:ballast-restore-failed' "$T/below-trigger-reserve-still-missing.out"
! grep -q 'skipped:below-trigger' "$T/below-trigger-reserve-still-missing.out"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["reason"]=="ballast-restore-failed" and r["candidates"]["ballast_restore_failures"]==1; assert r["precondition"]["reserve_available"] is False and r["postcondition"]["reserve_available_after"] is False and r["postcondition"]["allocated_bytes_after"]==899'
: >"$STATUS_CALLS_FILE"
: >"$BALLAST_LOG"
BALLAST_LOG="$T/ballast.log" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-release-fails.out"
grep -q 'kept:intent-write-failed' "$T/c14-release-fails.out"
grep -q '^release$' "$BALLAST_LOG" && grep -q '^ensure$' "$BALLAST_LOG"
! grep -q '^removed:' "$T/c14-release-fails.out"
# A non-ENOSPC sidecar failure never releases ballast or retries the artifact.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=5 TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-eio.out"
grep -q 'kept:intent-write-failed' "$T/c14-eio.out"
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 0 ]]
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

# A triggered clean pass cannot report success when its fresh final status says
# the scratch reserve is unavailable, even when ensure itself succeeds.
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" TEST_BALLAST_AVAILABLE_SEQUENCE="true false" TEST_STATUS_SEQUENCE="900 800" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-final-reserve-missing.out"
grep -q 'kept:ballast-restore-failed' "$T/c14-final-reserve-missing.out"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["ballast_restore_failures"]==1'

# A one-shot typed ENOSPC must release, retry through C14, and defer reserve
# restoration until later removals have made room. Recreate the earlier fixture
# because the final-availability regression may have removed it.
mkdir -p "$TEST_ROOT/repo/evidence/oldest" "$TEST_ROOT/repo/build/younger"
printf x >"$TEST_ROOT/repo/evidence/oldest/content"
printf x >"$TEST_ROOT/repo/build/younger/content"
[[ -f "$TEST_ROOT/repo/evidence/oldest/content" && -f "$TEST_ROOT/repo/build/younger/content" ]]
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TEST_ROOT/repo/evidence/oldest"
# The copied C14 fixture is test-only: production has no test hook or retry
# bypass.
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
    f'\n                if ENV.get("ACT_CURSOR"): Path({str(marker)!r} + ".cursor").write_text(Path(ENV["ACT_CURSOR"]).read_text())'
    f'\n                raise OSError(int(ENV["DISK_MAGICIAN_TEST_INTENT_ERRNO"]), "test")'
)
assert source.count(needle) == 1
path.write_text(source.replace(needle, replacement))
PY
CURSOR="$T/c14-enospc.cursor"
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" ACT_CURSOR="$CURSOR" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_ENSURE_MIN_STATUS_CALLS=3 TEST_STATUS_SEQUENCE="900 850 790 795" "$FIXTURE_SCRIPTS/volume_reclaim.sh" --clean >"$T/c14-final-restore.out"
[[ ! -e "$TEST_ROOT/retry/evidence/first" && ! -e "$TEST_ROOT/retry/build/second" ]]
[[ "$(grep -c '^release$' "$BALLAST_LOG")" == 1 && "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 - "$CURSOR" "$T/intent-once.cursor" "$TEST_ROOT/retry/evidence/first" "$TEST_ROOT/retry/build/second" <<'PY'
import json,sys
cursor,first_attempt,first,second=sys.argv[1:]
before=json.load(open(first_attempt)); after=json.load(open(cursor))
assert before["next_index"]==0 and before["items"]==[first]
assert after["next_index"]==2 and after["items"]==[first,second]
PY
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["candidates"]["removed"]==2 and r["postcondition"]["target_reached"] and r["postcondition"]["allocated_bytes_after"]==795 and r["candidates"]["ballast_restore_failures"]==0'

# A previous run can release ballast and fail to restore it.  The next run must
# detect the absent reserve, restore it after ordinary reclaim, and only then
# report success.  The old implementation skipped ensure because that second
# run did not release ballast itself.
TWO_RUN_ROOT="$TEST_ROOT/repo2"
mkdir -p "$TWO_RUN_ROOT/evidence/oldest"
printf x > "$TWO_RUN_ROOT/evidence/oldest/content"
python3 -c 'import os,sys,time; from pathlib import Path; t=time.time()-72*3600; root=Path(sys.argv[1]); [os.utime(p, (t,t)) for p in [root, *root.rglob("*")]]' "$TWO_RUN_ROOT/evidence/oldest"
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" DISK_MAGICIAN_TEST_INTENT_ERRNO=28 TEST_ENSURE_RC=1 TEST_BALLAST_AVAILABLE_SEQUENCE="true false false" TEST_STATUS_SEQUENCE="900 900" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-two-run-first.out"
grep -q '^release$' "$BALLAST_LOG" && grep -q '^ensure$' "$BALLAST_LOG"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["candidates"]["ballast_restore_failures"]==1'
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
BALLAST_LOG="$BALLAST_LOG" TEST_ENSURE_RC=0 TEST_BALLAST_AVAILABLE_SEQUENCE="false false true" TEST_STATUS_SEQUENCE="900 790 795" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/c14-two-run-second.out"
[[ ! -e "$TWO_RUN_ROOT/evidence/oldest" ]]
[[ ! -s "$BALLAST_LOG" || "$(grep -c '^release$' "$BALLAST_LOG")" == 0 ]]
[[ "$(grep -c '^ensure$' "$BALLAST_LOG")" == 1 ]]
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success" and r["postcondition"]["target_reached"] and r["postcondition"]["allocated_bytes_after"]==795 and r["candidates"]["ballast_restore_failures"]==0'
# Crossing 89% -> 95% must not claim success_noop / below-trigger
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
TEST_STATUS_SEQUENCE="890 950" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/crossing-89-95.out" || true
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="partial" and r["reason"]=="trim-target-not-reached" and r["postcondition"]["allocated_bytes_after"]==950'

# Stable 89% must report success_noop / below-trigger
: >"$BALLAST_LOG"; : >"$STATUS_CALLS_FILE"
TEST_STATUS_SEQUENCE="890 890" "$ROOT/scripts/volume_reclaim.sh" --clean >"$T/stable-89.out"
python3 "$ROOT/scripts/job_receipt.py" read --job volume_reclaim --last | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["outcome"]=="success_noop" and r["reason"]=="below-trigger" and r["postcondition"]["allocated_bytes_after"]==890'

echo 'volume_reclaim: real C14 whole-artifact removal and stop threshold, typed ENOSPC wrapper, and reserve restoration passed'
TEST_ROOT="$T/unavailable" "$ROOT/scripts/volume_reclaim.sh" | grep -q 'skipped:unavailable'
echo 'volume_reclaim: dry-run boundary, no-aged terminal receipt, 48h filter, oldest-first, and unavailable path passed'

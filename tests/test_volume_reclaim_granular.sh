#!/usr/bin/env bash
# Public scheduled actuator: arbitrary-depth discovery, no real cleanup.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" TEST_ROOT="$T/volume"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR" "$TEST_ROOT/arbitrary/deeper/stale" "$TEST_ROOT/arbitrary/deeper/fresh" "$TEST_ROOT/repository/.git"
python3 - "$TEST_ROOT" <<'PY'
import os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); stale=root/'arbitrary/deeper/stale'; fresh=root/'arbitrary/deeper/fresh'
(stale/'exact.bin').write_bytes(b'')
with (stale/'exact.bin').open('wb') as f: f.truncate(104857600)
(fresh/'active').write_text('fresh')
(root/'repository/.git/config').write_text('metadata')
for p in [stale,stale/'exact.bin']: os.utime(p,(time.time()-3*86400,)*2)
PY
cat > "$T/diskm" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
 'volume path scratch --for-reclaim') printf '%s\n' "$TEST_ROOT";;
 'volume verify-mount '*) exit 0;;
 'volume status --json --snapshot') printf '%s\n' '{"volumes":[{"class":"scratch","allocated_bytes":900,"quota_bytes":1000,"available":true}]}' ;;
 *) exit 1;;
esac
MOCK
chmod +x "$T/diskm"
set +e
ACT_DEADLINE_AT=0 DISK_MAGICIAN_DISKM_BIN="$T/diskm" bash "$ROOT/disk_magician.sh" volume reclaim >"$T/failed" 2>&1
rc=$?
set -e
test "$rc" -ne 0
grep -F 'measurement_status=incomplete rc=124' "$T/failed"
test -f "$TEST_ROOT/arbitrary/deeper/stale/exact.bin"
# Same-unit retry after the interrupted discovery.
DISK_MAGICIAN_DISKM_BIN="$T/diskm" bash "$ROOT/disk_magician.sh" volume reclaim >"$T/out" 2>&1
cat "$T/out"
grep -F "would_check:$TEST_ROOT/arbitrary/deeper/stale" "$T/out"
grep -F "$TEST_ROOT/arbitrary/deeper/stale/exact.bin" "$T/out"
! grep -F "would_check:$TEST_ROOT/arbitrary/deeper/fresh" "$T/out"
test -f "$TEST_ROOT/arbitrary/deeper/fresh/active"
test -f "$TEST_ROOT/repository/.git/config"

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DISPATCHER="${DISKM_TEST_DISPATCHER:-$ROOT/disk_magician.sh}"
TMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
T="$(mktemp -d "$TMP_PARENT/quarantine-remove-scratch.XXXXXX")"
case "$T" in "$TMP_PARENT"/quarantine-remove-scratch.*) ;; *) exit 2 ;; esac
TEST_REAL_PYTHON="$(command -v python3)"
export TEST_REAL_PYTHON
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$T"' EXIT
STATE="$T/state" BIN="$T/bin" VOL="$T/volume" OUTSIDE="$T/outside"
CFG="$T/config.json" SAFE="$T/safety.local.json"
mkdir -p "$STATE" "$BIN" "$VOL" "$OUTSIDE"
printf '{"volumes":{"swap_headroom_gb":40,"alarm_floor_gb":20,"encryption":"none","classes":{"scratch":{"name":"diskm-scratch","quota_gb":10,"mountpoint":"%s"}}}}\n' "$VOL" >"$CFG"
printf '{"never_delete":[],"protected_live_paths":[],"needs_decision":[],"min_stale_days":7}\n' >"$SAFE"
cat >"$BIN/diskm" <<'FAKE_DISKM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "volume path scratch --for-reclaim" ]]; then printf '%s\n' "$TEST_SCRATCH_ROOT"; exit 0; fi
if [[ "$*" == "volume verify-mount $TEST_SCRATCH_ROOT" ]]; then [[ "${TEST_SCRATCH_MOUNTED:-1}" == 1 ]]; exit $?; fi
exit 90
FAKE_DISKM
cat >"$BIN/python3" <<'FAKE_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1##*/}" == volume.py && "${2:-}" == verify-mount ]]; then [[ "${TEST_SCRATCH_MOUNTED:-1}" == 1 ]]; exit $?; fi
if [[ "${TEST_REPLACE_DURING_INVENTORY:-0}" == 1 && "${1##*/}" == c14_probe.py && "${2:-}" == inventory ]]; then
  mv "$TEST_RACE_TARGET" "$TEST_RACE_ORIGINAL"
  mkdir "$TEST_RACE_TARGET"
  printf replacement >"$TEST_RACE_TARGET/payload"
  "$TEST_REAL_PYTHON" "$@"
  result=$?
  mv "$TEST_RACE_TARGET" "$TEST_RACE_REPLACEMENT"
  mv "$TEST_RACE_ORIGINAL" "$TEST_RACE_TARGET"
  exit "$result"
fi
exec "$TEST_REAL_PYTHON" "$@"
FAKE_PYTHON
chmod +x "$BIN/diskm" "$BIN/python3"
cli() {
 env PATH="$BIN:$PATH" DISK_MAGICIAN_DISKM_BIN="$BIN/diskm" DISK_MAGICIAN_CONFIG="$CFG" \
 DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_DELETION_LOG="$T/deletions.log" \
 DISK_MAGICIAN_SAFETY_FILE="$SAFE" TEST_SCRATCH_ROOT="$VOL" \
 bash "$DISPATCHER" quarantine remove-scratch "$@"
}
set_age_hours() {
  python3 -c '
import os, sys, time
mtime = time.time() - 3600 * int(sys.argv[1])
for path in sys.argv[2:]:
    os.utime(path, (mtime, mtime))
' "$@"
}
stale() { set_age_hours 240 "$1"; }
PASS=0 FAIL=0
check() { LABEL="$1"; shift; if "$@"; then echo "PASS $LABEL"; PASS=$((PASS+1)); else printf 'FAIL %s (rc=%s, output=%s)\n' "$LABEL" "${RC:-}" "${OUT:-}"; FAIL=$((FAIL+1)); fi; }
ENTRY="$VOL/isolated-entry"; mkdir "$ENTRY"; printf old >"$ENTRY/payload"; stale "$ENTRY/payload"; stale "$ENTRY"
set +e
OUT="$(cli "$ENTRY" 2>&1)"; RC=$?
set -e
check "default mode returns exact C14 remove verdict" test "$RC" -eq 0 -a "$OUT" = remove
set +e
OUT="$(cli "$ENTRY///" 2>&1)"; RC=$?
set -e
check "multiple trailing slashes normalize to the exact entry" test "$RC" -eq 0 -a "$OUT" = remove
check "dry-run preserves candidate" test -f "$ENTRY/payload"
set +e
OUT="$(cli "$ENTRY" --dry-run 2>&1)"; RC=$?
set -e
check "explicit dry-run returns C14 verdict" test "$RC" -eq 0 -a "$OUT" = remove
set +e
OUT="$(cli "$ENTRY" --clean 2>&1)"; RC=$?
set -e
check "clean mode succeeds for C14-approved entry" test "$RC" -eq 0
check "clean removes exact original entry" test ! -e "$ENTRY"
check "clean removal is logged" grep -q "$ENTRY" "$T/deletions.log"
set +e
OUT="$(cli "$VOL" --clean 2>&1)"; RC=$?
set -e
check "Scratch volume root is refused" test "$RC" -eq 2
NESTED="$VOL/nested/item"; mkdir -p "$NESTED"; printf nested >"$NESTED/payload"; stale "$NESTED/payload"
set +e
OUT="$(cli "$NESTED" --clean 2>&1)"; RC=$?
set -e
check "nested target is refused" test "$RC" -eq 2
check "nested content preserved" test -f "$NESTED/payload"
EXTERNAL="$OUTSIDE/external"; mkdir "$EXTERNAL"; printf outside >"$EXTERNAL/payload"; stale "$EXTERNAL/payload"; stale "$EXTERNAL"
set +e
OUT="$(cli "$EXTERNAL" --clean 2>&1)"; RC=$?
set -e
check "outside target is refused" test "$RC" -eq 2
check "external content preserved" test -f "$EXTERNAL/payload"
LINK="$VOL/link"; ln -s "$EXTERNAL" "$LINK"
set +e
OUT="$(cli "$LINK" --clean 2>&1)"; RC=$?
set -e
check "symlink target is refused" test "$RC" -eq 2
check "symlink destination preserved" test -f "$EXTERNAL/payload"
BAD="$VOL/mount-guard"; mkdir "$BAD"; printf identity >"$BAD/payload"; stale "$BAD/payload"
set +e
OUT="$(TEST_SCRATCH_MOUNTED=0 cli "$BAD" --clean 2>&1)"; RC=$?
set -e
check "mount identity failure exits 75" test "$RC" -eq 75
check "mount failure preserves candidate" test -f "$BAD/payload"
FRESH="$VOL/recent-entry"; mkdir "$FRESH"; printf recent >"$FRESH/payload"; set_age_hours 30 "$FRESH/payload" "$FRESH"
set +e
OUT="$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=120 cli "$FRESH" --clean 2>&1)"; RC=$?
set -e
check "inherited short age floor cannot lower Scratch retention" grep -q "kept:recent-activity" <<<"$OUT"
check "recent payload remains" test -f "$FRESH/payload"
RACE="$VOL/race-entry"; mkdir "$RACE"; printf original >"$RACE/payload"; stale "$RACE/payload"
MARKER="$T/after-nominate"; ORIGINAL_ROOT="$T/volume-original"
(
  for _ in {1..500}; do
    if [[ -f "$MARKER" ]]; then
      mv "$VOL" "$ORIGINAL_ROOT"
      mkdir "$VOL"
      mkdir "$RACE"
      printf replacement >"$RACE/payload"
      stale "$RACE/payload"
      exit 0
    fi
    sleep 0.01
  done
  exit 1
) &
WATCH_PID=$!
set +e
OUT="$(DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_AFTER_NOMINATE="$MARKER" cli "$RACE" --clean 2>&1)"; RC=$?
set -e
wait "$WATCH_PID"
check "replaced Scratch mount target fails frozen identity check" grep -q "kept:identity-mismatch" <<<"$OUT"
check "pre-scan target inode remains under original volume" test -f "$ORIGINAL_ROOT/race-entry/payload"
check "replacement target remains untouched" grep -q replacement "$RACE/payload"
RACE_INVENTORY="$VOL/inventory-race"; mkdir "$RACE_INVENTORY"; printf original >"$RACE_INVENTORY/payload"; stale "$RACE_INVENTORY/payload"
INVENTORY_ORIGINAL="$T/inventory-original"; INVENTORY_REPLACEMENT="$T/inventory-replacement"
set +e
OUT="$(TEST_REPLACE_DURING_INVENTORY=1 TEST_RACE_TARGET="$RACE_INVENTORY" TEST_RACE_ORIGINAL="$INVENTORY_ORIGINAL" TEST_RACE_REPLACEMENT="$INVENTORY_REPLACEMENT" cli "$RACE_INVENTORY" --clean 2>&1)"; RC=$?
set -e
check "inventory from a replaced inode fails frozen identity check" grep -q "kept:identity-mismatch" <<<"$OUT"
check "original entry identity is still present" test -f "$RACE_INVENTORY/payload"
check "replaced during-scan inode is preserved separately" test -f "$INVENTORY_REPLACEMENT/payload"
set +e
OUT="$(cli "$BAD" --clean --unknown 2>&1)"; RC=$?
set -e
check "unknown options are rejected" test "$RC" -eq 2
set +e
OUT="$(cli "$BAD" --dry-run --clean 2>&1)"; RC=$?
set -e
check "conflicting modes are rejected" test "$RC" -eq 2
echo "PASS=$PASS FAIL=$FAIL"
test "$FAIL" = 0

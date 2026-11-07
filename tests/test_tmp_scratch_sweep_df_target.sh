#!/bin/bash
# test_tmp_scratch_sweep_df_target.sh — the sweep's free-space receipt must
# measure the volume it DELETES from, not the installed package dir.
#
# Regression (verified live on this host 2026-11-03): _df_free_bytes ran
# `df -kP "$SCRIPT_DIR"`, and $SCRIPT_DIR is the installed package dir on
# /System/Volumes/Data while the sweep prunes the Scratch volume
# (/Volumes/diskm-scratch). A live run recorded
# free_bytes_before=30005886976 (27.9 GiB) and df_delta_bytes=-530817024 while
# the Scratch mount had only 3.82 GB free — every free-space gate on this job
# measured a different filesystem than the one being pruned.
#
# The fixture gives the two candidate volumes deliberately different free-space
# numbers and asserts the receipt carries the PRUNE-TARGET volume's number:
#   - package dir (SCRIPT_DIR): 11 GiB free  (the pre-fix wrong answer)
#   - Scratch mount (pruned):    3 GiB free  (the correct answer)
# Pre-fix this test fails with 11811160064; post-fix it passes with 3221225472.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/tmp_scratch_sweep.sh"

FIXTURE_PARENT="${TMPDIR:-/tmp}"
FIXTURE_PARENT="${FIXTURE_PARENT%/}"
FIXTURE_PARENT="$(cd "$FIXTURE_PARENT" 2>/dev/null && pwd -P)" || {
  echo "FATAL: TMPDIR parent '${TMPDIR:-/tmp}' is not usable" >&2
  exit 2
}
if [[ ! -d "$FIXTURE_PARENT" ]]; then
  echo "FATAL: TMPDIR parent '$FIXTURE_PARENT' does not exist" >&2
  exit 2
fi
TMP_ROOT="$(mktemp -d "$FIXTURE_PARENT/disk-magician-sweep-df-target.XXXXXX")" || {
  echo "FATAL: could not allocate fixture root under TMPDIR" >&2
  exit 2
}
if [[ -z "$TMP_ROOT" || ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  echo "FATAL: invalid or symlinked fixture root '$TMP_ROOT'" >&2
  exit 2
fi
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
case "$TMP_ROOT" in
  "$FIXTURE_PARENT"/*) ;;
  *) echo "FATAL: fixture root outside TMPDIR: '$TMP_ROOT'" >&2; exit 2 ;;
esac
trap '/bin/rm -rf -- "${TMP_ROOT:?}"' EXIT

MOCK_BIN="$TMP_ROOT/scripts"
STATE_DIR="$TMP_ROOT/state"
HOME_DIR="$TMP_ROOT/home"
SCRATCH_MOUNT="$TMP_ROOT/scratch-volume"
VALID_TMP_DIR="$TMP_ROOT/valid-tmp"
PACKAGE_FREE_BYTES=$(( 11 * 1024 * 1024 * 1024 ))   # 11 GiB — the pre-fix wrong answer
SCRATCH_FREE_BYTES=$(( 3 * 1024 * 1024 * 1024 ))    # 3 GiB — the volume actually pruned
TMP_FREE_BYTES=$(( 7 * 1024 * 1024 * 1024 ))        # 7 GiB — distinguishable from 3 and 11 GiB
mkdir -p "$MOCK_BIN/lib" "$STATE_DIR" "$HOME_DIR" "$SCRATCH_MOUNT" "$VALID_TMP_DIR"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

cp "$SOURCE_SCRIPT" "$MOCK_BIN/tmp_scratch_sweep.sh"
chmod +x "$MOCK_BIN/tmp_scratch_sweep.sh"
cp "$REPO_ROOT/scripts/job_receipt.py" "$MOCK_BIN/job_receipt.py"
cp "$REPO_ROOT/scripts/lib/actuator_deadline.sh" "$MOCK_BIN/lib/actuator_deadline.sh"
cp "$REPO_ROOT/scripts/lib/scratch_roots.sh" "$MOCK_BIN/lib/scratch_roots.sh"

# df shim: answers per-path so the two volumes cannot be confused, and records
# every argument so the assertion can prove WHICH path was measured.
cat > "$MOCK_BIN/df" <<'MOCK_DF'
#!/bin/bash
printf '%s\n' "$*" >> "${DF_ARGUMENT_LOG:?}"
target="${*: -1}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "$target" in
  "${SCRATCH_MOUNT:?}") printf '/dev/scratch 4000 1000 %s 25%% %s\n' "$(( SCRATCH_FREE_BYTES / 1024 ))" "$target" ;;
  "${VALID_TMP_DIR:?}") printf '/dev/tmp 6000 1000 %s 16%% %s\n' "$(( TMP_FREE_BYTES / 1024 ))" "$target" ;;
  *) printf '/dev/data 8000 4000 %s 50%% %s\n' "$(( PACKAGE_FREE_BYTES / 1024 ))" "$target" ;;
esac
MOCK_DF
chmod +x "$MOCK_BIN/df"

# Delegates are stubs: this test is about the wrapper's own df evidence only.
cat > "$MOCK_BIN/cleanup_tmp.sh" <<'MOCK_TMP'
#!/bin/bash
helper="${DISK_MAGICIAN_RECEIPT_HELPER:?}"
run_id="$(python3 "$helper" begin --job cleanup_tmp --trigger "${DISK_MAGICIAN_RECEIPT_TRIGGER:-mock}" --precondition '{}')"
python3 "$helper" finish --job cleanup_tmp --run-id "$run_id" --outcome success --reason "mock" \
  --candidates '{"count":null,"bytes":null,"removed_count":0,"deferred_count":0,"interrupted_count":0}' \
  --postcondition '{"df_delta_bytes":0,"freed_bytes":0}' >/dev/null
exit 0
MOCK_TMP
cat > "$MOCK_BIN/cleanup_claude_state.sh" <<'MOCK_STATE'
#!/bin/bash
exit 0
MOCK_STATE
chmod +x "$MOCK_BIN/cleanup_tmp.sh" "$MOCK_BIN/cleanup_claude_state.sh"

# diskm shim: the canonical Scratch-volume resolver returns the pruned mount.
cat > "$TMP_ROOT/disk_magician.sh" <<'MOCK_DISKM'
#!/bin/bash
if [[ "$*" == "volume path scratch --for-reclaim" ]]; then
  case "${MOCK_VOL_PATH_RC:-0}" in
    3) exit 3 ;;
    75) exit 75 ;;
    *) printf '%s\n' "${SCRATCH_MOUNT:?}"; exit 0 ;;
  esac
fi
if [[ "$*" == "volume ballast recover scratch" ]]; then exit 0; fi
helper="${DISK_MAGICIAN_RECEIPT_HELPER:?}"
run_id="$(python3 "$helper" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-mock}" --precondition '{}')"
python3 "$helper" finish --job volume_reclaim --run-id "$run_id" --outcome success --reason "mock" \
  --trigger "${DISK_MAGICIAN_TRIGGER:-mock}" \
  --candidates '{"aged_scanned":0,"removed":0,"top_kept_reason":"available-floor","ballast_restore_failures":0}' \
  --postcondition '{"target_reached":true}' >/dev/null
printf 'skipped:available-floor:%s\n' "${SCRATCH_FREE_BYTES:?}"
exit 0
MOCK_DISKM
chmod +x "$TMP_ROOT/disk_magician.sh"

RECEIPT_FILE="$STATE_DIR/receipts/tmp_scratch_sweep.json"
DF_ARGUMENT_LOG="$TMP_ROOT/df-arguments.log"

run_sweep() {
  : > "$DF_ARGUMENT_LOG"
  env -i \
    HOME="$HOME_DIR" \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    TMPDIR="$TMP_ROOT" \
    SCRATCH_MOUNT="$SCRATCH_MOUNT" \
    VALID_TMP_DIR="$VALID_TMP_DIR" \
    PACKAGE_FREE_BYTES="$PACKAGE_FREE_BYTES" \
    SCRATCH_FREE_BYTES="$SCRATCH_FREE_BYTES" \
    TMP_FREE_BYTES="$TMP_FREE_BYTES" \
    MOCK_VOL_PATH_RC="${MOCK_VOL_PATH_RC:-0}" \
    DF_ARGUMENT_LOG="$DF_ARGUMENT_LOG" \
    DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    DISK_MAGICIAN_RECEIPT_HELPER="$MOCK_BIN/job_receipt.py" \
    DISK_MAGICIAN_DISKM_BIN="$TMP_ROOT/disk_magician.sh" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="${DISK_MAGICIAN_TMP_ROOT_OVERRIDE:-$VALID_TMP_DIR}" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-$VALID_TMP_DIR}" \
    DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="${DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE:-$VALID_TMP_DIR}" \
    /bin/bash "$MOCK_BIN/tmp_scratch_sweep.sh" "$@" >"$TMP_ROOT/sweep.out" 2>&1
}

receipt_field() {
  python3 - "$RECEIPT_FILE" "$1" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
node = receipt["last_terminal"]["postcondition"]
key = sys.argv[2]
print(node.get(key))
PY
}

echo "Test 1: receipt free_bytes_before measures the pruned Scratch mount, not \$SCRIPT_DIR"
if ! run_sweep --dry-run; then
  fail "sweep exited nonzero (see $TMP_ROOT/sweep.out)"
else
  pass "sweep exits 0"
fi
BEFORE="$(receipt_field free_bytes_before 2>/dev/null)"
AFTER="$(receipt_field free_bytes_after 2>/dev/null)"
DELTA="$(receipt_field df_delta_bytes 2>/dev/null)"
if [[ "$BEFORE" == "$SCRATCH_FREE_BYTES" ]]; then
  pass "free_bytes_before is the pruned volume's free space ($BEFORE)"
elif [[ "$BEFORE" == "$PACKAGE_FREE_BYTES" ]]; then
  fail "free_bytes_before measured the package dir instead of the pruned volume ($BEFORE)"
else
  fail "free_bytes_before=$BEFORE (expected $SCRATCH_FREE_BYTES)"
fi
if [[ "$AFTER" == "$SCRATCH_FREE_BYTES" ]]; then
  pass "free_bytes_after is the pruned volume's free space ($AFTER)"
elif [[ "$AFTER" == "$PACKAGE_FREE_BYTES" ]]; then
  fail "free_bytes_after measured the package dir instead of the pruned volume ($AFTER)"
else
  fail "free_bytes_after=$AFTER (expected $SCRATCH_FREE_BYTES)"
fi
if [[ "$DELTA" == "0" ]]; then
  pass "df_delta_bytes is a same-volume delta (0)"
else
  fail "df_delta_bytes=$DELTA (expected 0)"
fi

echo "Test 2: df is invoked with the prune target, and never with the package dir"
if grep -qxF -- "-kP $SCRATCH_MOUNT" "$DF_ARGUMENT_LOG"; then
  pass "df was asked for the pruned Scratch mount"
else
  fail "df was never asked for the pruned Scratch mount: $(tr '\n' ';' <"$DF_ARGUMENT_LOG")"
fi
if grep -qxF -- "-kP $MOCK_BIN" "$DF_ARGUMENT_LOG"; then
  fail "df was asked for the installed package dir (\$SCRIPT_DIR)"
else
  pass "df was never asked for the package dir"
fi

echo "Test 3: the fixture volumes are distinguishable, so this test can fail"
if [[ "$SCRATCH_FREE_BYTES" == "$PACKAGE_FREE_BYTES" || "$SCRATCH_FREE_BYTES" == "$TMP_FREE_BYTES" || "$PACKAGE_FREE_BYTES" == "$TMP_FREE_BYTES" ]]; then
  fail "fixture volumes carry colliding free-space values; the assertion proves nothing"
else
  pass "fixture volumes differ ($SCRATCH_FREE_BYTES vs $PACKAGE_FREE_BYTES vs $TMP_FREE_BYTES)"
fi

echo "Test 4: an unresolvable prune target leaves the free-space fields empty"
# No diskm resolver answer and no resolvable tmp root => measurement must stay
# empty (existing non-numeric tolerance), never fall back to $SCRIPT_DIR.
cat > "$TMP_ROOT/unavailable_disk_magician.sh" <<'MOCK_UNAVAILABLE'
#!/bin/bash
if [[ "$*" == "volume path scratch --for-reclaim" ]]; then exit 75; fi
if [[ "$*" == "volume ballast recover scratch" ]]; then exit 0; fi
helper="${DISK_MAGICIAN_RECEIPT_HELPER:?}"
run_id="$(python3 "$helper" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-mock}" --precondition '{}')"
python3 "$helper" finish --job volume_reclaim --run-id "$run_id" --outcome success --reason "mock" \
  --trigger "${DISK_MAGICIAN_TRIGGER:-mock}" \
  --candidates '{"aged_scanned":0,"removed":0,"top_kept_reason":"available-floor","ballast_restore_failures":0}' \
  --postcondition '{"target_reached":true}' >/dev/null
printf 'skipped:available-floor:0\n'
exit 0
MOCK_UNAVAILABLE
chmod +x "$TMP_ROOT/unavailable_disk_magician.sh"
: > "$DF_ARGUMENT_LOG"
env -i \
  HOME="$HOME_DIR" \
  PATH="$MOCK_BIN:/usr/bin:/bin" \
  TMPDIR="$TMP_ROOT/nonexistent-tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP_ROOT/nonexistent-private-tmp" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP_ROOT/nonexistent-tmp" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT/nonexistent-tmp" \
  SCRATCH_MOUNT="$TMP_ROOT/nonexistent-scratch" \
  PACKAGE_FREE_BYTES="$PACKAGE_FREE_BYTES" \
  SCRATCH_FREE_BYTES="$SCRATCH_FREE_BYTES" \
  TMP_FREE_BYTES="$TMP_FREE_BYTES" \
  DF_ARGUMENT_LOG="$DF_ARGUMENT_LOG" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_RECEIPT_HELPER="$MOCK_BIN/job_receipt.py" \
  DISK_MAGICIAN_DISKM_BIN="$TMP_ROOT/unavailable_disk_magician.sh" \
  /bin/bash "$MOCK_BIN/tmp_scratch_sweep.sh" --dry-run >"$TMP_ROOT/unavailable.out" 2>&1
if grep -qxF -- "-kP $MOCK_BIN" "$DF_ARGUMENT_LOG"; then
  fail "unresolvable target fell back to the package dir"
else
  pass "unresolvable target never fell back to the package dir"
fi
if grep -qE 'df -kP|/dev/data' "$DF_ARGUMENT_LOG" 2>/dev/null && [[ -s "$DF_ARGUMENT_LOG" ]]; then
  fail "unresolvable target still ran df: $(tr '\n' ';' <"$DF_ARGUMENT_LOG")"
else
  pass "unresolvable target performed no df measurement"
fi

echo "Test 5: --scratch-only with rc=3 Scratch resolver keeps df receipt fields null (no tmp fallback)"
rm -f "$RECEIPT_FILE"
MOCK_VOL_PATH_RC=3 run_sweep --scratch-only --dry-run || true
BEFORE="$(receipt_field free_bytes_before 2>/dev/null)"
AFTER="$(receipt_field free_bytes_after 2>/dev/null)"
DELTA="$(receipt_field df_delta_bytes 2>/dev/null)"
RECLAIMED_DF="$(receipt_field reclaimed_bytes_df 2>/dev/null)"
if [[ "$BEFORE" == "None" && "$AFTER" == "None" && "$DELTA" == "None" && "$RECLAIMED_DF" == "None" ]]; then
  pass "receipt df fields are null in --scratch-only mode when rc=3"
else
  fail "receipt df fields populated in --scratch-only mode when rc=3: before=$BEFORE after=$AFTER delta=$DELTA reclaimed_df=$RECLAIMED_DF"
fi
if grep -qxF -- "-kP $VALID_TMP_DIR" "$DF_ARGUMENT_LOG"; then
  fail "df was invoked for tmp root in --scratch-only mode when rc=3"
else
  pass "df was never invoked for tmp root in --scratch-only mode when rc=3"
fi

echo "Test 6: --scratch-only with rc=75 Scratch resolver keeps df receipt fields null"
rm -f "$RECEIPT_FILE"
MOCK_VOL_PATH_RC=75 run_sweep --scratch-only --dry-run || true
BEFORE="$(receipt_field free_bytes_before 2>/dev/null)"
AFTER="$(receipt_field free_bytes_after 2>/dev/null)"
DELTA="$(receipt_field df_delta_bytes 2>/dev/null)"
RECLAIMED_DF="$(receipt_field reclaimed_bytes_df 2>/dev/null)"
if [[ "$BEFORE" == "None" && "$AFTER" == "None" && "$DELTA" == "None" && "$RECLAIMED_DF" == "None" ]]; then
  pass "receipt df fields are null in --scratch-only mode when rc=75"
else
  fail "receipt df fields populated in --scratch-only mode when rc=75: before=$BEFORE after=$AFTER delta=$DELTA reclaimed_df=$RECLAIMED_DF"
fi
if grep -qxF -- "-kP $VALID_TMP_DIR" "$DF_ARGUMENT_LOG"; then
  fail "df was invoked for tmp root in --scratch-only mode when rc=75"
else
  pass "df was never invoked for tmp root in --scratch-only mode when rc=75"
fi

echo "Test 7: full mode with rc=3 falls back to tmp root and populates integer df fields"
rm -f "$RECEIPT_FILE"
MOCK_VOL_PATH_RC=3 run_sweep --dry-run || true
BEFORE="$(receipt_field free_bytes_before 2>/dev/null)"
AFTER="$(receipt_field free_bytes_after 2>/dev/null)"
DELTA="$(receipt_field df_delta_bytes 2>/dev/null)"
if [[ "$BEFORE" == "$TMP_FREE_BYTES" && "$AFTER" == "$TMP_FREE_BYTES" && "$DELTA" == "0" ]]; then
  pass "full mode with rc=3 measured tmp root free space ($BEFORE)"
else
  fail "full mode with rc=3 did not measure tmp root: before=$BEFORE after=$AFTER delta=$DELTA (expected $TMP_FREE_BYTES)"
fi
if grep -qxF -- "-kP $VALID_TMP_DIR" "$DF_ARGUMENT_LOG"; then
  pass "df was invoked for tmp root in full mode when rc=3"
else
  fail "df was not invoked for tmp root in full mode when rc=3: $(tr '\n' ';' <"$DF_ARGUMENT_LOG")"
fi

echo "Test 8: full mode with rc=75 keeps df receipt fields null (no tmp fallback on unverified Scratch config)"
rm -f "$RECEIPT_FILE"
MOCK_VOL_PATH_RC=75 run_sweep --dry-run || true
BEFORE="$(receipt_field free_bytes_before 2>/dev/null)"
AFTER="$(receipt_field free_bytes_after 2>/dev/null)"
DELTA="$(receipt_field df_delta_bytes 2>/dev/null)"
RECLAIMED_DF="$(receipt_field reclaimed_bytes_df 2>/dev/null)"
if [[ "$BEFORE" == "None" && "$AFTER" == "None" && "$DELTA" == "None" && "$RECLAIMED_DF" == "None" ]]; then
  pass "receipt df fields are null in full mode when rc=75"
else
  fail "receipt df fields populated in full mode when rc=75: before=$BEFORE after=$AFTER delta=$DELTA reclaimed_df=$RECLAIMED_DF"
fi
if grep -qxF -- "-kP $VALID_TMP_DIR" "$DF_ARGUMENT_LOG"; then
  fail "df was invoked for tmp root in full mode when rc=75"
else
  pass "df was never invoked for tmp root in full mode when rc=75"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All tmp_scratch_sweep df-target tests passed."

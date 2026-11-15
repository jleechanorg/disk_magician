#!/usr/bin/env bash
# Regression tests for batched scope checks (scope-batch) in
# scripts/lib/scratch_budget_artifact_children.py and scripts/cleanup_scratch_top_level.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$ROOT/scripts/lib/scratch_budget_artifact_children.py"
CLEANUP="$ROOT/scripts/cleanup_scratch_top_level.sh"
REAL_PYTHON3="$(command -v python3)"

T="$(mktemp -d "${TMPDIR:-/tmp}/dm-batch-scope.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1${2:+ ($2)}"; }

# --- Part 1: Direct scope-batch contract ---
SCOPE_ROOT="$T/scope-root"
mkdir -p "$SCOPE_ROOT/cand-a" "$SCOPE_ROOT/cand-b" "$SCOPE_ROOT/system-skip" \
         "$SCOPE_ROOT/_disk_magician_archive-skip" "$SCOPE_ROOT/com.apple.skip" \
         "$SCOPE_ROOT/git-repo/.git" "$SCOPE_ROOT/git-repo/sub"

batch_out="$T/scope-batch.bin"
printf '%s\0' \
  "$SCOPE_ROOT/cand-a" \
  "$SCOPE_ROOT/system-skip" \
  "$SCOPE_ROOT/cand-b" \
  "$SCOPE_ROOT/_disk_magician_archive-skip" \
  "$SCOPE_ROOT/com.apple.skip" \
  "$SCOPE_ROOT/git-repo/sub" \
  | "$REAL_PYTHON3" "$HELPER" scope-batch "$SCOPE_ROOT" >"$batch_out" 2>"$T/scope-batch.err"
rc=$?
expected_out="$T/scope-batch-expected.bin"
printf '%s\0' "$SCOPE_ROOT/cand-a" "$SCOPE_ROOT/cand-b" >"$expected_out"
if [[ "$rc" -eq 0 ]] && cmp -s "$batch_out" "$expected_out"; then
  ok "scope-batch emits only in-scope candidates NUL-delimited"
else
  bad "scope-batch emits only in-scope candidates NUL-delimited" "rc=$rc err=$(cat "$T/scope-batch.err" 2>/dev/null)"
fi

# Empty stdin
empty_out="$T/scope-empty.bin"
"$REAL_PYTHON3" "$HELPER" scope-batch "$SCOPE_ROOT" </dev/null >"$empty_out" 2>/dev/null
rc=$?
if [[ "$rc" -eq 0 && ! -s "$empty_out" ]]; then
  ok "scope-batch empty input exits 0 with empty output"
else
  bad "scope-batch empty input exits 0 with empty output" "rc=$rc"
fi

# Unterminated stdin fails closed
unterm_out="$T/scope-unterm.bin"
printf '%s' "$SCOPE_ROOT/cand-a" | "$REAL_PYTHON3" "$HELPER" scope-batch "$SCOPE_ROOT" >"$unterm_out" 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 && ! -s "$unterm_out" ]]; then
  ok "scope-batch unterminated input fails closed with no partial output"
else
  bad "scope-batch unterminated input fails closed" "rc=$rc"
fi

# Unmeasurable candidate (missing path -> OSError) fails closed with no partial output
unmeas_out="$T/scope-unmeas.bin"
printf '%s\0' "$SCOPE_ROOT/cand-a" "$SCOPE_ROOT/does-not-exist" \
  | "$REAL_PYTHON3" "$HELPER" scope-batch "$SCOPE_ROOT" >"$unmeas_out" 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 && ! -s "$unmeas_out" ]]; then
  ok "scope-batch unmeasurable candidate fails closed with no partial output"
else
  bad "scope-batch unmeasurable candidate fails closed" "rc=$rc"
fi

# --- Part 2: cleanup_scratch_top_level.sh --dry-run on registered root with 40 candidates ---
SANDBOX="$T/sandbox"
SCRATCH_ROOT="$SANDBOX/scratch"
STATE="$T/state"
LOG="$T/deletions.log"
VOLUME_CONFIG="$T/config.json"
mkdir -p "$SCRATCH_ROOT" "$STATE" "$SANDBOX"

SANDBOX="$(cd "$SANDBOX" && pwd -P)"
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"

"$REAL_PYTHON3" - "$VOLUME_CONFIG" "$SCRATCH_ROOT" <<'PY'
import json, sys
json.dump({
  "volumes": {
    "swap_headroom_gb": 40,
    "alarm_floor_gb": 20,
    "encryption": "none",
    "encryption_acknowledged_at": "2026-10-25T00:00:00Z",
    "classes": {
      "scratch": {"name": "diskm-scratch", "quota_gb": 30, "mountpoint": sys.argv[2]}
    }
  }
}, open(sys.argv[1], "w"))
PY

FAKE_DISKUTIL_STATE="$T/diskutil.json"
FAKE_DISKUTIL_CALLS="$T/diskutil.calls"
FAKE_DISKUTIL_MOUNTPOINT="$SCRATCH_ROOT"
"$REAL_PYTHON3" - "$FAKE_DISKUTIL_STATE" <<'PY'
import json, sys
state = {
  "container": {"ref": "disk3", "uuid": "CONTAINER-UUID", "ceiling": 1000 * 2**30, "free": 100 * 2**30},
  "volumes": [
    {"uuid": "DATA-UUID", "name": "Data", "ref": "disk3s1", "device": "disk3s1", "used": 100 * 2**30, "quota": 0, "roles": ["Data"], "mountpoint": "/System/Volumes/Data"},
    {"uuid": "SYSTEM-UUID", "name": "System", "ref": "disk3s5", "device": "disk3s5", "used": 10 * 2**30, "quota": 0, "roles": ["System"], "mountpoint": "/"},
    {"uuid": "VM-UUID", "name": "VM", "ref": "disk3s6", "device": "disk3s6", "used": 10 * 2**30, "quota": 0, "roles": ["VM"], "mountpoint": "/System/Volumes/VM"}
  ]
}
json.dump(state, open(sys.argv[1], "w"))
PY

export DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG"
export DISK_MAGICIAN_STATE_DIR="$STATE"
export DISK_MAGICIAN_DISKUTIL_BIN="$ROOT/tests/lib/fake_diskutil.py"
export FAKE_DISKUTIL_STATE FAKE_DISKUTIL_CALLS FAKE_DISKUTIL_MOUNTPOINT

rmdir "$SCRATCH_ROOT"
"$REAL_PYTHON3" -c 'import sys; from unittest.mock import patch; sys.path.insert(0, sys.argv[1]); import volume; patch.object(sys, "platform", "linux").start(); raise SystemExit(volume.create_cmd("scratch", True))' "$ROOT/scripts" >/dev/null

# Create 40 in-scope candidate directories + 1 out-of-scope directory
for i in $(seq -w 1 40); do
  mkdir -p "$SCRATCH_ROOT/cand-$i"
  printf 'payload\n' >"$SCRATCH_ROOT/cand-$i/file.bin"
done
mkdir -p "$SCRATCH_ROOT/system-preserved"
printf 'payload\n' >"$SCRATCH_ROOT/system-preserved/file.bin"

# Wrap python3 to count invocations of scratch_budget_artifact_children.py
SHIM_BIN="$T/shim-bin"
mkdir -p "$SHIM_BIN"
CALL_LOG="$T/artifact-children-calls.log"
cat >"$SHIM_BIN/python3" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == *"scratch_budget_artifact_children.py"* ]]; then
    printf '%s\n' "\$*" >>"$CALL_LOG"
    if [[ -n "\${FORCE_SCOPE_FAIL:-}" && " \$* " == *" scope"* ]]; then
      exit 2
    fi
    break
  fi
done
exec "$REAL_PYTHON3" "\$@"
SHIM
chmod +x "$SHIM_BIN/python3"

mkdir -p "$T/home"
chmod 700 "$T/home"

dry_out="$T/dry-run.out"
env -i HOME="$T/home" PATH="$SHIM_BIN:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" \
  TMPDIR="$T" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
  DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_DELETION_LOG="$LOG" \
  DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" \
  DISK_MAGICIAN_DISKUTIL_BIN="$ROOT/tests/lib/fake_diskutil.py" \
  FAKE_DISKUTIL_STATE="$FAKE_DISKUTIL_STATE" FAKE_DISKUTIL_CALLS="$FAKE_DISKUTIL_CALLS" \
  FAKE_DISKUTIL_MOUNTPOINT="$FAKE_DISKUTIL_MOUNTPOINT" \
  bash "$CLEANUP" --dry-run >"$dry_out" 2>&1
dry_rc=$?

call_count=0
[[ -f "$CALL_LOG" ]] && call_count="$(wc -l <"$CALL_LOG" | tr -d ' ')"

if [[ "$dry_rc" -eq 0 ]]; then
  ok "cleanup_scratch_top_level.sh --dry-run succeeds on 40 candidates"
else
  bad "cleanup_scratch_top_level.sh --dry-run succeeds on 40 candidates" "rc=$dry_rc"
fi

if [[ "$call_count" -le 2 ]]; then
  ok "scratch_budget_artifact_children.py invoked <= 2 times total ($call_count)"
else
  bad "scratch_budget_artifact_children.py invoked <= 2 times total" "got $call_count invocations (O(N) fork regression)"
fi

if grep -q "kept:discovery-boundary $SCRATCH_ROOT/system-preserved" "$dry_out"; then
  ok "out-of-scope (rc=3) candidate skipped as kept:discovery-boundary"
else
  bad "out-of-scope (rc=3) candidate skipped as kept:discovery-boundary"
fi

# --- Part 3: Unmeasurable-scope exits 75 ---
: >"$CALL_LOG"
unmeas_dry_out="$T/unmeas-dry.out"
env -i HOME="$T/home" PATH="$SHIM_BIN:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" \
  TMPDIR="$T" FORCE_SCOPE_FAIL=1 \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
  DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_DELETION_LOG="$LOG" \
  DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" \
  DISK_MAGICIAN_DISKUTIL_BIN="$ROOT/tests/lib/fake_diskutil.py" \
  FAKE_DISKUTIL_STATE="$FAKE_DISKUTIL_STATE" FAKE_DISKUTIL_CALLS="$FAKE_DISKUTIL_CALLS" \
  FAKE_DISKUTIL_MOUNTPOINT="$FAKE_DISKUTIL_MOUNTPOINT" \
  bash "$CLEANUP" --dry-run >"$unmeas_dry_out" 2>&1
unmeas_rc=$?

if [[ "$unmeas_rc" -eq 75 ]] && grep -q "unmeasurable-scope" "$unmeas_dry_out"; then
  ok "unmeasurable-scope exits 75 with summary"
else
  bad "unmeasurable-scope exits 75 with summary" "rc=$unmeas_rc"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

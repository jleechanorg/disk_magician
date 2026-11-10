#!/usr/bin/env bash
# Isolated contract coverage for operator-authorized diskm clean Scratch dispatch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_ROOT="${DISKM_SCRATCH:-/tmp}"
WORK="$(mktemp -d "$SCRATCH_ROOT/audit_clean_scratch.XXXXXX")"
trap 'python3 -c '\''import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1]); assert p.is_dir() and p.name.startswith("audit_clean_scratch."); shutil.rmtree(p)'\'' "$WORK"' EXIT
FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE/scripts/lib" "$WORK/home/.local/bin/guards"
printf '%s\n' '#!/usr/bin/env bash' 'exec /bin/rm "$@"' >"$WORK/home/.local/bin/guards/rm"
chmod +x "$WORK/home/.local/bin/guards/rm"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$FIXTURE/scripts/disk_audit.sh"
cp "$REPO_ROOT/scripts/lib/degraded_gate.sh" "$FIXTURE/scripts/lib/degraded_gate.sh"
cat >"$FIXTURE/disk_magician.sh" <<'INNER'
#!/usr/bin/env bash
printf '%s\n' "${TEST_VOLUME_STATUS_JSON:?}"
INNER
chmod +x "$FIXTURE/disk_magician.sh"
cat >"$FIXTURE/scripts/cleanup_scratch_top_level.sh" <<'INNER'
#!/usr/bin/env bash
{
  printf 'automatic=%s approval=%s args=' "${DISK_MAGICIAN_SCRATCH_AUTOMATIC-unset}" "${SCRATCH_TOP_LEVEL_APPROVED-unset}"
  printf '<%s>' "$@"
  printf '\n'
} >>"$DISPATCH_LOG"
printf '%s\n' 'stub-cleaner: completed'
INNER
chmod +x "$FIXTURE/scripts/cleanup_scratch_top_level.sh"

run_clean() {
  local output rc=0 expected_rc="${4:-0}"
  output="$(env HOME="$WORK/home" DISPATCH_LOG="$WORK/invocations" \
    DISK_MAGICIAN_DISKM_BIN="$FIXTURE/disk_magician.sh" \
    TEST_VOLUME_STATUS_JSON="$1" ${2:-} ${3:-} \
    bash "$FIXTURE/scripts/disk_audit.sh" clean --dry-run --live --skip-directory-breakdown --no-history 2>&1)" || rc=$?
  printf '%s\n' "$output"
  [[ "$rc" -eq "$expected_rc" ]] || { echo "FAIL: disk_audit exited $rc (expected $expected_rc)"; exit 1; }
}

assert_log() {
  local expected="$1" actual
  actual="$(cat "$WORK/invocations" 2>/dev/null || true)"
  [[ "$actual" == *"$expected"* ]] || { printf 'FAIL: expected %s in invocation: %s\n' "$expected" "$actual"; exit 1; }
}
assert_output() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || { printf 'FAIL: expected output %s\n' "$expected"; exit 1; }
}
volume_json() {
  python3 - "$1" "$2" <<'PY'
import json,sys
free_gib,used_pct=map(int,sys.argv[1:])
quota=200*1024**3
print(json.dumps({"container":{"free_bytes":free_gib*1024**3},"volumes":[{"class":"scratch","available":True,"allocated_bytes":quota*used_pct//100,"quota_bytes":quota}]}))
PY
}

echo "Case 1: explicit one-shot policy plus low host space selects approved budget mode and preserves dry-run"
: >"$WORK/invocations"
out="$(run_clean "$(volume_json 39 50)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=50" "SCRATCH_TOP_LEVEL_APPROVED=0 DISK_MAGICIAN_SCRATCH_AUTOMATIC=1")"
assert_output "$out" "scratch-budget: reason=operator-policy mode=budget"
assert_log "automatic=0 approval=1 args=<--dry-run><--budget-pct><50><--budget-floor-minutes><1440><--budget-preserve-content-keeps>"
echo "  PASS"

echo "Case 2: valid policy from launchd EnvironmentVariables is honored when pressure trigger is crossed"
# The installed Mac LaunchAgent currently carries this value; the template does
# not, so keep the test's plist fixture explicit and exercise the inherited env.
PLIST="$WORK/launchd.plist"
python3 - "$PLIST" <<'PY'
import plistlib,sys
with open(sys.argv[1],"wb") as f:
 plistlib.dump({"EnvironmentVariables":{"DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT":"50"}},f)
PY
launchd_pct="$(python3 - "$PLIST" <<'PY'
import plistlib,sys
print(plistlib.load(open(sys.argv[1],"rb"))["EnvironmentVariables"]["DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT"])
PY
)"
: >"$WORK/invocations"
out="$(run_clean "$(volume_json 80 80)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=$launchd_pct")"
assert_output "$out" "reason=operator-policy mode=budget"
assert_log "automatic=0 approval=1 args=<--dry-run><--budget-pct><50><--budget-floor-minutes><1440><--budget-preserve-content-keeps>"
echo "  PASS"

echo "Case 3: valid policy from Linux systemd drop-in is honored when Scratch crosses 70%"
DROPIN="$WORK/20-lru-budget.conf"
cat >"$DROPIN" <<'INNER'
[Service]
Environment=DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=72
INNER
dropin_pct="$(sed -n 's/^Environment=DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=//p' "$DROPIN")"
: >"$WORK/invocations"
out="$(run_clean "$(volume_json 80 70)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=$dropin_pct")"
assert_output "$out" "reason=operator-policy mode=budget"
assert_log "automatic=0 approval=1 args=<--dry-run><--budget-pct><72><--budget-floor-minutes><1440><--budget-preserve-content-keeps>"
echo "  PASS"
REAL_DROPIN="${HOME:-}/.config/systemd/user/diskm-scratch-reclaim.service.d/20-lru-budget.conf"
if [[ -r "$REAL_DROPIN" ]]; then
  actual_pct="$(sed -n 's/^Environment=DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=//p' "$REAL_DROPIN" | head -1)"
  if [[ "$actual_pct" =~ ^[1-9][0-9]?$ ]]; then
    : >"$WORK/invocations"
    out="$(run_clean "$(volume_json 80 70)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=$actual_pct")"
    assert_log "automatic=0 approval=1 args=<--dry-run><--budget-pct><$actual_pct><--budget-floor-minutes><1440><--budget-preserve-content-keeps>"
    echo "  PASS: current Linux systemd drop-in value $actual_pct passed through"
  else
    echo "FAIL: current Linux systemd drop-in has invalid budget policy '$actual_pct'"
    exit 1
  fi
fi

echo "Case 4: healthy host skips budget even when configured"
: >"$WORK/invocations"
out="$(run_clean "$(volume_json 80 69)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=50" "SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_AUTOMATIC=0")"
assert_output "$out" "reason=healthy mode=fallback"
assert_log "automatic=1 approval=0 args=<--dry-run><--available-floor>"
[[ "$(cat "$WORK/invocations")" != *"--budget-pct"* ]] || { echo "FAIL: healthy state dispatched budget mode"; exit 1; }
echo "  PASS"

echo "Case 5: absent or invalid policy under pressure uses conservative C14 available-floor mode"
for assignment in "" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=0"; do
  : >"$WORK/invocations"
  out="$(run_clean "$(volume_json 39 50)" "$assignment" "SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_AUTOMATIC=0")"
  if [[ "$assignment" == "" ]]; then assert_output "$out" "reason=policy-unconfigured mode=fallback"; else assert_output "$out" "reason=policy-invalid mode=fallback"; fi
  assert_log "automatic=1 approval=0 args=<--dry-run><--available-floor>"
  [[ "$(cat "$WORK/invocations")" != *"--budget-pct"* ]] || { echo "FAIL: invalid policy dispatched budget mode"; exit 1; }
done
echo "  PASS"

echo "Case 6: raised conservative floor is converted to minutes"
: >"$WORK/invocations"
out="$(run_clean "$(volume_json 39 50)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=50 SCRATCH_PRUNE_MIN_HOURS=72")"
assert_output "$out" "floor=4320m"
assert_log "--budget-floor-minutes><4320>"
echo "  PASS"

echo "Case 7: malformed and overflowing floor values never launch the cleaner"
for floor in invalid 153722867280912931; do
  : >"$WORK/invocations"
  out="$(run_clean "$(volume_json 39 50)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=50 SCRATCH_PRUNE_MIN_HOURS=$floor" "" 1)"
  assert_output "$out" "reason=invalid-floor; cleaner not launched"
  [[ ! -s "$WORK/invocations" ]] || { echo "FAIL: invalid floor launched cleaner"; exit 1; }
done
echo "  PASS"

echo "Case 8: budget target bounds reject zero, 100, and nondecimal values"
for pct in 0 100 x; do
  : >"$WORK/invocations"
  out="$(run_clean "$(volume_json 39 50)" "DISK_MAGICIAN_SCRATCH_LRU_BUDGET_PCT=$pct")"
  assert_output "$out" "reason=policy-invalid mode=fallback"
  assert_log "automatic=1 approval=0 args=<--dry-run><--available-floor>"
done
echo "  PASS"

echo "PASS: disk_audit Scratch policy dispatch"

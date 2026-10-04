#!/usr/bin/env bash
# test_residual_drilldown_gate.sh — absolute residual_gb gates drilldown (disk_magician-s8x)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/residual_drilldown.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$WORK"
export DISK_MAGICIAN_STATE_DIR="$WORK/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR" "$WORK/home"
echo '{"entries":[]}' > "$WORK/discover_last.json"
export DISK_MAGICIAN_DISCOVER_LAST="$WORK/discover_last.json"
export DISK_MAGICIAN_UNCOVERED_ROOTS_CMD="true"

PASS=0
FAIL=0
ok() { echo "OK: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

SNAP="$WORK/snap.json"
cat > "$SNAP" <<'JSON'
{
  "timestamp": "2026-09-11T12:00:00Z",
  "disk_used_gb": 800,
  "snapshot_coverage_pct": 20,
  "residual_gb": 120.5,
  "residual_delta_gb": 0.4
}
JSON

# Threshold is logged before the slow --discover fallback; cap wall-clock.
out="$(HOME="$WORK/home" timeout 5 "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1 || true)"
if grep -q "residual 120.5 GB >= threshold" <<< "$out"; then
  ok "gates on absolute residual_gb not delta"
else
  bad "expected >= threshold on 120.5 GB; rc=$rc output: $out"
fi

# Low residual should no-op
cat > "$SNAP" <<'JSON'
{
  "timestamp": "2026-09-11T12:01:00Z",
  "disk_used_gb": 800,
  "snapshot_coverage_pct": 95,
  "residual_gb": 2.0,
  "residual_delta_gb": 0.4
}
JSON
out="$(HOME="$WORK/home" "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)"
if grep -qE "residual 2(\.0)? GB < threshold" <<< "$out"; then
  ok "no-op below threshold"
else
  bad "expected no-op: $out"
fi

# An uncovered-roots checker that exceeds its cap must not abort or alter the
# existing residual no-op behavior.
SLEEPY_STUB="$WORK/sleepy_check_uncovered_roots.sh"
cat > "$SLEEPY_STUB" <<'STUB'
#!/usr/bin/env bash
sleep 5
echo '{"uncovered": []}'
STUB
chmod +x "$SLEEPY_STUB"
out="$(HOME="$WORK/home" DISK_MAGICIAN_UNCOVERED_ROOTS_CMD="$SLEEPY_STUB" DISK_MAGICIAN_UNCOVERED_TIMEOUT_S=1 timeout 5 "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)"
if grep -q "uncovered-roots check timed out" <<< "$out"; then
  ok "logs timeout and stays bounded"
else
  bad "expected timeout log: $out"
fi
if grep -qE "residual 2(\.0)? GB < threshold" <<< "$out"; then
  ok "existing no-op output unaffected by timeout"
else
  bad "expected no-op output: $out"
fi

rc=0
out="$(timeout 5 env HOME="$WORK/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin DISK_MAGICIAN_UNCOVERED_ROOTS_CMD="$SLEEPY_STUB" DISK_MAGICIAN_UNCOVERED_TIMEOUT_S=1 "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "uncovered-roots check timed out" <<< "$out"; then
  ok "timeout cap applies under launchd PATH"
else
  bad "expected bounded launchd-PATH run: rc=$rc output=$out"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

#!/usr/bin/env bash
# test_residual_drilldown_gate.sh — absolute residual_gb gates drilldown (disk_magician-s8x)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/residual_drilldown.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DISK_MAGICIAN_STATE_DIR="$WORK/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
echo '{"entries":[]}' > "$WORK/discover_last.json"
export DISK_MAGICIAN_DISCOVER_LAST="$WORK/discover_last.json"

# Hermetic stub for the uncovered-roots alert (bead disk_magician-drilldown-
# uncovered-alert-impl-bv6) — this test calls the real residual_drilldown.sh
# against real state under a `timeout 5` wall-clock budget; the real
# check_uncovered_roots.sh takes ~6.5s against live state and would blow that
# budget before this test's own assertions ever run. `true --json` exits 0
# with empty stdout, which uncovered_alert() fails to parse as JSON and
# silently skips (fail-soft), restoring this test's original hermetic
# behavior without touching its `timeout 5`.
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
out="$(timeout 5 "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1 || true)"
if grep -q "residual 120.5 GB >= threshold" <<< "$out"; then
  ok "gates on absolute residual_gb not delta"
else
  bad "expected >= threshold on 120.5 GB; output: $out"
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
out="$("$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)"
if grep -qE "residual 2(\.0)? GB < threshold" <<< "$out"; then
  ok "no-op below threshold"
else
  bad "expected no-op: $out"
fi

# Uncovered-roots check that outlives DISK_MAGICIAN_UNCOVERED_TIMEOUT_S must
# be cut off, and residual_drilldown must still exit with its normal code
# (fail-soft on timeout, not just on failure/missing).
SLEEPY_STUB="$WORK/sleepy_check_uncovered_roots.sh"
cat > "$SLEEPY_STUB" <<'STUB'
#!/usr/bin/env bash
sleep 5
echo '{"uncovered": []}'
STUB
chmod +x "$SLEEPY_STUB"

cat > "$SNAP" <<'JSON'
{
  "timestamp": "2026-09-11T12:02:00Z",
  "disk_used_gb": 800,
  "snapshot_coverage_pct": 95,
  "residual_gb": 2.0,
  "residual_delta_gb": 0.4
}
JSON
out="$(DISK_MAGICIAN_UNCOVERED_ROOTS_CMD="$SLEEPY_STUB" DISK_MAGICIAN_UNCOVERED_TIMEOUT_S=1 timeout 5 "$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "residual_drilldown exits with its normal code (0) when the uncovered-roots check times out"
else
  bad "expected exit 0 when uncovered-roots check times out, got rc=$rc: $out"
fi
if grep -q "uncovered-roots check timed out" <<< "$out"; then
  ok "logs the timeout instead of hanging or erroring"
else
  bad "expected a timeout log line: $out"
fi
if grep -qE "residual 2(\.0)? GB < threshold" <<< "$out"; then
  ok "existing no-op output unaffected by the timed-out uncovered-roots check"
else
  bad "expected no-op output unaffected by timeout: $out"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

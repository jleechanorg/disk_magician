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
out="$("$SCRIPT" --snapshot-file "$SNAP" --dry-run 2>&1)"
if grep -qE "residual 2(\.0)? GB < threshold" <<< "$out"; then
  ok "no-op below threshold"
else
  bad "expected no-op: $out"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

#!/usr/bin/env bash
# test_drilldown_uncovered_roots_alert.sh — proves residual_drilldown.sh
# surfaces an UNCOVERED-roots alert line when check_uncovered_roots.sh
# reports a non-empty "uncovered" list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/residual_drilldown.sh"

TMP_ROOT=$(mktemp -d -t drilldown_uncovered_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN" "$TMP_ROOT/state" "$TMP_ROOT/home"

cat > "$FAKE_BIN/check_uncovered_roots.sh" <<'MOCK'
#!/usr/bin/env bash
echo '{"uncovered": [{"path": "/fake/uncovered/root", "size_gb": 12.3}], "protected": [], "needs_decision": []}'
exit 0
MOCK
chmod +x "$FAKE_BIN/check_uncovered_roots.sh"
cp "$TARGET" "$FAKE_BIN/residual_drilldown.sh"
mkdir -p "$FAKE_BIN/lib"
cp "$SCRIPT_DIR/../scripts/lib/resolve_snapshot_json.sh" "$FAKE_BIN/lib/resolve_snapshot_json.sh"
chmod +x "$FAKE_BIN/residual_drilldown.sh"

echo '{"disk_used_gb": 500, "snapshot_coverage_pct": 90, "granularity_buckets": []}' > "$TMP_ROOT/state/disk_snapshot.json"

set +e
OUTPUT="$(cd "$FAKE_BIN" && DISK_MAGICIAN_SNAPSHOT_FILE="$TMP_ROOT/state/disk_snapshot.json" DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state" HOME="$TMP_ROOT/home" ./residual_drilldown.sh --dry-run 2>&1)"
RC=$?
set -e

PASS=0
FAIL=0
if echo "$OUTPUT" | grep -q "UNCOVERED"; then
  echo "  PASS  emits an UNCOVERED alert line"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  no UNCOVERED alert line found in:"
  echo "$OUTPUT"
  FAIL=$(( FAIL + 1 ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All drilldown_uncovered_roots_alert tests passed."

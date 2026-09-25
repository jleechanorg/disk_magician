#!/usr/bin/env bash
# test_drilldown_uncovered_roots_alert.sh — proves residual_drilldown.sh
# surfaces an UNCOVERED-roots alert line when check_uncovered_roots.sh
# reports a non-empty "uncovered" list, and that the alert is fail-soft
# (never changes residual_drilldown's own exit code or existing output
# when check_uncovered_roots.sh fails or is missing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/residual_drilldown.sh"

TMP_ROOT=$(mktemp -d -t drilldown_uncovered_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/home"
echo '{"disk_used_gb": 500, "snapshot_coverage_pct": 90, "granularity_buckets": []}' > "$TMP_ROOT/state/disk_snapshot.json"

setup_fake_bin() {
  local dir="$1"
  mkdir -p "$dir" "$dir/lib"
  cp "$TARGET" "$dir/residual_drilldown.sh"
  cp "$SCRIPT_DIR/../scripts/lib/resolve_snapshot_json.sh" "$dir/lib/resolve_snapshot_json.sh"
  chmod +x "$dir/residual_drilldown.sh"
}

run_drilldown() {
  local dir="$1"
  (cd "$dir" && DISK_MAGICIAN_SNAPSHOT_FILE="$TMP_ROOT/state/disk_snapshot.json" DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state" HOME="$TMP_ROOT/home" ./residual_drilldown.sh --dry-run 2>&1)
}

PASS=0
FAIL=0

echo "Test 1: emits an UNCOVERED alert line on the no-candidates (line-264) exit path"
FAKE_BIN="$TMP_ROOT/bin1"
setup_fake_bin "$FAKE_BIN"
cat > "$FAKE_BIN/check_uncovered_roots.sh" <<'MOCK'
#!/usr/bin/env bash
echo '{"uncovered": [{"path": "/fake/uncovered/root", "size_gb": 12.3}], "protected": [], "needs_decision": []}'
exit 0
MOCK
chmod +x "$FAKE_BIN/check_uncovered_roots.sh"

set +e
OUTPUT="$(run_drilldown "$FAKE_BIN")"
RC=$?
set -e

if echo "$OUTPUT" | grep -q "UNCOVERED"; then
  echo "  PASS  emits an UNCOVERED alert line"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  no UNCOVERED alert line found in:"
  echo "$OUTPUT"
  FAIL=$(( FAIL + 1 ))
fi

if [[ "$RC" -eq 0 ]]; then
  echo "  PASS  residual_drilldown still exits 0 on the no-candidates path"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  residual_drilldown exited $RC (expected 0)"
  FAIL=$(( FAIL + 1 ))
fi

echo "Test 2: fail-soft — exit code and existing output unchanged when check_uncovered_roots.sh fails"
FAKE_BIN2="$TMP_ROOT/bin2"
setup_fake_bin "$FAKE_BIN2"
cat > "$FAKE_BIN2/check_uncovered_roots.sh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$FAKE_BIN2/check_uncovered_roots.sh"

set +e
OUTPUT2="$(run_drilldown "$FAKE_BIN2")"
RC2=$?
set -e

if [[ "$RC2" -eq 0 ]]; then
  echo "  PASS  residual_drilldown still exits 0 when check_uncovered_roots.sh fails"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  residual_drilldown exited $RC2 (expected 0) when check_uncovered_roots.sh fails"
  FAIL=$(( FAIL + 1 ))
fi

if echo "$OUTPUT2" | grep -q "no untracked candidates found"; then
  echo "  PASS  existing no-op output unchanged when check_uncovered_roots.sh fails"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  existing no-op output missing/changed:"
  echo "$OUTPUT2"
  FAIL=$(( FAIL + 1 ))
fi

if echo "$OUTPUT2" | grep -q "UNCOVERED"; then
  echo "  FAIL  UNCOVERED alert fired despite check_uncovered_roots.sh failing"
  FAIL=$(( FAIL + 1 ))
else
  echo "  PASS  no UNCOVERED alert when check_uncovered_roots.sh fails"
  PASS=$(( PASS + 1 ))
fi

echo "Test 3: fail-soft — exit code and existing output unchanged when check_uncovered_roots.sh is missing"
FAKE_BIN3="$TMP_ROOT/bin3"
setup_fake_bin "$FAKE_BIN3"
# Deliberately no check_uncovered_roots.sh in $FAKE_BIN3 — simulates "missing".

set +e
OUTPUT3="$(run_drilldown "$FAKE_BIN3")"
RC3=$?
set -e

if [[ "$RC3" -eq 0 ]]; then
  echo "  PASS  residual_drilldown still exits 0 when check_uncovered_roots.sh is missing"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  residual_drilldown exited $RC3 (expected 0) when check_uncovered_roots.sh is missing"
  FAIL=$(( FAIL + 1 ))
fi

if echo "$OUTPUT3" | grep -q "no untracked candidates found"; then
  echo "  PASS  existing no-op output unchanged when check_uncovered_roots.sh is missing"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  existing no-op output missing/changed:"
  echo "$OUTPUT3"
  FAIL=$(( FAIL + 1 ))
fi

if echo "$OUTPUT3" | grep -qE "UNCOVERED|Traceback|No such file or directory"; then
  echo "  FAIL  leaked error/alert output when check_uncovered_roots.sh is missing:"
  echo "$OUTPUT3"
  FAIL=$(( FAIL + 1 ))
else
  echo "  PASS  no leaked error/alert output when check_uncovered_roots.sh is missing"
  PASS=$(( PASS + 1 ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All drilldown_uncovered_roots_alert tests passed."

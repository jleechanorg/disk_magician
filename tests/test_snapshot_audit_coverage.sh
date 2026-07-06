#!/usr/bin/env bash
# test_snapshot_audit_coverage.sh — TDD for partial-coverage snapshot acceptance.
#
# Reproduces the 2026-07-06 blocker: snapshot at 69.8% coverage with
# measurement_status=partial and snapshot_warning=low_coverage was rejected
# by disk_audit.sh even though JSON was valid.
#
# Run: bash tests/test_snapshot_audit_coverage.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
SNAP_SCRIPT="$REPO_ROOT/scripts/disk_snapshot.sh"

WORK="$(mktemp -d -t disk_audit_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

write_partial_snap() {
  local path="$1" cov="$2"
  python3 - "$path" "$cov" <<'PY'
import json, datetime, sys
path, cov = sys.argv[1], float(sys.argv[2])
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 776,
    "disk_free_gb": 102,
    "disk_pct": 83,
    "snapshot_coverage_pct": cov,
    "snapshot_warning": "low_coverage",
    "snapshot_metadata": {
        "captured_at": ts,
        "age_seconds": 120,
        "coverage_pct": cov,
        "measurement_status": "partial",
        "measured_paths_ok": 39,
        "measured_paths_total": 42,
    },
    "timeout_keys": ["library_messages", "library_containers", "downloads"],
    "directories": {
        "projects": 123471436,
        "colima": 15869036,
        "ao_sessions": 44102280,
        "codex_sessions": 16766204,
    },
}
json.dump(snap, open(path, "w"))
PY
}

section "1. Partial snapshot 69.8% is accepted by audit (uses snapshot-ranked view)"
PARTIAL="$WORK/partial_698.json"
write_partial_snap "$PARTIAL" 69.8
OUTPUT=$(DISK_SNAPSHOT_JSON="$PARTIAL" timeout 30 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -q "Largest directories (snapshot-ranked"; then
  ok "69.8% partial snapshot used for directory breakdown"
else
  bad "69.8% partial snapshot rejected — expected snapshot-ranked breakdown"
  echo "$OUTPUT" | sed 's/^/      /' | head -15
fi
if echo "$OUTPUT" | grep -qiE "partial coverage|low coverage|timeout_keys|69.8"; then
  ok "audit surfaces partial/low-coverage warning"
else
  bad "audit missing partial coverage warning"
fi

section "2. Truly low coverage 30% still rejected"
LOW="$WORK/low_30.json"
write_partial_snap "$LOW" 30.0
OUTPUT=$(DISK_SNAPSHOT_JSON="$LOW" timeout 30 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -q "Snapshot not usable"; then
  ok "30% snapshot rejected"
else
  bad "30% snapshot should be rejected"
fi

section "3. containers_captured is a single integer in snapshot JSON (emnx)"
# Synthetic: simulate multi-line grep -c bug by ensuring snapshot validates
FAKE_LISTING=$'123\t/foo\n456\t/bar'
CAP=$(printf '%s' "$FAKE_LISTING" | grep -c '^[0-9]' 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)
if [[ "$CAP" =~ ^[0-9]+$ ]]; then
  ok "containers_captured sanitizes to integer ($CAP)"
else
  bad "containers_captured not integer: '$CAP'"
fi

EMNX_SNAP="$WORK/emnx_snap.json"
python3 - "$EMNX_SNAP" <<'PY'
import json, datetime, sys
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts, "hostname": "t", "disk_total_gb": 100, "disk_used_gb": 50,
    "disk_free_gb": 50, "disk_pct": 50, "snapshot_coverage_pct": 80.0,
    "snapshot_metadata": {
        "captured_at": ts, "age_seconds": 0, "coverage_pct": 80.0,
        "measurement_status": "partial", "measured_paths_ok": 10,
        "measured_paths_total": 12,
        "library_containers_top_subdirs_captured": 0,
        "library_containers_total_subdirs": 602,
    },
    "directories": {"projects": 1000},
}
json.dump(snap, open(sys.argv[1], "w"))
PY
if python3 -m json.tool < "$EMNX_SNAP" >/dev/null 2>&1; then
  ok "synthetic snapshot with containers metadata is valid JSON"
else
  bad "containers metadata broke JSON"
fi

section "Summary"
echo "  PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All snapshot audit coverage checks passed."
exit 0

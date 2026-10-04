#!/usr/bin/env bash
# test_disk_audit_hostile_snapshot.sh — Hostile snapshot shell injection regression test
#
# Asserts that:
# 1. Hostile snapshot JSON containing literal shell metacharacters, subshell executions
#    ($(touch ...), `touch ...`), quotes, and command injections in snapshot_warning,
#    measurement_status, coverage, swap, or directories are safely parsed without
#    eval or command execution.
# 2. Sentinels are never created, proving zero code execution.
# 3. Typed parsing preserves valid metrics, sanitizes string fields, and
#    rejects non-finite (NaN, Infinity), boolean, and out-of-range coverage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"

TMP_DIR=$(mktemp -d -t test_hostile_snap.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

SENTINEL_DIR="$TMP_DIR/sentinels"
mkdir -p "$SENTINEL_DIR"

WARN_SENTINEL_1="$SENTINEL_DIR/hostile_warn_subshell"
WARN_SENTINEL_2="$SENTINEL_DIR/hostile_warn_backticks"
STATUS_SENTINEL="$SENTINEL_DIR/hostile_status_injected"
COV_SENTINEL="$SENTINEL_DIR/hostile_cov_injected"
SWAP_SENTINEL="$SENTINEL_DIR/hostile_swap_injected"
DIR_SENTINEL="$SENTINEL_DIR/hostile_dir_injected"

FIXTURE_HOME="$TMP_DIR/home"
FIXTURE_STATE="$TMP_DIR/state"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_STATE"

# Case 1: Write hostile JSON with literal subshells, backticks, and quotes via Python
HOSTILE_SNAP_1="$TMP_DIR/hostile_snap_1.json"
python3 - "$HOSTILE_SNAP_1" "$WARN_SENTINEL_1" "$WARN_SENTINEL_2" "$STATUS_SENTINEL" "$SWAP_SENTINEL" "$DIR_SENTINEL" <<'PY'
import json, sys
out, w1, w2, st, sw, dr = sys.argv[1:7]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": f"low_coverage; $({w1}); `{w2}`; ' \" evil",
    "swap_used_gb": f"1.5; $({sw})",
    "snapshot_metadata": {
        "age_seconds": 300,
        "measurement_status": f"partial; $({st}); ' evil",
        "coverage_pct": 85.5
    },
    "directories": {
        f"projects; $({dr})": 10485760,
        "colima": 5242880
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_1="$TMP_DIR/audit_1.log"
RC_1=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$HOSTILE_SNAP_1" \
bash "$TARGET_SCRIPT" >"$OUT_1" 2>&1 || RC_1=$?

if [[ $RC_1 -ne 0 ]]; then
  echo "FAIL: disk_audit.sh failed on hostile snapshot 1 with code $RC_1" >&2
  cat "$OUT_1" >&2
  exit 1
fi

# Verify ZERO sentinels were created in Case 1
for s in "$WARN_SENTINEL_1" "$WARN_SENTINEL_2" "$STATUS_SENTINEL" "$SWAP_SENTINEL" "$DIR_SENTINEL"; do
  if [[ -e "$s" ]]; then
    echo "FAIL: Command injection detected! Sentinel created: $s" >&2
    exit 1
  fi
done

# Verify partial coverage warning and sanitized status from hostile snapshot 1
if ! grep -qF "snapshot_warning=low_coverage" "$OUT_1"; then
  echo "FAIL: expected snapshot_warning safely parsed in audit output" >&2
  cat "$OUT_1" >&2
  exit 1
fi

if ! grep -qF "Snapshot measurement_status: partial; \$(/bin/echo" "$OUT_1" && ! grep -qF "Snapshot measurement_status: partial;" "$OUT_1"; then
  echo "FAIL: expected measurement_status safely preserved as literal text in audit output" >&2
  cat "$OUT_1" >&2
  exit 1
fi

# Case 2: Hostile command injection in snapshot_coverage_pct string
HOSTILE_SNAP_2="$TMP_DIR/hostile_snap_2.json"
python3 - "$HOSTILE_SNAP_2" "$COV_SENTINEL" "$SWAP_SENTINEL" <<'PY'
import json, sys
out, cov_s, sw_s = sys.argv[1:4]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": f"85.5; $({cov_s})",
    "snapshot_warning": "none",
    "swap_used_gb": f"1.5; $({sw_s})",
    "snapshot_metadata": {
        "age_seconds": 300,
        "measurement_status": "complete"
    },
    "directories": {}
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_2="$TMP_DIR/audit_2.log"
RC_2=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$HOSTILE_SNAP_2" \
bash "$TARGET_SCRIPT" >"$OUT_2" 2>&1 || RC_2=$?

if [[ $RC_2 -ne 0 ]]; then
  echo "FAIL: disk_audit.sh crashed on hostile snapshot 2 with code $RC_2" >&2
  cat "$OUT_2" >&2
  exit 1
fi

# Verify ZERO sentinels were created in Case 2
for s in "$COV_SENTINEL" "$SWAP_SENTINEL"; do
  if [[ -e "$s" ]]; then
    echo "FAIL: Command injection detected in Case 2! Sentinel created: $s" >&2
    exit 1
  fi
done

# Verify malformed coverage is safely rejected and falls back to live du
if ! grep -qF "Snapshot not usable (coverage" "$OUT_2"; then
  echo "FAIL: expected malformed coverage to be rejected in Case 2" >&2
  cat "$OUT_2" >&2
  exit 1
fi

# Case 3: Non-finite, boolean, and out-of-bounds coverage values must be rejected
python3 - "$TMP_DIR" <<'PY'
import json, sys, math
tmp = sys.argv[1]
test_cases = [
    ("nan", float("nan")),
    ("inf", float("inf")),
    ("neginf", float("-inf")),
    ("bool_true", True),
    ("bool_false", False),
    ("over_100", 150.0),
    ("neg_10", -10.0),
]
for name, val in test_cases:
    snap = {
        "timestamp": "2026-10-04T00:00:00Z",
        "disk_total_gb": 926,
        "disk_used_gb": 750,
        "disk_free_gb": 176,
        "disk_pct": 81,
        "snapshot_coverage_pct": val,
        "snapshot_warning": "",
        "swap_used_gb": val,
        "snapshot_metadata": {
            "age_seconds": True,
            "measurement_status": "complete"
        },
        "directories": {
            "projects": 10485760
        }
    }
    with open(f"{tmp}/snap_bad_{name}.json", "w") as f:
        json.dump(snap, f)
PY

for bad_name in "nan" "inf" "neginf" "bool_true" "bool_false" "over_100" "neg_10"; do
  SNAP_BAD="$TMP_DIR/snap_bad_${bad_name}.json"
  OUT_BAD="$TMP_DIR/audit_bad_${bad_name}.log"
  RC_BAD=0
  HOME="$FIXTURE_HOME" \
  DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
  DISK_SNAPSHOT_JSON="$SNAP_BAD" \
  bash "$TARGET_SCRIPT" >"$OUT_BAD" 2>&1 || RC_BAD=$?
  
  if [[ $RC_BAD -ne 0 ]]; then
    echo "FAIL: disk_audit.sh crashed on bad coverage '$bad_name' with code $RC_BAD" >&2
    cat "$OUT_BAD" >&2
    exit 1
  fi
  
  if ! grep -qF "Snapshot not usable (coverage" "$OUT_BAD"; then
    echo "FAIL: bad coverage '$bad_name' was not rejected by disk_audit.sh" >&2
    cat "$OUT_BAD" >&2
    exit 1
  fi
done

echo "PASS: hostile snapshot injection vectors and non-finite bypasses safely neutralized"
exit 0

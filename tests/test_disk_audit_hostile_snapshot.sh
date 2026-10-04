#!/usr/bin/env bash
# test_disk_audit_hostile_snapshot.sh — Hostile snapshot shell injection regression test
#
# Asserts that:
# 1. Hostile snapshot JSON containing literal shell metacharacters, subshell executions
#    ($(touch ...), `touch ...`), quotes, and command injections in snapshot_warning,
#    measurement_status, coverage, swap, or directories are safely parsed without
#    eval or command execution.
# 2. Sentinels are never created, proving zero code execution.
# 3. Dedicated quote breakout tests verify that unbalanced single and double quotes
#    do not cause syntax errors or break execution.
# 4. Typed parsing preserves valid metrics, sanitizes string fields, and
#    rejects non-finite (NaN, Infinity), boolean, and out-of-range coverage,
#    swap, and age_seconds values.
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
SWAP_SENTINEL_1="$SENTINEL_DIR/hostile_swap_injected_1"
SWAP_SENTINEL_2="$SENTINEL_DIR/hostile_swap_injected_2"
DIR_SENTINEL="$SENTINEL_DIR/hostile_dir_injected"

FIXTURE_HOME="$TMP_DIR/home"
FIXTURE_STATE="$TMP_DIR/state"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_STATE"

# Case 1: Pure command-substitution payloads (syntactically valid if evaluated by a shell)
HOSTILE_SNAP_1="$TMP_DIR/hostile_snap_1.json"
python3 - "$HOSTILE_SNAP_1" "$WARN_SENTINEL_1" "$WARN_SENTINEL_2" "$STATUS_SENTINEL" "$SWAP_SENTINEL_1" "$DIR_SENTINEL" <<'PY'
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
    "snapshot_warning": f"low_coverage; $(touch {w1}); `touch {w2}`",
    "swap_used_gb": f"1.5; $(touch {sw})",
    "snapshot_metadata": {
        "age_seconds": 300,
        "measurement_status": f"partial; $(touch {st})",
        "coverage_pct": 85.5
    },
    "directories": {
        f"projects; $(touch {dr})": 10485760,
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
for s in "$WARN_SENTINEL_1" "$WARN_SENTINEL_2" "$STATUS_SENTINEL" "$SWAP_SENTINEL_1" "$DIR_SENTINEL"; do
  if [[ -e "$s" ]]; then
    echo "FAIL: Command injection detected! Sentinel created: $s" >&2
    exit 1
  fi
done

# Verify partial coverage warning from hostile snapshot 1
if ! grep -qF "snapshot_warning=low_coverage" "$OUT_1"; then
  echo "FAIL: expected snapshot_warning safely parsed in audit output" >&2
  cat "$OUT_1" >&2
  exit 1
fi

# Verify measurement_status safely preserved as literal text (not executed)
EXPECTED_STATUS_STR="Snapshot measurement_status: partial; \$(touch $STATUS_SENTINEL)"
if ! grep -qF "$EXPECTED_STATUS_STR" "$OUT_1"; then
  echo "FAIL: expected literal measurement_status in audit output (got: $(grep -F 'Snapshot measurement_status:' "$OUT_1" || echo 'none'))" >&2
  cat "$OUT_1" >&2
  exit 1
fi

# Case 1b: Dedicated quote breakout test (unbalanced single and double quotes, semicolons)
HOSTILE_SNAP_QUOTES="$TMP_DIR/hostile_snap_quotes.json"
python3 - "$HOSTILE_SNAP_QUOTES" <<'PY'
import json, sys
out = sys.argv[1]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "warn with ' single and \" double quotes",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "age_seconds": 300,
        "measurement_status": "status with ' single and \" double quotes",
        "coverage_pct": 85.5
    },
    "directories": {
        "dir 'with \" quotes": 10485760
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_QUOTES="$TMP_DIR/audit_quotes.log"
RC_QUOTES=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$HOSTILE_SNAP_QUOTES" \
bash "$TARGET_SCRIPT" >"$OUT_QUOTES" 2>&1 || RC_QUOTES=$?

if [[ $RC_QUOTES -ne 0 ]]; then
  echo "FAIL: disk_audit.sh crashed on quote breakout snapshot with code $RC_QUOTES" >&2
  cat "$OUT_QUOTES" >&2
  exit 1
fi

if ! grep -qF "Snapshot measurement_status: status with ' single and \" double quotes" "$OUT_QUOTES"; then
  echo "FAIL: literal quotes in measurement_status not preserved" >&2
  cat "$OUT_QUOTES" >&2
  exit 1
fi

# Case 2: Hostile command injection in snapshot_coverage_pct string
HOSTILE_SNAP_2="$TMP_DIR/hostile_snap_2.json"
python3 - "$HOSTILE_SNAP_2" "$COV_SENTINEL" "$SWAP_SENTINEL_2" <<'PY'
import json, sys
out, cov_s, sw_s = sys.argv[1:4]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": f"85.5; $(touch {cov_s})",
    "snapshot_warning": "none",
    "swap_used_gb": f"1.5; $(touch {sw_s})",
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
for s in "$COV_SENTINEL" "$SWAP_SENTINEL_2"; do
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

# Case 3: Unit validation of python parsing logic for coverage, swap, and age_seconds
python3 - <<'PY'
import math, re

def parse_cov(raw_cov):
    if isinstance(raw_cov, (int, float)) and not isinstance(raw_cov, bool):
        val = float(raw_cov)
        if math.isfinite(val) and 0.0 <= val <= 100.0:
            return str(raw_cov)
    elif isinstance(raw_cov, str) and re.match(r'^-?[0-9]+(\.[0-9]+)?$', raw_cov.strip()):
        val = float(raw_cov.strip())
        if math.isfinite(val) and 0.0 <= val <= 100.0:
            return str(val)
    return ""

def parse_swap(raw_swap):
    if isinstance(raw_swap, (int, float)) and not isinstance(raw_swap, bool):
        val = float(raw_swap)
        if math.isfinite(val) and val >= 0.0:
            return str(raw_swap)
    elif isinstance(raw_swap, str) and re.match(r'^-?[0-9]+(\.[0-9]+)?$', raw_swap.strip()):
        val = float(str(raw_swap).strip())
        if math.isfinite(val) and val >= 0.0:
            return str(val)
    return ""

def parse_age_sec(raw_age_sec):
    if isinstance(raw_age_sec, int) and not isinstance(raw_age_sec, bool) and raw_age_sec >= 0:
        return str(raw_age_sec)
    elif isinstance(raw_age_sec, str) and raw_age_sec.strip().isdigit():
        return raw_age_sec.strip()
    return ""

# Verify coverage rejection
for bad in [float("nan"), float("inf"), float("-inf"), True, False, 150.0, -10.0, "nan", "inf", "True", "85.5; evil"]:
    assert parse_cov(bad) == "", f"Coverage parser failed to reject {bad!r}"

# Verify swap rejection
for bad in [float("nan"), float("inf"), float("-inf"), True, False, -5.0, "nan", "inf", "True", "15.0; evil"]:
    assert parse_swap(bad) == "", f"Swap parser failed to reject {bad!r}"

# Verify age_seconds rejection
for bad in [True, False, 1.5, float("nan"), float("inf"), -10, "True", "abc", "10; evil"]:
    assert parse_age_sec(bad) == "", f"Age_seconds parser failed to reject {bad!r}"

# Verify valid cases pass
assert parse_cov(85.5) == "85.5"
assert parse_cov("90.0") == "90.0"
assert parse_swap(12.5) == "12.5"
assert parse_swap("4.0") == "4.0"
assert parse_age_sec(300) == "300"
assert parse_age_sec("60") == "60"
PY

# Case 3b: End-to-end audit rejection of non-finite/boolean/out-of-bounds coverage
python3 - "$TMP_DIR" <<'PY'
import json, sys
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

# Case 3c: End-to-end verification that non-finite/boolean swap and age_seconds
# are sanitized and do NOT leak into output or trigger false warnings when snapshot is usable
SNAP_BAD_FIELDS="$TMP_DIR/snap_bad_fields.json"
python3 - "$SNAP_BAD_FIELDS" <<'PY'
import json, sys
out = sys.argv[1]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": float("inf"),
    "snapshot_metadata": {
        "age_seconds": True,
        "measurement_status": "complete"
    },
    "directories": {
        "projects": 10485760
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_BAD_FIELDS="$TMP_DIR/audit_bad_fields.log"
RC_BF=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$SNAP_BAD_FIELDS" \
bash "$TARGET_SCRIPT" >"$OUT_BAD_FIELDS" 2>&1 || RC_BF=$?

if [[ $RC_BF -ne 0 ]]; then
  echo "FAIL: disk_audit.sh crashed on bad swap/age fields with code $RC_BF" >&2
  cat "$OUT_BAD_FIELDS" >&2
  exit 1
fi

# Ensure snapshot was usable (coverage was valid)
if ! grep -qF "Coverage: 85.5%" "$OUT_BAD_FIELDS"; then
  echo "FAIL: expected snapshot with valid coverage to be usable" >&2
  cat "$OUT_BAD_FIELDS" >&2
  exit 1
fi

# Ensure invalid float("inf") swap did NOT trigger a false swap warning
if grep -qi "Swap used:" "$OUT_BAD_FIELDS" || grep -qi "inf GiB" "$OUT_BAD_FIELDS"; then
  echo "FAIL: invalid swap float('inf') leaked into output or triggered swap warning" >&2
  cat "$OUT_BAD_FIELDS" >&2
  exit 1
fi

# Ensure boolean age_seconds did NOT leak into output as True
if grep -qi "Age: True" "$OUT_BAD_FIELDS" || grep -qi "True min" "$OUT_BAD_FIELDS"; then
  echo "FAIL: boolean age_seconds leaked into output" >&2
  cat "$OUT_BAD_FIELDS" >&2
  exit 1
fi

# Verify that valid swap exceeding 10 GiB DOES trigger the swap warning
SNAP_VALID_SWAP="$TMP_DIR/snap_valid_swap.json"
python3 - "$SNAP_VALID_SWAP" <<'PY'
import json, sys
out = sys.argv[1]
snap = {
    "timestamp": "2026-10-04T00:00:00Z",
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 15.0,
    "snapshot_metadata": {
        "age_seconds": 300,
        "measurement_status": "complete"
    },
    "directories": {
        "projects": 10485760
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_VALID_SWAP="$TMP_DIR/audit_valid_swap.log"
RC_VS=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$SNAP_VALID_SWAP" \
bash "$TARGET_SCRIPT" >"$OUT_VALID_SWAP" 2>&1 || RC_VS=$?

if [[ $RC_VS -ne 0 ]]; then
  echo "FAIL: disk_audit.sh crashed on valid swap snapshot with code $RC_VS" >&2
  cat "$OUT_VALID_SWAP" >&2
  exit 1
fi

if ! grep -qF "Swap used: 15.0 GiB (>10 GiB)" "$OUT_VALID_SWAP"; then
  echo "FAIL: valid swap (15.0 GiB) did not trigger expected warning" >&2
  cat "$OUT_VALID_SWAP" >&2
  exit 1
fi

echo "PASS: hostile snapshot injection vectors and non-finite bypasses safely neutralized"
exit 0

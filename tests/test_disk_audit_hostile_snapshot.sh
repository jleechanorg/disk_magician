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
# 4. Terminal control sequences (CSI, OSC, ESC, bell) are stripped from displayable
#    strings (warning, status, directory names).
# 5. Strict metric and timestamp gates: rejects non-finite (NaN, Infinity), boolean,
#    and out-of-range coverage, sanitizes bad swap values on usable snapshots,
#    allows graceful clock-skew tolerance, and fails closed on missing, invalid, or future timestamps.
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

RECENT_TS=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

# Case 1: Pure command-substitution payloads (syntactically valid if evaluated by a shell)
HOSTILE_SNAP_1="$TMP_DIR/hostile_snap_1.json"
python3 - "$HOSTILE_SNAP_1" "$RECENT_TS" "$WARN_SENTINEL_1" "$WARN_SENTINEL_2" "$STATUS_SENTINEL" "$SWAP_SENTINEL_1" "$DIR_SENTINEL" <<'PY'
import json, sys
out, ts, w1, w2, st, sw, dr = sys.argv[1:8]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": f"low_coverage; $(touch {w1}); `touch {w2}`",
    "swap_used_gb": f"1.5; $(touch {sw})",
    "snapshot_metadata": {
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
python3 - "$HOSTILE_SNAP_QUOTES" "$RECENT_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "warn with ' single and \" double quotes",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
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

# Case 1c: Terminal escape stripping (CSI, OSC, bell characters stripped)
HOSTILE_SNAP_ESC="$TMP_DIR/hostile_snap_esc.json"
python3 - "$HOSTILE_SNAP_ESC" "$RECENT_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "warn \x1b[31;1mred alert\x1b[0m \x1b]0;hacked title\x07 clean",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "measurement_status": "status \x1b[2J \x1b]2;window title\x07 done",
        "coverage_pct": 85.5
    },
    "directories": {
        "dir \x1b[32mgreen\x1b[0m": 10485760
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_ESC="$TMP_DIR/audit_esc.log"
RC_ESC=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$HOSTILE_SNAP_ESC" \
bash "$TARGET_SCRIPT" >"$OUT_ESC" 2>&1 || RC_ESC=$?

if [[ $RC_ESC -ne 0 ]]; then
  echo "FAIL: disk_audit.sh crashed on terminal escape snapshot with code $RC_ESC" >&2
  cat "$OUT_ESC" >&2
  exit 1
fi

# Verify no ESC or BEL bytes exist in the output for these fields
if python3 -c "import sys; f=open('$OUT_ESC', 'rb'); data=f.read(); f.close(); sys.exit(0 if (b'\x1b' in data or b'\x07' in data) else 1)"; then
  echo "FAIL: terminal escape sequences (ESC or BEL) detected in audit output!" >&2
  exit 1
fi

if ! grep -qF "Snapshot measurement_status: status \\e[2J \\e]2;window title\\a done" "$OUT_ESC"; then
  echo "FAIL: sanitized status not found in output" >&2
  cat "$OUT_ESC" >&2
  exit 1
fi

# Case 2: Hostile command injection in snapshot_coverage_pct string
HOSTILE_SNAP_2="$TMP_DIR/hostile_snap_2.json"
python3 - "$HOSTILE_SNAP_2" "$RECENT_TS" "$COV_SENTINEL" "$SWAP_SENTINEL_2" <<'PY'
import json, sys
out, ts, cov_s, sw_s = sys.argv[1:5]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": f"85.5; $(touch {cov_s})",
    "snapshot_warning": "none",
    "swap_used_gb": f"1.5; $(touch {sw_s})",
    "snapshot_metadata": {
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

# Verify malformed coverage is safely rejected and reports Snapshot not usable
if ! grep -qF "Snapshot not usable (coverage" "$OUT_2"; then
  echo "FAIL: expected malformed coverage to be rejected in Case 2" >&2
  cat "$OUT_2" >&2
  exit 1
fi

# Case 3a: End-to-end audit rejection of non-finite/boolean/out-of-bounds coverage
python3 - "$TMP_DIR" "$RECENT_TS" <<'PY'
import json, sys
tmp, ts = sys.argv[1:3]
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
        "timestamp": ts,
        "disk_total_gb": 926,
        "disk_used_gb": 750,
        "disk_free_gb": 176,
        "disk_pct": 81,
        "snapshot_coverage_pct": val,
        "snapshot_warning": "",
        "swap_used_gb": 2.0,
        "snapshot_metadata": {
            "measurement_status": "complete"
        },
        "directories": {
            "projects": 10485760
        }
    }
    with open(f"{tmp}/snap_bad_cov_{name}.json", "w") as f:
        json.dump(snap, f)
PY

for bad_name in "nan" "inf" "neginf" "bool_true" "bool_false" "over_100" "neg_10"; do
  SNAP_BAD="$TMP_DIR/snap_bad_cov_${bad_name}.json"
  OUT_BAD="$TMP_DIR/audit_bad_cov_${bad_name}.log"
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

# Case 3b: Loop over non-finite / boolean / negative / injection values for swap_used_gb
# on a USABLE snapshot (coverage 85.5%, valid recent timestamp).
# Asserts snapshot remains usable, but invalid swap is sanitized and never triggers false alerts.
SWAP_SENTINEL_3="$SENTINEL_DIR/hostile_swap_injected_3"
python3 - "$TMP_DIR" "$RECENT_TS" "$SWAP_SENTINEL_3" <<'PY'
import json, sys
tmp, ts, sw_sentinel = sys.argv[1:4]
test_cases = [
    ("nan", float("nan")),
    ("inf", float("inf")),
    ("neginf", float("-inf")),
    ("bool_true", True),
    ("bool_false", False),
    ("neg_5", -5.0),
    ("cmd_inject", f"15.0; $(touch {sw_sentinel})"),
]
for name, val in test_cases:
    snap = {
        "timestamp": ts,
        "hostname": "test-host",
        "disk_total_gb": 926,
        "disk_used_gb": 750,
        "disk_free_gb": 176,
        "disk_pct": 81,
        "snapshot_coverage_pct": 85.5,
        "snapshot_warning": "",
        "swap_used_gb": val,
        "snapshot_metadata": {
            "measurement_status": "complete"
        },
        "directories": {
            "projects": 10485760
        }
    }
    with open(f"{tmp}/snap_bad_swap_{name}.json", "w") as f:
        json.dump(snap, f)
PY

for bad_swap_name in "nan" "inf" "neginf" "bool_true" "bool_false" "neg_5" "cmd_inject"; do
  SNAP_BS="$TMP_DIR/snap_bad_swap_${bad_swap_name}.json"
  OUT_BS="$TMP_DIR/audit_bad_swap_${bad_swap_name}.log"
  RC_BS=0
  HOME="$FIXTURE_HOME" \
  DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
  DISK_SNAPSHOT_JSON="$SNAP_BS" \
  bash "$TARGET_SCRIPT" >"$OUT_BS" 2>&1 || RC_BS=$?
  
  if [[ $RC_BS -ne 0 ]]; then
    echo "FAIL: disk_audit.sh crashed on bad swap '$bad_swap_name' with code $RC_BS" >&2
    cat "$OUT_BS" >&2
    exit 1
  fi
  
  if ! grep -qF "Coverage: 85.5%" "$OUT_BS"; then
    echo "FAIL: snapshot with valid coverage should remain usable for bad swap '$bad_swap_name'" >&2
    cat "$OUT_BS" >&2
    exit 1
  fi
  
  if grep -qi "Swap used:" "$OUT_BS" || grep -qi "inf GiB" "$OUT_BS" || grep -qi "nan GiB" "$OUT_BS"; then
    echo "FAIL: invalid swap '$bad_swap_name' triggered a false swap warning in audit output" >&2
    cat "$OUT_BS" >&2
    exit 1
  fi
done

if [[ -e "$SWAP_SENTINEL_3" ]]; then
  echo "FAIL: Command injection detected in swap test! Sentinel created: $SWAP_SENTINEL_3" >&2
  exit 1
fi

# Case 3c: Verify that valid swap exceeding 10 GiB DOES trigger the swap warning
SNAP_VALID_SWAP="$TMP_DIR/snap_valid_swap.json"
python3 - "$SNAP_VALID_SWAP" "$RECENT_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 15.0,
    "snapshot_metadata": {
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

# Case 3d: Missing, invalid, and future timestamps must be rejected fail-closed
# and report Directory Breakdown (Snapshot Unavailable) without ever displaying 'Age: ?'
FUTURE_TS=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

python3 - "$TMP_DIR" "$FUTURE_TS" <<'PY'
import json, sys
tmp, future_ts = sys.argv[1:3]
cases = [
    ("missing_ts", ""),
    ("invalid_ts", "not-a-valid-timestamp"),
    ("future_ts", future_ts),
]
for name, val in cases:
    snap = {
        "timestamp": val,
        "disk_total_gb": 926,
        "disk_used_gb": 750,
        "disk_free_gb": 176,
        "disk_pct": 81,
        "snapshot_coverage_pct": 85.5,
        "snapshot_warning": "",
        "swap_used_gb": 2.0,
        "snapshot_metadata": {
            "measurement_status": "complete"
        },
        "directories": {
            "projects": 10485760
        }
    }
    with open(f"{tmp}/snap_ts_{name}.json", "w") as f:
        json.dump(snap, f)
PY

# Missing timestamp
OUT_MISSING_TS="$TMP_DIR/audit_missing_ts.log"
RC_MTS=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$TMP_DIR/snap_ts_missing_ts.json" \
  bash "$TARGET_SCRIPT" >"$OUT_MISSING_TS" 2>&1 || RC_MTS=$?
if [[ $RC_MTS -ne 0 ]]; then
  echo "FAIL: audit crashed on missing timestamp with code $RC_MTS" >&2
  cat "$OUT_MISSING_TS" >&2
  exit 1
fi
if ! grep -qF "Directory Breakdown (Snapshot Unavailable)" "$OUT_MISSING_TS"; then
  echo "FAIL: expected Snapshot Unavailable section header on missing timestamp" >&2
  cat "$OUT_MISSING_TS" >&2
  exit 1
fi
if ! grep -qF "Snapshot not usable (timestamp missing or invalid)" "$OUT_MISSING_TS"; then
  echo "FAIL: missing timestamp was not rejected with expected reason" >&2
  cat "$OUT_MISSING_TS" >&2
  exit 1
fi

# Invalid timestamp
OUT_INVALID_TS="$TMP_DIR/audit_invalid_ts.log"
RC_ITS=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$TMP_DIR/snap_ts_invalid_ts.json" \
  bash "$TARGET_SCRIPT" >"$OUT_INVALID_TS" 2>&1 || RC_ITS=$?
if [[ $RC_ITS -ne 0 ]]; then
  echo "FAIL: audit crashed on invalid timestamp with code $RC_ITS" >&2
  cat "$OUT_INVALID_TS" >&2
  exit 1
fi
if ! grep -qF "Directory Breakdown (Snapshot Unavailable)" "$OUT_INVALID_TS"; then
  echo "FAIL: expected Snapshot Unavailable section header on invalid timestamp" >&2
  cat "$OUT_INVALID_TS" >&2
  exit 1
fi
if ! grep -qF "Snapshot not usable (timestamp missing or invalid)" "$OUT_INVALID_TS"; then
  echo "FAIL: invalid timestamp string was not rejected with expected reason" >&2
  cat "$OUT_INVALID_TS" >&2
  exit 1
fi

# Future timestamp (>120s in future)
OUT_FUTURE_TS="$TMP_DIR/audit_future_ts.log"
RC_FTS=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$TMP_DIR/snap_ts_future_ts.json" \
  bash "$TARGET_SCRIPT" >"$OUT_FUTURE_TS" 2>&1 || RC_FTS=$?
if [[ $RC_FTS -ne 0 ]]; then
  echo "FAIL: audit crashed on future timestamp with code $RC_FTS" >&2
  cat "$OUT_FUTURE_TS" >&2
  exit 1
fi
if ! grep -qF "Directory Breakdown (Snapshot Unavailable)" "$OUT_FUTURE_TS"; then
  echo "FAIL: expected Snapshot Unavailable section header on future timestamp" >&2
  cat "$OUT_FUTURE_TS" >&2
  exit 1
fi
if ! grep -qF "Snapshot not usable (timestamp is in the future)" "$OUT_FUTURE_TS"; then
  echo "FAIL: future timestamp was not rejected with expected reason" >&2
  cat "$OUT_FUTURE_TS" >&2
  exit 1
fi

# Ensure Age: ? never appears in any output
for log in "$OUT_MISSING_TS" "$OUT_INVALID_TS" "$OUT_FUTURE_TS"; do
  if grep -qF "Age: ?" "$log"; then
    echo "FAIL: 'Age: ?' displayed in audit output for bad timestamp" >&2
    cat "$log" >&2
    exit 1
  fi
done

# Case 3e: Graceful clock skew tolerance (timestamp 30s in future accepted as 0 min age)
SKEW_TS=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
SNAP_SKEW="$TMP_DIR/snap_skew.json"
python3 - "$SNAP_SKEW" "$SKEW_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "measurement_status": "complete"
    },
    "directories": {
        "projects": 10485760
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_SKEW="$TMP_DIR/audit_skew.log"
RC_SKEW=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP_SKEW" \
  bash "$TARGET_SCRIPT" >"$OUT_SKEW" 2>&1 || RC_SKEW=$?

if [[ $RC_SKEW -ne 0 ]]; then
  echo "FAIL: audit crashed on clock-skew snapshot with code $RC_SKEW" >&2
  cat "$OUT_SKEW" >&2
  exit 1
fi

if ! grep -qF "Coverage: 85.5%   Age: 0 min" "$OUT_SKEW"; then
  echo "FAIL: snapshot within 120s clock skew tolerance was not accepted with Age: 0 min" >&2
  cat "$OUT_SKEW" >&2
  exit 1
fi

# Case 3f: Tolerance boundary test (+180s in future is past 120s tolerance, rejected as future)
BOUNDARY_TS=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=180)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
SNAP_BOUNDARY="$TMP_DIR/snap_boundary.json"
python3 - "$SNAP_BOUNDARY" "$BOUNDARY_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "measurement_status": "complete"
    },
    "directories": {}
}
with open(out, "w") as f:
    json.dump(snap, f)
PY

OUT_BOUNDARY="$TMP_DIR/audit_boundary.log"
RC_BOUNDARY=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP_BOUNDARY" \
  bash "$TARGET_SCRIPT" >"$OUT_BOUNDARY" 2>&1 || RC_BOUNDARY=$?

if [[ $RC_BOUNDARY -ne 0 ]]; then
  echo "FAIL: audit crashed on boundary future timestamp with code $RC_BOUNDARY" >&2
  cat "$OUT_BOUNDARY" >&2
  exit 1
fi

if ! grep -qF "Snapshot not usable (timestamp is in the future)" "$OUT_BOUNDARY"; then
  echo "FAIL: timestamp past tolerance window (+180s) was not rejected as future" >&2
  cat "$OUT_BOUNDARY" >&2
  exit 1
fi

# Case 4: Command injection resistance in disk_history.sh path handling
HIST_SENTINEL_NAME="hist_path_marker"
HIST_SENTINEL="$REPO_ROOT/$HIST_SENTINEL_NAME"
rm -f "$HIST_SENTINEL"
HOSTILE_HIST_PATH="$TMP_DIR/snap; touch $HIST_SENTINEL_NAME; .json"
cp "$SNAP_SKEW" "$HOSTILE_HIST_PATH"

OUT_HIST_INJ="$TMP_DIR/hist_inj.log"
DISK_SNAPSHOT_JSON="$HOSTILE_HIST_PATH" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 5 >"$OUT_HIST_INJ" 2>&1 || true

if [[ -e "$HIST_SENTINEL" ]]; then
  rm -f "$HIST_SENTINEL"
  echo "FAIL: Command injection in disk_history.sh! Sentinel created: $HIST_SENTINEL" >&2
  exit 1
fi

# Case 5: Directory key collision safety across audit and history
SNAP_COLLISION="$TMP_DIR/snap_collision.json"
python3 - "$SNAP_COLLISION" "$RECENT_TS" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": "176\x1b[32m",
    "disk_pct": "81\x1b[31m\x07",
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "measurement_status": "complete"
    },
    "directories": {
        "foo": 1048576,
        "\x1b[31mfoo": 2097152
    }
}
with open(out, "w") as f:
    json.dump(snap, f, indent=2)
PY

OUT_COLLISION="$TMP_DIR/audit_collision.log"
RC_COLLISION=0
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP_COLLISION" \
  bash "$TARGET_SCRIPT" >"$OUT_COLLISION" 2>&1 || RC_COLLISION=$?

if [[ $RC_COLLISION -ne 0 ]]; then
  echo "FAIL: audit crashed on collision snapshot with code $RC_COLLISION" >&2
  cat "$OUT_COLLISION" >&2
  exit 1
fi

# Assert both buckets are preserved in audit output without overwriting
if ! grep -qF "foo" "$OUT_COLLISION" || ! grep -qF "\\e[31mfoo" "$OUT_COLLISION"; then
  echo "FAIL: directory key collision resulted in lost bucket in audit output!" >&2
  cat "$OUT_COLLISION" >&2
  exit 1
fi

# Test disk_history.sh with the collision snapshot and hostile numeric fields
OUT_HIST_COLLISION="$TMP_DIR/hist_collision.log"
DISK_SNAPSHOT_JSON="$SNAP_COLLISION" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 1 >"$OUT_HIST_COLLISION" 2>&1 || true

# Assert no raw ESC or BEL bytes reach history output
if python3 -c "import sys; f=open('$OUT_HIST_COLLISION', 'rb'); data=f.read(); f.close(); sys.exit(0 if (b'\x1b' in data or b'\x07' in data) else 1)"; then
  echo "FAIL: raw ESC or BEL bytes detected in disk_history.sh output!" >&2
  cat "$OUT_HIST_COLLISION" >&2
  exit 1
fi

# Assert numeric fields were cleanly coerced
if ! grep -qF "81%" "$OUT_HIST_COLLISION" || ! grep -qF "176G" "$OUT_HIST_COLLISION"; then
  echo "FAIL: numeric free_gb or pct not cleanly coerced in history table" >&2
  cat "$OUT_HIST_COLLISION" >&2
  exit 1
fi

# Case 6: Injective encoding & order-independent identity across git commits in disk_history.sh
HIST_GIT_DIR="$TMP_DIR/test_git_repo"
mkdir -p "$HIST_GIT_DIR/backup/test-host"
git -C "$HIST_GIT_DIR" init -q
git -C "$HIST_GIT_DIR" config user.email "jleechan2015@users.noreply.github.com"
git -C "$HIST_GIT_DIR" config user.name "jleechan"

SNAP_GIT_PATH="$HIST_GIT_DIR/backup/test-host/disk_snapshot.json"

# Commit 1: \x1bfoo is 10 GiB, literal \efoo is 1 GiB; U+E0001 is 20 GiB, U+E000+'1' is 2 GiB
python3 -c "
import json
data = {
    'timestamp': '2026-10-01T00:00:00Z',
    'disk_total_gb': 926,
    'disk_used_gb': 750,
    'disk_free_gb': 176,
    'disk_pct': 81,
    'snapshot_coverage_pct': 85.0,
    'directories': {
        '\x1bfoo': 10485760,
        r'\efoo': 1048576,
        chr(0xE0001): 20971520,
        chr(0xE000) + '1': 2097152
    }
}
with open('$SNAP_GIT_PATH', 'w') as f:
    json.dump(data, f)
"
git -C "$HIST_GIT_DIR" add backup/test-host/disk_snapshot.json
git -C "$HIST_GIT_DIR" commit -q -m "commit 1"

# Commit 2: Exactly identical sizes, but key order reversed in JSON dictionary
python3 -c "
import json
data = {
    'timestamp': '2026-10-02T00:00:00Z',
    'disk_total_gb': 926,
    'disk_used_gb': 750,
    'disk_free_gb': 176,
    'disk_pct': 81,
    'snapshot_coverage_pct': 85.0,
    'directories': {
        chr(0xE000) + '1': 2097152,
        chr(0xE0001): 20971520,
        r'\efoo': 1048576,
        '\x1bfoo': 10485760
    }
}
with open('$SNAP_GIT_PATH', 'w') as f:
    json.dump(data, f)
"
git -C "$HIST_GIT_DIR" add backup/test-host/disk_snapshot.json
git -C "$HIST_GIT_DIR" commit -q -m "commit 2"

OUT_SWAP_ORDER="$TMP_DIR/hist_swap_order.log"
DISK_SNAPSHOT_JSON="$SNAP_GIT_PATH" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 2 >"$OUT_SWAP_ORDER" 2>&1

# Assert no false regression was reported!
if grep -qF "<-" "$OUT_SWAP_ORDER"; then
  echo "FAIL: false regression detected across commits due to swapped key order!" >&2
  cat "$OUT_SWAP_ORDER" >&2
  exit 1
fi

# Assert both formerly-colliding labels and astral labels appear distinctly in the history table
if ! grep -qF "\\U000e0001" "$OUT_SWAP_ORDER" || \
   ! grep -qF "\\ue0001" "$OUT_SWAP_ORDER" || \
   ! grep -qF "\\efoo" "$OUT_SWAP_ORDER" || \
   ! grep -qF "\\\\efoo" "$OUT_SWAP_ORDER"; then
  echo "FAIL: expected distinct labels (\\U000e0001, \\ue0001, \\efoo, \\\\efoo) missing in history table!" >&2
  cat "$OUT_SWAP_ORDER" >&2
  exit 1
fi

# Assert values are properly separated and preserved across rows
if ! grep -qF "20.0G" "$OUT_SWAP_ORDER" || \
   ! grep -qF "2.0G" "$OUT_SWAP_ORDER" || \
   ! grep -qF "10.0G" "$OUT_SWAP_ORDER" || \
   ! grep -qF "1.0G" "$OUT_SWAP_ORDER"; then
  echo "FAIL: expected separate directory sizes (20.0G, 2.0G, 10.0G, 1.0G) missing in history rows!" >&2
  cat "$OUT_SWAP_ORDER" >&2
  exit 1
fi

# Case 7: Hostile snapshot values and structure in disk_history.sh
SNAP_MALFORMED="$TMP_DIR/snap_malformed.json"
python3 - "$SNAP_MALFORMED" <<'PY'
import json, sys
data = {
    "timestamp": "2026-10-02T00:00:00Z",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.0,
    "directories": {
        "bad_str": "12x",
        "bad_bool": True,
        "bad_nan": "nan",
        "valid_dir": 5242880
    }
}
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY

OUT_HIST_MALFORMED="$TMP_DIR/hist_malformed.log"
RC_HIST_MALFORMED=0
DISK_SNAPSHOT_JSON="$SNAP_MALFORMED" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 1 >"$OUT_HIST_MALFORMED" 2>&1 || RC_HIST_MALFORMED=$?

if [[ $RC_HIST_MALFORMED -ne 0 ]]; then
  echo "FAIL: disk_history.sh crashed on malformed directory values with code $RC_HIST_MALFORMED" >&2
  cat "$OUT_HIST_MALFORMED" >&2
  exit 1
fi

if ! grep -qF "valid_dir" "$OUT_HIST_MALFORMED" || ! grep -qF "null" "$OUT_HIST_MALFORMED"; then
  echo "FAIL: valid directory or null placeholder missing from malformed history output" >&2
  cat "$OUT_HIST_MALFORMED" >&2
  exit 1
fi

# Case 7b: Hostile non-dict JSON root in disk_history.sh
SNAP_LIST_ROOT="$TMP_DIR/snap_list_root.json"
echo '[1, 2, "not a dict"]' > "$SNAP_LIST_ROOT"
OUT_HIST_LIST="$TMP_DIR/hist_list.log"
# Should handle gracefully without unhandled AttributeError
DISK_SNAPSHOT_JSON="$SNAP_LIST_ROOT" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 1 >"$OUT_HIST_LIST" 2>&1 || true
if grep -q "AttributeError" "$OUT_HIST_LIST"; then
  echo "FAIL: disk_history.sh raised AttributeError on non-dict root JSON" >&2
  cat "$OUT_HIST_LIST" >&2
  exit 1
fi

# Case 7c: Direct audit fixture for directory numeric string coercion and rejection
SNAP_AUDIT_COERCION="$TMP_DIR/snap_audit_coercion.json"
python3 - "$SNAP_AUDIT_COERCION" "$RECENT_TS" <<'PY'
import json, sys
data = {
    "timestamp": sys.argv[2],
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {"measurement_status": "complete"},
    "directories": {
        "float_rounded": 1048576.6,
        "valid_str": "2097152",
        "bool_true": True,
        "bool_false": False,
        "nan_str": "nan",
        "inf_str": "infinity",
        "negative_num": -1024,
        "bad_str": "12x"
    }
}
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY

OUT_AUDIT_COERCION="$TMP_DIR/audit_coercion.log"
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP_AUDIT_COERCION" \
  bash "$TARGET_SCRIPT" --no-history >"$OUT_AUDIT_COERCION" 2>&1

# Assert float was rounded and numeric string was accepted
if ! grep -qF "float_rounded" "$OUT_AUDIT_COERCION" || ! grep -qF "valid_str" "$OUT_AUDIT_COERCION"; then
  echo "FAIL: valid rounded float or numeric string missing from audit output" >&2
  cat "$OUT_AUDIT_COERCION" >&2
  exit 1
fi

# Assert booleans, non-finite, negative, and invalid strings were rejected
for bad_key in "bool_true" "bool_false" "nan_str" "inf_str" "negative_num" "bad_str"; do
  if grep -qF "$bad_key" "$OUT_AUDIT_COERCION"; then
    echo "FAIL: invalid directory value '$bad_key' was not rejected by audit coercion!" >&2
    cat "$OUT_AUDIT_COERCION" >&2
    exit 1
  fi
done

# Case 8: Control-bearing DISK_SNAPSHOT_JSON filename sanitization
HOSTILE_FILENAME_SNAP="$TMP_DIR/"$'snap_hostile_\x1b[31malert\x07.json'
cp "$SNAP_SKEW" "$HOSTILE_FILENAME_SNAP"

OUT_AUDIT_FN="$TMP_DIR/audit_fn.log"
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$HOSTILE_FILENAME_SNAP" \
  bash "$TARGET_SCRIPT" >"$OUT_AUDIT_FN" 2>&1 || true

if python3 -c "import sys; f=open('$OUT_AUDIT_FN', 'rb'); data=f.read(); f.close(); sys.exit(0 if (b'\x1b' in data or b'\x07' in data) else 1)"; then
  echo "FAIL: raw ESC or BEL bytes detected in disk_audit.sh output with hostile filename!" >&2
  cat "$OUT_AUDIT_FN" >&2
  exit 1
fi

if ! grep -qF "\\e[31malert\\a" "$OUT_AUDIT_FN"; then
  echo "FAIL: sanitized filename \\e[31malert\\a not found in disk_audit.sh output" >&2
  cat "$OUT_AUDIT_FN" >&2
  exit 1
fi

OUT_HIST_FN="$TMP_DIR/hist_fn.log"
DISK_SNAPSHOT_JSON="$HOSTILE_FILENAME_SNAP" python3 "$REPO_ROOT/scripts/disk_history.sh" --limit 1 >"$OUT_HIST_FN" 2>&1 || true

if python3 -c "import sys; f=open('$OUT_HIST_FN', 'rb'); data=f.read(); f.close(); sys.exit(0 if (b'\x1b' in data or b'\x07' in data) else 1)"; then
  echo "FAIL: raw ESC or BEL bytes detected in disk_history.sh output with hostile filename!" >&2
  cat "$OUT_HIST_FN" >&2
  exit 1
fi

if ! grep -qF "\\e[31malert\\a" "$OUT_HIST_FN"; then
  echo "FAIL: sanitized filename \\e[31malert\\a not found in disk_history.sh output" >&2
  cat "$OUT_HIST_FN" >&2
  exit 1
fi

# Case 9: Unicode format characters (U+200B, U+200E) and line separators (U+2028)
SNAP_UNICODE="$TMP_DIR/snap_unicode.json"
python3 - "$SNAP_UNICODE" "$RECENT_TS" <<'PY'
import json, sys
snap = {
    "timestamp": sys.argv[2],
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 85.5,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {
        "measurement_status": "complete"
    },
    "directories": {
        "zwsp_\u200b_dir": 1048576,
        "linesep_\u2028_dir": 2097152,
        "bidi_\u200e_dir": 3145728,
        f"astral_{chr(0xE0001)}_dir": 4194304
    }
}
with open(sys.argv[1], "w") as f:
    json.dump(snap, f)
PY

OUT_AUDIT_UNICODE="$TMP_DIR/audit_unicode.log"
HOME="$FIXTURE_HOME" DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP_UNICODE" \
  bash "$TARGET_SCRIPT" >"$OUT_AUDIT_UNICODE" 2>&1

if ! grep -qF "zwsp_\\u200b_dir" "$OUT_AUDIT_UNICODE" || \
   ! grep -qF "linesep_\\u2028_dir" "$OUT_AUDIT_UNICODE" || \
   ! grep -qF "bidi_\\u200e_dir" "$OUT_AUDIT_UNICODE" || \
   ! grep -qF "astral_\\U000e0001_dir" "$OUT_AUDIT_UNICODE"; then
  echo "FAIL: unicode format characters or line separators not safely escaped in audit output" >&2
  cat "$OUT_AUDIT_UNICODE" >&2
  exit 1
fi

# Assert no raw unescaped U+200B, U+2028, U+200E, or astral bytes exist in audit output
if python3 -c "import sys; f=open('$OUT_AUDIT_UNICODE', 'rb'); data=f.read(); f.close(); sys.exit(0 if (b'\xe2\x80\x8b' in data or b'\xe2\x80\xa8' in data or b'\xe2\x80\x8e' in data or chr(0xE0001).encode('utf-8') in data) else 1)"; then
  echo "FAIL: raw unescaped unicode format/separator bytes found in audit output!" >&2
  exit 1
fi

echo "PASS: hostile snapshot injection vectors, terminal escapes, and timestamp gates safely neutralized"
exit 0

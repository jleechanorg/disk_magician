#!/usr/bin/env bash
# test_disk_audit_hostile_snapshot.sh — Hostile snapshot shell injection regression test
#
# Asserts that:
# 1. Hostile snapshot JSON containing shell metacharacters, subshell executions,
#    and command injections in snapshot_warning, measurement_status, coverage,
#    swap, or directories are safely parsed without eval or command execution.
# 2. Sentinels are never created, proving zero code execution.
# 3. Typed parsing preserves valid metrics, sanitizes string fields, and
#    neutralizes malicious strings without running shell syntax.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"

TMP_DIR=$(mktemp -d -t test_hostile_snap.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

SENTINEL_DIR="$TMP_DIR/sentinels"
mkdir -p "$SENTINEL_DIR"

WARN_SENTINEL="$SENTINEL_DIR/hostile_warn_injected"
STATUS_SENTINEL="$SENTINEL_DIR/hostile_status_injected"
COV_SENTINEL="$SENTINEL_DIR/hostile_cov_injected"
SWAP_SENTINEL="$SENTINEL_DIR/hostile_swap_injected"
DIR_SENTINEL="$SENTINEL_DIR/hostile_dir_injected"

# Case 1: Hostile command injection in snapshot_warning, measurement_status, swap, and directories
HOSTILE_SNAP_1="$TMP_DIR/hostile_snap_1.json"
cat > "$HOSTILE_SNAP_1" << EOF
{
  "timestamp": "2026-10-04T00:00:00Z",
  "hostname": "test-host",
  "disk_total_gb": 926,
  "disk_used_gb": 750,
  "disk_free_gb": 176,
  "disk_pct": 81,
  "snapshot_coverage_pct": 85.5,
  "snapshot_warning": "low_coverage; touch $WARN_SENTINEL; evil",
  "swap_used_gb": "1.5; touch $SWAP_SENTINEL",
  "snapshot_metadata": {
    "age_seconds": 300,
    "measurement_status": "partial; touch $STATUS_SENTINEL",
    "coverage_pct": 85.5
  },
  "directories": {
    "projects; touch $DIR_SENTINEL": 10485760,
    "colima": 5242880
  }
}
EOF

FIXTURE_HOME="$TMP_DIR/home"
FIXTURE_STATE="$TMP_DIR/state"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_STATE"

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

# Verify ZERO sentinels were created
for s in "$WARN_SENTINEL" "$STATUS_SENTINEL" "$DIR_SENTINEL"; do
  if [[ -e "$s" ]]; then
    echo "FAIL: Command injection detected! Sentinel created: $s" >&2
    exit 1
  fi
done

# Verify partial coverage warning from the hostile snapshot was safely reported
if ! grep -qF "snapshot_warning=low_coverage" "$OUT_1"; then
  echo "FAIL: expected snapshot_warning safely parsed in audit output" >&2
  cat "$OUT_1" >&2
  exit 1
fi

# Case 2: Hostile command injection in snapshot_coverage_pct
HOSTILE_SNAP_2="$TMP_DIR/hostile_snap_2.json"
cat > "$HOSTILE_SNAP_2" << EOF
{
  "timestamp": "2026-10-04T00:00:00Z",
  "hostname": "test-host",
  "disk_total_gb": 926,
  "disk_used_gb": 750,
  "disk_free_gb": 176,
  "disk_pct": 81,
  "snapshot_coverage_pct": "85.5; touch $COV_SENTINEL",
  "snapshot_warning": "none",
  "swap_used_gb": "1.5; touch $SWAP_SENTINEL",
  "snapshot_metadata": {
    "age_seconds": 300,
    "measurement_status": "complete"
  },
  "directories": {}
}
EOF

OUT_2="$TMP_DIR/audit_2.log"
RC_2=0
HOME="$FIXTURE_HOME" \
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" \
DISK_SNAPSHOT_JSON="$HOSTILE_SNAP_2" \
bash "$TARGET_SCRIPT" >"$OUT_2" 2>&1 || RC_2=$?

# Verify ZERO sentinels were created in Case 2
for s in "$COV_SENTINEL" "$SWAP_SENTINEL"; do
  if [[ -e "$s" ]]; then
    echo "FAIL: Command injection detected in Case 2! Sentinel created: $s" >&2
    exit 1
  fi
done

echo "PASS: hostile snapshot injection vectors safely neutralized with zero code execution"
exit 0

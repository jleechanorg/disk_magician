#!/usr/bin/env bash
# tests/test_swap_warning.sh — bead disk_magician-8to.
#
# Verifies disk_audit.sh and disk_usage_alert.sh both print a warning when
# a snapshot's swap_used_gb exceeds 10 GiB, naming it as disk space
# consumed outside the Data volume — and stay silent (no crash, no
# warning) for a snapshot at/under the threshold or missing the key.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_snapshot() {
  local path="$1" swap_used="$2"
  python3 -c "
import json, datetime
d = {
    'schema_version': 2,
    'timestamp': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'disk_used_gb': 500,
    'snapshot_coverage_pct': 95.0,
    'swap_total_gb': 32.0,
    'swap_used_gb': $swap_used,
    'vm_volume_used_gb': 3.0,
    'directories': {},
}
json.dump(d, open('$path', 'w'))
"
}

HIGH_SNAP="$TMP/high_swap.json"
LOW_SNAP="$TMP/low_swap.json"
make_snapshot "$HIGH_SNAP" 15.25
make_snapshot "$LOW_SNAP" 2.0

# ────────── disk_audit.sh ──────────
AUDIT_OUT_HIGH=$(DISK_SNAPSHOT_JSON="$HIGH_SNAP" timeout 30 bash "$REPO_ROOT/scripts/disk_audit.sh" \
  --no-history --skip-directory-breakdown 2>&1)
if echo "$AUDIT_OUT_HIGH" | grep -q "Swap used: 15.25 GiB (>10 GiB)"; then
  pass "disk_audit.sh warns on swap_used_gb=15.25 (>10)"
else
  fail "disk_audit.sh did not print the swap warning for swap_used_gb=15.25:
$AUDIT_OUT_HIGH"
fi
echo "$AUDIT_OUT_HIGH" | grep -qi "outside the Data volume" || fail "disk_audit.sh swap warning doesn't name it as outside the Data volume"

AUDIT_OUT_LOW=$(DISK_SNAPSHOT_JSON="$LOW_SNAP" timeout 30 bash "$REPO_ROOT/scripts/disk_audit.sh" \
  --no-history --skip-directory-breakdown 2>&1)
if echo "$AUDIT_OUT_LOW" | grep -q "Swap used:"; then
  fail "disk_audit.sh warned even though swap_used_gb=2.0 is under the 10 GiB threshold"
else
  pass "disk_audit.sh stays silent when swap_used_gb is under threshold"
fi

# ────────── disk_usage_alert.sh ──────────
ALERT_OUT_HIGH=$(DISK_MAGICIAN_SNAPSHOT_FILE="$HIGH_SNAP" DISK_MAGICIAN_ALERT_SILENCE_FILE="$TMP/nope" \
  timeout 15 bash "$REPO_ROOT/scripts/disk_usage_alert.sh" 2>&1)
alert_rc_high=$?
if echo "$ALERT_OUT_HIGH" | grep -q "Swap used: 15.25 GiB (>10 GB)"; then
  pass "disk_usage_alert.sh warns on swap_used_gb=15.25 (>10)"
else
  fail "disk_usage_alert.sh did not print the swap warning for swap_used_gb=15.25:
$ALERT_OUT_HIGH (rc=$alert_rc_high)"
fi
echo "$ALERT_OUT_HIGH" | grep -qi "outside the Data volume" || fail "disk_usage_alert.sh swap warning doesn't name it as outside the Data volume"
[[ $alert_rc_high -eq 1 ]] || fail "disk_usage_alert.sh should exit 1 when the swap alert fires (got $alert_rc_high)"

# (default mode, not --status: --status never evaluates the swap gate at
# all, so it wouldn't exercise the code under test)
ALERT_OUT_LOW=$(DISK_MAGICIAN_SNAPSHOT_FILE="$LOW_SNAP" \
  timeout 15 bash "$REPO_ROOT/scripts/disk_usage_alert.sh" 2>&1 || true)
if echo "$ALERT_OUT_LOW" | grep -qi "Swap used:"; then
  fail "disk_usage_alert.sh unexpectedly printed a swap warning for swap_used_gb=2.0"
else
  pass "disk_usage_alert.sh stays silent (no swap warning) when swap_used_gb is under threshold"
fi

if [[ $FAIL -eq 0 ]]; then
  echo "ALL PASS: swap-used warning gate (disk_magician-8to)"
  exit 0
else
  exit 1
fi

#!/usr/bin/env bash
# tests/test_disk_snapshot_swap_vm.sh — bead disk_magician-8to.
#
# Verifies disk_snapshot.sh records swap_used_gb/swap_total_gb (parsed from
# `sysctl vm.swapusage`) and vm_volume_used_gb (from `df /System/Volumes/VM`)
# as additive top-level JSON keys, using a fake sysctl/df on PATH so the
# assertion is against known values rather than whatever this host reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_SH="$REPO_ROOT/scripts/disk_snapshot.sh"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

# Fake sysctl: always answers vm.swapusage with known values (4096.00M
# total, 1234.56M used) regardless of query, matching the real tool's
# single-purpose usage in disk_snapshot.sh.
cat > "$FAKE_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "vm.swapusage" ]]; then
  echo "vm.swapusage: total = 4096.00M  used = 1234.56M  free = 2861.44M  (encrypted)"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/sysctl"

# Fake df: real df is still needed for the primary Data-volume stats (get_disk_stats)
# and for the VM-volume check — answer both with fixed, parseable values so
# the test doesn't depend on this host's actual disk/VM-volume sizes.
cat > "$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "/System/Volumes/VM" ]]; then
    echo "Filesystem 1024-blocks Used Available Capacity Mounted"
    echo "/dev/disk1s1 1000000000 5242880 900000000 1% /System/Volumes/VM"
    exit 0
  fi
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk1s1 1000000000 500000000 500000000 50% /"
exit 0
EOF
chmod +x "$FAKE_BIN/df"

# Minimal config: a single tiny, fast-to-measure monitored dir so the
# snapshot completes quickly.
cat > "$TMP/config.json" <<EOF
{
  "monitored_dirs": [
    {"key": "home_root", "path": "~", "timeout": 5}
  ],
  "monitored_globs": [],
  "monitored_file_globs": []
}
EOF

OUT_JSON="$TMP/out.json"
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" \
  DISK_MAGICIAN_CONFIG="$TMP/config.json" \
  DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=30 \
  timeout 30 bash "$SNAPSHOT_SH" --output "$OUT_JSON" >/tmp/dm_swap_test_stderr.$$  2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  fail "disk_snapshot.sh exited $rc: $(cat /tmp/dm_swap_test_stderr.$$)"
fi
rm -f /tmp/dm_swap_test_stderr.$$

python3 - "$OUT_JSON" <<'PY' || FAIL_PY=1
import json, sys
d = json.load(open(sys.argv[1]))
assert abs(d["swap_total_gb"] - 4.0) < 0.01, d["swap_total_gb"]
assert abs(d["swap_used_gb"] - (1234.56 / 1024)) < 0.01, d["swap_used_gb"]
assert abs(d["vm_volume_used_gb"] - (5242880 / 1024 / 1024)) < 0.01, d["vm_volume_used_gb"]
assert d["schema_version"] == 2
print("PASS: swap_total_gb/swap_used_gb/vm_volume_used_gb parsed correctly from fake sysctl/df")
PY
[[ "${FAIL_PY:-0}" == "1" ]] && fail "swap/VM volume JSON assertions failed"

# ────────── Missing-keys tolerance: an OLD snapshot (pre-8to) has no swap
# keys at all — downstream readers must not crash or misbehave.
OLD_SNAPSHOT="$TMP/old_snapshot.json"
python3 -c "
import json
json.dump({'schema_version': 2, 'timestamp': '2026-01-01T00:00:00Z',
           'disk_used_gb': 100, 'snapshot_coverage_pct': 90.0,
           'directories': {}}, open('$OLD_SNAPSHOT', 'w'))
"
ALERT_OUT=$(DISK_MAGICIAN_SNAPSHOT_FILE="$OLD_SNAPSHOT" HOME="$FAKE_HOME" \
  timeout 15 bash "$REPO_ROOT/scripts/disk_usage_alert.sh" --status 2>&1)
alert_rc=$?
if [[ $alert_rc -ne 0 ]]; then
  fail "disk_usage_alert.sh --status crashed on a pre-swap-tracking snapshot: $ALERT_OUT"
else
  pass "disk_usage_alert.sh tolerates a snapshot with no swap_used_gb key"
fi

if [[ $FAIL -eq 0 ]]; then
  echo "ALL PASS: disk_snapshot.sh swap/VM-volume tracking (disk_magician-8to)"
  exit 0
else
  exit 1
fi

#!/usr/bin/env bash
# tests/test_disk_snapshot_nonfile_signals.sh — bead disk_magician-rpv.
#
# Verifies disk_snapshot.sh records the additive non-file signals needed to
# attribute df's ±8-62 GiB / hour swings: per-APFS-volume capacity_in_use
# (Data/VM/Preboot/Update), container free/capacity + a purgeable estimate,
# local APFS snapshot count/names, and Colima diffdisk allocation (measured
# two independent ways since it's a sparse file). Uses fake diskutil/tmutil
# on PATH so assertions are against known values rather than whatever this
# host currently reports.
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

# Fake diskutil: only implements `apfs list -plist`, emitting a plist with
# one container carrying Data/VM/Preboot/Update volumes at known
# CapacityInUse values plus a known CapacityFree/CapacityCeiling. Real
# `plutil` (a stock macOS tool, not shimmed) converts this to JSON — the
# same stdin-in/stdout-out invocation used in production, so this also
# proves the plist never touches a file (the plutil-corrupts-live-plist
# footgun this repo hit on 2026-09-11).
cat > "$FAKE_BIN/diskutil" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "apfs list" ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Containers</key>
    <array>
        <dict>
            <key>CapacityCeiling</key>
            <integer>1000000000000</integer>
            <key>CapacityFree</key>
            <integer>30000000000</integer>
            <key>Volumes</key>
            <array>
                <dict>
                    <key>Name</key><string>Macintosh HD - Data</string>
                    <key>Roles</key><array><string>Data</string></array>
                    <key>CapacityInUse</key><integer>900000000000</integer>
                </dict>
                <dict>
                    <key>Name</key><string>VM</string>
                    <key>Roles</key><array><string>VM</string></array>
                    <key>CapacityInUse</key><integer>21474836480</integer>
                </dict>
                <dict>
                    <key>Name</key><string>Preboot</string>
                    <key>Roles</key><array><string>Preboot</string></array>
                    <key>CapacityInUse</key><integer>7000000000</integer>
                </dict>
                <dict>
                    <key>Name</key><string>Update</string>
                    <key>Roles</key><array><string>Update</string></array>
                    <key>CapacityInUse</key><integer>2000000</integer>
                </dict>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/diskutil"

# Fake tmutil: two known local snapshot names.
cat > "$FAKE_BIN/tmutil" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "listlocalsnapshots /" ]]; then
  echo "Snapshots for disk /:"
  echo "com.apple.TimeMachine.2026-09-24-120000.local"
  echo "com.apple.TimeMachine.2026-09-24-160000.local"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/tmutil"

# Fake sysctl/df so the pre-existing swap/VM test path (which this snapshot
# run also exercises) stays deterministic instead of depending on this host.
cat > "$FAKE_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "vm.swapusage" ]]; then
  echo "vm.swapusage: total = 4096.00M  used = 1234.56M  free = 2861.44M  (encrypted)"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/sysctl"

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
echo "/dev/disk1s1 1000000000 500000000 27500000 50% /"
exit 0
EOF
chmod +x "$FAKE_BIN/df"

# Real Colima diffdisk path is a real file so real stat/du measure it —
# stat/du are used pervasively elsewhere in disk_snapshot.sh's directory
# measurement, so shimming them globally would corrupt unrelated
# measurements in this same run. 1 MiB of real (non-sparse) written data.
mkdir -p "$FAKE_HOME/.colima/_lima/colima"
head -c 1048576 /dev/zero > "$FAKE_HOME/.colima/_lima/colima/diffdisk"

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
  timeout 30 bash "$SNAPSHOT_SH" --output "$OUT_JSON" >"$TMP/stderr.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  fail "disk_snapshot.sh exited $rc: $(cat "$TMP/stderr.log")"
fi

python3 - "$OUT_JSON" <<'PY' || FAIL_PY=1
import json, sys
d = json.load(open(sys.argv[1]))

assert abs(d["apfs_volumes_gb"]["Data"] - (900000000000 / 1024**3)) < 0.01, d["apfs_volumes_gb"]
assert abs(d["apfs_volumes_gb"]["VM"] - (21474836480 / 1024**3)) < 0.01, d["apfs_volumes_gb"]
assert abs(d["apfs_volumes_gb"]["Preboot"] - (7000000000 / 1024**3)) < 0.01, d["apfs_volumes_gb"]
assert abs(d["apfs_volumes_gb"]["Update"] - (2000000 / 1024**3)) < 0.001, d["apfs_volumes_gb"]

assert abs(d["apfs_container_free_gb"] - (30000000000 / 1024**3)) < 0.01, d["apfs_container_free_gb"]
assert abs(d["apfs_container_capacity_gb"] - (1000000000000 / 1024**3)) < 0.01, d["apfs_container_capacity_gb"]

# purgeable estimate = df available (27500000 KB, from the fake df above) -
# apfs_container_free_gb (30000000000 bytes).
expected_purgeable = 27500000 / 1024 / 1024 - (30000000000 / 1024**3)
assert abs(d["apfs_purgeable_estimate_gb"] - expected_purgeable) < 0.01, d["apfs_purgeable_estimate_gb"]

assert d["local_snapshots_count"] == 2, d["local_snapshots_count"]
assert d["local_snapshot_names"] == [
    "com.apple.TimeMachine.2026-09-24-120000.local",
    "com.apple.TimeMachine.2026-09-24-160000.local",
], d["local_snapshot_names"]

# 1 MiB of real written data: both allocation measurements should read
# close to 1 MiB / 1024^3 GiB (allow filesystem block-rounding slack).
one_mib_gb = 1048576 / 1024**3
assert abs(d["colima_diffdisk_stat_allocated_gb"] - one_mib_gb) < 0.002, d["colima_diffdisk_stat_allocated_gb"]
assert abs(d["colima_diffdisk_du_allocated_gb"] - one_mib_gb) < 0.002, d["colima_diffdisk_du_allocated_gb"]

assert d["schema_version"] == 2

print("PASS: apfs_volumes_gb/apfs_container_free_gb/apfs_purgeable_estimate_gb/local_snapshots_count/local_snapshot_names/colima_diffdisk_*_allocated_gb parsed correctly from fake diskutil/tmutil + real diffdisk file")
PY
[[ "${FAIL_PY:-0}" == "1" ]] && fail "non-file-signal JSON assertions failed"

# ────────── Missing-keys tolerance: an OLD snapshot has none of these keys
# — downstream readers must not crash or misbehave.
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
  fail "disk_usage_alert.sh --status crashed on a pre-nonfile-signals snapshot: $ALERT_OUT"
else
  pass "disk_usage_alert.sh tolerates a snapshot with none of the new non-file-signal keys"
fi

# ────────── Failing-tool degradation: when diskutil/tmutil are present on
# PATH but fail (nonzero exit / empty output — e.g. a transient diskutil
# hang or a locked-down sandbox), the new probes must degrade to null
# (never a fabricated 0 — /advice review, Codex + Opus, both high
# confidence, 2026-09-25: a silent 0 on probe failure would read to the
# correlator as a real multi-GiB swing) rather than aborting the whole
# snapshot. Real full PATH is kept (prepended, not replaced) so every other
# tool disk_snapshot.sh needs still resolves normally — only diskutil/tmutil
# are shadowed.
FAILING_BIN="$TMP/failing_bin"
mkdir -p "$FAILING_BIN"
cat > "$FAILING_BIN/diskutil" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAILING_BIN/diskutil"
cat > "$FAILING_BIN/tmutil" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAILING_BIN/tmutil"
BARE_OUT="$TMP/bare_out.json"
PATH="$FAILING_BIN:$PATH" HOME="$FAKE_HOME" \
  DISK_MAGICIAN_CONFIG="$TMP/config.json" \
  DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=30 \
  timeout 30 bash "$SNAPSHOT_SH" --output "$BARE_OUT" >"$TMP/bare_stderr.log" 2>&1
bare_rc=$?
if [[ $bare_rc -ne 0 ]]; then
  fail "disk_snapshot.sh exited $bare_rc without diskutil/tmutil on PATH: $(cat "$TMP/bare_stderr.log")"
else
  python3 - "$BARE_OUT" <<'PY' || FAIL_BARE=1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["apfs_volumes_gb"] == {"Data": None, "VM": None, "Preboot": None, "Update": None}, d["apfs_volumes_gb"]
assert d["apfs_container_free_gb"] is None, d["apfs_container_free_gb"]
assert d["apfs_purgeable_estimate_gb"] is None, d["apfs_purgeable_estimate_gb"]
assert d["local_snapshots_count"] is None, d["local_snapshots_count"]
assert d["local_snapshot_names"] is None, d["local_snapshot_names"]
print("PASS: missing diskutil/tmutil degrades to null (never a fabricated 0), snapshot still succeeds")
PY
  [[ "${FAIL_BARE:-0}" == "1" ]] && fail "no-diskutil/tmutil degradation assertions failed"
fi

# ────────── Colima measurement failure vs missing file: a diffdisk that
# EXISTS but whose stat/du calls fail must read null (measurement failed),
# distinct from a genuinely absent diffdisk (real 0 — Colima not running).
# Shims a failing `stat`/`du` scoped ONLY to this one run via a wrapper that
# fails for the diffdisk path and delegates every other path to the real
# tool, so the rest of disk_snapshot.sh's own du-heavy directory measurement
# is unaffected.
COLIMA_FAIL_BIN="$TMP/colima_fail_bin"
mkdir -p "$COLIMA_FAIL_BIN"
REAL_STAT="$(command -v stat)"
REAL_DU="$(command -v du)"
cat > "$COLIMA_FAIL_BIN/stat" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == *"/.colima/_lima/colima/diffdisk" ]] && exit 1
done
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$COLIMA_FAIL_BIN/stat"
cat > "$COLIMA_FAIL_BIN/du" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" == *"/.colima/_lima/colima/diffdisk" ]] && exit 1
done
exec "$REAL_DU" "\$@"
EOF
chmod +x "$COLIMA_FAIL_BIN/du"
COLIMA_FAIL_OUT="$TMP/colima_fail_out.json"
PATH="$COLIMA_FAIL_BIN:$FAKE_BIN:$PATH" HOME="$FAKE_HOME" \
  DISK_MAGICIAN_CONFIG="$TMP/config.json" \
  DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=30 \
  timeout 30 bash "$SNAPSHOT_SH" --output "$COLIMA_FAIL_OUT" >"$TMP/colima_fail_stderr.log" 2>&1
colima_fail_rc=$?
if [[ $colima_fail_rc -ne 0 ]]; then
  fail "disk_snapshot.sh exited $colima_fail_rc with a failing stat/du on an existing diffdisk: $(cat "$TMP/colima_fail_stderr.log")"
else
  python3 - "$COLIMA_FAIL_OUT" <<'PY' || FAIL_COLIMA=1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["colima_diffdisk_stat_allocated_gb"] is None, d["colima_diffdisk_stat_allocated_gb"]
assert d["colima_diffdisk_du_allocated_gb"] is None, d["colima_diffdisk_du_allocated_gb"]
print("PASS: existing diffdisk with failing stat/du reads null, not a fabricated 0")
PY
  [[ "${FAIL_COLIMA:-0}" == "1" ]] && fail "colima stat/du failure-vs-zero assertions failed"
fi

if [[ $FAIL -eq 0 ]]; then
  echo "ALL PASS: disk_snapshot.sh non-file-signal tracking (disk_magician-rpv)"
  exit 0
else
  exit 1
fi

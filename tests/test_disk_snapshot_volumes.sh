#!/usr/bin/env bash
# Focused test for additive diskm quota-volume snapshot data.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP=$(mktemp -d)
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/disk-magician" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "volume status --json --snapshot" ]] || exit 2
if [[ "${FAKE_VOLUME_FAIL:-0}" == "1" ]]; then exit 1; fi
printf '%s\n' "$FAKE_VOLUME_JSON"
if [[ "${FAKE_VOLUME_ALARM:-0}" == "1" ]]; then exit 1; fi
if [[ "${FAKE_VOLUME_FATAL:-0}" == "1" ]]; then exit 2; fi
SH
chmod +x "$TMP/bin/disk-magician"
FAKE_DISKM="$TMP/bin/disk-magician"
FAKE_VOLUME_JSON='{"ok":true,"alarms":[],"volumes":[{"class":"scratch","allocated_bytes":5368709120,"quota_bytes":32212254720}]}'
export FAKE_DISKM FAKE_VOLUME_JSON
cat > "$TMP/config.json" <<EOF_CONFIG
{"monitored_dirs":[{"key":"home_root","path":"$TMP/home","timeout":5}],"monitored_globs":[],"monitored_file_globs":[]}
EOF_CONFIG
run_snapshot() {
  local output="$1" fail_probe="$2" alarm="${3:-0}" fatal="${4:-0}"
  PATH="$TMP/bin:$PATH" \
    DISK_MAGICIAN_CONFIG="$TMP/config.json" \
    DISK_MAGICIAN_DISKM_BIN="$FAKE_DISKM" \
    DISK_MAGICIAN_STATE_DIR="$TMP/state" \
    DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=30 \
    FAKE_VOLUME_FAIL="$fail_probe" \
    FAKE_VOLUME_ALARM="$alarm" \
    FAKE_VOLUME_FATAL="$fatal" \
    timeout 60 bash "$REPO_ROOT/scripts/disk_snapshot.sh" --output "$output" >/dev/null 2>&1
}
if ! run_snapshot "$TMP/seeded.json" 0; then
  echo "FAIL: snapshot failed with a healthy volume status probe" >&2
  exit 1
fi
python3 - "$TMP/seeded.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
assert snapshot["diskm_volumes"]["volumes"][0]["allocated_bytes"] == 5368709120, snapshot.get("diskm_volumes")
print("PASS: snapshot includes measured diskm volume allocation")
PY
if ! run_snapshot "$TMP/alarm.json" 0 1; then
  echo "FAIL: snapshot command failed with a high-water volume status" >&2
  exit 1
fi
python3 - "$TMP/alarm.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
assert snapshot["diskm_volumes"]["volumes"][0]["allocated_bytes"] == 5368709120, snapshot.get("diskm_volumes")
print("PASS: high-water exit code preserves measured volume allocation")
PY
if ! run_snapshot "$TMP/failed.json" 1; then
  echo "FAIL: snapshot failed when volume status probe returned nonzero" >&2
  exit 1
fi
python3 - "$TMP/failed.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
assert snapshot["diskm_volumes"] is None, snapshot.get("diskm_volumes")
print("PASS: failed volume status probe is preserved as null")
PY

if ! run_snapshot "$TMP/fatal.json" 0 0 1; then
  echo "FAIL: snapshot failed when volume status probe returned fatal status" >&2
  exit 1
fi
python3 - "$TMP/fatal.json" <<PY
import json, sys
snapshot = json.load(open(sys.argv[1]))
assert snapshot["diskm_volumes"] is None, snapshot.get("diskm_volumes")
print("PASS: fatal volume status probe is preserved as null")
PY

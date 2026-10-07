#!/usr/bin/env bash
# test_check_launchd_fleet.sh — Behavioral tests for check_launchd_fleet.sh
#
# Regression coverage for the 2026-09-06 incident: disk_magician's own
# launchd fleet (including its watchdog) was silently unloaded for 6+ days
# with zero visible error. This test builds a fake LaunchAgents dir + a
# stubbed `launchctl` on PATH and asserts the script correctly classifies:
#   - a plist that's valid AND launchctl reports loaded          -> OK
#   - a plist that's valid but launchctl has no record of it     -> NOT LOADED
#   - a plist truncated to a bare <array> (the real incident's
#     failure mode — missing <dict>/Label/ProgramArguments)      -> INVALID PLIST
#   - a known label with no plist file on disk at all            -> MISSING PLIST
#
# Run: bash tests/test_check_launchd_fleet.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check_launchd_fleet.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_DIR=$(mktemp -d -t check_launchd_fleet_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
PLIST_DIR="$TMP_DIR/launchd"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$PLIST_DIR" "$FAKE_BIN"

# Valid, correctly-structured plist — this label will be reported "loaded"
# by the stubbed launchctl below, so it must classify as OK (no output line).
cat > "$PLIST_DIR/com.disk-magician.sweeper-health.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.disk-magician.sweeper-health</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/echo</string>
  </array>
</dict>
</plist>
EOF

# Valid plist, but the stubbed launchctl below will NOT list it -> NOT LOADED.
cp "$PLIST_DIR/com.disk-magician.sweeper-health.plist" "$PLIST_DIR/com.disk-magician.colima-prune.plist"
sed -i '' 's/sweeper-health/colima-prune/' "$PLIST_DIR/com.disk-magician.colima-prune.plist" 2>/dev/null \
  || sed -i 's/sweeper-health/colima-prune/' "$PLIST_DIR/com.disk-magician.colima-prune.plist"

# The real 2026-09-06 failure mode: truncated to a bare <array>, no <dict>.
cat > "$PLIST_DIR/com.jleechanorg.disk-magician.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<string>/Users/jleechan/.local/bin/disk-magician</string>
	<string>snapshot</string>
</array>
</plist>
EOF

# All other known labels are intentionally left absent -> MISSING PLIST.

# Stub launchctl: only ever reports com.disk-magician.sweeper-health loaded.
# Compatibility note: the legacy no-argument checker intentionally excludes
# the privileged APFS LaunchDaemon; template-derived JSON inventory includes it
# separately as a system-domain record.
cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  echo "12345	0	com.disk-magician.sweeper-health"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl"

OUTPUT=$(PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$TMP_DIR/no-daemons" "$SCRIPT" 2>&1) && RC=0 || RC=$?

fail=0
assert_contains() {
  local desc="$1" needle="$2"
  if ! grep -qF -- "$needle" <<<"$OUTPUT"; then
    echo "FAIL: $desc — expected to find: $needle" >&2
    echo "--- actual output ---" >&2
    echo "$OUTPUT" >&2
    fail=1
  fi
}

echo "$OUTPUT"

assert_contains "exit code signals unhealthy fleet" ""
if [[ "$RC" -ne 1 ]]; then
  echo "FAIL: expected exit code 1 (unhealthy fleet present), got $RC" >&2
  fail=1
fi

assert_contains "malformed bare-<array> plist is flagged INVALID, not silently OK" \
  "INVALID PLIST   com.jleechanorg.disk-magician"
assert_contains "valid-but-unregistered plist is flagged NOT LOADED" \
  "NOT LOADED      com.disk-magician.colima-prune"
assert_contains "a known label with no plist file at all is flagged MISSING" \
  "MISSING PLIST   com.disk-magician.hermes-vacuum"
assert_contains "the one healthy label produces no failure line for itself" \
  "Fleet:"

if grep -qE "(INVALID|NOT LOADED|MISSING).*sweeper-health$" <<<"$OUTPUT"; then
  echo "FAIL: the loaded+valid sweeper-health label was incorrectly flagged" >&2
  fail=1
fi

assert_contains "the system APFS daemon label is checked and flagged MISSING when absent" \
  "MISSING PLIST   com.disk-magician.apfs-snapshots"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: initial fleet checks failed" >&2
  exit 1
fi

# Test LaunchDaemon path: com.jleechanorg.disk-magician-frontier-root
DAEMON_DIR="$TMP_DIR/daemons"
mkdir -p "$DAEMON_DIR"
cat > "$DAEMON_DIR/com.jleechanorg.disk-magician-frontier-root.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jleechanorg.disk-magician-frontier-root</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/echo</string>
  </array>
</dict>
</plist>
EOF

sed 's/com.jleechanorg.disk-magician-frontier-root/com.disk-magician.apfs-snapshots/' \
  "$DAEMON_DIR/com.jleechanorg.disk-magician-frontier-root.plist" > "$DAEMON_DIR/com.disk-magician.apfs-snapshots.plist"
unhealthy_count() { sed -n 's/.*⚠️  \([0-9][0-9]*\) job(s) unhealthy.*/\1/p' <<<"$1"; }

# Update stub launchctl to support 'print system/<label>'
cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  echo "12345	0	com.disk-magician.sweeper-health"
  exit 0
elif [[ "${1:-}" == "print" && "${2:-}" == "system/com.jleechanorg.disk-magician-frontier-root" ]]; then
  case "${MOCK_SYSTEM_DAEMON_LOADED:-1}" in
    1) exit 0 ;;
    0) exit 113 ;;
    *) echo "Unhandled error 5: Input/output error" >&2; exit 5 ;;
  esac
fi
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl"

# Sub-test 1: System daemon plist present and system launchctl returns 0 -> healthy (no failure line)
OUTPUT_DAEMON_OK=$(PATH="$FAKE_BIN:$PATH" \
  DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$DAEMON_DIR" \
  MOCK_SYSTEM_DAEMON_LOADED=1 \
  "$SCRIPT" 2>&1) || true

if ! grep -qF "Fleet:" <<<"$OUTPUT_DAEMON_OK"; then
  echo "FAIL: loaded system daemon run produced no fleet summary" >&2
  fail=1
fi
if grep -qF "com.jleechanorg.disk-magician-frontier-root" <<<"$OUTPUT_DAEMON_OK"; then
  echo "FAIL: loaded system daemon was unexpectedly flagged as failure" >&2
  echo "$OUTPUT_DAEMON_OK" >&2
  fail=1
fi

BASE_UNHEALTHY="$(unhealthy_count "$OUTPUT_DAEMON_OK")"
if grep -qF "com.disk-magician.apfs-snapshots" <<<"$OUTPUT_DAEMON_OK"; then
  echo "FAIL: loaded APFS system daemon was unexpectedly flagged" >&2
  fail=1
fi

# Sub-test 2: System daemon plist present but system launchctl returns 113 -> NOT LOADED
OUTPUT_DAEMON_UNLOADED=$(PATH="$FAKE_BIN:$PATH" \
  DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$DAEMON_DIR" \
  MOCK_SYSTEM_DAEMON_LOADED=0 \
  "$SCRIPT" 2>&1) || true
if [[ "$(unhealthy_count "$OUTPUT_DAEMON_UNLOADED")" != "$((BASE_UNHEALTHY + 1))" ]]; then
  echo "FAIL: NOT LOADED daemon did not add exactly one unhealthy job" >&2
  fail=1
fi

if ! grep -qF "NOT LOADED      com.jleechanorg.disk-magician-frontier-root  (plist valid but system launchctl has no record)" <<<"$OUTPUT_DAEMON_UNLOADED"; then
  echo "FAIL: unloaded system daemon was not correctly reported as NOT LOADED" >&2
  echo "$OUTPUT_DAEMON_UNLOADED" >&2
  fail=1
fi

# Sub-test 3: launchctl print fails for a reason other than "not found" -> UNKNOWN STATE, not NOT LOADED
OUTPUT_DAEMON_ERR=$(PATH="$FAKE_BIN:$PATH" \
  DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$DAEMON_DIR" \
  MOCK_SYSTEM_DAEMON_LOADED=err \
  "$SCRIPT" 2>&1) || true

if ! grep -qF "UNKNOWN STATE   com.jleechanorg.disk-magician-frontier-root  (launchctl print system/com.jleechanorg.disk-magician-frontier-root exited 5" <<<"$OUTPUT_DAEMON_ERR" \
  || grep -qE "NOT LOADED +com.jleechanorg.disk-magician-frontier-root" <<<"$OUTPUT_DAEMON_ERR"; then
  echo "FAIL: launchctl print error was not reported as UNKNOWN STATE" >&2
  echo "$OUTPUT_DAEMON_ERR" >&2
  fail=1
fi
if [[ "$(unhealthy_count "$OUTPUT_DAEMON_ERR")" != "$((BASE_UNHEALTHY + 1))" ]]; then
  echo "FAIL: UNKNOWN STATE daemon did not add exactly one unhealthy job" >&2
  fail=1
fi

# Sub-test 4: same label in LaunchAgents and LaunchDaemons -> UNKNOWN STATE (agent must not mask daemon)
cp "$DAEMON_DIR/com.jleechanorg.disk-magician-frontier-root.plist" "$PLIST_DIR/"
OUTPUT_DUP=$(PATH="$FAKE_BIN:$PATH" \
  DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$DAEMON_DIR" \
  MOCK_SYSTEM_DAEMON_LOADED=0 \
  "$SCRIPT" 2>&1) || true
rm -f "$PLIST_DIR/com.jleechanorg.disk-magician-frontier-root.plist"
if ! grep -qF "UNKNOWN STATE   com.jleechanorg.disk-magician-frontier-root  (plist in both" <<<"$OUTPUT_DUP"; then
  echo "FAIL: same-label LaunchAgent masked the system daemon" >&2
  echo "$OUTPUT_DUP" >&2
  fail=1
fi

# Sub-test 5: a fully healthy fleet (every label loaded, daemons via system domain) exits 0
HEALTHY_DIR="$TMP_DIR/healthy"
mkdir -p "$HEALTHY_DIR"
LIST_FILE="$TMP_DIR/healthy_list.txt"
: > "$LIST_FILE"
LABELS="$(sed -n '/^KNOWN_LABELS=(/,/^)/p' "$SCRIPT" | grep -oE '^  com\.[A-Za-z0-9.-]+' | tr -d ' ')"
for l in $LABELS; do
  [[ -f "$DAEMON_DIR/$l.plist" ]] && continue
  sed "s/com.disk-magician.sweeper-health/$l/" "$PLIST_DIR/com.disk-magician.sweeper-health.plist" > "$HEALTHY_DIR/$l.plist"
  printf '1\t0\t%s\n' "$l" >> "$LIST_FILE"
done
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "list" ]]; then cat "%s"; fi\nexit 0\n' "$LIST_FILE" > "$FAKE_BIN/launchctl"
chmod +x "$FAKE_BIN/launchctl"
OUTPUT_HEALTHY=$(PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$HEALTHY_DIR" \
  DISK_MAGICIAN_LAUNCHDAEMONS_DIR="$DAEMON_DIR" "$SCRIPT" --fleet-only 2>&1) && HRC=0 || HRC=$?
TOTAL="$(wc -w <<<"$LABELS" | tr -d ' ')"
if [[ "$HRC" -ne 0 ]] || ! grep -qF "Fleet: $TOTAL/$TOTAL loaded and valid." <<<"$OUTPUT_HEALTHY"; then
  echo "FAIL: fully healthy fleet did not exit 0 with $TOTAL/$TOTAL (rc=$HRC)" >&2
  echo "$OUTPUT_HEALTHY" >&2
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  exit 1
fi

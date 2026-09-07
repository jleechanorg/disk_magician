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
cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  echo "12345	0	com.disk-magician.sweeper-health"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl"

OUTPUT=$(PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$PLIST_DIR" "$SCRIPT" 2>&1) && RC=0 || RC=$?

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

if [[ "$fail" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  exit 1
fi

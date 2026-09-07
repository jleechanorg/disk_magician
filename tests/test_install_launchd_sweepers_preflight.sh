#!/usr/bin/env bash
# test_install_launchd_sweepers_preflight.sh — Regression test for bead
# disk_magician-zwb: install_launchd_sweepers.sh must reject bare <array> plists
# (missing <dict> wrapper) and invalid XML plists before calling launchctl bootstrap.
#
# Root cause (2026-08-31 mass corruption): plists were truncated to bare <array>
# files. plutil -lint validates plist XML syntax, which permits top-level
# arrays, but launchd rejects them silently. Preflight must check both
# plutil -lint and top-level Label key existence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/install_launchd_sweepers.sh"

if [[ ! -x "$TARGET_SCRIPT" ]]; then
  echo "FAIL: $TARGET_SCRIPT not executable" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d -t test_sweepers_preflight.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

STATE_DIR="$TMP_ROOT/state"
LAUNCHAGENTS_DIR="$TMP_ROOT/LaunchAgents"
MOCK_LAUNCHD_SRC="$TMP_ROOT/launchd"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$STATE_DIR" "$LAUNCHAGENTS_DIR" "$MOCK_LAUNCHD_SRC" "$FAKE_BIN"

export BOOTSTRAP_LOG="$TMP_ROOT/bootstrap_calls.log"
cat > "$FAKE_BIN/launchctl" <<'LAUNCH_MOCK'
#!/usr/bin/env bash
echo "$@" >> "$BOOTSTRAP_LOG"
exit 0
LAUNCH_MOCK
chmod +x "$FAKE_BIN/launchctl"

# 1. Test bare <array> plist: passes plutil -lint, but lacks <dict> and Label key
cat > "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-array.plist" <<'ARRAY_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <string>/bin/echo</string>
  <string>corrupt</string>
</array>
</plist>
ARRAY_PLIST

# 2. Test invalid XML plist: unclosed tag, fails plutil -lint
cat > "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-xml.plist" <<'XML_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.disk-magician.corrupt-xml</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/true</string>
</dict>
</plist>
XML_PLIST

# 3. Test valid plist
cat > "$MOCK_LAUNCHD_SRC/com.disk-magician.valid-job.plist" <<'VALID_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.disk-magician.valid-job</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/true</string>
  </array>
</dict>
</plist>
VALID_PLIST

# 4. Bare array plist that contains an inner dict with Label (passes plutil -lint, but lacks top-level dict)
cat > "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-wrapper.plist" <<'WRAPPER_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>Label</key>
    <string>com.disk-magician.corrupt-wrapper</string>
  </dict>
</array>
</plist>
WRAPPER_PLIST

# Test installing valid plist
OUT_VALID="$TMP_ROOT/out_valid.txt"
set +e
PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCHAGENTS_DIR" \
  bash "$TARGET_SCRIPT" "$MOCK_LAUNCHD_SRC/com.disk-magician.valid-job.plist" >"$OUT_VALID" 2>&1
RC_VALID=$?
set -e

if [[ $RC_VALID -ne 0 ]]; then
  echo "FAIL: valid plist installation failed (rc=$RC_VALID)" >&2
  cat "$OUT_VALID" >&2
  exit 1
fi

if [[ ! -f "$LAUNCHAGENTS_DIR/com.disk-magician.valid-job.plist" ]]; then
  echo "FAIL: valid plist was not written to LaunchAgents dir" >&2
  exit 1
fi

if ! grep -q "bootstrap.*com.disk-magician.valid-job" "$BOOTSTRAP_LOG"; then
  echo "FAIL: launchctl bootstrap was not called for valid plist" >&2
  exit 1
fi

# Reset bootstrap log
: > "$BOOTSTRAP_LOG"

# Test installing invalid XML plist
OUT_XML="$TMP_ROOT/out_xml.txt"
set +e
PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCHAGENTS_DIR" \
  bash "$TARGET_SCRIPT" "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-xml.plist" >"$OUT_XML" 2>&1
RC_XML=$?
set -e

if [[ $RC_XML -eq 0 ]]; then
  echo "FAIL: invalid XML plist unexpectedly succeeded" >&2
  cat "$OUT_XML" >&2
  exit 1
fi

if grep -q "bootstrap.*com.disk-magician.corrupt-xml" "$BOOTSTRAP_LOG"; then
  echo "FAIL: launchctl bootstrap was called for corrupt XML plist" >&2
  exit 1
fi

if [[ -f "$LAUNCHAGENTS_DIR/com.disk-magician.corrupt-xml.plist" ]]; then
  echo "FAIL: corrupt XML plist was left behind in LaunchAgents" >&2
  exit 1
fi

if ! grep -q "fails plutil -lint" "$OUT_XML"; then
  echo "FAIL: expected plutil -lint failure message in output" >&2
  cat "$OUT_XML" >&2
  exit 1
fi

# Test installing bare <array> plist (fails label/dict check)
OUT_ARRAY="$TMP_ROOT/out_array.txt"
set +e
PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCHAGENTS_DIR" \
  bash "$TARGET_SCRIPT" "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-array.plist" >"$OUT_ARRAY" 2>&1
RC_ARRAY=$?
set -e

if grep -q "bootstrap.*corrupt-array" "$BOOTSTRAP_LOG"; then
  echo "FAIL: launchctl bootstrap was called for bare array plist" >&2
  exit 1
fi

# Test installing plist where Label is nested inside array (passes lint, fails top-level label extraction)
OUT_WRAPPER="$TMP_ROOT/out_wrapper.txt"
set +e
PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCHAGENTS_DIR" \
  bash "$TARGET_SCRIPT" "$MOCK_LAUNCHD_SRC/com.disk-magician.corrupt-wrapper.plist" >"$OUT_WRAPPER" 2>&1
RC_WRAPPER=$?
set -e

if [[ $RC_WRAPPER -eq 0 ]]; then
  echo "FAIL: bare array plist with mock label unexpectedly succeeded" >&2
  cat "$OUT_WRAPPER" >&2
  exit 1
fi

if grep -q "bootstrap.*corrupt-wrapper" "$BOOTSTRAP_LOG"; then
  echo "FAIL: launchctl bootstrap was called for corrupt wrapper plist" >&2
  exit 1
fi

if [[ -f "$LAUNCHAGENTS_DIR/com.disk-magician.corrupt-wrapper.plist" ]]; then
  echo "FAIL: corrupt wrapper plist was left behind in LaunchAgents" >&2
  exit 1
fi

if ! grep -q "has no top-level Label key" "$OUT_WRAPPER"; then
  echo "FAIL: expected 'has no top-level Label key' error message in output" >&2
  cat "$OUT_WRAPPER" >&2
  exit 1
fi

echo "PASS: all install_launchd_sweepers preflight tests passed"
exit 0

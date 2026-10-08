#!/usr/bin/env bash
# test_sweeper_health_ledger_warn.sh — ledger freshness WARN coverage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/sweeper_health_check.sh"

TMP_ROOT=$(mktemp -d -t sweeper_health_ledger_warn.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
PLIST_DIR="$TMP_ROOT/launchd"
LOG_PATH="$TMP_ROOT/sweeper.log"
STATE_REPO="$TMP_ROOT/state-repo"
mkdir -p "$FAKE_BIN" "$PLIST_DIR" "$STATE_REPO"

cp "$TARGET" "$FAKE_BIN/sweeper_health_check.sh"
chmod +x "$FAKE_BIN/sweeper_health_check.sh"

cat > "$FAKE_BIN/check_ledger_freshness.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${DISK_MAGICIAN_STATE_REPO:-unset}" > "$LEDGER_STATE_OUT"
printf '%b\n' "$LEDGER_RESPONSE"
exit "$LEDGER_RC"
EOF
chmod +x "$FAKE_BIN/check_ledger_freshness.sh"

cat > "$FAKE_BIN/disk_status.py" <<'EOF'
import os
from pathlib import Path

Path(os.environ["PUBLICATION_OUT"]).write_text("publication-called\n")
EOF

cat > "$PLIST_DIR/com.jleechanorg.disk-magician-fresh.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jleechanorg.disk-magician-fresh</string>
  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
</dict>
</plist>
EOF
printf 'sweep complete\n' > "$LOG_PATH"

run_case() {
  local response="$1" rc="$2" output
  set +e
  output="$(LEDGER_RESPONSE="$response" LEDGER_RC="$rc" \
    LEDGER_STATE_OUT="$TMP_ROOT/ledger-state" PUBLICATION_OUT="$TMP_ROOT/publication" \
    "$FAKE_BIN/sweeper_health_check.sh" \
      --plist-dir "$PLIST_DIR" --state-repo "$STATE_REPO" --no-notify 2>&1)"
  local actual_rc=$?
  set -e
  printf '%s\n' "$output"
  [[ "$actual_rc" -eq 1 ]] || return 1
  [[ "$output" == *"[WARN] ledger/topdown-5g.json"* ]] || return 1
  [[ "$output" == *"${response//$'\t'/ }"* ]] || return 1
  [[ "$(cat "$TMP_ROOT/ledger-state")" == "$STATE_REPO" ]] || return 1
  [[ -f "$TMP_ROOT/publication" ]] || return 1
}

echo "=== sweeper health ledger warning ==="
run_case $'STALE\tno_published_ledger_commit' 1
echo "  PASS  stale ledger is a WARN and preserves publication checking"
run_case $'UNKNOWN\tstate_repo_unreadable' 2
echo "  PASS  unknown ledger is a WARN and preserves publication checking"
echo "All sweeper_health_ledger_warn tests passed."

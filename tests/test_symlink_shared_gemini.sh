#!/usr/bin/env bash
# Behavioral regression tests for retiring whole-root AO session .gemini aliases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEDUP_SCRIPT="$REPO_ROOT/scripts/symlink-shared-gemini.sh"
INSTALL_SCRIPT="$REPO_ROOT/scripts/install_launchd_sweepers.sh"

TMP_DIR="$(mktemp -d /tmp/gemini_dedup_retirement_test.XXXXXX)"

PASS=0
FAIL=0
pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL  $1"
  FAIL=$((FAIL + 1))
}
expect_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing: $needle)"
  fi
}

echo "=== Gemini dedup retirement contract ==="

echo "Test 1: --clean never replaces a session .gemini directory with a host alias"
TEST_HOME="$TMP_DIR/home"
export HOME="$TEST_HOME"
mkdir -p "$HOME/.gemini" "$HOME/.ao-sessions/session-a/.gemini"
echo canonical >"$HOME/.gemini/host-marker"
echo session-owned >"$HOME/.ao-sessions/session-a/.gemini/session-marker"

set +e
OUT="$("$DEDUP_SCRIPT" --clean 2>&1)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then pass "retired entrypoint exits successfully"; else fail "retired entrypoint exits successfully (rc=$RC)"; fi
if [[ -d "$HOME/.ao-sessions/session-a/.gemini" && ! -L "$HOME/.ao-sessions/session-a/.gemini" ]]; then
  pass "session .gemini remains a real directory"
else
  fail "session .gemini remains a real directory"
fi
if [[ -f "$HOME/.ao-sessions/session-a/.gemini/session-marker" ]]; then
  pass "session-owned data remains intact"
else
  fail "session-owned data remains intact"
fi
expect_contains "operator is told AO owns materialization" "Agent Orchestrator owns per-session .gemini materialization" "$OUT"

echo "Test 2: backup cleanup remains safety-gated"
UNPROTECTED="$HOME/.ao-sessions/session-a/.gemini.bak.20260701-010101"
PROTECTED="$HOME/.ao-sessions/session-b/.gemini.bak.20260701-010102"
mkdir -p "$UNPROTECTED" "$PROTECTED" "$HOME/.config/disk-magician"
echo old >"$UNPROTECTED/marker"
echo preserve >"$PROTECTED/marker"
cat >"$HOME/.config/disk-magician/safety.local.json" <<EOF
{
  "never_delete": [
    {"path": "$PROTECTED", "reason": "regression fixture"}
  ]
}
EOF

OUT="$("$DEDUP_SCRIPT" --clean --delete-backups 2>&1)"
if [[ ! -e "$UNPROTECTED" ]]; then pass "unprotected backup is deleted"; else fail "unprotected backup is deleted"; fi
if [[ -d "$PROTECTED" ]]; then pass "protected backup is preserved"; else fail "protected backup is preserved"; fi
expect_contains "protected cleanup reports the safety reason" "skip protected:" "$OUT"

echo "Test 3: installer removes the retired unattended job and does not reinstall it"
FAKE_BIN="$TMP_DIR/bin"
LAUNCH_AGENTS="$TMP_DIR/LaunchAgents"
LAUNCHCTL_LOG="$TMP_DIR/launchctl.log"
mkdir -p "$FAKE_BIN" "$LAUNCH_AGENTS"
export LAUNCHCTL_LOG
cat >"$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LAUNCHCTL_LOG"
EOF
chmod +x "$FAKE_BIN/launchctl"
echo stale >"$LAUNCH_AGENTS/com.disk-magician.gemini-dedup.plist"

OUT="$(
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCH_AGENTS" \
    "$INSTALL_SCRIPT" 2>&1
)"

if [[ ! -e "$LAUNCH_AGENTS/com.disk-magician.gemini-dedup.plist" ]]; then
  pass "retired plist is removed"
else
  fail "retired plist is removed"
fi
if grep -Fq "bootout gui/$(id -u)/com.disk-magician.gemini-dedup" "$LAUNCHCTL_LOG"; then
  pass "retired launchd label is booted out"
else
  fail "retired launchd label is booted out"
fi
if grep -Fq "bootstrap gui/$(id -u) $LAUNCH_AGENTS/com.disk-magician.gemini-dedup.plist" "$LAUNCHCTL_LOG"; then
  fail "retired launchd label is not bootstrapped"
else
  pass "retired launchd label is not bootstrapped"
fi
expect_contains "installer reports retirement" "retired com.disk-magician.gemini-dedup" "$OUT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

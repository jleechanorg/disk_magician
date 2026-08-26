#!/usr/bin/env bash
# Behavioral test suite for cross-repo AGY self-link and state-root integrity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary_agy_selflink.sh"
DEDUP_SCRIPT="$REPO_ROOT/scripts/symlink-shared-gemini.sh"

TMP_DIR="$(mktemp -d /tmp/agy_canary_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

echo "=== AGY Self-Link & Mutable State Root Integrity Canary ==="

# Test 1: Clean baseline passes canary
echo "Test 1: Clean host .gemini directory passes canary"
TEST_HOME="$TMP_DIR/home1"
mkdir -p "$TEST_HOME/.gemini/antigravity-cli" "$TEST_HOME/.gemini/skills"
echo '{"theme": "dark"}' > "$TEST_HOME/.gemini/settings.json"
echo "host marker" > "$TEST_HOME/.gemini/marker.txt"

if "$CANARY_SCRIPT" --host-dir "$TEST_HOME/.gemini" --sessions-dir "$TEST_HOME/.ao-sessions" >/dev/null 2>&1; then
  pass "clean host .gemini passes canary"
else
  fail "clean host .gemini passes canary"
fi

# Test 2: Host .gemini as a symlink is rejected
echo "Test 2: Host .gemini as a symlink is rejected"
TEST_HOME2="$TMP_DIR/home2"
mkdir -p "$TEST_HOME2/real_gemini" "$TEST_HOME2"
ln -s "$TEST_HOME2/real_gemini" "$TEST_HOME2/.gemini"

set +e
OUT2="$("$CANARY_SCRIPT" --host-dir "$TEST_HOME2/.gemini" 2>&1)"
RC2=$?
set -e
if [[ "$RC2" -ne 0 ]] && echo "$OUT2" | grep -q "violates mutable state-root invariant"; then
  pass "symlink host root rejected"
else
  fail "symlink host root rejected (rc=$RC2)"
fi

# Test 3: Circular / self-referential symlink inside host .gemini is detected
echo "Test 3: Circular self-link inside host .gemini is detected and rejected"
TEST_HOME3="$TMP_DIR/home3"
mkdir -p "$TEST_HOME3/.gemini/sub"
# Create a direct self-link
ln -s "$TEST_HOME3/.gemini/sub/loop" "$TEST_HOME3/.gemini/sub/loop" 2>/dev/null || true

set +e
OUT3="$("$CANARY_SCRIPT" --host-dir "$TEST_HOME3/.gemini" 2>&1)"
RC3=$?
set -e
if [[ "$RC3" -ne 0 ]] && echo "$OUT3" | grep -q "self-link detected"; then
  pass "internal self-link detected"
else
  fail "internal self-link detected (rc=$RC3)"
fi

# Test 4: Session .gemini alias to host .gemini is detected and detached
echo "Test 4: Dangerous session .gemini alias to host root is detected and detached"
TEST_HOME4="$TMP_DIR/home4"
mkdir -p "$TEST_HOME4/.gemini/skills" "$TEST_HOME4/.ao-sessions/session-xyz"
echo "canonical-host" > "$TEST_HOME4/.gemini/settings.json"
# Link session .gemini directly to host .gemini (the dangerous pattern)
ln -s "$TEST_HOME4/.gemini" "$TEST_HOME4/.ao-sessions/session-xyz/.gemini"

# Canary with --detach
set +e
OUT4="$("$CANARY_SCRIPT" --host-dir "$TEST_HOME4/.gemini" --sessions-dir "$TEST_HOME4/.ao-sessions" --detach 2>&1)"
RC4=$?
set -e

# Verify session link was detached and replaced with real dir
if [[ -d "$TEST_HOME4/.ao-sessions/session-xyz/.gemini" && ! -L "$TEST_HOME4/.ao-sessions/session-xyz/.gemini" ]]; then
  pass "session .gemini alias detached into real directory"
else
  fail "session .gemini alias detached into real directory"
fi

# Verify host entries remained intact regular files
if [[ -f "$TEST_HOME4/.gemini/settings.json" && ! -L "$TEST_HOME4/.gemini/settings.json" ]]; then
  pass "host .gemini entries remain regular files"
else
  fail "host .gemini entries remain regular files"
fi

# Test 5: Dedup script retains no-op on session root and canary passes after dedup
echo "Test 5: Dedup script followed by canary pass"
TEST_HOME5="$TMP_DIR/home5"
export HOME="$TEST_HOME5"
mkdir -p "$HOME/.gemini" "$HOME/.ao-sessions/session-abc/.gemini"
echo "host" > "$HOME/.gemini/host.txt"
echo "session" > "$HOME/.ao-sessions/session-abc/.gemini/session.txt"

"$DEDUP_SCRIPT" --clean >/dev/null 2>&1
if "$CANARY_SCRIPT" --host-dir "$HOME/.gemini" --sessions-dir "$HOME/.ao-sessions" >/dev/null 2>&1; then
  pass "canary passes cleanly after dedup script"
else
  fail "canary passes cleanly after dedup script"
fi

# Test 6: AGY non-UI startup smoke simulation
echo "Test 6: AGY non-UI startup smoke test"
if command -v agy >/dev/null 2>&1; then
  # Run non-interactive print help or check agy execution
  AGY_SMOKE="$(agy --help 2>&1 || true)"
  if echo "$AGY_SMOKE" | grep -q "Usage of agy"; then
    pass "AGY non-UI startup smoke succeeded"
  else
    fail "AGY non-UI startup smoke failed"
  fi
else
  pass "AGY non-UI startup smoke skipped (agy binary not in path)"
fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

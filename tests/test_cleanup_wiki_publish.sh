#!/bin/bash
# test_cleanup_wiki_publish.sh — Regression test: wiki-publish automatic deletion is disabled.
#
# Contract:
# Automatic wiki-publish deletion is removed entirely until lifecycle provenance is known.
# Old-unknown, active, protected, recent, and advice entries must all survive both
# --dry-run and --clean invocations of cleanup_dev_caches.sh, and both invocations must exit 0.
set -euo pipefail
export PATH="/bin:/usr/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_dev_caches.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d -t test_wiki_publish.XXXXXX)
trap 'chmod -R u+rwx "$TMP_DIR" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS  $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $desc" >&2
    FAIL=$(( FAIL + 1 ))
  fi
}

echo "=== test_cleanup_wiki_publish.sh ==="

MOCK_HOME="$TMP_DIR/mock_home"
WIKI_DIR="$MOCK_HOME/.cache/wiki-publish"
mkdir -p "$WIKI_DIR/old-unknown" \
         "$WIKI_DIR/active" \
         "$WIKI_DIR/protected" \
         "$WIKI_DIR/recent" \
         "$WIKI_DIR/advice" \
         "$MOCK_HOME/.config/disk-magician"

echo "payload" > "$WIKI_DIR/old-unknown/f.txt"
echo "payload" > "$WIKI_DIR/active/f.txt"
echo "payload" > "$WIKI_DIR/protected/f.txt"
echo "payload" > "$WIKI_DIR/recent/f.txt"
echo "payload" > "$WIKI_DIR/advice/f.txt"

# Set mtime of old-unknown to 60 days ago
python3 -c '
import os, time, sys
t = time.time() - 60 * 86400
p = sys.argv[1]
os.utime(p, (t, t))
os.utime(os.path.join(p, "f.txt"), (t, t))
' "$WIKI_DIR/old-unknown"

# Configure safety rule for protected entry
cat > "$MOCK_HOME/.config/disk-magician/safety.local.json" <<EOF
{
  "never_delete": [
    {"path": "~/.cache/wiki-publish/protected", "reason": "test protected entry"}
  ]
}
EOF

# Hold active file open in background to test active entry survival
exec 3< "$WIKI_DIR/active/f.txt"

# Run 1: --dry-run
echo "Test 1: --dry-run does not delete or schedule deletion of wiki-publish entries"
DRY_OUT="$TMP_DIR/dry_run.out"
set +e
HOME="$MOCK_HOME" /bin/bash "$SCRIPT" --dry-run >"$DRY_OUT" 2>&1
RC_DRY=$?
set -e

check "dry-run exits 0" test "$RC_DRY" -eq 0
check "old-unknown survives dry-run" test -d "$WIKI_DIR/old-unknown"
check "active survives dry-run" test -d "$WIKI_DIR/active"
check "protected survives dry-run" test -d "$WIKI_DIR/protected"
check "recent survives dry-run" test -d "$WIKI_DIR/recent"
check "advice survives dry-run" test -d "$WIKI_DIR/advice"

# Must NOT report "would delete" for any wiki-publish entry
if grep -q "would delete .*wiki-publish" "$DRY_OUT"; then
  echo "  FAIL  dry-run planned deletion of wiki-publish entries" >&2
  FAIL=$(( FAIL + 1 ))
else
  echo "  PASS  dry-run did not plan deletion of wiki-publish entries"
  PASS=$(( PASS + 1 ))
fi

# Run 2: --clean
echo "Test 2: --clean preserves all wiki-publish entries (automatic deletion removed)"
CLEAN_OUT="$TMP_DIR/clean.out"
set +e
HOME="$MOCK_HOME" /bin/bash "$SCRIPT" --clean >"$CLEAN_OUT" 2>&1
RC_CLEAN=$?
set -e

check "clean exits 0" test "$RC_CLEAN" -eq 0
check "old-unknown survives clean" test -d "$WIKI_DIR/old-unknown"
check "active survives clean" test -d "$WIKI_DIR/active"
check "protected survives clean" test -d "$WIKI_DIR/protected"
check "recent survives clean" test -d "$WIKI_DIR/recent"
check "advice survives clean" test -d "$WIKI_DIR/advice"

# Close background fd
exec 3<&-

# Verify retention log message is emitted
if grep -qE "(retained|disabled|retention|lifecycle)" "$CLEAN_OUT"; then
  echo "  PASS  retention log message present in clean output"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  retention log message missing from clean output" >&2
  FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

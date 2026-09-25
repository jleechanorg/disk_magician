#!/usr/bin/env bash
# test_sweeper_health_ledger_warn.sh — proves sweeper_health_check.sh WARNs
# and exits 1 when check_ledger_freshness.sh reports STALE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/sweeper_health_check.sh"

TMP_ROOT=$(mktemp -d -t sweeper_health_ledger_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
# sweeper_health_check.sh hard-fails before reaching any sweeper logic if
# $HOME/Library/LaunchAgents does not exist (see its own plist-dir guard).
# The fake $HOME below needs that directory present (empty is fine — 0
# plists) so the run actually reaches the ledger-freshness check.
mkdir -p "$TMP_ROOT/home/Library/LaunchAgents"
cat > "$FAKE_BIN/check_ledger_freshness.sh" <<'MOCK'
#!/usr/bin/env bash
echo -e "STALE\tno_published_ledger_commit"
exit 1
MOCK
chmod +x "$FAKE_BIN/check_ledger_freshness.sh"
cp "$TARGET" "$FAKE_BIN/sweeper_health_check.sh"
chmod +x "$FAKE_BIN/sweeper_health_check.sh"

# sweeper_health_check.sh resolves its own SCRIPT_DIR internally, so the
# stub above only wins if it is invoked via the copy that resolves
# check_ledger_freshness.sh relative to $FAKE_BIN, which is the case here
# because both files are copied into the same directory.
set +e
OUTPUT="$(cd "$FAKE_BIN" && DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state" HOME="$TMP_ROOT/home" ./sweeper_health_check.sh --no-notify 2>&1)"
RC=$?
set -e

PASS=0
FAIL=0
# Assert the stub's unique reason string, not just the generic "stale" text
# in the production label — the label alone would also match an UNKNOWN
# result, an absent helper, or the real host's own stale ledger, so it
# can't prove this specific stub actually ran.
if echo "$OUTPUT" | grep -qiE '\[WARN\].*ledger' && echo "$OUTPUT" | grep -qF "no_published_ledger_commit"; then
  echo "  PASS  emits a WARN line mentioning ledger, carrying the stub's reason"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  no WARN line mentioning ledger + the stub's reason found in:"
  echo "$OUTPUT"
  FAIL=$(( FAIL + 1 ))
fi
if [[ "$RC" == "1" ]]; then
  echo "  PASS  exits 1 when ledger is stale"
  PASS=$(( PASS + 1 ))
else
  echo "  FAIL  exit code was $RC, expected 1"
  FAIL=$(( FAIL + 1 ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All sweeper_health_ledger_warn tests passed."

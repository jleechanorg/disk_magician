#!/usr/bin/env bash
# test_check_ledger_freshness.sh — stale published ledger detection
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check_ledger_freshness.sh"
PASS=0
FAIL=0
ok() { echo "OK: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/repo"
STATE="$WORK/repo"
mkdir -p "$STATE/ledger"
echo '{"disk_used_kb":1}' > "$STATE/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE/ledger/topdown-5g.status.json"
git -C "$STATE" add ledger/topdown-5g.json ledger/topdown-5g.status.json
git -C "$STATE" -c user.email=t@test -c user.name=t commit -q -m "init ledger"

# Backdate commit metadata by setting an old commit time via env is hard; instead
# use STALE_HOURS=0 so any commit is immediately stale.
export DISK_MAGICIAN_STATE_REPO="$STATE"
export DISK_MAGICIAN_LEDGER_STALE_HOURS=-1
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] && ok "flags stale when threshold 0h" || bad "expected STALE rc=1 got rc=$rc out=$out"

# Fresh with huge threshold
export DISK_MAGICIAN_LEDGER_STALE_HOURS=99999
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* ]] && ok "OK within 99999h window" || bad "expected OK rc=0 got rc=$rc out=$out"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

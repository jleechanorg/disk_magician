#!/usr/bin/env bash
# test_install_root_frontier_runner.sh — test root frontier runner installer contract
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

echo "── 1. Installer CLI dry-run and help ──"
OUT=$("$REPO_ROOT/scripts/install_root_frontier_runner.sh" --help)
echo "$OUT" | grep -q "Usage:" && ok "help displays usage" || bad "help display" "$OUT"

OUT_DRY=$("$REPO_ROOT/scripts/install_root_frontier_runner.sh" --dry-run)
echo "$OUT_DRY" | grep -q "/usr/local/libexec/disk-magician" && ok "dry-run names immutable libexec path" || bad "dry-run libexec" "$OUT_DRY"
echo "$OUT_DRY" | grep -q "com.jleechanorg.disk-magician-frontier-root.plist" && ok "dry-run names daemon plist" || bad "dry-run plist" "$OUT_DRY"

echo "── 2. Plist template structural invariants ──"
PLIST="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-frontier-root.plist.template"
[[ -f "$PLIST" ]] && ok "plist template exists" || bad "plist missing" "$PLIST"

grep -q '<string>root</string>' "$PLIST" && ok "plist runs as root" || bad "plist user" "not root"
grep -q '/usr/local/libexec/disk-magician/disk_frontier_scan.py' "$PLIST" && ok "plist points to immutable binary" || bad "plist binary" "not libexec"
grep -q 'DISK_MAGICIAN_SCAN_USER_HOME' "$PLIST" && ok "plist declares scan user home env var" || bad "plist env" "missing scan user home"
! grep -q '@REPO_ROOT@' "$PLIST" && ok "plist contains zero checkout repository references" || bad "plist checkout ref" "contains @REPO_ROOT@"
! grep -q '@HOME@' "$PLIST" && ok "plist contains zero user HOME references in binary path" || bad "plist home ref" "contains @HOME@"

echo "── 3. Non-root refusal ──"
RC=0
OUT_NON_ROOT=$("$REPO_ROOT/scripts/install_root_frontier_runner.sh" 2>&1) || RC=$?
[[ $RC -ne 0 ]] && ok "refuses non-root execution" || bad "non-root refusal" "exited 0"
echo "$OUT_NON_ROOT" | grep -q "must be run as root" && ok "prints root requirement error" || bad "error message" "$OUT_NON_ROOT"

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

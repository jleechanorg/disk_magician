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

echo "$OUT_DRY" | grep -q "$REPO_ROOT/launchd/diskm_root_launcher.c" && ok "dry-run names FDA launcher source" || bad "dry-run launcher" "$OUT_DRY"

OUT_DRY_NOW=$("$REPO_ROOT/scripts/install_root_frontier_runner.sh" --dry-run --run-now)
! echo "$OUT_DRY" | grep -q "Would kickstart" && ok "default dry-run does not request immediate start" || bad "default run-now" "$OUT_DRY"
echo "$OUT_DRY_NOW" | grep -q "Would kickstart system/com.jleechanorg.disk-magician-frontier-root after bootstrap" \
  && ok "run-now dry-run names exact system service" || bad "run-now dry-run label" "$OUT_DRY_NOW"
KICKSTART_CALLS=
KICKSTART_RC=0
launchctl() { KICKSTART_CALLS="$*"; return "$KICKSTART_RC"; }
source "$REPO_ROOT/scripts/lib/frontier_runner_launchd.sh"
frontier_root_runner_after_bootstrap false
[[ -z "$KICKSTART_CALLS" ]] && ok "default post-bootstrap path does not kickstart" || bad "default kickstart" "$KICKSTART_CALLS"
frontier_root_runner_after_bootstrap true
[[ "$KICKSTART_CALLS" == "kickstart system/com.jleechanorg.disk-magician-frontier-root" ]] \
  && ok "run-now targets exact service without restart flag" \
  || bad "kickstart target" "$KICKSTART_CALLS"
KICKSTART_RC=23
RC=0
( frontier_root_runner_after_bootstrap true ) || RC=$?
[[ "$RC" -eq 23 ]] && ok "kickstart failure propagates" || bad "kickstart failure status" "rc=$RC"

echo "── 2. Plist template structural invariants ──"
PLIST="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-frontier-root.plist.template"
[[ -f "$PLIST" ]] && ok "plist template exists" || bad "plist missing" "$PLIST"

grep -q '<string>root</string>' "$PLIST" && ok "plist runs as root" || bad "plist user" "not root"
grep -q '<string>/usr/local/libexec/disk-magician/diskm</string>' "$PLIST" && ok "plist runs immutable FDA launcher" || bad "plist binary" "not libexec launcher"
! grep -q '/usr/bin/python3' "$PLIST" && ok "plist does not bypass launcher" || bad "plist python" "invokes python directly"
grep -q 'DISK_MAGICIAN_SCAN_USER_HOME' "$PLIST" && ok "plist declares scan user home env var" || bad "plist env" "missing scan user home"
! grep -q '@REPO_ROOT@' "$PLIST" && ok "plist contains zero checkout repository references" || bad "plist checkout ref" "contains @REPO_ROOT@"
! grep -q '@HOME@' "$PLIST" && ok "plist contains zero user HOME references in binary path" || bad "plist home ref" "contains @HOME@"
grep -q '@USER_HOME@' "$PLIST" && ok "plist uses explicit @USER_HOME@ placeholder" || bad "plist user home" "missing @USER_HOME@"

echo "── 3. Non-root refusal ──"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  RC=0
  OUT_NON_ROOT=$("$REPO_ROOT/scripts/install_root_frontier_runner.sh" 2>&1) || RC=$?
  [[ $RC -ne 0 ]] && ok "refuses non-root execution" || bad "non-root refusal" "exited 0"
  echo "$OUT_NON_ROOT" | grep -q "must be run as root" && ok "prints root requirement error" || bad "error message" "$OUT_NON_ROOT"
else
  ok "skipping non-root check when running as root"
  ok "root execution mode active"
fi

echo "── 3b. Launcher compiles and refuses non-root ──"
LTMP="$(mktemp -d)"
if clang -Wall -Werror -o "$LTMP/diskm" "$REPO_ROOT/launchd/diskm_root_launcher.c" 2>"$LTMP/cc.log"; then
  ok "launcher compiles warning-free"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    RC=0; "$LTMP/diskm" --help >/dev/null 2>&1 || RC=$?
    [[ $RC -eq 77 ]] && ok "launcher refuses non-root (77)" || bad "launcher non-root" "rc=$RC"
  fi
else
  bad "launcher compile" "$(cat "$LTMP/cc.log")"
fi
rm -rf "$LTMP"

echo "── 4. Symlink-ancestor rejection (TOCTOU/privilege-escalation guard) ──"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
ATTACKER_DIR="$TMPD/attacker-controlled"
mkdir -p "$ATTACKER_DIR"
FAKE_LIBEXEC_PARENT="$TMPD/usr-local-libexec"
mkdir -p "$FAKE_LIBEXEC_PARENT"
ln -s "$ATTACKER_DIR" "$FAKE_LIBEXEC_PARENT/disk-magician"

RC=0
OUT_SYMLINK=$(DISK_MAGICIAN_LIBEXEC_DIR="$FAKE_LIBEXEC_PARENT/disk-magician" \
  DISK_MAGICIAN_STATE_DIR="$TMPD/state" \
  "$REPO_ROOT/scripts/install_root_frontier_runner.sh" --dry-run 2>&1) || RC=$?
[[ $RC -ne 0 ]] && ok "refuses to install through a pre-planted symlink" \
  || bad "symlink rejection" "exited 0 with LIBEXEC_DIR as symlink: $OUT_SYMLINK"
echo "$OUT_SYMLINK" | grep -q "refusing to install through symlink" \
  && ok "prints symlink refusal error" || bad "symlink error message" "$OUT_SYMLINK"

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

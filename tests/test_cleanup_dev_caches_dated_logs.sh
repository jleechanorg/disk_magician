#!/usr/bin/env bash
# test_cleanup_dev_caches_dated_logs.sh — rotated dated log dirs and the
# GoogleUpdater crx_cache are owned by cleanup_dev_caches.sh (fixture HOME only).
#
# Contract: dated leaf dirs (YYYY.MM.DD or YYYY/MM/DD) older than 7 days under
# ~/.config/gcloud/logs and ~/Library/Logs/com.openai.codex are removed; fresh
# ones and their year/month parents are kept; crx_cache contents go; the
# deletion ledger ~/Library/Logs/disk-magician-deletions.log is never touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_dev_caches.sh"

WORK="$(cd "$(mktemp -d -t test_dev_caches_dated.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

backdate() {  # <path> <days>
  local ts
  ts=$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "-$2 days" +%Y%m%d%H%M)
  touch -t "$ts" "$1"
}

mkhome() {
  local h="$1" g="$1/.config/gcloud/logs" c="$1/Library/Logs/com.openai.codex"
  local u="$1/Library/Application Support/Google/GoogleUpdater/crx_cache"
  mkdir -p "$h/.config/disk-magician" "$g/2020.01.01" "$g/2026.10.21" "$c/2026/10/01" "$c/2026/10/21" "$u"
  printf '{}\n' >"$h/.config/disk-magician/safety.local.json"
  printf 'x\n' >"$g/2020.01.01/a.log"; printf 'x\n' >"$g/2026.10.21/a.log"
  printf 'x\n' >"$c/2026/10/01/a.log"; printf 'x\n' >"$c/2026/10/21/a.log"
  printf 'x\n' >"$u/blob"
  printf 'ledger\n' >"$h/Library/Logs/disk-magician-deletions.log"
  backdate "$g/2020.01.01/a.log" 30; backdate "$g/2020.01.01" 30
  backdate "$c/2026/10/01/a.log" 30; backdate "$c/2026/10/01" 30
  backdate "$c/2026/10" 30; backdate "$c/2026" 30   # parents look old but hold fresh logs
  backdate "$u/blob" 30
}

run() {
  local h="$1"; shift
  HOME="$h" DISK_MAGICIAN_SAFETY_FILE="$h/.config/disk-magician/safety.local.json" \
    DISK_MAGICIAN_TEST_SANDBOX="$h" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dev_caches_dated_logs \
    DISK_MAGICIAN_DELETION_LOG="$h/deletions.log" bash "$SCRIPT" "$@"
}

H="$WORK/h"; mkhome "$H"
G="$H/.config/gcloud/logs"; C="$H/Library/Logs/com.openai.codex"

echo "Test 1: dry-run names the stale dirs and deletes nothing"
rc=0; run "$H" --dry-run >"$WORK/t1.out" 2>&1 || rc=$?
check "dry-run exits 0" '[[ "$rc" -eq 0 ]]'
check "dry-run flags stale gcloud day dir" 'grep -qF "would delete $G/2020.01.01" "$WORK/t1.out"'
check "dry-run flags stale codex day dir" 'grep -qF "would delete $C/2026/10/01" "$WORK/t1.out"'
check "dry-run keeps everything" '[[ -d "$G/2020.01.01" && -d "$C/2026/10/01" && -f "$H/Library/Application Support/Google/GoogleUpdater/crx_cache/blob" ]]'

echo "Test 2: --clean removes only stale dated dirs and the crx_cache contents"
rc=0; run "$H" --clean >"$WORK/t2.out" 2>&1 || rc=$?
check "clean exits 0" '[[ "$rc" -eq 0 ]]'
check "stale gcloud day dir gone" '[[ ! -e "$G/2020.01.01" ]]'
check "stale codex day dir gone" '[[ ! -e "$C/2026/10/01" ]]'
check "fresh gcloud day dir kept" '[[ -f "$G/2026.10.21/a.log" ]]'
check "fresh codex day dir kept" '[[ -f "$C/2026/10/21/a.log" ]]'
check "old-looking year/month parents kept" '[[ -d "$C/2026/10" && -d "$C/2026" ]]'
check "crx_cache contents gone, dir kept" '[[ -d "$H/Library/Application Support/Google/GoogleUpdater/crx_cache" && ! -e "$H/Library/Application Support/Google/GoogleUpdater/crx_cache/blob" ]]'
check "deletion ledger untouched" '[[ "$(cat "$H/Library/Logs/disk-magician-deletions.log")" == ledger ]]'

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

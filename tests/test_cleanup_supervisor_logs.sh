#!/usr/bin/env bash
# test_cleanup_supervisor_logs.sh — the cleanup-supervisor-logs seam.
#
# Contract (bead disk_magician-cleanup-cli-gaps-v8kd): rotated
# cmux-codex-launchd logs are pruned through the single `diskm` entry point,
# not by invoking scripts/cleanup_supervisor_logs.sh directly. The dispatcher
# must forward arguments and exit status, and the script itself must keep the
# active log, stderr log, and state file while removing only timestamped
# rotations older than its 7-day threshold (safety rules always win).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_supervisor_logs.sh"

WORK="$(cd "$(mktemp -d -t test_cleanup_supervisor_logs.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

# backdate <path> <days>
backdate() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
t = time.time() - float(sys.argv[2]) * 86400
os.utime(sys.argv[1], (t, t))
PY
}

echo "Test 1: dispatcher forwards arguments and exit status"
for tree in "$REPO_ROOT" "$REPO_ROOT/src/disk_magician"; do
  [[ -f "$tree/disk_magician.sh" ]] || continue
  fixture="$WORK/fixture-$(basename "$tree")"
  mkdir -p "$fixture/scripts"
  cp "$tree/disk_magician.sh" "$fixture/disk_magician.sh"
  cat >"$fixture/scripts/cleanup_supervisor_logs.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
exit 23
EOF
  chmod +x "$fixture/scripts/cleanup_supervisor_logs.sh"
  args=(--clean --days 3)
  rc=0
  out="$(HOME="$WORK/home" bash "$fixture/disk_magician.sh" cleanup-supervisor-logs "${args[@]}" 2>&1)" || rc=$?
  check "$(basename "$tree"): cleanup-supervisor-logs forwards args verbatim" '[[ "$out" == $'"'"'--clean\n--days\n3'"'"' ]]'
  check "$(basename "$tree"): cleanup-supervisor-logs forwards exit status" '[[ "$rc" -eq 23 ]]'
  help="$(HOME="$WORK/home" bash "$fixture/disk_magician.sh" --help 2>&1 || true)"
  check "$(basename "$tree"): help lists cleanup-supervisor-logs" 'grep -q "cleanup-supervisor-logs" <<<"$help"'
done

echo "Test 2: sandboxed retention"
H="$WORK/home"; SUP="$H/.claude/supervisor"
mkdir -p "$SUP" "$H/.config/disk-magician"
printf '{}\n' >"$H/.config/disk-magician/safety.local.json"
STALE="$SUP/cmux-codex-launchd.20260101T000000.log"
RECENT="$SUP/cmux-codex-launchd.20260116T000000.log"
ACTIVE="$SUP/cmux-codex-launchd.log"
ERR="$SUP/cmux-codex-launchd.stderr.log"
STATE="$SUP/cmux-codex-launchd-state.json"
for f in "$STALE" "$RECENT" "$ACTIVE" "$ERR"; do printf 'log line\n' >"$f"; done
printf '{}\n' >"$STATE"
backdate "$STALE" 10
backdate "$RECENT" 2

run() {
  HOME="$H" DISK_MAGICIAN_SAFETY_FILE="$H/.config/disk-magician/safety.local.json" \
    DISK_MAGICIAN_TEST_SANDBOX="$H" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_supervisor_logs \
    DISK_MAGICIAN_DELETION_LOG="$WORK/deletions.log" bash "$SCRIPT" "$@"
}

rc=0; run --dry-run >"$WORK/dry.out" 2>&1 || rc=$?
check "dry-run exits 0" '[[ "$rc" -eq 0 ]]'
check "dry-run keeps the stale rotation" '[[ -f "$STALE" ]]'
check "dry-run reports the would-remove" 'grep -qF "would remove: $STALE" "$WORK/dry.out"'

rc=0; run --clean >"$WORK/clean.out" 2>&1 || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "--clean removes the stale rotation" '[[ ! -e "$STALE" ]]'
check "--clean keeps a recent rotation" '[[ -f "$RECENT" ]]'
check "--clean keeps the active log" '[[ -f "$ACTIVE" ]]'
check "--clean keeps the stderr log" '[[ -f "$ERR" ]]'
check "--clean keeps the state file" '[[ -f "$STATE" ]]'

echo "Test 3: a safety rule preserves an otherwise stale rotation (fail closed)"
H3="$WORK/home3"; SUP3="$H3/.claude/supervisor"
mkdir -p "$SUP3" "$H3/.config/disk-magician"
PROT="$SUP3/cmux-codex-launchd.20260101T000000.log"
printf 'log line\n' >"$PROT"
backdate "$PROT" 10
printf '{"never_delete": ["~/.claude/supervisor/cmux-codex-launchd.2026*.log"]}\n' \
  >"$H3/.config/disk-magician/safety.local.json"
rc=0
HOME="$H3" DISK_MAGICIAN_SAFETY_FILE="$H3/.config/disk-magician/safety.local.json" \
  DISK_MAGICIAN_TEST_SANDBOX="$H3" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_supervisor_logs \
  DISK_MAGICIAN_DELETION_LOG="$WORK/deletions3.log" bash "$SCRIPT" --clean >"$WORK/protected.out" 2>&1 || rc=$?
check "protected rotation survives --clean" '[[ -f "$PROT" ]]'
check "protection is reported" 'grep -q "SAFETY-SKIP" "$WORK/protected.out"'

echo "Test 4: unreadable safety file fails closed"
H4="$WORK/home4"; SUP4="$H4/.claude/supervisor"
mkdir -p "$SUP4" "$H4/.config/disk-magician"
F4="$SUP4/cmux-codex-launchd.20260101T000000.log"
printf 'log line\n' >"$F4"
backdate "$F4" 10
printf 'not json\n' >"$H4/.config/disk-magician/safety.local.json"
HOME="$H4" DISK_MAGICIAN_SAFETY_FILE="$H4/.config/disk-magician/safety.local.json" \
  DISK_MAGICIAN_TEST_SANDBOX="$H4" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_supervisor_logs \
  DISK_MAGICIAN_DELETION_LOG="$WORK/deletions4.log" bash "$SCRIPT" --clean >"$WORK/unreadable.out" 2>&1 || true
check "unreadable safety file preserves the rotation" '[[ -f "$F4" ]]'

echo "Test 5: no supervisor dir is a no-op"
rc=0
HOME="$WORK/emptyhome" DISK_MAGICIAN_TEST_SANDBOX="$WORK/emptyhome" \
  DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_supervisor_logs \
  DISK_MAGICIAN_DELETION_LOG="$WORK/deletions5.log" bash "$SCRIPT" --clean >"$WORK/empty.out" 2>&1 || rc=$?
check "missing dir exits 0" '[[ "$rc" -eq 0 ]]'
check "missing dir logs nothing to do" 'grep -q "nothing to do" "$WORK/empty.out"'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

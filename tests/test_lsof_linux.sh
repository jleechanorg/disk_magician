#!/usr/bin/env bash
# Tests for scripts/lib/lsof_linux.sh (Linux lsof interpretation for cwd gates).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/lsof_linux.sh
source "$REPO_ROOT/scripts/lib/lsof_linux.sh"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== lsof_stderr_incomplete =="
mount_warn=$'lsof: WARNING: can\'t stat() tracefs file system /sys/kernel/debug/tracing\n      Output information may be incomplete.'
lsof_stderr_incomplete "" && bad "empty stderr flagged" || ok "empty stderr is complete"
lsof_stderr_incomplete "$mount_warn" && bad "mount-stat warning flagged" || ok "mount-stat warning alone is complete"
lsof_stderr_incomplete "$mount_warn"$'\nlsof: WARNING: can\'t open /proc/42/fd: Permission denied' && ok "other warning still incomplete" || bad "other warning ignored"
lsof_stderr_incomplete $'      Output information may be incomplete.\nlsof: WARNING: can\'t stat() file /home/x/wt: No such file' && ok "non-mount stat warning still incomplete" || bad "non-mount stat warning ignored"

if [[ -d /proc/self ]]; then
  echo "== lsof_drop_foreign_denied (Linux) =="
  sleep 30 & own=$!
  dead=999999; while [[ -e /proc/$dead ]]; do dead=$((dead - 1)); done
  input=$(printf 'n/proc/1/cwd (readlink: Permission denied)\nn/proc/%s/cwd (readlink: Permission denied)\nn/proc/%s/cwd (readlink: Permission denied)\nn/home/x\n' "$dead" "$own")
  out=$(lsof_drop_foreign_denied <<<"$input" 2>/dev/null)
  if [[ "$(stat -c %u /proc/1)" != "$(id -u)" ]]; then
    grep -q '^n/proc/1/cwd' <<<"$out" && bad "foreign (pid 1) denied line kept" || ok "foreign denied line dropped"
  fi
  grep -q "^n/proc/$dead/cwd" <<<"$out" && bad "exited pid line kept" || ok "exited pid line dropped"
  grep -q "^n/proc/$own/cwd" <<<"$out" && ok "own denied line kept (fail closed)" || bad "own denied line dropped without approval"
  grep -qx 'n/home/x' <<<"$out" && ok "normal cwd record passes through" || bad "normal cwd record lost"
  out=$(DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED=1 lsof_drop_foreign_denied <<<"$input" 2>/dev/null)
  grep -q "^n/proc/$own/cwd" <<<"$out" && bad "approved own denied line kept" || ok "explicit approval drops own denied line"
  kill "$own" 2>/dev/null
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

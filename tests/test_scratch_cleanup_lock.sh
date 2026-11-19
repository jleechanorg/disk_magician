#!/usr/bin/env bash
# Cleanup jobs should run without waiting for the retired whole-job lock.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_CLEANER="$REPO_ROOT/scripts/cleanup_tmp.sh"
PR_CLEANER="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test_scratch_nonblocking.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
STATE="$ROOT/state"
TMP="$ROOT/tmp"
LOCK="$STATE/.disk_magician_locks/scratch_cleanup.lock"
READY="$ROOT/lock-ready"
RELEASE="$ROOT/release-lock"
PASS=0
FAIL=0
HOLDER_PID=""
CLEANER_PIDS=()

ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }
wait_for_file() {
  for _ in {1..200}; do [[ -e "$1" ]] && return 0; sleep 0.025; done
  return 1
}
cleanup() {
  touch "$RELEASE"
  for pid in "${CLEANER_PIDS[@]+"${CLEANER_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "$HOLDER_PID" ]]; then
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  python3 -c 'import shutil,sys; p=sys.argv[1]; assert p.startswith("/tmp/test_scratch_nonblocking."); shutil.rmtree(p)' "$ROOT"
}
trap cleanup EXIT

mkdir -m 0700 -p "$STATE/.disk_magician_locks" "$TMP"
LOCK_ROOT="$ROOT/no-lock-home"
mkdir -m 0700 -p "$LOCK_ROOT"
export DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=0
export DISK_MAGICIAN_TEST_SANDBOX="$ROOT"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP"
export DISK_MAGICIAN_TMP_DIR="$TMP"
export DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*'
export DISK_MAGICIAN_PR_SCRATCH_ROOTS="$TMP"

# Hold a legacy lock exactly as an older or unrelated process could.
python3 - "$LOCK" "$READY" "$RELEASE" <<'PY' &
import fcntl
import os
import sys
import time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.01)
PY
HOLDER_PID=$!
wait_for_file "$READY" || { bad "legacy lock holder started"; exit 1; }
ok "legacy lock holder started"

echo "=== cleanup entrypoints run while the legacy lock is held ==="
HOME="$STATE" bash "$TMP_CLEANER" --clean >"$ROOT/tmp.out" 2>&1 &
CLEANER_PIDS+=("$!")
HOME="$STATE" bash "$PR_CLEANER" --clean --tmp-dir "$TMP" --min-age-hours 48 >"$ROOT/pr.out" 2>&1 &
CLEANER_PIDS+=("$!")

TMP_RC=0
PR_RC=0
wait "${CLEANER_PIDS[0]}" || TMP_RC=$?
wait "${CLEANER_PIDS[1]}" || PR_RC=$?
CLEANER_PIDS=()
[[ "$TMP_RC" == 0 ]] && ok "cleanup_tmp completes while legacy lock is held" || { bad "cleanup_tmp completes while legacy lock is held (rc=$TMP_RC)"; tail -8 "$ROOT/tmp.out"; }
[[ "$PR_RC" == 0 ]] && ok "cleanup_pr_scratch completes while legacy lock is held" || { bad "cleanup_pr_scratch completes while legacy lock is held (rc=$PR_RC)"; tail -8 "$ROOT/pr.out"; }

touch "$RELEASE"
wait "$HOLDER_PID"
HOLDER_PID=""
[[ -f "$LOCK" ]] && ok "existing lock file is left untouched" || bad "existing lock file is left untouched"

# The compatibility dispatcher forwards arguments and preserves the child's exit status.
set +e
HOME="$LOCK_ROOT" python3 "$REPO_ROOT/scripts/scratch_lock.py" run --caller test --script /bin/sh --args -- -c 'exit 23'
DISPATCH_RC=$?
set -e
[[ "$DISPATCH_RC" == 23 ]] && ok "legacy dispatcher immediately forwards the command and status" || bad "legacy dispatcher immediately forwards the command and status (rc=$DISPATCH_RC)"
[[ ! -e "$LOCK_ROOT/.disk_magician_locks/scratch_cleanup.lock" ]] && ok "new invocations create no shared lock file" || bad "new invocations create no shared lock file"

echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

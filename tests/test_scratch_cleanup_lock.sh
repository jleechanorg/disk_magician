#!/usr/bin/env bash
# Focused integration tests for kernel flock serialization of scratch cleanup.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_TMP_BIN="$REPO_ROOT/scripts/cleanup_tmp.sh"
CLEANUP_PR_BIN="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"
ROOT=$(mktemp -d -t test_scratch_lock.XXXXXX)
ROOT=$(cd "$ROOT" && pwd -P)
cleanup() {
  rm -f "$ROOT/pause"
  if [[ -n "${HOLDER_PID:-}" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
record() {
  if [[ "$1" == pass ]]; then PASS=$((PASS + 1)); echo "  PASS  $2";
  else FAIL=$((FAIL + 1)); echo "  FAIL  $2" >&2; fi
}
wait_for_file() {
  for _ in {1..200}; do [[ -e "$1" ]] && return 0; sleep 0.025; done
  return 1
}

# A scanner child pauses while retaining the inherited lock descriptor.
mkdir -p "$ROOT/bin"
export REAL_FIND=$(command -v find)
cat > "$ROOT/bin/find" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${TEST_INHERITED_CONTENDER:-}" ]]; then
  unset TEST_INHERITED_CONTENDER
  bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$TEST_CHILD_TMP" >"$TEST_CHILD_OUT" 2>&1
  echo "$?" >"$TEST_CHILD_RC"
fi
if [[ -n "${TEST_PAUSE_FILE:-}" && -f "$TEST_PAUSE_FILE" ]]; then
  touch "$TEST_PAUSED_FILE"
  while [[ -f "$TEST_PAUSE_FILE" ]]; do sleep 0.025; done
fi
exec "$REAL_FIND" "$@"
EOF
chmod +x "$ROOT/bin/find"
export PATH="$ROOT/bin:$PATH"
export DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find"
export DISK_MAGICIAN_TEST_SANDBOX="$ROOT"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$ROOT"
export DISK_MAGICIAN_PR_SCRATCH_ROOTS="$ROOT"
export DISK_MAGICIAN_TEST_CONTEXT=1
export CLEANUP_PR_BIN

echo "=== scratch cleanup kernel-lock integration tests ==="

# Lock placement is fixed under the verified per-user HOME, independent of
# the cleanup state-root override. The two settings may vary without splitting locks.
DEFAULT="$ROOT/default"; mkdir -m 0700 -p "$DEFAULT/home" "$DEFAULT/alternate-state"
for state in unset alternate; do
  if [[ "$state" == unset ]]; then
    (umask 0002; HOME="$DEFAULT/home" python3 "$REPO_ROOT/scripts/scratch_lock.py" run --caller probe --script /usr/bin/true --args --)
  else
    (umask 0002; HOME="$DEFAULT/home" DISK_MAGICIAN_STATE_DIR="$DEFAULT/alternate-state" python3 "$REPO_ROOT/scripts/scratch_lock.py" run --caller probe --script /usr/bin/true --args --)
  fi
  [[ -f "$DEFAULT/home/.disk_magician_locks/scratch_cleanup.lock" && ! -e "$DEFAULT/alternate-state/.disk_magician_locks/scratch_cleanup.lock" ]] && record pass "$state state root still uses per-user lock" || record fail "$state state root still uses per-user lock"
done
[[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$DEFAULT/home/.disk_magician_locks")" == 0o700 ]] && record pass "umask 0002 creates root mode 0700" || record fail "umask 0002 creates root mode 0700"
[[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$DEFAULT/home/.disk_magician_locks/scratch_cleanup.lock")" == 0o600 ]] && record pass "default lock file mode 0600" || record fail "default lock file mode 0600"
chmod 0755 "$DEFAULT/home/.disk_magician_locks"
if HOME="$DEFAULT/home" python3 "$REPO_ROOT/scripts/scratch_lock.py" run --caller probe --script /usr/bin/true --args -- >/dev/null 2>&1; then
  record fail "existing public lock root fails closed"
else
  [[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$DEFAULT/home/.disk_magician_locks")" == 0o755 ]] && record pass "existing public lock root fails closed without chmod" || record fail "existing public lock root fails closed without chmod"
fi

# Both real entrypoints reject the other while its find child is paused.
for holder in tmp pr; do
  CASE="$ROOT/contend_$holder"
  STATE="$CASE/state"; TMP="$CASE/tmp"
  mkdir -p "$STATE" "$TMP"
  touch "$ROOT/pause"
  if [[ "$holder" == tmp ]]; then
    HOME="$STATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP" TEST_PAUSE_FILE="$ROOT/pause" \
      TEST_PAUSED_FILE="$CASE/paused" bash "$CLEANUP_TMP_BIN" --clean >"$CASE/holder.out" 2>&1 &
    HOLDER_PID=$!
    wait_for_file "$CASE/paused" || record fail "$holder reached paused scanner"
    set +e
    DISK_MAGICIAN_STATE_DIR="$CASE/alternate-state" HOME="$STATE" bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$TMP" >"$CASE/contender.out" 2>&1
    rc=$?
    set -e
  else
    HOME="$STATE" DISK_MAGICIAN_TMP_DIR="$TMP" DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" TEST_PAUSE_FILE="$ROOT/pause" TEST_PAUSED_FILE="$CASE/paused" \
      bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$TMP" --min-age-hours 0 >"$CASE/holder.out" 2>&1 &
    HOLDER_PID=$!
    wait_for_file "$CASE/paused" || record fail "$holder reached paused scanner"
    set +e
    DISK_MAGICIAN_STATE_DIR="$CASE/alternate-state" HOME="$STATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP" bash "$CLEANUP_TMP_BIN" --clean >"$CASE/contender.out" 2>&1
    rc=$?
    set -e
  fi
  [[ $rc -eq 1 ]] && grep -q "scratch lock held" "$CASE/contender.out" && record pass "$holder blocks the other entrypoint" || record fail "$holder blocks the other entrypoint (rc=$rc)"
  rm -f "$ROOT/pause"
  wait "$HOLDER_PID" || true
  HOLDER_PID=""
  if grep -q "cleanup_.*sh starting" "$CASE/holder.out" && ! grep -q "DRY RUN:" "$CASE/holder.out"; then
    record pass "$holder preserves --clean across lock re-exec"
  else
    record fail "$holder preserves --clean across lock re-exec"
  fi
  if [[ "$holder" == pr ]]; then
    grep -Fq "starting (roots: $TMP," "$CASE/holder.out" && record pass "pr preserves --tmp-dir across lock re-exec" || record fail "pr preserves --tmp-dir across lock re-exec"
  fi
done

if [[ $EUID -eq 0 ]]; then
  OWNER="$ROOT/unsafe_owner"; mkdir -p "$OWNER/state" "$OWNER/tmp/candidate"
  mkdir -m 0700 -p "$OWNER/state/.disk_magician_locks"
  touch "$OWNER/state/.disk_magician_locks/scratch_cleanup.lock"
  chown 1 "$OWNER/state/.disk_magician_locks/scratch_cleanup.lock"
  set +e
  HOME="$OWNER/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$OWNER/tmp" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$OWNER/tmp" bash "$CLEANUP_TMP_BIN" --clean >"$OWNER/out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 && -d "$OWNER/tmp/candidate" ]] && record pass "wrong-owner lock stops before scan" || record fail "wrong-owner lock stops before scan (rc=$rc)"
else
  echo "  SKIP  wrong-owner lock fixture requires root"
fi

# A scanner descendant inherits the FD but must not reuse its parent's identity.
CHILD="$ROOT/inherited"; mkdir -p "$CHILD/state" "$CHILD/tmp/candidate"
touch "$ROOT/pause"
HOME="$CHILD/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$CHILD/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$CHILD/tmp" TEST_PAUSE_FILE="$ROOT/pause" \
  TEST_PAUSED_FILE="$CHILD/paused" TEST_INHERITED_CONTENDER=1 TEST_CHILD_TMP="$CHILD/tmp" \
  TEST_CHILD_OUT="$CHILD/child.out" TEST_CHILD_RC="$CHILD/child.rc" \
  bash "$CLEANUP_TMP_BIN" --clean >"$CHILD/holder.out" 2>&1 &
HOLDER_PID=$!
wait_for_file "$CHILD/child.rc" && wait_for_file "$CHILD/paused" || record fail "inherited contender reached paused scanner"
[[ "$(cat "$CHILD/child.rc")" == 1 ]] && grep -q "scratch lock held" "$CHILD/child.out" && \
  [[ -d "$CHILD/tmp/candidate" ]] && record pass "descendant cannot reuse inherited lock" || record fail "descendant cannot reuse inherited lock"
set +e
HOME="$CHILD/state" bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$CHILD/tmp" >"$CHILD/independent.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] && grep -q "scratch lock held" "$CHILD/independent.out" && record pass "scanner child retains lock after descendant exits" || record fail "scanner child retains lock after descendant exits (rc=$rc)"
rm -f "$ROOT/pause"
wait "$HOLDER_PID" || true
HOLDER_PID=""
HOME="$CHILD/state" python3 "$REPO_ROOT/scripts/scratch_lock.py" run \
  --caller probe --script /usr/bin/true --args -- && record pass "real caller succeeds after scanner exits" || record fail "real caller succeeds after scanner exits"

# Unsafe lock objects and directories fail before either cleaner can scan.
for kind in symlink mode parent parent_symlink; do
  CASE="$ROOT/unsafe_$kind"; mkdir -p "$CASE/state" "$CASE/tmp/candidate"
  case "$kind" in
    symlink) mkdir -m 0700 -p "$CASE/state/.disk_magician_locks"; touch "$CASE/target"; ln -s "$CASE/target" "$CASE/state/.disk_magician_locks/scratch_cleanup.lock" ;;
    mode) mkdir -m 0700 -p "$CASE/state/.disk_magician_locks"; touch "$CASE/state/.disk_magician_locks/scratch_cleanup.lock"; chmod 0666 "$CASE/state/.disk_magician_locks/scratch_cleanup.lock" ;;
    parent) mkdir -m 0700 -p "$CASE/state/.disk_magician_locks"; chmod 0777 "$CASE/state/.disk_magician_locks" ;;
    parent_symlink) rm -rf "$CASE/state"; ln -s "$CASE/real_state" "$CASE/state"; mkdir -m 0700 -p "$CASE/real_state/.disk_magician_locks" ;;
  esac
  set +e
  HOME="$CASE/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$CASE/tmp" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$CASE/tmp" bash "$CLEANUP_TMP_BIN" --clean >"$CASE/out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 && -d "$CASE/tmp/candidate" ]] && record pass "$kind lock state stops before scan" || record fail "$kind lock state stops before scan (rc=$rc)"
done

# Dry-run ignores a lock file (including a directory at that pathname).
DRY="$ROOT/dry"; mkdir -m 0700 -p "$DRY/state/.disk_magician_locks" "$DRY/tmp"; mkdir "$DRY/state/.disk_magician_locks/scratch_cleanup.lock"
HOME="$DRY/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$DRY/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$DRY/tmp" bash "$CLEANUP_TMP_BIN" --dry-run >"$DRY.out" 2>&1
record pass "dry-run succeeds with lock pathname occupied by directory"

# Lock open failure is before any scan and preserves a candidate.
BAD="$ROOT/bad"; mkdir -m 0700 -p "$BAD/state/.disk_magician_locks" "$BAD/tmp/candidate"; mkdir "$BAD/state/.disk_magician_locks/scratch_cleanup.lock"
set +e
HOME="$BAD/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$BAD/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$BAD/tmp" bash "$CLEANUP_TMP_BIN" --clean >"$BAD.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 && -d "$BAD/tmp/candidate" ]] && record pass "lock open failure stops before scan" || record fail "lock open failure stops before scan (rc=$rc)"

# Kill the shell while its paused scanner child still owns the descriptor.
ORPHAN="$ROOT/orphan"; mkdir -p "$ORPHAN/state" "$ORPHAN/tmp"
touch "$ROOT/pause"
HOME="$ORPHAN/state" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORPHAN/tmp" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$ORPHAN/tmp" TEST_PAUSE_FILE="$ROOT/pause" \
  TEST_PAUSED_FILE="$ORPHAN/paused" bash "$CLEANUP_TMP_BIN" --clean >"$ORPHAN/holder.out" 2>&1 &
HOLDER_PID=$!
wait_for_file "$ORPHAN/paused" || record fail "orphan fixture reached paused scanner"
CHILD_PID=$(pgrep -P "$HOLDER_PID" | head -1 || true)
if [[ -z "$CHILD_PID" ]]; then
  # Re-exec means Bash may have directly spawned the find shim; locate by marker env.
  CHILD_PID=$(ps -eo pid,args | awk -v pause="$ROOT/pause" '$0 ~ /find/ && $0 ~ pause {print $1; exit}')
fi
kill -KILL "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
set +e
HOME="$ORPHAN/state" DISK_MAGICIAN_TMP_DIR="$ORPHAN/tmp" \
  DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" \
  bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$ORPHAN/tmp" --min-age-hours 0 >"$ORPHAN/contender.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]] && grep -q "scratch lock held" "$ORPHAN/contender.out" && record pass "SIGKILLed shell leaves child-held lock active" || record fail "SIGKILLed shell leaves child-held lock active (rc=$rc)"
rm -f "$ROOT/pause"
if [[ -n "$CHILD_PID" ]]; then
  for _ in {1..200}; do
    [[ -e "$ORPHAN/state/.disk_magician_locks/scratch_cleanup.lock" ]] || break
    # The kernel releases flock when the final descriptor owner exits; a lock
    # file itself is persistent, so use a real short acquisition probe below.
    sleep 0.025
    break
  done
fi
for _ in {1..200}; do
  if HOME="$ORPHAN/state" python3 "$REPO_ROOT/scripts/scratch_lock.py" run \
      --caller probe --script /usr/bin/true --args -- >/dev/null 2>&1; then break; fi
  sleep 0.025
done
HOME="$ORPHAN/state" DISK_MAGICIAN_TMP_DIR="$ORPHAN/tmp" \
  DISK_MAGICIAN_PR_SCRATCH_PATTERNS='*' DISK_MAGICIAN_FIND_BIN="$ROOT/bin/find" \
  bash "$CLEANUP_PR_BIN" --clean --tmp-dir "$ORPHAN/tmp" --min-age-hours 0 >"$ORPHAN/retry.out" 2>&1
record pass "contender acquires after orphan scanner exits"

# The exec wrapper must preserve the original script's exit status.
STATUS="$ROOT/status"; mkdir -m 0700 -p "$STATUS/state"
cat > "$STATUS/exit.sh" <<'EOF'
#!/usr/bin/env bash
source "$SCRATCH_LOCK_LIB"
scratch_lock_acquire exit-test
exit 37
EOF
chmod +x "$STATUS/exit.sh"
set +e
SCRATCH_LOCK_LIB="$REPO_ROOT/scripts/lib/scratch_lock.sh" HOME="$STATUS/state" \
  bash "$STATUS/exit.sh" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 37 ]] && record pass "exec wrapper propagates child exit status" || record fail "exec wrapper propagates child exit status (rc=$rc)"

echo "=== Results: $PASS pass, $FAIL fail ==="
(( FAIL == 0 ))

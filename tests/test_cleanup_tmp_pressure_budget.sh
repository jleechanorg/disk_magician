#!/usr/bin/env bash
# test_cleanup_tmp_pressure_budget.sh — cleanup_tmp.sh --large must reach eligible
# candidates inside the pressure-step budget (beads disk_magician-dcz, -ws86).
#
# Live failure 2026-10-11: du ran on every top-level /private/tmp dir BEFORE the
# recency check, so a large /tmp spent the whole 600s step before its first
# verdict; a held scratch lock returned rc=1 (FAILED) instead of a skip.
#
# Run: bash tests/test_cleanup_tmp_pressure_budget.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cleanup_tmp_pb.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOLDER_PID=""
trap '[[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; [[ -n "${2:-}" ]] && echo "        $2"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

NATIVE_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$NATIVE_TIMEOUT" ]] || { echo "SKIP: no timeout binary"; exit 0; }

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/emptytmp"
# du shim: logs the target; hangs on a path named *slow* so the bound is observable.
cat > "$BIN/du" <<EOF
#!/usr/bin/env bash
echo "\${@: -1}" >> "$TMP_ROOT/du.log"
case "\${@: -1}" in *slow*) exec sleep 30 ;; *fail_*|*agent_prompt_fail*) exit 1 ;; *perm_1) echo "du: Permission denied" >&2; printf "1258291\\t%s\\n" "\${@: -1}"; exit 1 ;; *big_[123]) printf "1258291\\t%s\\n" "\${@: -1}"; exit 0 ;; esac
exec /usr/bin/du "\$@"
EOF
cat > "$BIN/lsof" <<EOF
#!/usr/bin/env bash
echo x >> "$TMP_ROOT/lsof.log"
printf 'p1\nf3\ntREG\nn/usr/bin/other\n'
EOF
chmod +x "$BIN/du" "$BIN/lsof"
ln -s "$NATIVE_TIMEOUT" "$BIN/timeout"

mk_fixture() {  # <private_tmp> [extra old dirs...] — old_big (old) + recent_big (fresh)
  local root="$1" d
  rm -rf "$root"
  mkdir -p "$root" "$TMP_ROOT/home"
  chmod 755 "$TMP_ROOT/home"
  for d in old_big recent_big "${@:2}"; do
    mkdir -p "$root/$d"
    head -c 4096 /dev/zero > "$root/$d/payload.bin"
  done
  for d in old_big "${@:2}"; do /usr/bin/find "$root/$d" -exec touch -t 202001010000 {} +; done
  : > "$TMP_ROOT/du.log"; : > "$TMP_ROOT/lsof.log"
}
run_tmp() {  # <private_tmp> [VAR=val ...] — sets RC and OUT
  local root="$1"; shift
  set +e
  OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:/usr/bin:/bin" \
    LARGE_TMP_APPROVED=1 LARGE_TMP_MIN_KB=1 LARGE_TMP_ACTIVE_HOURS=4 \
    DISK_MAGICIAN_LSOF_BIN="$BIN/lsof" DISK_MAGICIAN_TIMEOUT_BIN="$BIN/timeout" \
    DISK_MAGICIAN_ARCHIVE_ROOT="$TMP_ROOT/archive" DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$root" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP_ROOT/emptytmp" DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT/emptytmp" "$@" \
    bash "$SOURCE_SCRIPT" --clean ${TMP_ARGS---large} 2>&1)"
  RC=$?
  set -e
}

echo "Test 1: recency is decided before size/lsof; eligible dir is still archived"
P1="$TMP_ROOT/p1"; mk_fixture "$P1"
run_tmp "$P1"
check "rc 0" '[[ $RC -eq 0 ]]' "rc=$RC $OUT"
check "recent dir skipped" 'grep -q "recently active dir.*recent_big" <<<"$OUT"' "$OUT"
check "du never run on recent dir" '! grep -q recent_big "$TMP_ROOT/du.log"'
check "old dir archived" '[[ ! -e "$P1/old_big" ]]'
check "recent dir preserved" '[[ -e "$P1/recent_big" ]]'
check "lsof only for the eligible dir (1 call)" '[[ "$(wc -l < "$TMP_ROOT/lsof.log" | tr -d " ")" == 1 ]]'

echo "Test 2: a hung du is bounded and fails closed for that entry only"
P2="$TMP_ROOT/p2"; mk_fixture "$P2" slow_big
start=$SECONDS
run_tmp "$P2" DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS=1
check "finished fast (<20s)" '(( SECONDS - start < 20 ))' "took $((SECONDS - start))s"
check "slow dir preserved" '[[ -e "$P2/slow_big" ]]'
check "other eligible dir still archived" '[[ ! -e "$P2/old_big" ]]'

mkdir -p "$TMP_ROOT/home/.disk_magician_locks"; chmod 700 "$TMP_ROOT/home/.disk_magician_locks"
hold_lock() {  # <seconds>
  : > "$TMP_ROOT/hold.out"
  python3 -c "
import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600)
fcntl.flock(fd,fcntl.LOCK_EX)
print('held',flush=True)
time.sleep(float(sys.argv[2]))" "$TMP_ROOT/home/.disk_magician_locks/scratch_cleanup.lock" "$1" > "$TMP_ROOT/hold.out" &
  HOLDER_PID=$!
  for _ in $(seq 100); do grep -q held "$TMP_ROOT/hold.out" 2>/dev/null && break; sleep 0.05; done
}

echo "Test 3: held scratch lock - bounded wait, then proceeds when released"
P3="$TMP_ROOT/p3"; mk_fixture "$P3"
hold_lock 2
run_tmp "$P3" DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=15
wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""
check "waited then ran (rc 0)" '[[ $RC -eq 0 ]]' "rc=$RC $OUT"
check "eligible dir archived after wait" '[[ ! -e "$P3/old_big" ]]'

echo "Test 4: lock held past the wait budget - distinct skip rc 75, nothing touched"
P4="$TMP_ROOT/p4"; mk_fixture "$P4"
hold_lock 6
run_tmp "$P4" DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=1
printf "%s" "$OUT" > "$TMP_ROOT/wait4.out"
kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""
check "rc 75 (skip, not failure)" '[[ $RC -eq 75 ]]' "rc=$RC"
check "skip message" 'grep -q "skipped, scratch lock held" <<<"$OUT"' "$OUT"
check "fixture untouched" '[[ -e "$P4/old_big" ]]'

echo "Test 5: budget mode - du timeout must NOT evict the unknown-size entry"
R5="$TMP_ROOT/r5"; rm -rf "$R5"; mkdir -p "$R5"
for d in a_slow big_1 big_2 big_3; do mkdir -p "$R5/$d"; head -c 100 /dev/zero > "$R5/$d/f"; done
/usr/bin/find "$R5/a_slow" -exec touch -t 201901010000 {} +
/usr/bin/find "$R5/big_1" -exec touch -t 202001010000 {} +
/usr/bin/find "$R5/big_2" -exec touch -t 202101010000 {} +
/usr/bin/find "$R5/big_3" -exec touch -t 202201010000 {} +
mk_fixture "$TMP_ROOT/p5"
set +e
OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$BIN/lsof" DISK_MAGICIAN_TIMEOUT_BIN="$BIN/timeout" \
  DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$TMP_ROOT/archive" DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP_ROOT/p5" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$R5" DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT/emptytmp" \
  bash "$SOURCE_SCRIPT" --clean --budget-gb 2 2>&1)"
RC=$?
set -e
check "rc 0" '[[ $RC -eq 0 ]]' "rc=$RC $OUT"
check "unknown-size entry preserved" '[[ -e "$R5/a_slow" ]]' "$OUT"
check "unknown-size entry reported excluded" 'grep -q "size unknown" <<<"$OUT"'
check "two oldest measured entries evicted" '[[ ! -e "$R5/big_1" && ! -e "$R5/big_2" ]]'
check "newest measured entry kept (no over-eviction)" '[[ -e "$R5/big_3" ]]'

echo "Test 6: recency find timeout is treated as active (preserved)"
cat > "$BIN/find_timeout" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == /usr/bin/find ]] && exit 124; done
while [[ \$# -gt 0 && "\$1" == -* ]]; do shift; done; shift
exec "\$@"
EOF
chmod +x "$BIN/find_timeout"
P6="$TMP_ROOT/p6"; mk_fixture "$P6"
run_tmp "$P6" DISK_MAGICIAN_PROBE_TIMEOUT_BIN="$BIN/find_timeout"
check "old dir preserved when find times out" '[[ -e "$P6/old_big" ]]' "$OUT"
check "logged fail-closed" 'grep -q "Active-use check failed" <<<"$OUT"'

echo "Test 7: budget lsof snapshot timeout -> no prefilter, run continues"
cat > "$BIN/lsof_timeout" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == */lsof ]] && exit 124; done
while [[ \$# -gt 0 && "\$1" == -* ]]; do shift; done; shift
exec "\$@"
EOF
chmod +x "$BIN/lsof_timeout"
set +e
OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:/usr/bin:/bin" DISK_MAGICIAN_LSOF_BIN="$BIN/lsof" \
  DISK_MAGICIAN_TIMEOUT_BIN="$BIN/timeout" DISK_MAGICIAN_PROBE_TIMEOUT_BIN="$BIN/lsof_timeout" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$TMP_ROOT/archive" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP_ROOT/p5" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$R5" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT/emptytmp" \
  bash "$SOURCE_SCRIPT" --dry-run --budget-gb 2 2>&1)"
RC=$?
set -e
check "rc 0" '[[ $RC -eq 0 ]]' "rc=$RC"
check "proceeds without prefilter" 'grep -q "lsof snapshot unavailable" <<<"$OUT"' "$OUT"

echo "Test 8: no usable timeout binary -> one-time unbounded warning"
P8="$TMP_ROOT/p8"; mk_fixture "$P8"
run_tmp "$P8" DISK_MAGICIAN_PROBE_TIMEOUT_BIN=/nonexistent
check "warns once" '[[ "$(grep -c "probes are unbounded" <<<"$OUT")" == 1 ]]' "$OUT"
check "still archives eligible dir" '[[ ! -e "$P8/old_big" ]]'

echo "Test 9: probe timeout parsing"
P9="$TMP_ROOT/p9"; mk_fixture "$P9"
run_tmp "$P9" DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS=abc
check "invalid value logs fallback" 'grep -q "invalid DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS" <<<"$OUT"' "$OUT"
run_tmp "$P9" DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS=120
check "values >99 accepted silently" '! grep -q "invalid DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS" <<<"$OUT"'

echo "Test 10: scratch_lock wait parsing rejects non-finite values"
check "parse_wait" 'python3 -c "
import sys; sys.path.insert(0, \"$REPO_ROOT/scripts\")
import scratch_lock as s
assert s.parse_wait(\"inf\")==20.0 and s.parse_wait(\"nan\")==20.0 and s.parse_wait(\"x\")==20.0
assert s.parse_wait(\"-5\")==0.0 and s.parse_wait(\"3\")==3.0 and s.parse_wait(None)==20.0"'
check "message reports the wait" 'grep -q "after waiting" <<<"$(cat "$TMP_ROOT/wait4.out")"'

budget_run() {  # <root> [VAR=val ...] — budget run over <root>; sets RC and OUT
  local root="$1"; shift
  set +e
  OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:/usr/bin:/bin" \
    DISK_MAGICIAN_LSOF_BIN="$BIN/lsof" DISK_MAGICIAN_TIMEOUT_BIN="$BIN/timeout" \
    DISK_MAGICIAN_ARCHIVE_ROOT="$TMP_ROOT/archive" DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP_ROOT/p5" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$root" DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT/emptytmp" \
    "$@" bash "$SOURCE_SCRIPT" --clean --budget-gb 2 2>&1)"
  RC=$?
  set -e
}
mk_budget_root() {  # <root> <oldest_extra...>
  local root="$1" d y=2019
  rm -rf "$root"; mkdir -p "$root"
  for d in "${@:2}" big_1 big_2 big_3; do
    mkdir -p "$root/$d"; head -c 100 /dev/zero > "$root/$d/f"
    /usr/bin/find "$root/$d" -exec touch -t ${y}01010000 {} +; y=$((y + 1))
  done
}

echo "Test 11: du fails (rc 1, no output) -> unknown, entry kept under budget"
R11="$TMP_ROOT/r11"; mk_budget_root "$R11" fail_a
budget_run "$R11"
check "failing-du entry kept" '[[ -e "$R11/fail_a" ]]' "$OUT"
check "logged du failed" 'grep -q "du failed rc=1, size unknown" <<<"$OUT"'

echo "Test 12: broken timeout wrapper (rc 125) -> unknown, nothing evicted"
printf '#!/usr/bin/env bash\nexit 125\n' > "$BIN/timeout125"; chmod +x "$BIN/timeout125"
R12="$TMP_ROOT/r12"; mk_budget_root "$R12"
budget_run "$R12" DISK_MAGICIAN_PROBE_TIMEOUT_BIN="$BIN/timeout125"
check "all entries kept" '[[ -e "$R12/big_1" && -e "$R12/big_2" && -e "$R12/big_3" ]]' "$OUT"
check "logged wrapper failure" 'grep -q "du wrapper failed rc=125" <<<"$OUT"'

echo "Test 13: du rc 1 WITH numeric total (Permission denied) -> lower bound used"
R13="$TMP_ROOT/r13"; mk_budget_root "$R13" perm_1
rm -rf "$R13/big_1"
budget_run "$R13"
check "partial-size entry evicted as 1258291 KB" '[[ ! -e "$R13/perm_1" ]]' "$OUT"
check "second-oldest evicted, newest kept" '[[ ! -e "$R13/big_2" && -e "$R13/big_3" ]]'

echo "Test 14: agent_prompt file with unknown size is skipped, not deleted"
printf x > "$TMP_ROOT/emptytmp/agent_prompt_fail.txt"; touch -t 202001010000 "$TMP_ROOT/emptytmp/agent_prompt_fail.txt"
printf x > "$TMP_ROOT/emptytmp/agent_prompt_ok.txt"; touch -t 202001010000 "$TMP_ROOT/emptytmp/agent_prompt_ok.txt"
P14="$TMP_ROOT/p14"; mk_fixture "$P14"
run_tmp "$P14" TMP_ARGS=
check "unknown-size prompt kept" '[[ -e "$TMP_ROOT/emptytmp/agent_prompt_fail.txt" ]]' "$OUT"
check "measurable stale prompt still removed" '[[ ! -e "$TMP_ROOT/emptytmp/agent_prompt_ok.txt" ]]'

echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))

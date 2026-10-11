#!/usr/bin/env bash
# test_cleanup_tmp_container_descend.sh — --large descends one level into
# active non-git container dirs (e.g. /private/tmp/worldai_claw) so idle
# children are reclaimed while the container and live children are kept.
# RED: run against a script lacking the descent (CLEANUP_TMP_SCRIPT=<old copy>).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="${CLEANUP_TMP_SCRIPT:-$REPO_ROOT/scripts/cleanup_tmp.sh}"
[[ "$SOURCE_SCRIPT" == /* ]] || SOURCE_SCRIPT="$REPO_ROOT/$SOURCE_SCRIPT"
TMP_ROOT=$(mktemp -d -t cleanup_tmp_container.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }
assert_exists() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
assert_missing() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (still present: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (no '$2')"; fi; }

set_old() { /usr/bin/find "$1" -exec touch -t 202001010000 {} +; }

# make_env <name>: sets PT (private tmp), AR (archive), BIN
make_env() {
  local n="$1"
  PT="$TMP_ROOT/$n-private-tmp"; AR="$TMP_ROOT/$n-archive"; BIN="$TMP_ROOT/$n-bin"
  mkdir -p "$PT" "$AR" "$BIN" "$TMP_ROOT/$n-tmp"
  cat > "$BIN/getconf" <<'S'
#!/usr/bin/env bash
[[ "${1:-}" == DARWIN_USER_TEMP_DIR ]] && exit 0
exec /usr/bin/getconf "$@"
S
  cat > "$BIN/timeout" <<'S'
#!/usr/bin/env bash
[[ "${1:-}" == --kill-after=* ]] && shift
shift
exec "$@"
S
  # lsof stub: reports every path listed in $FAKE_OPEN_FILE as open.
  cat > "$BIN/lsof" <<'S'
#!/usr/bin/env bash
echo p1234; echo fcwd; echo n/
if [[ -n "${FAKE_OPEN_FILE:-}" && -s "$FAKE_OPEN_FILE" ]]; then
  while IFS= read -r f; do printf 'f3\nn%s\ntREG\n' "$f"; done < "$FAKE_OPEN_FILE"
fi
exit 0
S
  chmod +x "$BIN"/*
}

# run_sweep <name> <--clean|--dry-run> [VAR=val ...]: sets RC and OUT
run_sweep() {
  local n="$1" mode="$2"; shift 2
  set +e
  env -i HOME="$TMP_ROOT/$n-home" PATH="$BIN:/usr/bin:/bin:/usr/sbin" \
    LARGE_TMP_APPROVED=1 LARGE_TMP_MIN_KB=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
    DISK_MAGICIAN_LSOF_BIN="$BIN/lsof" DISK_MAGICIAN_ARCHIVE_ROOT="$AR" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP_ROOT/$n-tmp" \
    "$@" bash "$SOURCE_SCRIPT" "$mode" --large >"$TMP_ROOT/$n.out" 2>&1
  RC=$?
  set -e
  OUT="$(cat "$TMP_ROOT/$n.out")"
}

mkchild() { mkdir -p "$1"; head -c 20000 /dev/zero > "$1/payload.bin"; }
archived() { /usr/bin/find "$AR" -mindepth 3 -maxdepth 3 -name "$1" 2>/dev/null | head -n1; }

echo "Test 1: active container -> idle child archived; fresh child and container kept"
make_env t1
mkdir -p "$PT/agentbox"
mkchild "$PT/agentbox/old-child"; set_old "$PT/agentbox/old-child"
mkchild "$PT/agentbox/fresh-child"
run_sweep t1 --clean
assert_missing "t1 old child moved out" "$PT/agentbox/old-child"
[[ -n "$(archived old-child)" ]] && pass "t1 old child present in archive" || fail "t1 old child present in archive"
assert_exists "t1 fresh child kept" "$PT/agentbox/fresh-child"
assert_exists "t1 container kept" "$PT/agentbox"
assert_contains "t1 archived total counts child size only" "Dirs archived: 1" "$OUT"

echo "Test 2: dry-run reports child, changes nothing, counts child KB"
make_env t2
mkdir -p "$PT/agentbox"
mkchild "$PT/agentbox/old-child"; set_old "$PT/agentbox/old-child"
mkchild "$PT/agentbox/fresh-child"
run_sweep t2 --dry-run
assert_exists "t2 old child untouched" "$PT/agentbox/old-child"
assert_contains "t2 dry-run names child" "would archive: $PT/agentbox/old-child" "$OUT"
KB=$(du -sk "$PT/agentbox/old-child" | awk '{print $1}')
assert_contains "t2 archived KB equals child size" "Total archived: ${KB} KB" "$OUT"

echo "Test 3: idle child with a live open file is kept"
make_env t3
mkdir -p "$PT/agentbox"
mkchild "$PT/agentbox/old-open"; set_old "$PT/agentbox/old-open"
mkchild "$PT/agentbox/fresh-child"
CANON="$(cd "$PT/agentbox/old-open" && pwd -P)"
echo "$CANON/payload.bin" > "$TMP_ROOT/t3-open.list"
run_sweep t3 --clean FAKE_OPEN_FILE="$TMP_ROOT/t3-open.list"
assert_exists "t3 open child kept" "$PT/agentbox/old-open"

echo "Test 4: idle child linked worktree with uncommitted change is kept"
# (a .git *file* keeps the legacy depth-2 git-clone pass out of the way)
make_env t4
mkdir -p "$PT/agentbox" "$TMP_ROOT/t4-main"
git -C "$TMP_ROOT/t4-main" init -q
git -C "$TMP_ROOT/t4-main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP_ROOT/t4-main" worktree add -q "$PT/agentbox/old-wt" -b t4wt
echo dirty > "$PT/agentbox/old-wt/uncommitted.txt"
head -c 20000 /dev/zero > "$PT/agentbox/old-wt/payload.bin"
set_old "$PT/agentbox/old-wt"
mkchild "$PT/agentbox/fresh-child"
run_sweep t4 --clean
assert_exists "t4 dirty worktree child kept" "$PT/agentbox/old-wt"
assert_contains "t4 logs unsaved-work skip" "unsaved work" "$OUT"

echo "Test 5: container that is itself a git repo is not descended"
make_env t5
mkdir -p "$PT/repo"
git -C "$PT/repo" init -q
mkchild "$PT/repo/old-child"; set_old "$PT/repo/old-child"
mkchild "$PT/repo/fresh-child"
run_sweep t5 --clean
assert_exists "t5 child of git-repo container kept" "$PT/repo/old-child"

echo "Test 6: .in-use marker on child keeps it; marker on container keeps all"
make_env t6
mkdir -p "$PT/agentbox" "$PT/marked"
mkchild "$PT/agentbox/old-marked"; touch "$PT/agentbox/old-marked/.in-use"; set_old "$PT/agentbox/old-marked"
mkchild "$PT/agentbox/fresh-child"
mkchild "$PT/marked/old-child"; set_old "$PT/marked/old-child"; touch "$PT/marked/.in-use"
run_sweep t6 --clean
assert_exists "t6 marked child kept" "$PT/agentbox/old-marked"
assert_exists "t6 child under marked container kept" "$PT/marked/old-child"

echo "Test 7: protected-root container children are kept"
make_env t7
mkdir -p "$PT/keepme"
mkchild "$PT/keepme/old-child"; set_old "$PT/keepme/old-child"
mkchild "$PT/keepme/fresh-child"
run_sweep t7 --clean DISK_MAGICIAN_PROTECTED_TMP_ROOTS=keepme
assert_exists "t7 protected container child kept" "$PT/keepme/old-child"

echo "Test 8: nested grandchildren are not descended (one level only)"
make_env t8
mkdir -p "$PT/agentbox/mid/deep"
head -c 20000 /dev/zero > "$PT/agentbox/mid/deep/payload.bin"
set_old "$PT/agentbox/mid"
mkchild "$PT/agentbox/fresh-child"
run_sweep t8 --clean
# mid is idle (child level) so it goes whole; deep is never archived separately.
assert_missing "t8 idle mid archived as a unit" "$PT/agentbox/mid"
if grep -qE "archive.*/deep|evaluat.*/deep" <<<"$OUT"; then fail "t8 grandchild not separately evaluated"; else pass "t8 grandchild not separately evaluated"; fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_cleanup_tmp_container_descend.sh — --large descends one level into
# explicitly known active container dirs (e.g. /private/tmp/agent-scratch) so
# idle children are reclaimed while the container and live children are kept.
# RED: run against a script lacking the descent (CLEANUP_TMP_SCRIPT=<old copy>).
#
# Archive gate (bead disk_magician-archive-same-volume-regrowth-03bn): a
# quarantine move is only allowed for candidates with a declared-ephemeral
# retention row (E2/E3). Rows name DIRECT children of a scratch root, so a
# descended child (`<root>/<container>/<child>`) is unproven: C14 refuses every
# purge of a retention-0 receipt, and archiving it would grow
# _disk_magician_archive without ever reclaiming a byte. The descend tests
# below therefore assert the candidate stays at its original path, logs
# "Skipping archive candidate (C14 kept:unproven-content)", and is not counted
# as archived. The only nested row is the `.git`-directory shape (240 min),
# which also needs a C14 repo baseline and therefore has no fixture here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="${CLEANUP_TMP_SCRIPT:-$REPO_ROOT/scripts/cleanup_tmp.sh}"
[[ "$SOURCE_SCRIPT" == /* ]] || SOURCE_SCRIPT="$REPO_ROOT/$SOURCE_SCRIPT"
# Keep Linux fixtures out of /tmp because cleanup_tmp intentionally applies
# macOS /tmp -> /private/tmp alias normalization to lsof paths.
FIXTURE_ROOT="/tmp/disk_magician/fixtures"
mkdir -p "$FIXTURE_ROOT"
TMP_ROOT=$(mktemp -d "$FIXTURE_ROOT/cleanup_tmp_container.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }
assert_exists() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
assert_missing() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (still present: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (no '$2')"; fi; }

set_old() { /usr/bin/find "$1" -exec touch -t 202001010000 {} +; }

set_age_hours() {
  local path="$1" hours="$2" stamp
  stamp="$(date -v-"${hours}"H '+%Y%m%d%H%M' 2>/dev/null || date -d "${hours} hours ago" '+%Y%m%d%H%M')"
  /usr/bin/find "$path" -name .git -prune -o -exec touch -t "$stamp" {} +
}

# make_depth3_c14_entry <source> <entry> <retention> <private_tmp> <tmp_root>
# Builds a valid expired E2 origin receipt and moves its source to an
# arbitrary archive <entry> (including a depth-3 container child). Mirrors
# test_cleanup_tmp_archive_purge.sh: the source is flattened onto <tmp_root>
# so its declared-ephemeral row is a single component, and archived_at is
# backdated past the retention window so C14 E1 approves the reclaimed unit.
make_depth3_c14_entry() {
  local source="$1" entry="$2" retention="$3" private_tmp="$4" tmp_root="$5" archived_at actual_retention
  private_tmp="$(cd "$private_tmp" && pwd -P)"
  tmp_root="$(cd "$tmp_root" && pwd -P)"
  source="$tmp_root/${source##*/}"
  mkdir -p "$source" "${entry%/*}"
  printf 'depth3 expired scratch fixture\n' >"$source/payload.bin"
  actual_retention="$(DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$private_tmp" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tmp_root" \
    bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2"' _ "$REPO_ROOT" "$source")"
  [[ "$actual_retention" == "$retention" ]] || { fail "depth3 fixture retention for $source (expected $retention, got $actual_retention)"; return 1; }
  archived_at="$(python3 -c 'import sys,time; print(int(time.time())-int(sys.argv[1])*3600)' "$(( retention / 60 + 25 ))")"
  python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt "$source" "$entry.c14-origin.json" "$archived_at" "$retention" >/dev/null
  mv "$source" "$entry"
  set_old "$entry"
}

make_clean_pushed_worktree() {
  local main="$1" wt="$2" branch="$3" remote
  remote="${main}-remote.git"
  git init --bare -q "$remote"
  git init -q -b main "$main"
  git -C "$main" config user.name test
  git -C "$main" config user.email jleechan2015@users.noreply.github.com
  head -c 20000 /dev/zero > "$main/payload.bin"
  git -C "$main" add payload.bin
  git -C "$main" commit -q -m init
  git -C "$main" remote add origin "$remote"
  git -C "$main" push -q -u origin main
  git -C "$main" worktree add -q -b "$branch" "$wt"
  git -C "$wt" push -q -u origin "$branch"
}

# make_env <name>: sets PT (private tmp), AR (archive), BIN
make_env() {
  local n="$1"
  PT="$TMP_ROOT/$n-private-tmp"; AR="$TMP_ROOT/$n-archive"; BIN="$TMP_ROOT/$n-bin"
  # Clean mode acquires the shared scratch lock under HOME.  The lock contract
  # requires HOME to be an existing, user-owned directory.
  mkdir -p "$PT" "$AR" "$BIN" "$TMP_ROOT/$n-tmp" "$TMP_ROOT/$n-home"
  chmod 700 "$TMP_ROOT/$n-home"
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
  # lsof stub: emulates the real targeted contract C14 reads. A targeted
  # query (a +D tree scan or an explicit path) prints the FAKE_OPEN_FILE
  # records and exits 0 when a match exists, otherwise prints nothing and
  # exits 1. A targetless table query (cleanup_tmp fail-closed has_open_files)
  # always keeps a well-formed synthetic record so it stays fail-closed.
  cat > "$BIN/lsof" <<'S'
#!/usr/bin/env bash
target=""
for arg in "$@"; do
  case "$arg" in
    +D|--) target=1 ;;
    /*) target=1 ;;
  esac
done
if [[ -n "$target" ]]; then
  if [[ -n "${FAKE_OPEN_FILE:-}" && -s "$FAKE_OPEN_FILE" ]]; then
    while IFS= read -r f; do printf 'p1234\nf3\nn%s\ntREG\n' "$f"; done < "$FAKE_OPEN_FILE"
    exit 0
  fi
  exit 1
fi
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
  if (( RC != 0 )); then
    fail "$n sweep exits 0 (rc=$RC; output: $OUT)"
  fi
}

mkchild() { mkdir -p "$1"; head -c 20000 /dev/zero > "$1/payload.bin"; }
archived() { /usr/bin/find "$AR" -mindepth 3 -maxdepth 3 -name "$1" 2>/dev/null | head -n1; }

echo "Test 1: active container -> idle child evaluated and kept (no declared-ephemeral row); fresh child and container kept"
make_env t1
mkdir -p "$PT/agent-scratch"
mkchild "$PT/agent-scratch/old-child"; set_old "$PT/agent-scratch/old-child"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t1 --clean
# A descended child is one level below the scratch root, so no E2/E3
# declared-ephemeral row can match it: cleanup_tmp evaluates it, then keeps it
# visible at its original path instead of quarantining it with an unpurgeable
# retention-0 receipt (bead disk_magician-archive-same-volume-regrowth-03bn).
assert_exists "t1 idle child kept at its original path" "$PT/agent-scratch/old-child"
assert_contains "t1 idle child is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-child" "$OUT"
assert_exists "t1 fresh child kept" "$PT/agent-scratch/fresh-child"
assert_exists "t1 container kept" "$PT/agent-scratch"
assert_contains "t1 unproven child is not counted as archived" "Dirs archived: 0" "$OUT"

echo "Test 2: dry-run reports the unproven child skip, changes nothing, counts nothing"
make_env t2
mkdir -p "$PT/agent-scratch"
mkchild "$PT/agent-scratch/old-child"; set_old "$PT/agent-scratch/old-child"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t2 --dry-run
assert_exists "t2 old child untouched" "$PT/agent-scratch/old-child"
assert_contains "t2 dry-run reports the unproven child skip" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-child" "$OUT"
assert_contains "t2 unproven child is not counted as archived" "Dirs archived: 0" "$OUT"

echo "Test 3: idle child with a live open file is kept"
make_env t3
mkdir -p "$PT/agent-scratch"
mkchild "$PT/agent-scratch/old-open"; set_old "$PT/agent-scratch/old-open"
mkchild "$PT/agent-scratch/fresh-child"
CANON="$(cd "$PT/agent-scratch/old-open" && pwd -P)"
echo "$CANON/payload.bin" > "$TMP_ROOT/t3-open.list"
run_sweep t3 --clean FAKE_OPEN_FILE="$TMP_ROOT/t3-open.list"
assert_exists "t3 open child kept" "$PT/agent-scratch/old-open"

echo "Test 4: idle child linked worktree with uncommitted change is kept"
# (a .git *file* keeps the legacy depth-2 git-clone pass out of the way)
make_env t4
mkdir -p "$PT/agent-scratch" "$TMP_ROOT/t4-main"
git -C "$TMP_ROOT/t4-main" init -q
git -C "$TMP_ROOT/t4-main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP_ROOT/t4-main" worktree add -q "$PT/agent-scratch/old-wt" -b t4wt
echo dirty > "$PT/agent-scratch/old-wt/uncommitted.txt"
head -c 20000 /dev/zero > "$PT/agent-scratch/old-wt/payload.bin"
set_old "$PT/agent-scratch/old-wt"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t4 --clean
assert_exists "t4 dirty worktree child kept" "$PT/agent-scratch/old-wt"
assert_contains "t4 logs unsaved-work skip" "unsaved work" "$OUT"

echo "Test 5: container that is itself a git repo is not descended"
make_env t5
mkdir -p "$PT/repo"
git -C "$PT/repo" init -q
mkchild "$PT/repo/old-child"; set_old "$PT/repo/old-child"
mkchild "$PT/repo/fresh-child"
run_sweep t5 --clean DISK_MAGICIAN_SCRATCH_CONTAINER_ROOTS=repo
assert_exists "t5 child of git-repo container kept" "$PT/repo/old-child"

echo "Test 6: .in-use marker on or below child keeps it; marker on container keeps all"
make_env t6
mkdir -p "$PT/agent-scratch" "$PT/marked"
mkchild "$PT/agent-scratch/old-marked"; touch "$PT/agent-scratch/old-marked/.in-use"; set_old "$PT/agent-scratch/old-marked"
mkchild "$PT/agent-scratch/old-nested-marked"; mkdir -p "$PT/agent-scratch/old-nested-marked/runtime"; touch "$PT/agent-scratch/old-nested-marked/runtime/.in-use"; set_old "$PT/agent-scratch/old-nested-marked"
mkchild "$PT/agent-scratch/old-unmarked"; set_old "$PT/agent-scratch/old-unmarked"
mkchild "$PT/agent-scratch/fresh-child"
mkchild "$PT/marked/old-child"; set_old "$PT/marked/old-child"; touch "$PT/marked/.in-use"
run_sweep t6 --clean DISK_MAGICIAN_SCRATCH_CONTAINER_ROOTS="agent-scratch marked"
assert_exists "t6 marked child kept" "$PT/agent-scratch/old-marked"
assert_exists "t6 child with nested marker kept" "$PT/agent-scratch/old-nested-marked"
assert_exists "t6 eligible sibling of marked children kept at its original path" "$PT/agent-scratch/old-unmarked"
assert_contains "t6 eligible sibling still reaches the archive gate" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-unmarked" "$OUT"
assert_exists "t6 child under marked container kept" "$PT/marked/old-child"

echo "Test 7: protected root keeps itself, its canonical evidence child, and its unproven stale children"
make_env t7
mkdir -p "$PT/keepme"
mkchild "$PT/keepme/old-child"; set_old "$PT/keepme/old-child"
mkchild "$PT/keepme/fresh-child"
# Canonical `evidence` child of a protected root is never touched, even when
# stale, while the root itself is preserved. A stale non-evidence child is
# evaluated but stays in place: nested content has no declared-ephemeral row
# (bead disk_magician-archive-same-volume-regrowth-03bn).
mkchild "$PT/keepme/evidence"; set_old "$PT/keepme/evidence"
run_sweep t7 --clean DISK_MAGICIAN_PROTECTED_TMP_ROOTS=keepme DISK_MAGICIAN_SCRATCH_CONTAINER_ROOTS=keepme
assert_exists "t7 protected root kept" "$PT/keepme"
assert_exists "t7 canonical evidence child kept" "$PT/keepme/evidence"
assert_exists "t7 fresh child kept" "$PT/keepme/fresh-child"
assert_exists "t7 stale scratch child kept at its original path" "$PT/keepme/old-child"
assert_contains "t7 stale scratch child is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/keepme/old-child" "$OUT"

echo "Test 8: nested grandchildren are not descended (one level only)"
make_env t8
mkdir -p "$PT/agent-scratch/mid/deep"
head -c 20000 /dev/zero > "$PT/agent-scratch/mid/deep/payload.bin"
set_old "$PT/agent-scratch/mid"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t8 --clean
# mid is the only descended unit (kept: no declared-ephemeral row); deep is
# never evaluated or archived separately.
assert_exists "t8 idle mid kept as a unit" "$PT/agent-scratch/mid"
assert_contains "t8 idle mid is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/mid" "$OUT"
if grep -qE "archive.*/deep|evaluat.*/deep" <<<"$OUT"; then fail "t8 grandchild not separately evaluated"; else pass "t8 grandchild not separately evaluated"; fi

echo "Test 9: unknown active workspace is atomic even when one child is idle"
make_env t9
mkdir -p "$PT/build"
mkchild "$PT/build/sources"; set_old "$PT/build/sources"
mkchild "$PT/build/logs"
run_sweep t9 --clean
assert_exists "t9 idle sources in unknown active workspace kept" "$PT/build/sources"
assert_exists "t9 fresh logs in unknown active workspace kept" "$PT/build/logs"
assert_contains "t9 unknown workspace skipped as one active unit" "Skipping recently active dir" "$OUT"

echo "Test 10: clean pushed worktree 25h old remains protected by seven-day floor"
make_env t10
mkdir -p "$PT/agent-scratch"
make_clean_pushed_worktree "$TMP_ROOT/t10-main" "$PT/agent-scratch/old-wt" t10wt
set_age_hours "$PT/agent-scratch/old-wt" 25
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t10 --clean
assert_exists "t10 25h-old clean pushed worktree kept" "$PT/agent-scratch/old-wt"
assert_contains "t10 seven-day worktree floor reported" \
  "recently active nested repository/worktree (<7d)" "$OUT"

echo "Test 11: unmeasurable clean pushed worktree fails closed"
make_env t11
mkdir -p "$PT/agent-scratch"
make_clean_pushed_worktree "$TMP_ROOT/t11-main" "$PT/agent-scratch/old-wt" t11wt
set_old "$PT/agent-scratch/old-wt"
mkchild "$PT/agent-scratch/fresh-child"
cat > "$BIN/find" <<'S'
#!/usr/bin/env bash
[[ "${FAIL_RECENCY_ROOT:-}" == "${1:-}" ]] && exit 91
exec /usr/bin/find "$@"
S
chmod +x "$BIN/find"
run_sweep t11 --clean FAIL_RECENCY_ROOT="$PT/agent-scratch/old-wt"
assert_exists "t11 unmeasurable clean pushed worktree kept" "$PT/agent-scratch/old-wt"
assert_contains "t11 fail-closed recency protection reported" \
  "recently active nested repository/worktree (<7d)" "$OUT"

echo "Test 12: clean pushed linked worktree older than seven days reaches the archive gate but stays unproven"
make_env t12
mkdir -p "$PT/agent-scratch"
make_clean_pushed_worktree "$TMP_ROOT/t12-main" "$PT/agent-scratch/old-wt" t12wt
set_old "$PT/agent-scratch/old-wt"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t12 --clean
# A linked worktree's .git is a FILE and the nested path is two components, so
# no E2/E3 declared-ephemeral row matches: the candidate stays in place instead
# of being quarantined with an unpurgeable retention-0 receipt (bead
# disk_magician-archive-same-volume-regrowth-03bn).
assert_exists "t12 old clean pushed worktree kept at its original path" "$PT/agent-scratch/old-wt"
assert_contains "t12 worktree child is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-wt" "$OUT"

echo "Test 13: machine safety policy blocks child quarantine without counting it"
make_env t13
mkdir -p "$PT/agent-scratch" "$TMP_ROOT/t13-config"
mkchild "$PT/agent-scratch/never-child"; set_old "$PT/agent-scratch/never-child"
mkchild "$PT/agent-scratch/live-child"; set_old "$PT/agent-scratch/live-child"
mkchild "$PT/agent-scratch/decision-child"; set_old "$PT/agent-scratch/decision-child"
mkchild "$PT/agent-scratch/fresh-child"
cat > "$TMP_ROOT/t13-config/safety.local.json" <<JSON
{
  "never_delete": ["$PT/agent-scratch/never-child"],
  "protected_live_paths": [
    {"path": "$PT/agent-scratch/live-child", "reason": "test live path"}
  ],
  "needs_decision": [
    {"path": "$PT/agent-scratch/decision-child", "reason": "test operator decision"}
  ]
}
JSON
run_sweep t13 --clean DISK_MAGICIAN_SAFETY_FILE="$TMP_ROOT/t13-config/safety.local.json"
assert_exists "t13 never_delete child kept at original path" "$PT/agent-scratch/never-child"
assert_exists "t13 protected_live_paths child kept at original path" "$PT/agent-scratch/live-child"
assert_exists "t13 needs_decision child kept at original path" "$PT/agent-scratch/decision-child"
assert_contains "t13 safety refusal reported" "SAFETY-SKIP" "$OUT"
assert_contains "t13 never_delete reason reported" "never_delete:" "$OUT"
assert_contains "t13 protected_live_paths reason reported" "protected_live_paths:" "$OUT"
assert_contains "t13 needs_decision reason reported" "needs_decision:" "$OUT"
assert_contains "t13 refused children excluded from archive totals" "Dirs archived: 0" "$OUT"

echo "Test 14: nested repository with an uncommitted change protects its container child"
make_env t14
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t14-main" "$PT/agent-scratch/runtime/run-id/repo" t14wt
echo dirty >> "$PT/agent-scratch/runtime/run-id/repo/payload.bin"
set_old "$PT/agent-scratch/runtime"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t14 --clean
assert_exists "t14 child containing dirty nested repository kept" "$PT/agent-scratch/runtime"
assert_contains "t14 nested unsaved-work protection reported" \
  "nested repository unsaved work" "$OUT"

echo "Test 15: nested repository with an unpushed commit protects its container child"
make_env t15
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t15-main" "$PT/agent-scratch/runtime/run-id/repo" t15wt
echo committed >> "$PT/agent-scratch/runtime/run-id/repo/payload.bin"
git -C "$PT/agent-scratch/runtime/run-id/repo" add payload.bin
git -C "$PT/agent-scratch/runtime/run-id/repo" commit -q -m unpushed
set_old "$PT/agent-scratch/runtime"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t15 --clean
assert_exists "t15 child containing unpushed nested repository kept" "$PT/agent-scratch/runtime"
assert_contains "t15 nested unpushed-work protection reported" \
  "nested repository unsaved work" "$OUT"

echo "Test 16: recently active clean nested worktree honors the seven-day floor"
make_env t16
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t16-main" "$PT/agent-scratch/runtime/run-id/repo" t16wt
set_age_hours "$PT/agent-scratch/runtime" 25
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t16 --clean
assert_exists "t16 child containing 25h-old clean nested worktree kept" "$PT/agent-scratch/runtime"
assert_contains "t16 nested worktree recency protection reported" \
  "recently active nested repository/worktree (<7d)" "$OUT"

echo "Test 17: old clean pushed nested worktree reaches the archive gate but stays unproven"
make_env t17
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t17-main" "$PT/agent-scratch/runtime/run-id/repo" t17wt
set_old "$PT/agent-scratch/runtime"
mkchild "$PT/agent-scratch/fresh-child"
run_sweep t17 --clean
assert_exists "t17 old clean nested worktree child kept at its original path" "$PT/agent-scratch/runtime"
assert_contains "t17 nested worktree child is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/runtime" "$OUT"

echo "Test 18: idle scratch container with a dirty nested repository stays in place"
make_env t18
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t18-main" "$PT/agent-scratch/runtime/run-id/repo" t18wt
echo dirty >> "$PT/agent-scratch/runtime/run-id/repo/payload.bin"
mkchild "$PT/agent-scratch/old-sibling"
set_old "$PT/agent-scratch"
run_sweep t18 --clean
assert_exists "t18 idle container with dirty nested repository kept" "$PT/agent-scratch"
assert_exists "t18 child containing dirty nested repository kept" "$PT/agent-scratch/runtime"
assert_exists "t18 eligible sibling of dirty repository kept at its original path" "$PT/agent-scratch/old-sibling"
assert_contains "t18 eligible sibling still reaches the archive gate" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-sibling" "$OUT"
assert_contains "t18 depth-zero nested unsaved-work protection reported" \
  "nested repository unsaved work" "$OUT"

echo "Test 19: idle scratch container with only an old clean repository stays in place (no declared row)"
make_env t19
mkdir -p "$PT/agent-scratch/runtime/run-id"
make_clean_pushed_worktree "$TMP_ROOT/t19-main" "$PT/agent-scratch/runtime/run-id/repo" t19wt
set_old "$PT/agent-scratch"
run_sweep t19 --clean
assert_exists "t19 idle container kept at its original path" "$PT/agent-scratch"
assert_contains "t19 idle container is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch" "$OUT"
assert_contains "t19 unproven container is not counted as archived" "Dirs archived: 0" "$OUT"

echo "Test 20: depth-3 receipt traversal reclaims valid entries and preserves unknown bytes"
# Cursor review 6 / bead cuea.12: a child archived under a container lands at
# "$AR/<ts>/<container>/<unit>" with its receipt as a sibling file at depth 3.
# The purge scan must discover those receipts (never walk container bytes),
# reclaim a VALID expired E2 entry, and leave unclassifiable content, the
# container, and the receipt sidecar untouched.
make_env t20

# 20a: a descended child with no declared-ephemeral row is never archived by the
# sweep; a legacy depth-3 entry of that shape (retention 0, written by older
# builds) is still discovered and preserved as unknown archive content.
mkdir -p "$PT/agent-scratch"
mkchild "$PT/agent-scratch/old-child"; set_old "$PT/agent-scratch/old-child"
run_sweep t20 --clean
assert_exists "t20a unproven descended child stays at its original path" "$PT/agent-scratch/old-child"
assert_contains "t20a unproven descended child is rejected before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $PT/agent-scratch/old-child" "$OUT"
if [[ -z "$(archived old-child)" ]]; then pass "t20a nothing was quarantined for the unproven child"; else fail "t20a nothing was quarantined for the unproven child"; fi
# Build the legacy entry by hand: a retention-0 origin receipt is what older
# builds wrote for undeclared content, and it must never be purged.
UNKNOWN_ENTRY="$AR/20200101T000000Z/agent-scratch/old-child"
mkdir -p "${UNKNOWN_ENTRY%/*}"
python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt \
  "$PT/agent-scratch/old-child" "$UNKNOWN_ENTRY.c14-origin.json" "" 0 >/dev/null
mv "$PT/agent-scratch/old-child" "$UNKNOWN_ENTRY"
set_old "$UNKNOWN_ENTRY"
run_sweep t20 --clean LARGE_TMP_ARCHIVE_RETENTION_HOURS=1
assert_exists "t20a legacy unknown descended child preserved (same archive guard)" "$UNKNOWN_ENTRY"
assert_exists "t20a origin receipt sidecar preserved" "$UNKNOWN_ENTRY.c14-origin.json"
assert_exists "t20a container itself never removed" "$PT/agent-scratch"
assert_contains "t20a unknown descended child is discovered and evaluated" \
  "Skipping aged archive (C14 kept:archive-identity): $UNKNOWN_ENTRY" "$OUT"

# 20b: a valid expired E2 receipt placed at depth 3 is reclaimed through the
# same traversal (the receipt names the original top-level scratch path).
D3_STAMP="$AR/20200102T000000Z"
D3_ENTRY="$D3_STAMP/agent-scratch/cli_validation_gemini_depth3"
mkdir -p "$PT" "$TMP_ROOT/t20-tmp"
make_depth3_c14_entry "$TMP_ROOT/t20-tmp/cli_validation_gemini_depth3" "$D3_ENTRY" 60 "$PT" "$TMP_ROOT/t20-tmp"
run_sweep t20 --clean LARGE_TMP_ARCHIVE_RETENTION_HOURS=1
assert_missing "t20b valid depth-3 receipted entry reclaimed" "$D3_ENTRY"
assert_contains "t20b depth-3 purge is logged" "Purged aged archive after C14 approval" "$OUT"



echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]

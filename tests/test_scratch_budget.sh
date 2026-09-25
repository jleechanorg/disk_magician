#!/usr/bin/env bash
# test_scratch_budget.sh — coverage for scripts/lib/scratch_budget.sh
# (bead disk_magician-d45 / dcz): size-budget eviction engine shared by
# cleanup_tmp.sh and cleanup_pr_scratch.sh.
#
# Exercises scratch_budget_evict_root() directly against a minimal caller
# harness (log/path_size_kb/is_protected_root/is_protected_tmp_path/
# has_open_files stubs), mirroring the duck-typed contract both real
# sweepers already satisfy, so this proves the eviction LOGIC in isolation
# from either script's enumeration/CLI wiring.
#
# Tests:
# 1. Under-budget root: nothing evicted, total unaffected.
# 2. Over-budget root: evicts oldest-first by content mtime.
# 3. Stops evicting once back under budget (does not over-evict).
# 4. Young (<floor) items are never evicted even when the root is over
#    budget and nothing else is available to evict.
# 5. Open-file items (has_open_files=true) are preserved.
# 6. lsof failure (has_open_files fails closed / always "open") preserves
#    everything — zero deletions.
# 7. is_protected_root-matched candidates are preserved.
# 8. Dry-run mode reports what would be evicted without deleting.
# 9. Floor is clamped to a 60-minute minimum even if the caller passes less.
# 10. Every real eviction appends a persistent deletion-log line (bead
#     disk_magician-ka4).
# 11. DISK_MAGICIAN_TEST_SANDBOX set + root outside it aborts before any
#     deletion (bead disk_magician-ka4).
#
# Run: bash tests/test_scratch_budget.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMP_TEST_ROOT="$(mktemp -d -t test_scratch_budget.XXXXXX)"
trap 'chmod -R u+w "$TMP_TEST_ROOT" 2>/dev/null || true; rm -rf "$TMP_TEST_ROOT"' EXIT

# Persistent-deletion-log fixture (bead disk_magician-ka4): every real test
# invocation below points DISK_MAGICIAN_DELETION_LOG at this fixture file so
# no test run ever writes to the real ~/Library/Logs/disk-magician-deletions.log.
DELETION_LOG_FIXTURE="$TMP_TEST_ROOT/deletions.log"

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to exist: $path"; fi
}

assert_missing() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to be gone: $path"; fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then record_pass "$name"; else record_fail "$name" "expected '$expected', got '$actual'"; fi
}

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then record_pass "$name"; else record_fail "$name" "expected rc=$expected, got rc=$actual"; fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output to contain: $needle"
  fi
}

# make_kb_file <path> <kb> — a file of exactly <kb> KiB.
make_kb_file() {
  local path="$1" kb="$2"
  mkdir -p "$(dirname "$path")"
  dd if=/dev/zero of="$path" bs=1024 count="$kb" status=none
}

set_age_hours() {
  local path="$1" hours="$2"
  local stamp
  stamp="$(date -v-"${hours}"H +%Y%m%d%H%M 2>/dev/null || date -d "-${hours} hours" +%Y%m%d%H%M)"
  touch -t "$stamp" "$path"
}

set_age_minutes() {
  local path="$1" minutes="$2"
  local stamp
  stamp="$(date -v-"${minutes}"M +%Y%m%d%H%M 2>/dev/null || date -d "-${minutes} minutes" +%Y%m%d%H%M)"
  touch -t "$stamp" "$path"
}

# run_budget <root> <budget_kb> <floor_minutes> <open_pred_basename|-> <protected_root_basename|-> <lsof_fails|0/1> <dry_run|true/false> [test_sandbox_dir]
# Prints "dirs=<n> files=<n> kb=<n>" then the remaining root listing.
# DISK_MAGICIAN_DELETION_LOG always points at the fixture log (never the
# real ~/Library/Logs path). Every call carries DISK_MAGICIAN_TEST_CONTEXT
# (tests/lib/sandbox_env.sh names scratch_budget_evict_root as a covered
# destructive path -- PR #78 /advice round 2, Codex) and defaults
# DISK_MAGICIAN_TEST_SANDBOX to $TMP_TEST_ROOT, which contains every test's
# <root> fixture. [test_sandbox_dir], when given, overrides the sandbox to
# something NOT containing <root> so the production sandbox_guard_roots()
# abort can be exercised (bead disk_magician-ka4 acceptance criteria, Test11).
run_budget() {
  local root="$1" budget_kb="$2" floor_minutes="$3" open_base="$4" protected_base="$5" lsof_fails="$6" dry_run="$7"
  local sandbox_dir="${8:-$TMP_TEST_ROOT}"
  DM_ROOT="$root" DM_BUDGET_KB="$budget_kb" DM_FLOOR_MIN="$floor_minutes" \
  DM_OPEN_BASE="$open_base" DM_PROTECTED_BASE="$protected_base" DM_LSOF_FAILS="$lsof_fails" \
  DM_DRY_RUN="$dry_run" \
  DISK_MAGICIAN_DELETION_LOG="$DELETION_LOG_FIXTURE" \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$sandbox_dir" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/scripts/safety_lib.sh"
    source "'"$REPO_ROOT"'/scripts/lib/worktree_recency.sh"
    source "'"$REPO_ROOT"'/scripts/lib/scratch_budget.sh"

    DRY_RUN="$DM_DRY_RUN"
    log() { :; }
    path_size_kb() { du -sk "$1" 2>/dev/null | awk "{print \$1+0}"; }
    is_protected_root() { [[ -n "$DM_PROTECTED_BASE" && "$1" == "$DM_PROTECTED_BASE" ]]; }
    is_protected_tmp_path() { return 1; }
    has_open_files() {
      [[ "$DM_LSOF_FAILS" == "1" ]] && return 0
      [[ -n "$DM_OPEN_BASE" && "$(basename "$1")" == "$DM_OPEN_BASE" ]]
    }

    BUDGET_DIRS_DELETED=0
    BUDGET_FILES_DELETED=0
    BUDGET_KB_FREED=0
    scratch_budget_evict_root "$DM_ROOT" "$DM_BUDGET_KB" "$DM_FLOOR_MIN" >/dev/null
    echo "dirs=$BUDGET_DIRS_DELETED files=$BUDGET_FILES_DELETED kb=$BUDGET_KB_FREED"
  '
}

# ===================== Test 1: under budget — no-op =====================
R1="$TMP_TEST_ROOT/t1"
make_kb_file "$R1/a/f" 1024
set_age_hours "$R1/a/f" 5
result="$(run_budget "$R1" 10240 120 - - 0 false)"
assert_eq "Test1: under-budget root evicts nothing" "dirs=0 files=0 kb=0" "$result"
assert_exists "Test1: candidate survives" "$R1/a"

# ===================== Test 2: over budget — oldest first =====================
R2="$TMP_TEST_ROOT/t2"
make_kb_file "$R2/old/f" 2048
make_kb_file "$R2/mid/f" 2048
make_kb_file "$R2/new/f" 2048
set_age_hours "$R2/old/f" 10
set_age_hours "$R2/mid/f" 6
set_age_hours "$R2/new/f" 3
# total 6144 KB, budget 5120 KB -> only need to free 1024 KB -> evicts "old" only
result="$(run_budget "$R2" 5120 120 - - 0 false)"
assert_eq "Test2: over-budget evicts oldest first (1 dir)" "dirs=1 files=0 kb=2048" "$result"
assert_missing "Test2: oldest evicted" "$R2/old"
assert_exists "Test2: mid preserved (under budget after oldest evicted)" "$R2/mid"
assert_exists "Test2: newest preserved" "$R2/new"

# ===================== Test 3: stops once under budget =====================
R3="$TMP_TEST_ROOT/t3"
make_kb_file "$R3/oldest/f" 2048
make_kb_file "$R3/older/f" 2048
make_kb_file "$R3/newest/f" 2048
set_age_hours "$R3/oldest/f" 20
set_age_hours "$R3/older/f" 10
set_age_hours "$R3/newest/f" 3
# total 6144 KB, budget 3072 KB -> need 3072 KB -> evicting "oldest" alone (2048) isn't
# enough, so "older" is also evicted (cumulative 4096 >= 3072); "newest" must survive.
result="$(run_budget "$R3" 3072 120 - - 0 false)"
assert_eq "Test3: evicts until under budget then stops" "dirs=2 files=0 kb=4096" "$result"
assert_missing "Test3: oldest evicted" "$R3/oldest"
assert_missing "Test3: older evicted" "$R3/older"
assert_exists "Test3: newest survives (loop stopped)" "$R3/newest"

# ===================== Test 4: young (<floor) preserved =====================
R4="$TMP_TEST_ROOT/t4"
make_kb_file "$R4/young/f" 4096
set_age_hours "$R4/young/f" 1  # 1h old, floor is 2h (120min) -> too young
result="$(run_budget "$R4" 1024 120 - - 0 false)"
assert_eq "Test4: young item never evicted even though over budget" "dirs=0 files=0 kb=0" "$result"
assert_exists "Test4: young survives" "$R4/young"

# ===================== Test 5: open-file item preserved =====================
R5="$TMP_TEST_ROOT/t5"
make_kb_file "$R5/openitem/f" 2048
make_kb_file "$R5/closeditem/f" 2048
set_age_hours "$R5/openitem/f" 10
set_age_hours "$R5/closeditem/f" 10
result="$(run_budget "$R5" 1024 120 openitem - 0 false)"
assert_exists "Test5: open-file item preserved" "$R5/openitem"
assert_missing "Test5: closed item evicted instead" "$R5/closeditem"

# ===================== Test 6: lsof failure preserves ALL =====================
R6="$TMP_TEST_ROOT/t6"
make_kb_file "$R6/a/f" 2048
make_kb_file "$R6/b/f" 2048
set_age_hours "$R6/a/f" 10
set_age_hours "$R6/b/f" 10
result="$(run_budget "$R6" 1024 120 - - 1 false)"
assert_eq "Test6: lsof failure evicts nothing (fail closed)" "dirs=0 files=0 kb=0" "$result"
assert_exists "Test6: a survives" "$R6/a"
assert_exists "Test6: b survives" "$R6/b"

# ===================== Test 7: protected root preserved =====================
R7="$TMP_TEST_ROOT/t7"
make_kb_file "$R7/worldarchitect.ai/f" 4096
make_kb_file "$R7/evictable/f" 4096
set_age_hours "$R7/worldarchitect.ai/f" 20
set_age_hours "$R7/evictable/f" 20
result="$(run_budget "$R7" 1024 120 - worldarchitect.ai 0 false)"
assert_exists "Test7: protected root preserved" "$R7/worldarchitect.ai"
assert_missing "Test7: evictable candidate removed instead" "$R7/evictable"

# ===================== Test 8: dry-run reports without deleting =====================
R8="$TMP_TEST_ROOT/t8"
make_kb_file "$R8/old/f" 4096
set_age_hours "$R8/old/f" 10
result="$(run_budget "$R8" 1024 120 - - 0 true)"
# Dry-run still reports "would evict" counts (same convention as the real
# sweepers' DIRS_DELETED in their own --dry-run summaries) but must not
# touch the filesystem.
assert_eq "Test8: dry-run reports would-evict counts" "dirs=1 files=0 kb=4096" "$result"
assert_exists "Test8: dry-run does not actually delete" "$R8/old"

# ===================== Test 9: floor clamps to a 60-minute minimum =====================
R9="$TMP_TEST_ROOT/t9"
make_kb_file "$R9/almostfresh/f" 4096
# 30 min old: over a 0-minute floor (would be evictable if the clamp were
# missing) but under the mandatory 60-minute clamp -> must survive.
set_age_minutes "$R9/almostfresh/f" 30
result="$(run_budget "$R9" 1024 0 - - 0 false)"
assert_eq "Test9: 0-minute floor request clamps to 60min (30min-old item survives)" "dirs=0 files=0 kb=0" "$result"
assert_exists "Test9: 30min-old item survives the clamped 60min floor" "$R9/almostfresh"

# ===================== Test 10: persistent deletion log =====================
# Test 2's eviction of $R2/old above already ran with DISK_MAGICIAN_DELETION_LOG
# pointed at the fixture; verify the audit line actually landed (bead
# disk_magician-ka4 acceptance criteria: every real removal is logged
# independent of the caller's own stdout/stderr).
if [[ -f "$DELETION_LOG_FIXTURE" ]]; then
  record_pass "Test10: deletion log fixture file was created"
else
  record_fail "Test10: deletion log fixture file was created" "expected $DELETION_LOG_FIXTURE to exist"
fi
DELETION_LOG_CONTENT="$(cat "$DELETION_LOG_FIXTURE" 2>/dev/null || true)"
assert_contains "Test10: deletion log records evicted path" "$R2/old" "$DELETION_LOG_CONTENT"
assert_contains "Test10: deletion log records evict_budget action" "evict_budget" "$DELETION_LOG_CONTENT"
# Tab-separated: ts<TAB>script<TAB>action<TAB>kb<TAB>path
if awk -F'\t' -v needle="$R2/old" '$0 ~ needle && NF == 5 {found=1} END{exit !found}' "$DELETION_LOG_FIXTURE"; then
  record_pass "Test10: deletion log line has 5 tab-separated fields"
else
  record_fail "Test10: deletion log line has 5 tab-separated fields" "expected a 5-field TSV line for $R2/old"
fi

# ===================== Test 11: sandbox_guard_roots aborts outside sandbox =====================
# Bead disk_magician-ka4 acceptance criteria: when DISK_MAGICIAN_TEST_SANDBOX
# is set, scratch_budget_evict_root must abort BEFORE any deletion if the
# root resolves outside the sandbox — this is the mechanical backstop for
# the 2026-09-22 incident (a real run deleted host /private/tmp + $TMPDIR
# content because no such check existed).
R11="$TMP_TEST_ROOT/t11"
make_kb_file "$R11/old/f" 4096
set_age_hours "$R11/old/f" 10
UNRELATED_SANDBOX="$TMP_TEST_ROOT/unrelated-sandbox"
mkdir -p "$UNRELATED_SANDBOX"
set +e
result11="$(run_budget "$R11" 1024 120 - - 0 false "$UNRELATED_SANDBOX" 2>&1)"
rc11=$?
set -e
if [[ "$rc11" -eq 90 ]]; then
  record_pass "Test11: sandbox_guard_roots aborts with rc=90 when root is outside sandbox"
else
  record_fail "Test11: sandbox_guard_roots aborts with rc=90 when root is outside sandbox" "expected rc=90, got rc=$rc11: $result11"
fi
assert_contains "Test11: abort message names the offending root" "$R11" "$result11"
assert_exists "Test11: candidate untouched by the aborted run" "$R11/old"

# ===================== Test 12: unmeasurable content mtime is preserved =====================
# PR #71 /advice request-changes (Opus): scratch_budget_content_mtime()
# returned 0 (epoch) when stat/find failed on a subtree. Sorting oldest-first
# by mtime made that item sort FIRST for eviction -- the opposite of the
# "cannot measure -> preserve" rule this repo enforces everywhere else
# (worktree_recency.sh, safety_gate). An item whose content mtime cannot be
# determined must never be evicted, regardless of how over-budget the root is.
R12="$TMP_TEST_ROOT/t12"
make_kb_file "$R12/unmeasurable/f" 4096
make_kb_file "$R12/measurable/f" 4096
set_age_hours "$R12/unmeasurable/f" 10
set_age_hours "$R12/measurable/f" 10
result12="$(
  DISK_MAGICIAN_DELETION_LOG="$DELETION_LOG_FIXTURE" \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_TEST_ROOT" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/scripts/safety_lib.sh"
    source "'"$REPO_ROOT"'/scripts/lib/worktree_recency.sh"
    source "'"$REPO_ROOT"'/scripts/lib/scratch_budget.sh"

    DRY_RUN=false
    log() { echo "LOG: $*" >&2; }
    path_size_kb() { du -sk "$1" 2>/dev/null | awk "{print \$1+0}"; }
    is_protected_root() { return 1; }
    is_protected_tmp_path() { return 1; }
    has_open_files() { return 1; }
    # Override the real content-mtime probe: "unmeasurable" always fails to
    # measure (mirrors an unreadable subtree / a stat race), everything else
    # measures normally. Emits the empty-string sentinel the fixed
    # scratch_budget_content_mtime() itself now returns on failure (Test13) --
    # NOT the pre-fix "0" fallback, which a naive test could confuse with a
    # coincidental TSV-parsing side effect rather than the real fix.
    scratch_budget_content_mtime() {
      if [[ "$(basename "$1")" == "unmeasurable" ]]; then
        echo ""
        return 0
      fi
      find "$1" -type f -exec stat -f "%m" {} + 2>/dev/null \
        | awk "{if (\$1+0>m) m=\$1+0} END{print m+0}"
    }

    BUDGET_DIRS_DELETED=0
    BUDGET_FILES_DELETED=0
    BUDGET_KB_FREED=0
    scratch_budget_evict_root "'"$R12"'" 1024 120 >/dev/null
    echo "dirs=$BUDGET_DIRS_DELETED files=$BUDGET_FILES_DELETED kb=$BUDGET_KB_FREED"
  ' 2>&1
)"
BUDGET_COUNTS_LINE="$(tail -n1 <<<"$result12")"
assert_exists "Test12: unmeasurable-mtime item is preserved, never evicted" "$R12/unmeasurable"
assert_missing "Test12: measurable item evicted instead" "$R12/measurable"
assert_eq "Test12: exactly one eviction (the measurable item)" "dirs=1 files=0 kb=4096" "$BUDGET_COUNTS_LINE"
# The decisive assertion: an explicit preserve decision, not an accidental
# survival. Pre-fix, the enumeration loop unconditionally appends every
# candidate to the eviction-candidates file regardless of mtime validity and
# never logs this message -- so this line only appears once the enumeration
# loop explicitly filters out an unmeasurable candidate before eviction.
assert_contains "Test12: preserve decision is explicit and logged" \
  "cannot measure content mtime" "$result12"

# ===================== Test 13: content_mtime returns empty, not "0", on failure =====================
# Direct unit coverage of the contract change: a genuinely unmeasurable path
# (does not exist) must yield an empty string, never the string "0" (which a
# caller could confuse with a legitimate epoch-0 file and treat as ancient).
R13_MISSING="$TMP_TEST_ROOT/t13-does-not-exist"
mtime13="$(bash -c '
  source "'"$REPO_ROOT"'/scripts/lib/scratch_budget.sh"
  scratch_budget_content_mtime "'"$R13_MISSING"'"
')"
assert_eq "Test13: content_mtime is empty (not \"0\") for a missing/unmeasurable path" "" "$mtime13"

# ===================== Test 14: a `stat` failure on a top-level FILE must not abort the caller =====================
# /advice review of PR #78 (Opus, PR #71 follow-up): the FILE branch of
# scratch_budget_content_mtime() ran a bare `stat -f '%m' "$path" 2>/dev/null`
# with no `|| true`. Under the callers' `set -euo pipefail`, a `stat` failure
# (e.g. a file that vanishes between the caller's `-f` check and this
# function's own `stat` call -- the same TOCTOU class as the disk_magician-lsl
# incident) aborts the ENTIRE calling script instead of yielding "unmeasurable,
# preserve". Reproduced with a `stat` PATH shim that fails for exactly one
# real, existing file (so bash's builtin `[[ -f ]]` test still succeeds, only
# the external `stat` command fails).
R14="$TMP_TEST_ROOT/t14"
mkdir -p "$R14"
touch "$R14/racy-file.txt"
STAT_SHIM_BIN="$TMP_TEST_ROOT/t14-bin"
mkdir -p "$STAT_SHIM_BIN"
cat > "$STAT_SHIM_BIN/stat" <<EOF
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\$arg"; done
if [[ "\$last" == "$R14/racy-file.txt" ]]; then
  exit 1
fi
exec /usr/bin/stat "\$@"
EOF
chmod +x "$STAT_SHIM_BIN/stat"

set +e
result14="$(PATH="$STAT_SHIM_BIN:$PATH" bash -c '
  set -euo pipefail
  source "'"$REPO_ROOT"'/scripts/lib/scratch_budget.sh"
  echo "before call"
  mtime="$(scratch_budget_content_mtime "'"$R14/racy-file.txt"'")"
  echo "after call: mtime=[$mtime]"
' 2>&1)"
rc14=$?
set -e
assert_rc "Test14: caller script survives a stat failure on a top-level file" 0 "$rc14"
assert_contains "Test14: caller reaches the line after the failed-stat call" "after call: mtime=[]" "$result14"

# ===================== Test 15: TemporaryItems basename excluded (round-3 /advice) =====================
R15="$TMP_TEST_ROOT/t15"
make_kb_file "$R15/TemporaryItems/f" 5120
set_age_hours "$R15/TemporaryItems/f" 20
make_kb_file "$R15/old_scratch/f" 5120
set_age_hours "$R15/old_scratch/f" 5
run_budget "$R15" 1024 60 - - 0 false >/dev/null
assert_exists "Test15: TemporaryItems survives eviction even as the oldest/largest candidate" "$R15/TemporaryItems"
assert_missing "Test15: plain old scratch dir is still evicted under the same budget pressure" "$R15/old_scratch"

echo ""
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

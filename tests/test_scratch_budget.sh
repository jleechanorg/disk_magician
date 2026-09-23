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
#
# Run: bash tests/test_scratch_budget.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_TEST_ROOT="$(mktemp -d -t test_scratch_budget.XXXXXX)"
trap 'chmod -R u+w "$TMP_TEST_ROOT" 2>/dev/null || true; rm -rf "$TMP_TEST_ROOT"' EXIT

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

# run_budget <root> <budget_kb> <floor_minutes> <open_pred_basename|-> <protected_root_basename|-> <lsof_fails|0/1> <dry_run|true/false>
# Prints "dirs=<n> files=<n> kb=<n>" then the remaining root listing.
run_budget() {
  local root="$1" budget_kb="$2" floor_minutes="$3" open_base="$4" protected_base="$5" lsof_fails="$6" dry_run="$7"
  DM_ROOT="$root" DM_BUDGET_KB="$budget_kb" DM_FLOOR_MIN="$floor_minutes" \
  DM_OPEN_BASE="$open_base" DM_PROTECTED_BASE="$protected_base" DM_LSOF_FAILS="$lsof_fails" \
  DM_DRY_RUN="$dry_run" bash -c '
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

echo ""
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

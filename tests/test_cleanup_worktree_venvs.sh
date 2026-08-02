#!/usr/bin/env bash
# test_cleanup_worktree_venvs.sh — fixture tests for scripts/cleanup_worktree_venvs.sh
#
# Covers bead disk_magician-7v3 (--purge-bak-days) and bead disk_magician-w7m
# (concurrency lock). Style mirrors tests/test_cleanup_worktrees_repo_local.sh
# (env -i subprocess invocation, PASS/FAIL counters) and
# tests/test_worktree_recency.sh (synthetic .git-pointer fixtures — no real
# git binary needed, since is_likely_worktree only checks for a `.git` FILE
# and worktree_age_days only reads file mtimes).
#
# Run: bash tests/test_cleanup_worktree_venvs.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_worktree_venvs.sh"

TMP_ROOT=$(mktemp -d -t cleanup_wt_venvs.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_fail "$name" "unexpected: $needle"
  else
    record_pass "$name"
  fi
}

# mk_worktree <path> — fake linked-worktree shape: a .git POINTER FILE (not a
# real git admin dir — matches test_worktree_recency.sh's mk_worktree; neither
# is_likely_worktree() nor worktree_age_days() need a real git repo).
mk_worktree() {
  local wt="$1"
  mkdir -p "$wt"
  echo "gitdir: /fake/admin/$(basename "$wt")" > "$wt/.git"
}

# age_path_days_ago <path> <days> — backdate a single path's mtime.
age_path_days_ago() {
  local path="$1" days="$2" ts
  ts=$(date -v-"${days}"d +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

STATE_DIR="$TMP_ROOT/state"
ROOTS_DIR="$TMP_ROOT/roots"
mkdir -p "$STATE_DIR" "$ROOTS_DIR"

echo "=== fixtures ==="

# (a) stale worktree (>14d real activity) with a venv.bak.* older than
# --purge-bak-days -> must be flagged for purge in dry-run.
#
# The bak dir is left EMPTY (no files inside): worktree_recency.sh's scan
# only counts `-type f` mtimes, never directory mtimes, so an empty bak dir
# contributes nothing to the worktree's measured activity regardless of its
# own age. This matters for realism too — a real `mv venv venv.bak.<ts>`
# preserves the moved files' original (old) mtimes, it does not bump them to
# "now"; a bak dir loaded with freshly-touched content would be an unrealistic
# fixture that self-poisons the very recency signal this test is verifying.
STALE_WT="$ROOTS_DIR/stale_wt"
mk_worktree "$STALE_WT"
: > "$STALE_WT/README.md"
age_path_days_ago "$STALE_WT/README.md" 30
age_path_days_ago "$STALE_WT/.git" 30
mkdir -p "$STALE_WT/venv.bak.20260101"
age_path_days_ago "$STALE_WT/venv.bak.20260101" 10

# (b) RECENT worktree (<14d — touched "now") whose venv.bak.* dir looks
# ancient on its own (60d) -> must stay protected because the PARENT is young.
RECENT_WT="$ROOTS_DIR/recent_wt"
mk_worktree "$RECENT_WT"
: > "$RECENT_WT/README.md"
touch "$RECENT_WT/README.md"   # now — age 0
mkdir -p "$RECENT_WT/venv.bak.20251201"
age_path_days_ago "$RECENT_WT/venv.bak.20251201" 60

# (d) UNMEASURABLE worktree: only a .git pointer + an EMPTY venv.bak.* dir
# (no regular files anywhere in the tree) -> worktree_age_days can find no
# evidence at all and fails closed to age 0 ("now"), i.e. protected — the
# same fail-closed contract as test_worktree_recency.sh case 5, exercised
# here through this script's own gate.
UNMEASURABLE_WT="$ROOTS_DIR/unmeasurable_wt"
mk_worktree "$UNMEASURABLE_WT"
age_path_days_ago "$UNMEASURABLE_WT/.git" 30
mkdir -p "$UNMEASURABLE_WT/venv.bak.20250101"
age_path_days_ago "$UNMEASURABLE_WT/venv.bak.20250101" 60

echo
echo "=== Test 1: dry-run --purge-bak-days flags only the stale worktree's bak dir ==="
OUT1="$TMP_ROOT/out1.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --purge-bak-days 5 --dry-run \
  >"$OUT1" 2>&1
OUT1_CONTENT=$(cat "$OUT1")

assert_contains "(a) stale bak dir flagged in dry-run" \
  "would purge $STALE_WT/venv.bak.20260101" "$OUT1_CONTENT"
assert_not_contains "(b) recent-worktree bak dir NOT flagged" \
  "would purge $RECENT_WT/venv.bak.20251201" "$OUT1_CONTENT"
assert_contains "(b) recent-worktree bak dir reported protected" \
  "skip (parent worktree < 14d, protected): $RECENT_WT/venv.bak.20251201" "$OUT1_CONTENT"
assert_not_contains "(d) unmeasurable-worktree bak dir NOT flagged" \
  "would purge $UNMEASURABLE_WT/venv.bak.20250101" "$OUT1_CONTENT"
assert_contains "(d) unmeasurable-worktree bak dir reported protected (fail-closed)" \
  "skip (parent worktree < 14d, protected): $UNMEASURABLE_WT/venv.bak.20250101" "$OUT1_CONTENT"

if [[ -d "$STALE_WT/venv.bak.20260101" && -d "$RECENT_WT/venv.bak.20251201" && -d "$UNMEASURABLE_WT/venv.bak.20250101" ]]; then
  record_pass "dry-run deleted nothing"
else
  record_fail "dry-run deleted nothing" "a bak dir vanished during a dry-run"
fi

echo
echo "=== Test 2 (c): --clean --purge-bak-days without WORKTREE_APPROVED=1 refuses, deletes nothing ==="
OUT2="$TMP_ROOT/out2.txt"
set +e
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --purge-bak-days 5 --clean \
  >"$OUT2" 2>&1
RC2=$?
set -e
OUT2_CONTENT=$(cat "$OUT2")
if [[ "$RC2" -eq 3 ]]; then record_pass "(c) refused with expected exit code 3"; else record_fail "(c) refused with expected exit code 3" "rc=$RC2"; fi
assert_contains "(c) refusal message" "requires WORKTREE APPROVED=1" "$OUT2_CONTENT"
if [[ -d "$STALE_WT/venv.bak.20260101" ]]; then
  record_pass "(c) stale bak dir still on disk after refused --clean"
else
  record_fail "(c) stale bak dir still on disk after refused --clean" "bak dir removed without approval"
fi

echo
echo "=== Test 3: --clean --purge-bak-days WITH WORKTREE_APPROVED=1 actually purges only the stale one ==="
OUT3="$TMP_ROOT/out3.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  WORKTREE_APPROVED=1 \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --purge-bak-days 5 --clean \
  >"$OUT3" 2>&1
if [[ ! -d "$STALE_WT/venv.bak.20260101" ]]; then
  record_pass "stale bak dir actually removed with approval"
else
  record_fail "stale bak dir actually removed with approval" "still present: $STALE_WT/venv.bak.20260101"
fi
if [[ -d "$RECENT_WT/venv.bak.20251201" ]]; then
  record_pass "recent-worktree bak dir survives real --clean run"
else
  record_fail "recent-worktree bak dir survives real --clean run" "was deleted despite young parent"
fi
if [[ -d "$UNMEASURABLE_WT/venv.bak.20250101" ]]; then
  record_pass "unmeasurable-worktree bak dir survives real --clean run"
else
  record_fail "unmeasurable-worktree bak dir survives real --clean run" "was deleted despite fail-closed protection"
fi

echo
echo "=== Test 4 (w7m): concurrent invocation skips instead of running alongside ==="
mkdir -p "$STATE_DIR/cleanup_worktree_venvs.lock"
echo 999999 > "$STATE_DIR/cleanup_worktree_venvs.lock/pid"   # pid unlikely to exist -> but lock is fresh (age 0), so TTL steal must NOT kick in
OUT4="$TMP_ROOT/out4.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run \
  >"$OUT4" 2>&1
RC4=$?
OUT4_CONTENT=$(cat "$OUT4")
if [[ "$RC4" -eq 0 ]]; then record_pass "held-lock run exits 0 (skip, not error)"; else record_fail "held-lock run exits 0 (skip, not error)" "rc=$RC4"; fi
assert_contains "held-lock run logs skip message" "skipped, lock held" "$OUT4_CONTENT"
assert_not_contains "held-lock run does not scan" "=== STRIP DORMANT WORKTREE VENVS ===" "$OUT4_CONTENT"
rm -rf "$STATE_DIR/cleanup_worktree_venvs.lock"

echo
echo "=== Test 5 (w7m): lock is released after a normal run, so a second run proceeds ==="
OUT5="$TMP_ROOT/out5.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run \
  >"$OUT5" 2>&1
assert_contains "post-release run proceeds normally" "=== STRIP DORMANT WORKTREE VENVS ===" "$(cat "$OUT5")"
if [[ -d "$STATE_DIR/cleanup_worktree_venvs.lock" ]]; then
  record_fail "lock released on exit" "lock dir still present after run completed"
else
  record_pass "lock released on exit"
fi

echo
echo "=== Test 6 (7v3 roots gap): <repo>/.claude/worktrees/* agent trees are discovered and stripped ==="
CLAUDE_WT="$ROOTS_DIR/some_repo/.claude/worktrees/agent-xyz"
mk_worktree "$CLAUDE_WT"
: > "$CLAUDE_WT/README.md"
age_path_days_ago "$CLAUDE_WT/README.md" 30
age_path_days_ago "$CLAUDE_WT/.git" 30
mkdir -p "$CLAUDE_WT/venv/lib"
: > "$CLAUDE_WT/venv/lib/site.py"
age_path_days_ago "$CLAUDE_WT/venv/lib/site.py" 30
OUT6="$TMP_ROOT/out6.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run \
  >"$OUT6" 2>&1
OUT6_CONTENT=$(cat "$OUT6")
assert_contains "roots log includes expanded .claude/worktrees dir" \
  "$ROOTS_DIR/some_repo/.claude/worktrees" "$OUT6_CONTENT"
assert_contains "agent-tree venv flagged for stripping" \
  "would strip $CLAUDE_WT/venv" "$OUT6_CONTENT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

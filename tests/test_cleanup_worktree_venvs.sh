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
mkdir -p "$STALE_WT/.venv.bak.20260101"
age_path_days_ago "$STALE_WT/.venv.bak.20260101" 10

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
assert_contains "(a) stale .venv bak dir flagged in dry-run" \
  "would purge $STALE_WT/.venv.bak.20260101" "$OUT1_CONTENT"
assert_not_contains "(b) recent-worktree bak dir NOT flagged" \
  "would purge $RECENT_WT/venv.bak.20251201" "$OUT1_CONTENT"
assert_contains "(b) recent-worktree bak dir reported protected" \
  "skip (parent worktree < 14d, protected): $RECENT_WT/venv.bak.20251201" "$OUT1_CONTENT"
assert_not_contains "(d) unmeasurable-worktree bak dir NOT flagged" \
  "would purge $UNMEASURABLE_WT/venv.bak.20250101" "$OUT1_CONTENT"
assert_contains "(d) unmeasurable-worktree bak dir reported protected (fail-closed)" \
  "skip (parent worktree < 14d, protected): $UNMEASURABLE_WT/venv.bak.20250101" "$OUT1_CONTENT"

if [[ -d "$STALE_WT/venv.bak.20260101" && -d "$STALE_WT/.venv.bak.20260101" && -d "$RECENT_WT/venv.bak.20251201" && -d "$UNMEASURABLE_WT/venv.bak.20250101" ]]; then
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
assert_contains "(c) refusal message" "requires WORKTREE_APPROVED=1" "$OUT2_CONTENT"
if [[ -d "$STALE_WT/venv.bak.20260101" && -d "$STALE_WT/.venv.bak.20260101" ]]; then
  record_pass "(c) stale bak dirs still on disk after refused --clean"
else
  record_fail "(c) stale bak dirs still on disk after refused --clean" "bak dir removed without approval"
fi

echo
echo "=== Test 3: --clean --purge-bak-days WITH WORKTREE_APPROVED=1 actually purges only the stale one ==="
OUT3="$TMP_ROOT/out3.txt"
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  WORKTREE_APPROVED=1 \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --purge-bak-days 5 --clean \
  >"$OUT3" 2>&1
if [[ ! -d "$STALE_WT/venv.bak.20260101" && ! -d "$STALE_WT/.venv.bak.20260101" ]]; then
  record_pass "stale bak dirs actually removed with approval"
else
  record_fail "stale bak dirs actually removed with approval" "still present in: $STALE_WT"
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
echo "=== Test 6b: default roots include \$HOME/.worktrees, 7-day rule still applies ==="
STD_HOME="$TMP_ROOT/stdhome"
STD_OLD="$STD_HOME/.worktrees/r/old"
STD_YOUNG="$STD_HOME/.worktrees/r/young"
for wt in "$STD_OLD" "$STD_YOUNG"; do
  mk_worktree "$wt"
  : > "$wt/README.md"
  mkdir -p "$wt/.venv/lib"
  : > "$wt/.venv/lib/site.py"
done
for p in "$STD_OLD/README.md" "$STD_OLD/.git" "$STD_OLD/.venv/lib/site.py"; do
  age_path_days_ago "$p" 10
done
age_path_days_ago "$STD_YOUNG/README.md" 2
OUT6B="$TMP_ROOT/out6b.txt"
env -i HOME="$STD_HOME" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --dry-run >"$OUT6B" 2>&1
OUT6B_CONTENT=$(cat "$OUT6B")
assert_contains "default roots list \$HOME/.worktrees" "$STD_HOME/.worktrees" "$OUT6B_CONTENT"
assert_contains "10d std-root venv flagged" "would strip $STD_OLD/.venv" "$OUT6B_CONTENT"
assert_not_contains "2d std-root venv protected" "would strip $STD_YOUNG/.venv" "$OUT6B_CONTENT"

echo
echo "=== Test 7: hard floor clamp survives leading-zero and sub-floor overrides ==="
# bash's `-lt`/`(( ))` parse a leading-zero numeral like "08" as octal
# (invalid digit -> arithmetic error) if compared without a base prefix;
# a naive regex-only clamp lets "08" through unclamped and later crashes /
# fails open downstream (found live by both /advice reviewers, PR #55).
# Isolated via the same env -i HOME/DISK_MAGICIAN_STATE_DIR pattern as
# every other invocation in this file -- a bare env-var call would share
# this host's real lock file and could flake under concurrent contention
# (found live by /advice round 4).
OUT7_ZERO=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" WORKTREE_MIN_AGE_DAYS=0 \
  bash "$TARGET_SCRIPT" --dry-run --roots "$TMP_ROOT/nonexistent" 2>&1)
assert_contains "WORKTREE_MIN_AGE_DAYS=0 clamps to the 7-day floor" "Min age:    7 days" "$OUT7_ZERO"

OUT7_OCTAL=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" WORKTREE_MIN_AGE_DAYS=08 \
  bash "$TARGET_SCRIPT" --dry-run --roots "$TMP_ROOT/nonexistent" 2>&1)
assert_contains "WORKTREE_MIN_AGE_DAYS=08 normalizes without an octal error" "Min age:    8 days" "$OUT7_OCTAL"
[[ "$OUT7_OCTAL" != *"value too great for base"* ]] \
  && record_pass "no arithmetic error on leading-zero input" \
  || record_fail "no arithmetic error on leading-zero input" "$OUT7_OCTAL"

OUT7_RAISED=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" WORKTREE_MIN_AGE_DAYS=30 \
  bash "$TARGET_SCRIPT" --dry-run --roots "$TMP_ROOT/nonexistent" 2>&1)
assert_contains "a raised floor (30) is preserved, not clamped down" "Min age:    30 days" "$OUT7_RAISED"

echo
echo "=== Test 8 (9h3): bounded discovery — same worktrees found, no deep/root find traversal ==="
# Fake find on PATH logs every invocation's start dir, then defers to the real
# find (worktree_recency.sh legitimately runs find INSIDE candidate worktrees).
FAKEBIN="$TMP_ROOT/fakebin"; FIND_LOG="$TMP_ROOT/find_calls.log"
mkdir -p "$FAKEBIN"; : > "$FIND_LOG"
cat > "$FAKEBIN/find" <<SHIM
#!/bin/bash
printf '%s\n' "\$1" >> "$FIND_LOG"
exec /usr/bin/find "\$@"
SHIM
chmod +x "$FAKEBIN/find"

R8="$TMP_ROOT/roots8"
mk_stale_wt_with_venv() {  # <wt-path> (creates the worktree if absent)
  local wt="$1"
  [[ -e "$wt/.git" ]] || mk_worktree "$wt"
  : > "$wt/README.md"; mkdir -p "$wt/.venv/lib"; : > "$wt/.venv/lib/site.py"
  for p in "$wt/README.md" "$wt/.git" "$wt/.venv/lib/site.py"; do age_path_days_ago "$p" 30; done
}
# (1) plain worktree at depth 1
mk_stale_wt_with_venv "$R8/plain_wt"
# (2) agent tree under a repo at depth 2: <root>/org/repoB/.claude/worktrees/agent1
mk_stale_wt_with_venv "$R8/org/repoB/.claude/worktrees/agent1"
# (3) git-registered worktree nested at depth 4 — only reachable via
#     `git worktree list --porcelain` of the discovered repo
GIT8="/usr/bin/git"
if "$GIT8" --version >/dev/null 2>&1; then
  mkdir -p "$R8/repoA"
  "$GIT8" -C "$R8/repoA" init -q
  "$GIT8" -C "$R8/repoA" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  "$GIT8" -C "$R8/repoA" worktree add -q "$R8/repoA/nested/deep/wtA" >/dev/null 2>&1
  find "$R8/repoA/nested/deep/wtA" -exec touch -t "$(date -v-30d +%Y%m%d%H%M)" {} + 2>/dev/null
  mk_stale_wt_with_venv "$R8/repoA/nested/deep/wtA"
fi
# (4) deep tree (depth 5-6) under node_modules holding a worktree-shaped dir —
#     must NOT be traversed or flagged
DEEP_WT="$R8/node_modules/a/b/c/deepwt"
mk_stale_wt_with_venv "$DEEP_WT"
mkdir -p "$R8/node_modules/a/b/c/d/e/f"

: > "$FIND_LOG"
OUT8="$TMP_ROOT/out8.txt"
env -i HOME="$TMP_ROOT/home" PATH="$FAKEBIN:/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$R8" --min-age 14 --purge-bak-days 5 --dry-run \
  >"$OUT8" 2>&1
OUT8_CONTENT=$(cat "$OUT8")
assert_contains "depth-1 worktree venv found" "would strip $R8/plain_wt/.venv" "$OUT8_CONTENT"
assert_contains "depth-2 repo .claude/worktrees agent venv found" \
  "would strip $R8/org/repoB/.claude/worktrees/agent1/.venv" "$OUT8_CONTENT"
if "$GIT8" --version >/dev/null 2>&1; then
  assert_contains "git-registered nested worktree venv found" "deep/wtA/.venv (" "$OUT8_CONTENT"
fi
assert_not_contains "deep node_modules worktree NOT flagged" "would strip $DEEP_WT/.venv" "$OUT8_CONTENT"
if grep -qxF "$R8" "$FIND_LOG" || grep -qF "$R8/node_modules" "$FIND_LOG" \
   || grep -qxF "$R8/org/repoB/.claude/worktrees" "$FIND_LOG"; then
  record_fail "no find traversal from a root or into node_modules" "$(sort -u "$FIND_LOG" | head -5)"
else
  record_pass "no find traversal from a root or into node_modules"
fi

echo "=== Test 9 (9h3): discovery never broadens past the old find scope ==="
R9="$TMP_ROOT/roots9"
if "$GIT8" --version >/dev/null 2>&1; then
  mkdir -p "$R9/repoA"
  "$GIT8" -C "$R9/repoA" init -q
  "$GIT8" -C "$R9/repoA" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  "$GIT8" -C "$R9/repoA" worktree add -q "$R9/repoA/a/b/c/d/e/f/wtDeep" >/dev/null 2>&1
  mk_stale_wt_with_venv "$R9/repoA/a/b/c/d/e/f/wtDeep"
fi
# a worktree passed directly as --roots: the old -mindepth 2 never stripped <root>/.venv
mk_stale_wt_with_venv "$R9/rootwt"
OUT9=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$R9" --min-age 14 --purge-bak-days 5 --dry-run 2>&1)
OUT9R=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$R9/rootwt" --min-age 14 --purge-bak-days 5 --dry-run 2>&1)
if "$GIT8" --version >/dev/null 2>&1; then
  assert_not_contains "registered worktree deeper than old scope NOT flagged" "wtDeep/.venv" "$OUT9"
fi
assert_not_contains "--roots <worktree> does not strip the root's own venv" "would strip $R9/rootwt/.venv" "$OUT9R"

# symlinked dirs under the root lead outside it; the old find -P never followed them
OUTSIDE9="$TMP_ROOT/outside9"
mk_stale_wt_with_venv "$OUTSIDE9/org/wtT"
mk_stale_wt_with_venv "$OUTSIDE9/repoX/.claude/worktrees/brX"
ln -s "$OUTSIDE9/org" "$R9/slink"
ln -s "$OUTSIDE9/repoX" "$R9/slink2"
if "$GIT8" --version >/dev/null 2>&1; then
  mkdir -p "$OUTSIDE9/real"
  ln -s "$OUTSIDE9/real" "$R9/repoA/linkreg"
  "$GIT8" -C "$R9/repoA" worktree add -q "$R9/repoA/linkreg/wt6" >/dev/null 2>&1
  mk_stale_wt_with_venv "$R9/repoA/linkreg/wt6"
  # git realpaths new registrations; record the symlinked path as older/other tools may
  printf '%s\n' "$R9/repoA/linkreg/wt6/.git" > "$R9/repoA/.git/worktrees/wt6/gitdir"
  "$GIT8" -C "$R9/repoA" worktree list --porcelain | grep -q "^worktree $R9/repoA/linkreg/wt6\$" \
    || echo "  NOTE  git normalized the symlinked registration path; wt6 case is vacuous here"
fi
OUT9S=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$R9" --min-age 14 --purge-bak-days 5 --dry-run 2>&1)
assert_not_contains "worktree behind a symlinked dir NOT flagged" "wtT/.venv" "$OUT9S"
assert_not_contains "agent worktrees behind a symlinked repo NOT flagged" "brX/.venv" "$OUT9S"
assert_not_contains "registered worktree via symlinked path NOT flagged" "wt6/.venv" "$OUT9S"
if "$GIT8" --version >/dev/null 2>&1; then
  mkdir -p "$R9/repoA/locked/sub"
  "$GIT8" -C "$R9/repoA" worktree add -q "$R9/repoA/locked/sub/wtlocked" >/dev/null 2>&1
  mk_stale_wt_with_venv "$R9/repoA/locked/sub/wtlocked"
  chmod 311 "$R9/repoA/locked"
  OUT9X=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    bash "$TARGET_SCRIPT" --roots "$R9" --min-age 14 --purge-bak-days 5 --dry-run 2>&1)
  chmod 755 "$R9/repoA/locked"
  assert_not_contains "registered worktree under an exec-only dir NOT flagged" "wtlocked/.venv" "$OUT9X"
fi
ln -s "$R9" "$TMP_ROOT/roots9link"
OUT9L=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  bash "$TARGET_SCRIPT" --roots "$TMP_ROOT/roots9link" --min-age 14 --purge-bak-days 5 --dry-run 2>&1)
assert_not_contains "a --roots entry that is itself a symlink is not scanned" "would strip" "$OUT9L"

echo
echo "=== Test 10 (ez5pho): 5-min load per core deferral gate ==="
OUT10=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_LOAD5_OVERRIDE="5.5000" \
  DISK_MAGICIAN_MAX_LOAD5_PER_CORE="4.0" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run 2>&1)
assert_contains "high load per core defers execution" "exceeds max 4.0" "$OUT10"
assert_not_contains "high load per core does not scan" "=== STRIP DORMANT WORKTREE VENVS ===" "$OUT10"

OUT10_INVALID=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_LOAD5_OVERRIDE="invalid_load_string" \
  DISK_MAGICIAN_MAX_LOAD5_PER_CORE="4.0" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run 2>&1)
assert_contains "invalid load reading defers execution (fail-closed)" "unmeasurable" "$OUT10_INVALID"
assert_not_contains "invalid load reading does not scan" "=== STRIP DORMANT WORKTREE VENVS ===" "$OUT10_INVALID"

OUT10_NORMAL=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_LOAD5_OVERRIDE="1.5000" \
  DISK_MAGICIAN_MAX_LOAD5_PER_CORE="4.0" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run 2>&1)
assert_contains "normal load per core proceeds to scan" "=== STRIP DORMANT WORKTREE VENVS ===" "$OUT10_NORMAL"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_cleanup_claude_state.sh — fixture tests for scripts/cleanup_claude_state.sh
# (bead disk_magician-isw: ~/.claude/state per-task work dirs have no reclaim
# path). Style mirrors tests/test_cleanup_worktree_venvs.sh (env subprocess
# invocation, PASS/FAIL counters, real fixtures under a mktemp dir only --
# NEVER touches the real ~/.claude/state).
#
# Run: bash tests/test_cleanup_claude_state.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_claude_state.sh"

TMP_ROOT=$(mktemp -d -t cleanup_claude_state.XXXXXX)
BG_PIDS=()
cleanup() {
  local pid
  for pid in "${BG_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

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

age_path_days_ago() {
  local path="$1" days="$2" ts
  ts=$(date -v-"${days}"d +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

# Real PATH needed: /usr/bin (git), /usr/sbin (lsof), and wherever GNU
# coreutils `timeout` lives on this box (checked live -- not assumed).
TIMEOUT_BIN_DIR="$(dirname "$(command -v timeout)")"
REAL_PATH="/usr/bin:/bin:/usr/sbin:$TIMEOUT_BIN_DIR"

ROOTS_DIR="$TMP_ROOT/state"
mkdir -p "$ROOTS_DIR"
# Canonicalize now (macOS /var -> /private/var symlink) so every fixture
# path built below matches what the script itself reports (it resolves
# STATE_ROOT via `cd ... && pwd -P`).
ROOTS_DIR="$(cd "$ROOTS_DIR" && pwd -P)"

# mk_git_remote <name> -- a bare "remote" repo other fixtures clone/push to.
mk_git_remote() {
  local name="$1"
  git init --bare -q "$TMP_ROOT/remotes/$name.git"
}

echo "=== fixtures ==="
mkdir -p "$TMP_ROOT/remotes"

# (1) OLD CLEAN CLONE -- clone from a remote, HEAD == origin/main, no local
# changes, all content backdated >7d -> ELIGIBLE.
mk_git_remote old_clean
git -C "$TMP_ROOT/remotes/old_clean.git" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
SEED="$TMP_ROOT/seed_old_clean"
git init -q "$SEED"
git -C "$SEED" config user.email jleechan2015@users.noreply.github.com
git -C "$SEED" config user.name tester
echo hello > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m init
git -C "$SEED" branch -M main
git -C "$SEED" remote add origin "$TMP_ROOT/remotes/old_clean.git"
git -C "$SEED" push -q origin main
OLD_CLEAN="$ROOTS_DIR/old-clean-abcd"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$OLD_CLEAN"
git -C "$OLD_CLEAN" config user.email jleechan2015@users.noreply.github.com
git -C "$OLD_CLEAN" config user.name tester
while IFS= read -r f; do age_path_days_ago "$f" 30; done < <(find "$OLD_CLEAN" -type f)

# (2) YOUNG CLONE -- same shape, but content touched "now" -> PRESERVED
# even though we will NOT backdate the dir itself (dir mtime is irrelevant).
YOUNG="$ROOTS_DIR/young-clone-efgh"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$YOUNG"
git -C "$YOUNG" config user.email jleechan2015@users.noreply.github.com
git -C "$YOUNG" config user.name tester
touch "$YOUNG/README.md"

# (3) DIRTY REPO -- old clone, but with an uncommitted change -> NEEDS-REVIEW.
# Content must still read as >=7d old (via worktree_age_days) so the run
# reaches the git-triage branch instead of bailing out early on age; the
# `echo >>` touches mtime to "now", so backdate AFTER dirtying, not before.
DIRTY="$ROOTS_DIR/dirty-clone-ijkl"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$DIRTY"
git -C "$DIRTY" config user.email jleechan2015@users.noreply.github.com
git -C "$DIRTY" config user.name tester
echo "uncommitted" >> "$DIRTY/README.md"
while IFS= read -r f; do age_path_days_ago "$f" 30; done < <(find "$DIRTY" -type f)

# (4) UNPUSHED COMMIT -- old clone, clean working tree, but a local commit
# that was never pushed (no upstream ahead) -> NEEDS-REVIEW.
UNPUSHED="$ROOTS_DIR/unpushed-clone-mnop"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$UNPUSHED"
git -C "$UNPUSHED" config user.email jleechan2015@users.noreply.github.com
git -C "$UNPUSHED" config user.name tester
echo "local only" > "$UNPUSHED/local.txt"
git -C "$UNPUSHED" add local.txt
git -C "$UNPUSHED" commit -q -m "local only commit"
while IFS= read -r f; do age_path_days_ago "$f" 30; done < <(find "$UNPUSHED" -type f)

# (5) STASH PRESENT -- old clone, clean working tree, but a stash entry ->
# NEEDS-REVIEW.
STASHED="$ROOTS_DIR/stashed-clone-qrst"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$STASHED"
git -C "$STASHED" config user.email jleechan2015@users.noreply.github.com
git -C "$STASHED" config user.name tester
echo "stash me" >> "$STASHED/README.md"
git -C "$STASHED" stash -q
while IFS= read -r f; do age_path_days_ago "$f" 30; done < <(find "$STASHED" -type f)

# (6) UNMEASURABLE AGE -- an empty dir (no regular files at all) -> age 0
# via worktree_age_days's fail-closed contract -> PRESERVED.
UNMEASURABLE="$ROOTS_DIR/unmeasurable-uvwx"
mkdir -p "$UNMEASURABLE"

# (7) SYMLINK ESCAPE -- a direct child of the state root that is itself a
# symlink pointing outside the root -> REFUSED, never followed.
ESCAPE_TARGET="$TMP_ROOT/outside_target"
mkdir -p "$ESCAPE_TARGET"
: > "$ESCAPE_TARGET/secret.txt"
ln -s "$ESCAPE_TARGET" "$ROOTS_DIR/escape-symlink-yzab"

echo
echo "=== Test 1: dry-run classifies each fixture correctly ==="
OUT1="$TMP_ROOT/out1.txt"
env -i HOME="$TMP_ROOT/home" PATH="$REAL_PATH" \
  bash "$TARGET_SCRIPT" --root "$ROOTS_DIR" --min-age 7 --dry-run \
  >"$OUT1" 2>&1
OUT1_CONTENT=$(cat "$OUT1")
echo "$OUT1_CONTENT" | sed 's/^/    /'

assert_contains "(1) old clean clone -> ELIGIBLE" "ELIGIBLE $OLD_CLEAN" "$OUT1_CONTENT"
assert_contains "(2) young clone -> PRESERVE (age)" "PRESERVE $YOUNG" "$OUT1_CONTENT"
assert_contains "(3) dirty repo -> NEEDS-REVIEW" "NEEDS-REVIEW $DIRTY  (dirty" "$OUT1_CONTENT"
assert_contains "(4) unpushed commit -> NEEDS-REVIEW" "NEEDS-REVIEW $UNPUSHED  (unpushed-ahead-of-upstream" "$OUT1_CONTENT"
assert_contains "(5) stash present -> NEEDS-REVIEW" "NEEDS-REVIEW $STASHED  (stash-present" "$OUT1_CONTENT"
assert_contains "(6) unmeasurable age -> PRESERVE" "PRESERVE $UNMEASURABLE" "$OUT1_CONTENT"
assert_contains "(7) symlink escape -> REFUSED" "REFUSED  $ROOTS_DIR/escape-symlink-yzab" "$OUT1_CONTENT"

if [[ -d "$OLD_CLEAN" && -d "$DIRTY" && -d "$UNPUSHED" ]]; then
  record_pass "dry-run deleted nothing"
else
  record_fail "dry-run deleted nothing" "a fixture vanished during a dry-run"
fi

echo
echo "=== Test 2: lsof active handle -> PRESERVE ==="
LSOF_ACTIVE="$ROOTS_DIR/lsof-active-cdef"
git clone -q "$TMP_ROOT/remotes/old_clean.git" "$LSOF_ACTIVE"
git -C "$LSOF_ACTIVE" config user.email jleechan2015@users.noreply.github.com
git -C "$LSOF_ACTIVE" config user.name tester
while IFS= read -r f; do age_path_days_ago "$f" 30; done < <(find "$LSOF_ACTIVE" -type f)
# Hold a real open file handle inside the candidate via `tail -f`.
tail -f "$LSOF_ACTIVE/README.md" >/dev/null 2>&1 &
TAIL_PID=$!
BG_PIDS+=("$TAIL_PID")
sleep 0.3

OUT2="$TMP_ROOT/out2.txt"
env -i HOME="$TMP_ROOT/home" PATH="$REAL_PATH" \
  bash "$TARGET_SCRIPT" --root "$ROOTS_DIR" --min-age 7 --dry-run \
  >"$OUT2" 2>&1
OUT2_CONTENT=$(cat "$OUT2")
assert_contains "(lsof active) open handle -> PRESERVE" "PRESERVE $LSOF_ACTIVE  (open file handles" "$OUT2_CONTENT"

kill "$TAIL_PID" >/dev/null 2>&1 || true
wait "$TAIL_PID" 2>/dev/null || true

echo
echo "=== Test 3: lsof probe failure -> PRESERVE (fail closed) ==="
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "lsof: fatal simulated failure" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/lsof"

OUT3="$TMP_ROOT/out3.txt"
env -i HOME="$TMP_ROOT/home" PATH="$FAKE_BIN:$REAL_PATH" \
  bash "$TARGET_SCRIPT" --root "$ROOTS_DIR" --min-age 7 --dry-run \
  >"$OUT3" 2>&1
OUT3_CONTENT=$(cat "$OUT3")
assert_contains "(lsof failure) old-clean now PRESERVE (fail closed)" "PRESERVE $OLD_CLEAN  (open file handles" "$OUT3_CONTENT"

echo
echo "=== Test 4: --clean without CLAUDE_STATE_APPROVED=1 refuses, deletes nothing ==="
OUT4="$TMP_ROOT/out4.txt"
env -i HOME="$TMP_ROOT/home" PATH="$REAL_PATH" \
  bash "$TARGET_SCRIPT" --root "$ROOTS_DIR" --min-age 7 --clean \
  >"$OUT4" 2>&1
OUT4_CONTENT=$(cat "$OUT4")
assert_contains "(missing approval) refusal message printed" "Refusing to delete: set CLAUDE_STATE_APPROVED=1" "$OUT4_CONTENT"
if [[ -d "$OLD_CLEAN" ]]; then
  record_pass "(missing approval) old-clean survives --clean without approval"
else
  record_fail "(missing approval) old-clean survives --clean without approval" "eligible dir was deleted without CLAUDE_STATE_APPROVED=1"
fi

echo
echo "=== Test 5: --clean WITH CLAUDE_STATE_APPROVED=1 deletes only ELIGIBLE ==="
OUT5="$TMP_ROOT/out5.txt"
env -i HOME="$TMP_ROOT/home" PATH="$REAL_PATH" CLAUDE_STATE_APPROVED=1 \
  bash "$TARGET_SCRIPT" --root "$ROOTS_DIR" --min-age 7 --clean \
  >"$OUT5" 2>&1
OUT5_CONTENT=$(cat "$OUT5")
echo "$OUT5_CONTENT" | sed 's/^/    /'

if [[ ! -d "$OLD_CLEAN" ]]; then
  record_pass "(clean+approved) eligible old-clean deleted"
else
  record_fail "(clean+approved) eligible old-clean deleted" "still present: $OLD_CLEAN"
fi
if [[ -d "$YOUNG" && -d "$DIRTY" && -d "$UNPUSHED" && -d "$STASHED" && -d "$UNMEASURABLE" ]]; then
  record_pass "(clean+approved) NEEDS-REVIEW / young / unmeasurable all preserved"
else
  record_fail "(clean+approved) NEEDS-REVIEW / young / unmeasurable all preserved" "one of the protected fixtures vanished"
fi
if [[ -L "$ROOTS_DIR/escape-symlink-yzab" && -f "$ESCAPE_TARGET/secret.txt" ]]; then
  record_pass "(clean+approved) symlink + its target untouched"
else
  record_fail "(clean+approved) symlink + its target untouched" "symlink or its target vanished"
fi

echo
echo "=== Test 6: refuses to operate against ~/.claude/projects ==="
FAKE_HOME="$TMP_ROOT/home2"
mkdir -p "$FAKE_HOME/.claude/projects"
OUT6="$TMP_ROOT/out6.txt"
env -i HOME="$FAKE_HOME" PATH="$REAL_PATH" \
  bash "$TARGET_SCRIPT" --root "$FAKE_HOME/.claude/projects" --min-age 7 --dry-run \
  >"$OUT6" 2>&1
RC6=$?
OUT6_CONTENT=$(cat "$OUT6")
assert_contains "(projects guard) refuses when --root points at ~/.claude/projects" "REFUSING" "$OUT6_CONTENT"
if [[ $RC6 -ne 0 ]]; then
  record_pass "(projects guard) nonzero exit"
else
  record_fail "(projects guard) nonzero exit" "expected nonzero exit, got $RC6"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]

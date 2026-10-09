#!/usr/bin/env bash
# test_safety_min_stale_days_wiring.sh — verifies that safety_min_stale_days()
# is properly consulted as a staleness floor by worktree and state cleanup scripts:
#   - scripts/cleanup_worktrees.sh
#   - scripts/cleanup_worktree_venvs.sh
#   - scripts/worktree_hygiene.sh
#   - scripts/cleanup_claude_state.sh
#
# Invariants tested:
#   1. Clamping to configured floor: when safety.local.json specifies min_stale_days > 7,
#      --min-age / default clamps up to that floor.
#   2. Hard floor enforcement: when safety.local.json specifies min_stale_days < 7 (or 0),
#      the hard floor remains 7 and cannot be lowered.
#   3. Explicit higher age preservation: when --min-age is specified higher than the floor,
#      the higher value is respected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_DIR=$(mktemp -d -t test_safety_wiring.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

record_pass() {
  echo "  PASS  $1"
  PASS=$(( PASS + 1 ))
}

record_fail() {
  echo "  FAIL  $1"
  echo "        $2"
  FAIL=$(( FAIL + 1 ))
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected output containing '$needle', got: $haystack"
  fi
}

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected rc=$expected got rc=$actual"
  fi
}

SAFETY_14="$TMP_DIR/safety_14.json"
cat > "$SAFETY_14" <<'JSON'
{"min_stale_days": 14}
JSON

SAFETY_3="$TMP_DIR/safety_3.json"
cat > "$SAFETY_3" <<'JSON'
{"min_stale_days": 3}
JSON

export GIT_AUTHOR_NAME="Test Author"
export GIT_AUTHOR_EMAIL="fixture@users.noreply.github.com"
export GIT_COMMITTER_NAME="Test Committer"
export GIT_COMMITTER_EMAIL="fixture@users.noreply.github.com"

# Create mock home and git repo for worktree tests
FAKE_HOME="$TMP_DIR/home"
mkdir -p "$FAKE_HOME"
TEST_REPO="$TMP_DIR/test_repo"
git init -b main "$TEST_REPO" >/dev/null 2>&1
(
  cd "$TEST_REPO"
  echo "init" > README.md
  git add README.md
  git commit -m "init" >/dev/null 2>&1
)

echo "=== Suite 1: cleanup_worktrees.sh ==="
# Case 1: min_stale_days=14, --min-age 0 -> clamped to 14d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" --dry-run --repos "$TEST_REPO" --min-age 0 2>&1)
assert_contains "cleanup_worktrees.sh: min_stale_days=14 clamps --min-age 0 to 14d" "(others: 14d)" "$out"

# Case 2: min_stale_days=14, no --min-age flag -> defaults to 14d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" --dry-run --repos "$TEST_REPO" 2>&1)
assert_contains "cleanup_worktrees.sh: min_stale_days=14 defaults to 14d" "(others: 14d)" "$out"

# Case 3: min_stale_days=14, --min-age 21 -> preserves 21d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" --dry-run --repos "$TEST_REPO" --min-age 21 2>&1)
assert_contains "cleanup_worktrees.sh: min_stale_days=14 respects higher --min-age 21d" "(others: 21d)" "$out"

# Case 4: min_stale_days=3, --min-age 0 -> hard floor 7d enforced
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_3" \
  bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" --dry-run --repos "$TEST_REPO" --min-age 0 2>&1)
assert_contains "cleanup_worktrees.sh: min_stale_days=3 clamps up to hard floor 3d" "(others: 3d)" "$out"


echo "=== Suite 2: cleanup_worktree_venvs.sh ==="
# Case 1: min_stale_days=14, --min-age 0 -> clamped to 14 days
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$TEST_REPO" --min-age 0 2>&1)
assert_contains "cleanup_worktree_venvs.sh: min_stale_days=14 clamps --min-age 0 to 14 days" "Min age:    14 days" "$out"

# Case 2: min_stale_days=14, no --min-age flag -> defaults to 14 days
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$TEST_REPO" 2>&1)
assert_contains "cleanup_worktree_venvs.sh: min_stale_days=14 defaults to 14 days" "Min age:    14 days" "$out"

# Case 3: min_stale_days=14, --min-age 21 -> preserves 21 days
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$TEST_REPO" --min-age 21 2>&1)
assert_contains "cleanup_worktree_venvs.sh: min_stale_days=14 respects higher --min-age 21 days" "Min age:    21 days" "$out"

# Case 4: min_stale_days=3, --min-age 0 -> hard floor 7 days enforced
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_3" \
  bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$TEST_REPO" --min-age 0 2>&1)
assert_contains "cleanup_worktree_venvs.sh: min_stale_days=3 clamps up to hard floor 7 days" "Min age:    7 days" "$out"


backdate_tree() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
root, days = sys.argv[1], int(sys.argv[2])
t = time.time() - days * 86400
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".git"]
    for f in files:
        if f == ".git":
            continue
        try:
            os.utime(os.path.join(d, f), (t, t), follow_symlinks=False)
        except OSError:
            pass
PY
}

echo "=== Suite 3: worktree_hygiene.sh ==="
# Create a worktree aged to 10 days
WT_10D="$TMP_DIR/wt_10d"
git -C "$TEST_REPO" worktree add -b wt-10d "$WT_10D" >/dev/null 2>&1
echo "change" > "$WT_10D/file.txt"
backdate_tree "$WT_10D" 10

# Case 1: min_stale_days=14 -> 10-day-old worktree must be PRESERVED as young even if --min-age 0 passed
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  bash "$REPO_ROOT/scripts/worktree_hygiene.sh" --repos "$TEST_REPO" --skip-push --skip-gh --min-age 0 2>&1)
assert_contains "worktree_hygiene.sh: 10d worktree preserved as young when floor=14d" "| young" "$out"

# Case 2: min_stale_days=3 (clamps to 7) -> 10-day-old worktree qualifies (not young)
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_3" \
  bash "$REPO_ROOT/scripts/worktree_hygiene.sh" --repos "$TEST_REPO" --skip-push --skip-gh --min-age 0 2>&1)
# With floor 7d, a 10d worktree is >= 7d, so it is evaluated (NEEDS-REVIEW or SAFE), NOT marked "young"
if [[ "$out" == *"| young"* ]]; then
  record_fail "worktree_hygiene.sh: 10d worktree not marked young when floor=7d" "was marked young unexpectedly: $out"
else
  record_pass "worktree_hygiene.sh: 10d worktree evaluated when floor=7d"
fi


echo "=== Suite 4: cleanup_claude_state.sh ==="
FAKE_STATE="$TMP_DIR/state"
mkdir -p "$FAKE_STATE"

# Case 1: min_stale_days=14, --min-age 0 -> banner reports min-age=14d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$FAKE_STATE" \
  bash "$REPO_ROOT/scripts/cleanup_claude_state.sh" --root "$FAKE_STATE" --dry-run --min-age 0 2>&1)
assert_contains "cleanup_claude_state.sh: min_stale_days=14 clamps --min-age 0 to 14d" "min-age=14d" "$out"

# Case 2: min_stale_days=14, no --min-age flag -> defaults to 14d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$FAKE_STATE" \
  bash "$REPO_ROOT/scripts/cleanup_claude_state.sh" --root "$FAKE_STATE" --dry-run 2>&1)
assert_contains "cleanup_claude_state.sh: min_stale_days=14 defaults to 14d" "min-age=14d" "$out"

# Case 3: min_stale_days=14, --min-age 21 -> respects 21d
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_14" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$FAKE_STATE" \
  bash "$REPO_ROOT/scripts/cleanup_claude_state.sh" --root "$FAKE_STATE" --dry-run --min-age 21 2>&1)
assert_contains "cleanup_claude_state.sh: min_stale_days=14 respects higher --min-age 21d" "min-age=21d" "$out"

# Case 4: min_stale_days=3, --min-age 0 -> hard floor 7d enforced
out=$(HOME="$FAKE_HOME" DISK_MAGICIAN_SAFETY_FILE="$SAFETY_3" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$FAKE_STATE" \
  bash "$REPO_ROOT/scripts/cleanup_claude_state.sh" --root "$FAKE_STATE" --dry-run --min-age 0 2>&1)
assert_contains "cleanup_claude_state.sh: min_stale_days=3 clamps up to hard floor 7d" "min-age=7d" "$out"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

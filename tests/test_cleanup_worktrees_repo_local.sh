#!/usr/bin/env bash
# test_cleanup_worktrees_repo_local.sh — Fixture tests for repo-local worktree governance.
#
# Run: bash tests/test_cleanup_worktrees_repo_local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_SCRIPT="$REPO_ROOT/scripts/cleanup_worktrees.sh"

TMP_ROOT=$(mktemp -d -t cleanup_wt_repo_local.XXXXXX)
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
    sed 's/^/        | /' <<<"$haystack"
  fi
}

run_dry_run() {
  local out_file="$1" repo_path="$2" min_age="${3:-0}"
  env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
    bash "$CLEANUP_SCRIPT" --dry-run --repos "$repo_path" --min-age "$min_age" \
    >"$out_file" 2>&1
}

age_worktree_days_ago() {
  local wt_path="$1" days="$2"
  local ts
  ts=$(date -v-"${days}"d +%Y%m%d%H%M)
  touch -t "$ts" "$wt_path/.git"
}

setup_fixture_repo() {
  local main_repo="$TMP_ROOT/fixture-repo"
  mkdir -p "$main_repo/.claude/worktrees"
  export HERMES_SKIP_EXAMPLE_COM_GUARD=1
  git -C "$main_repo" init -b main >/dev/null
  git -C "$main_repo" config user.email "fixture@users.noreply.github.com"
  git -C "$main_repo" config user.name "Fixture User"
  printf 'base\n' > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "base" >/dev/null
  BASE_SHA=$(git -C "$main_repo" rev-parse HEAD)

  git -C "$main_repo" branch merged-tip
  printf 'merged\n' >> "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "merged change" >/dev/null
  MERGED_SHA=$(git -C "$main_repo" rev-parse HEAD)
  git -C "$main_repo" checkout main >/dev/null
  git -C "$main_repo" merge --ff-only merged-tip >/dev/null

  git -C "$main_repo" branch ahead-tip
  git -C "$main_repo" checkout ahead-tip >/dev/null
  printf 'ahead\n' >> "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -m "ahead change" >/dev/null
  AHEAD_SHA=$(git -C "$main_repo" rev-parse HEAD)
  git -C "$main_repo" checkout main >/dev/null

  git -C "$main_repo" worktree add -B wt-ancestor "$main_repo/.claude/worktrees/wt-ancestor" "$BASE_SHA" >/dev/null
  git -C "$main_repo" worktree add -B wt-dirty "$main_repo/.claude/worktrees/wt-dirty" "$BASE_SHA" >/dev/null
  printf 'dirty\n' >> "$main_repo/.claude/worktrees/wt-dirty/README.md"

  git -C "$main_repo" worktree add -B wt-untracked "$main_repo/.claude/worktrees/wt-untracked" "$BASE_SHA" >/dev/null
  printf 'stray\n' > "$main_repo/.claude/worktrees/wt-untracked/stray.txt"

  git -C "$main_repo" worktree add -B wt-ahead "$main_repo/.claude/worktrees/wt-ahead" "$AHEAD_SHA" >/dev/null

  git -C "$main_repo" worktree add -B wt-locked "$main_repo/.claude/worktrees/wt-locked" "$BASE_SHA" >/dev/null
  git -C "$main_repo" worktree lock wt-locked >/dev/null

  git -C "$main_repo" worktree add -B wt-young "$main_repo/.claude/worktrees/wt-young" "$BASE_SHA" >/dev/null

  local spaced_dir="$main_repo/.claude/worktrees/wt spaced path"
  git -C "$main_repo" worktree add -B wt-spaced "$spaced_dir" "$BASE_SHA" >/dev/null

  for wt in wt-ancestor wt-dirty wt-untracked wt-ahead wt-locked "wt spaced path"; do
    age_worktree_days_ago "$main_repo/.claude/worktrees/$wt" 30
  done
  age_worktree_days_ago "$main_repo/.claude/worktrees/wt-young" 3

  printf '%s\n' "$main_repo"
}

echo "=== repo-local worktree cleanup fixture tests ==="

MAIN_REPO=$(setup_fixture_repo)
OUT="$TMP_ROOT/dry-run.out"
run_dry_run "$OUT" "$MAIN_REPO" 14
OUT_CONTENT=$(cat "$OUT")

assert_contains "dry-run banner" "=== WORKTREE CLEANUP (DRY-RUN) ===" "$OUT_CONTENT"
assert_contains "ancestor worktree eligible" "repo-local   ELIGIBLE" "$OUT_CONTENT"
assert_contains "ancestor path fragment" ".claude/worktrees/wt-ancestor" "$OUT_CONTENT"
assert_contains "dirty worktree preserved" "repo-local   PRESERVE" "$OUT_CONTENT"
assert_contains "dirty reason" ".claude/worktrees/wt-dirty | dirty" "$OUT_CONTENT"
assert_contains "untracked reason" ".claude/worktrees/wt-untracked | untracked" "$OUT_CONTENT"
assert_contains "ahead reason" ".claude/worktrees/wt-ahead | ahead-of-main" "$OUT_CONTENT"
assert_contains "locked reason" ".claude/worktrees/wt-locked | locked" "$OUT_CONTENT"
assert_contains "young reason" ".claude/worktrees/wt-young | young" "$OUT_CONTENT"
assert_contains "spaced path eligible" ".claude/worktrees/wt spaced path" "$OUT_CONTENT"
assert_contains "summary eligible count" "Repo-local:  2 eligible" "$OUT_CONTENT"
assert_contains "summary preserved count" "Repo-local:  2 eligible, 5 preserved." "$OUT_CONTENT"

echo "Test: --clean without WORKTREE_APPROVED refuses before deletion"
OUT_REFUSE="$TMP_ROOT/refuse.out"
set +e
env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
  bash "$CLEANUP_SCRIPT" --clean --repos "$MAIN_REPO" --min-age 0 >"$OUT_REFUSE" 2>&1
RC_REFUSE=$?
set -e
if [[ "$RC_REFUSE" -eq 0 ]]; then record_pass "refusal exits 0"; else record_fail "refusal exits 0" "rc=$RC_REFUSE"; fi
assert_contains "refusal message" "Refusing to delete worktrees: set WORKTREE_APPROVED=1" "$(cat "$OUT_REFUSE")"
if [[ -d "$MAIN_REPO/.claude/worktrees/wt-ancestor" ]]; then
  record_pass "ancestor worktree still on disk after refused clean"
else
  record_fail "ancestor worktree still on disk after refused clean" "worktree removed unexpectedly"
fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_worktree_repo_discovery.sh — Behavioral tests for
# scripts/lib/worktree_repo_discovery.sh
#
# Covers jleechan-dqiz/jleechan-4dtg: ~/.worktrees (26 GiB, ~70 entries
# spanning many main repos) was invisible to worktree_hygiene.sh's
# auto-discovery, so no repo whose ONLY worktrees live there ever got
# IDENTIFY/TRIAGE/CLASSIFY-checked. Fixed by adding $HOME/.worktrees to the
# same _dwr_find_repos_from_worktrees scan used for $HOME/.ao/data/worktrees
# and $HOME/.gemini/antigravity/worktrees.
#
# Run: bash tests/test_worktree_repo_discovery.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/worktree_repo_discovery.sh"

TMP_DIR=$(mktemp -d -t worktree_repo_discovery_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR"

PASS=0
FAIL=0
expect() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (did not find: $needle)"
    FAIL=$((FAIL + 1))
  fi
}
refute() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (unexpectedly found: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== worktree_repo_discovery.sh test ==="

echo "Test 1: override arg bypasses auto-discovery entirely"
# shellcheck source=/dev/null
source "$LIB"
OUT="$(discover_worktree_repos "/foo/bar,/baz/qux")"
expect "returns exactly the override paths" "/foo/bar" "$OUT"
expect "splits on comma" "/baz/qux" "$OUT"

echo "Test 2: a repo whose ONLY worktree lives under ~/.worktrees is discovered"
mkdir -p "$TMP_DIR/some-other-repo/.git/worktrees/branch-a"
mkdir -p "$TMP_DIR/.worktrees/branch-a"
echo "gitdir: $TMP_DIR/some-other-repo/.git/worktrees/branch-a" > "$TMP_DIR/.worktrees/branch-a/.git"
OUT="$(discover_worktree_repos "")"
expect "discovers the main repo via ~/.worktrees" "$TMP_DIR/some-other-repo" "$OUT"

echo "Test 3: worldarchitect.ai base repo is always included even with no worktrees anywhere"
rm -rf "$TMP_DIR/.worktrees" "$TMP_DIR/some-other-repo"
OUT="$(discover_worktree_repos "")"
expect "always includes the worldarchitect.ai base path" "$TMP_DIR/projects/worldarchitect.ai" "$OUT"

echo "Test 4: a nested container dir under ~/.worktrees (e.g. ~/.worktrees/<project>/<branch>) is still found"
mkdir -p "$TMP_DIR/nested-repo/.git/worktrees/deep-branch"
mkdir -p "$TMP_DIR/.worktrees/some-project/deep-branch"
echo "gitdir: $TMP_DIR/nested-repo/.git/worktrees/deep-branch" > "$TMP_DIR/.worktrees/some-project/deep-branch/.git"
OUT="$(discover_worktree_repos "")"
expect "finds repos at any nesting depth under ~/.worktrees" "$TMP_DIR/nested-repo" "$OUT"

echo "Test 5: a non-worktree-pointer .git directory (a real repo, not a worktree) under ~/.worktrees is ignored"
rm -rf "$TMP_DIR/.worktrees" "$TMP_DIR/nested-repo"
mkdir -p "$TMP_DIR/.worktrees/regular-clone/.git/refs"
OUT="$(discover_worktree_repos "")"
refute "does not misinterpret a real repo's .git dir as a worktree pointer" "regular-clone" "$OUT"

echo "Test 6: a worktree pointer whose main repo's .git has since been removed (stale reference) is not surfaced"
rm -rf "$TMP_DIR/.worktrees"
mkdir -p "$TMP_DIR/dead-repo"  # no .git -- was deleted after the worktree was registered
mkdir -p "$TMP_DIR/.worktrees/stale-branch"
echo "gitdir: $TMP_DIR/dead-repo/.git/worktrees/stale-branch" > "$TMP_DIR/.worktrees/stale-branch/.git"
OUT="$(discover_worktree_repos "")"
refute "does not surface a repo with no .git (would crash worktree_hygiene.sh under bash 3.2)" "dead-repo" "$OUT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

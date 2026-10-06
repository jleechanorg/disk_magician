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

echo "Test 3: worldarchitect.ai candidate without .git is not surfaced; with .git is surfaced"
rm -rf "$TMP_DIR/.worktrees" "$TMP_DIR/some-other-repo"
OUT="$(discover_worktree_repos "")"
refute "does not include worldarchitect.ai when .git does not exist" "$TMP_DIR/projects/worldarchitect.ai" "$OUT"
mkdir -p "$TMP_DIR/projects/worldarchitect.ai/.git"
OUT="$(discover_worktree_repos "")"
expect "includes worldarchitect.ai when valid .git exists" "$TMP_DIR/projects/worldarchitect.ai" "$OUT"
rm -rf "$TMP_DIR/projects/worldarchitect.ai"

echo "Test 4: a nested container dir under ~/.worktrees (e.g. ~/.worktrees/<project>/<branch>) is still found"
mkdir -p "$TMP_DIR/nested-repo/.git/worktrees/deep-branch"
mkdir -p "$TMP_DIR/.worktrees/some-project/deep-branch"
echo "gitdir: $TMP_DIR/nested-repo/.git/worktrees/deep-branch" > "$TMP_DIR/.worktrees/some-project/deep-branch/.git"
OUT="$(discover_worktree_repos "")"
expect "finds repos nested up to depth 3 under ~/.worktrees" "$TMP_DIR/nested-repo" "$OUT"

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

echo "Test 7: worldai_claw candidate without .git is not surfaced"
mkdir -p "$TMP_DIR/project_worldaiclaw/worldai_claw"  # no .git dir
OUT="$(discover_worktree_repos "")"
refute "does not surface worldai_claw when .git directory is missing" "$TMP_DIR/project_worldaiclaw/worldai_claw" "$OUT"

echo "Test 8: worldai_claw candidate with .git is surfaced"
mkdir -p "$TMP_DIR/project_worldaiclaw/worldai_claw/.git"
OUT="$(discover_worktree_repos "")"
expect "surfaces worldai_claw when valid .git exists" "$TMP_DIR/project_worldaiclaw/worldai_claw" "$OUT"

echo "Test 9: worktrees in project_worldaiclaw and wc-wt with valid main repo are discovered"
mkdir -p "$TMP_DIR/my-wc-repo/.git/worktrees/wt-1"
mkdir -p "$TMP_DIR/wc-wt/wt-1"
echo "gitdir: $TMP_DIR/my-wc-repo/.git/worktrees/wt-1" > "$TMP_DIR/wc-wt/wt-1/.git"
OUT="$(discover_worktree_repos "")"
expect "discovers main repo from wc-wt worktree" "$TMP_DIR/my-wc-repo" "$OUT"

echo "Test 10: worktrees in project_worldaiclaw pointing to dead repo without .git are not surfaced"
mkdir -p "$TMP_DIR/dead-claw-repo"  # no .git
mkdir -p "$TMP_DIR/project_worldaiclaw/stale-wt"
echo "gitdir: $TMP_DIR/dead-claw-repo/.git/worktrees/stale-wt" > "$TMP_DIR/project_worldaiclaw/stale-wt/.git"
OUT="$(discover_worktree_repos "")"
refute "does not surface dead main repo referenced by worktree in project_worldaiclaw" "dead-claw-repo" "$OUT"

echo "Test 11: .git files inside node_modules at depth 3 are pruned and ignored"
mkdir -p "$TMP_DIR/project_worldaiclaw/node_modules/fake-pkg"
mkdir -p "$TMP_DIR/bogus-repo/.git/worktrees/pkg"
echo "gitdir: $TMP_DIR/bogus-repo/.git/worktrees/pkg" > "$TMP_DIR/project_worldaiclaw/node_modules/fake-pkg/.git"
OUT="$(discover_worktree_repos "")"
refute "prunes node_modules subtrees during discovery" "bogus-repo" "$OUT"

echo "Test 12: valid worktree nested at maximum depth 3 is discovered"
mkdir -p "$TMP_DIR/deep-repo/.git/worktrees/nested-wt"
mkdir -p "$TMP_DIR/wc-wt/group-a/nested-wt"
echo "gitdir: $TMP_DIR/deep-repo/.git/worktrees/nested-wt" > "$TMP_DIR/wc-wt/group-a/nested-wt/.git"
OUT="$(discover_worktree_repos "")"
expect "discovers worktrees nested at depth 3" "$TMP_DIR/deep-repo" "$OUT"

echo "Test 13: timeout recovery preserves valid records up to last newline and emits warning"
mkdir -p "$TMP_DIR/timeout-repo/.git/worktrees/valid-wt"
mkdir -p "$TMP_DIR/wc-wt/valid-wt"
echo "gitdir: $TMP_DIR/timeout-repo/.git/worktrees/valid-wt" > "$TMP_DIR/wc-wt/valid-wt/.git"

FAKE_BIN="$TMP_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/find" << 'EOF'
#!/usr/bin/env bash
# Emit one complete line, one incomplete line, then sleep to trigger timeout
if [[ "$*" == *"/wc-wt"* ]]; then
  printf "%s\n" "$HOME/wc-wt/valid-wt/.git"
  printf "%s" "$HOME/wc-wt/incomplete-line"
  sleep 2
else
  /usr/bin/find "$@"
fi
EOF
chmod +x "$FAKE_BIN/find"

STDERR_OUT="$TMP_DIR/stderr_timeout.log"
OUT="$(PATH="$FAKE_BIN:$PATH" WORKTREE_DISCOVERY_TIMEOUT=0.5 discover_worktree_repos "" 2>"$STDERR_OUT")"
expect "discovers repo emitted before timeout" "$TMP_DIR/timeout-repo" "$OUT"
expect "emits timeout warning to stderr" "worktree_repo_discovery: timeout searching root" "$(cat "$STDERR_OUT")"
refute "does not throw TypeError in stderr" "TypeError" "$(cat "$STDERR_OUT")"

echo "Test 14: skips root when no timeout-capable runner is available"
NO_RUNNER_BIN="$TMP_DIR/norunner_bin"
mkdir -p "$NO_RUNNER_BIN"
# Symlink basic POSIX utilities except python3, timeout, and gtimeout
for cmd in sh bash find grep sed cut tr sort ls rm mkdir cat; do
  target="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$target" ]] && ln -s "$target" "$NO_RUNNER_BIN/$cmd"
done

NO_RUNNER_STDERR="$TMP_DIR/norunner_stderr.log"
OUT="$(PATH="$NO_RUNNER_BIN" discover_worktree_repos "" 2>"$NO_RUNNER_STDERR")"
expect "skips root when no runner is found" "skipping root" "$(cat "$NO_RUNNER_STDERR")"

echo "Test 15: timeout fallback preserves newline-complete records and drops truncated trailing record"
TIMEOUT_FB_BIN="$TMP_DIR/timeout_fb_bin"
mkdir -p "$TIMEOUT_FB_BIN"
for cmd in sh bash grep sed cut tr sort ls rm mkdir cat; do
  target="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$target" ]] && ln -s "$target" "$TIMEOUT_FB_BIN/$cmd"
done
# Mock timeout that emits 1 complete line and 1 incomplete line, then exits 124
cat > "$TIMEOUT_FB_BIN/timeout" << 'EOF'
#!/bin/sh
search_dir="$3"
printf "%s/complete-wt/.git\n" "$search_dir"
printf "%s/truncated-wt/.git" "$search_dir"
exit 124
EOF
chmod +x "$TIMEOUT_FB_BIN/timeout"

mkdir -p "$TMP_DIR/fb-complete-repo/.git/worktrees/wt"
mkdir -p "$TMP_DIR/fb-truncated-repo/.git/worktrees/wt"
mkdir -p "$TMP_DIR/wc-wt/complete-wt"
mkdir -p "$TMP_DIR/wc-wt/truncated-wt"
echo "gitdir: $TMP_DIR/fb-complete-repo/.git/worktrees/wt" > "$TMP_DIR/wc-wt/complete-wt/.git"
echo "gitdir: $TMP_DIR/fb-truncated-repo/.git/worktrees/wt" > "$TMP_DIR/wc-wt/truncated-wt/.git"

TIMEOUT_FB_STDERR="$TMP_DIR/timeout_fb_stderr.log"
OUT="$(PATH="$TIMEOUT_FB_BIN" discover_worktree_repos "" 2>"$TIMEOUT_FB_STDERR")"
expect "timeout fallback preserves complete record" "$TMP_DIR/fb-complete-repo" "$OUT"
refute "timeout fallback drops truncated trailing record" "$TMP_DIR/fb-truncated-repo" "$OUT"
expect "timeout fallback emits timeout warning to stderr" "worktree_repo_discovery: timeout searching root" "$(cat "$TIMEOUT_FB_STDERR")"

echo "Test 16: gtimeout fallback preserves newline-complete records and drops truncated trailing record"
GTIMEOUT_FB_BIN="$TMP_DIR/gtimeout_fb_bin"
mkdir -p "$GTIMEOUT_FB_BIN"
for cmd in sh bash grep sed cut tr sort ls rm mkdir cat; do
  target="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$target" ]] && ln -s "$target" "$GTIMEOUT_FB_BIN/$cmd"
done
cat > "$GTIMEOUT_FB_BIN/gtimeout" << 'EOF'
#!/bin/sh
search_dir="$3"
printf "%s/complete-wt/.git\n" "$search_dir"
printf "%s/truncated-wt/.git" "$search_dir"
exit 124
EOF
chmod +x "$GTIMEOUT_FB_BIN/gtimeout"

GTIMEOUT_FB_STDERR="$TMP_DIR/gtimeout_fb_stderr.log"
OUT="$(PATH="$GTIMEOUT_FB_BIN" discover_worktree_repos "" 2>"$GTIMEOUT_FB_STDERR")"
expect "gtimeout fallback preserves complete record" "$TMP_DIR/fb-complete-repo" "$OUT"
refute "gtimeout fallback drops truncated trailing record" "$TMP_DIR/fb-truncated-repo" "$OUT"
expect "gtimeout fallback emits timeout warning to stderr" "worktree_repo_discovery: timeout searching root" "$(cat "$GTIMEOUT_FB_STDERR")"

echo "Test 17: discovers main repo from worktrees in custom STANDARD_WORKTREE_ROOT"
mkdir -p "$TMP_DIR/custom-std-main/.git/worktrees/wt-std"
mkdir -p "$TMP_DIR/custom_std_root/project/wt-std"
echo "gitdir: $TMP_DIR/custom-std-main/.git/worktrees/wt-std" > "$TMP_DIR/custom_std_root/project/wt-std/.git"
OUT="$(STANDARD_WORKTREE_ROOT="$TMP_DIR/custom_std_root" discover_worktree_repos "")"
expect "discovers main repo from custom STANDARD_WORKTREE_ROOT" "$TMP_DIR/custom-std-main" "$OUT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]


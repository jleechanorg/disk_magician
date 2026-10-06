#!/usr/bin/env bash
# test_worktree_new.sh — `diskm worktree-new` (spec D2): worktrees are created
# under $HOME/.worktrees/<repo>/<name>. Runs entirely under a temp HOME with
# temp repos; never touches the real ~/.worktrees.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_new.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset STANDARD_WORKTREE_ROOT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Bare origin with one commit, cloned to $TMPROOT/myrepo, plus one local-only
# commit so origin/HEAD and HEAD differ.
git init -q --bare -b main "$TMPROOT/origin.git"
git clone -q "$TMPROOT/origin.git" "$TMPROOT/seed" 2>/dev/null
git -C "$TMPROOT/seed" commit -q --allow-empty -m base
git -C "$TMPROOT/seed" push -q origin HEAD:main
git clone -q "$TMPROOT/origin.git" "$TMPROOT/myrepo"
git -C "$TMPROOT/myrepo" commit -q --allow-empty -m local-only
REPO="$TMPROOT/myrepo"
ORIGIN_SHA="$(git -C "$REPO" rev-parse origin/HEAD)"
LOCAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
WTROOT="$HOME/.worktrees/myrepo"

echo "== case 1: new branch from origin/HEAD, stdout is exactly the path =="
out="$(bash "$SCRIPT" "$REPO" feat/x 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-x" "stdout"
assert_eq "$(git -C "$WTROOT/feat-x" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/x" "branch"
assert_eq "$(git -C "$WTROOT/feat-x" rev-parse HEAD 2>/dev/null)" "$ORIGIN_SHA" "based on origin/HEAD"

echo "== case 2: --base and --name honored =="
out="$(bash "$SCRIPT" "$REPO" feat/y --base HEAD --name custom 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/custom" "stdout"
assert_eq "$(git -C "$WTROOT/custom" rev-parse HEAD 2>/dev/null)" "$LOCAL_SHA" "based on --base HEAD"

echo "== case 3: existing branch checked out without -b =="
git -C "$REPO" branch existing "$LOCAL_SHA"
out="$(bash "$SCRIPT" "$REPO" existing 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$(git -C "$WTROOT/existing" rev-parse --abbrev-ref HEAD 2>/dev/null)" "existing" "branch"
assert_eq "$(git -C "$WTROOT/existing" rev-parse HEAD 2>/dev/null)" "$LOCAL_SHA" "existing branch tip kept"

echo "== case 4: existing target path -> exit 1, nothing created =="
mkdir -p "$WTROOT/taken"
out="$(bash "$SCRIPT" "$REPO" feat/z --name taken 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "exit code"
assert_eq "$out" "" "stdout empty"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/z; then bad "branch feat/z created"; else ok "no branch created"; fi
assert_eq "$(ls -A "$WTROOT/taken")" "" "taken dir untouched"

echo "== case 5: no origin -> falls back to HEAD =="
git init -q -b main "$TMPROOT/noorigin"
git -C "$TMPROOT/noorigin" commit -q --allow-empty -m only
out="$(bash "$SCRIPT" "$TMPROOT/noorigin" feat/n 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$HOME/.worktrees/noorigin/feat-n" "stdout"
assert_eq "$(git -C "$out" rev-parse HEAD 2>/dev/null)" "$(git -C "$TMPROOT/noorigin" rev-parse HEAD)" "based on HEAD"

echo "== case 6: non-repo path and missing args -> exit 1 =="
mkdir -p "$TMPROOT/plain"
bash "$SCRIPT" "$TMPROOT/plain" feat/q >/dev/null 2>&1; assert_eq "$?" "1" "non-repo"
bash "$SCRIPT" "$REPO" >/dev/null 2>&1; assert_eq "$?" "1" "missing branch"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

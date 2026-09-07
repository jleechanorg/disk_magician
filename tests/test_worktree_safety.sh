#!/usr/bin/env bash
# test_worktree_safety.sh — unit tests for scripts/lib/worktree_safety.sh
#
# Regression tests for bead disk_magician-0jy and disk_magician-nv3:
# Asserts worktree_has_unsaved_work() returns:
#   rc 1 (SAFE)   only for provably clean-and-pushed worktrees or non-git dirs
#   rc 0 (UNSAFE) for uncommitted changes, untracked files, unpushed commits,
#                 no upstream, dangling .git symlink, corrupted repo, or git probe error.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_safety.sh
source "$REPO_ROOT/scripts/lib/worktree_safety.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d -t test_worktree_safety.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

# Set up non-placeholder git user identity for temporary commits
export GIT_AUTHOR_NAME="Test Author"
export GIT_AUTHOR_EMAIL="fixture@users.noreply.github.com"
export GIT_COMMITTER_NAME="Test Committer"
export GIT_COMMITTER_EMAIL="fixture@users.noreply.github.com"

echo "── Case 1: Non-git directory is safe (rc 1) ──"
NONGIT="$TMPROOT/nongit_dir"
mkdir -p "$NONGIT"
echo "some random data" > "$NONGIT/file.txt"
if worktree_has_unsaved_work "$NONGIT"; then
  bad "non-git dir reported as having unsaved work"
else
  ok "non-git dir reported safe (rc 1)"
fi

echo "── Setup upstream & clone for git test cases ──"
UPSTREAM="$TMPROOT/upstream.git"
git init --bare "$UPSTREAM" >/dev/null 2>&1

CLONE="$TMPROOT/repo"
git clone "$UPSTREAM" "$CLONE" >/dev/null 2>&1
(
  cd "$CLONE"
  git config user.name "Test Author"
  git config user.email "fixture@users.noreply.github.com"
  git checkout -b main >/dev/null 2>&1
  echo "init" > README.md
  git add README.md
  git commit -m "initial commit" >/dev/null 2>&1
  git push -u origin main >/dev/null 2>&1
)

echo "── Case 2: Clean worktree with tracked upstream and 0 unpushed commits is safe (rc 1) ──"
if worktree_has_unsaved_work "$CLONE"; then
  bad "clean worktree reported as having unsaved work"
else
  ok "clean worktree reported safe (rc 1)"
fi

echo "── Case 3: Worktree with uncommitted modified file is unsafe (rc 0) ──"
echo "modified content" >> "$CLONE/README.md"
if worktree_has_unsaved_work "$CLONE"; then
  ok "modified worktree reported unsafe (rc 0)"
else
  bad "modified worktree reported safe — DATA LOSS RISK"
fi
# Revert modification
(cd "$CLONE" && git checkout -- README.md)

echo "── Case 4: Worktree with untracked file is unsafe (rc 0) ──"
echo "untracked" > "$CLONE/untracked.txt"
if worktree_has_unsaved_work "$CLONE"; then
  ok "worktree with untracked file reported unsafe (rc 0)"
else
  bad "worktree with untracked file reported safe — DATA LOSS RISK"
fi
# Remove untracked file
rm -f "$CLONE/untracked.txt"

echo "── Case 5: Worktree with unpushed commit is unsafe (rc 0) ──"
(
  cd "$CLONE"
  echo "new commit content" >> README.md
  git commit -am "unpushed commit" >/dev/null 2>&1
)
if worktree_has_unsaved_work "$CLONE"; then
  ok "worktree with unpushed commit reported unsafe (rc 0)"
else
  bad "worktree with unpushed commit reported safe — DATA LOSS RISK"
fi
# Reset to upstream
(cd "$CLONE" && git reset --hard origin/main >/dev/null 2>&1)

echo "── Case 6: Worktree with no upstream configured is unsafe (rc 0) ──"
(
  cd "$CLONE"
  git checkout -b feature-no-upstream >/dev/null 2>&1
)
if worktree_has_unsaved_work "$CLONE"; then
  ok "branch with no upstream reported unsafe (rc 0)"
else
  bad "branch with no upstream reported safe — DATA LOSS RISK"
fi
(cd "$CLONE" && git checkout main >/dev/null 2>&1)

echo "── Case 7: Dangling .git symlink is unsafe (rc 0, fail closed) ──"
DANGLING="$TMPROOT/dangling_symlink"
mkdir -p "$DANGLING"
ln -s "$TMPROOT/nonexistent_git_admin" "$DANGLING/.git"
if worktree_has_unsaved_work "$DANGLING"; then
  ok "dangling .git symlink reported unsafe (rc 0)"
else
  bad "dangling .git symlink reported safe — CORRUPT METADATA OVERLOOKED"
fi

echo "── Case 8: Corrupted .git directory (rev-parse failure) is unsafe (rc 0) ──"
CORRUPT="$TMPROOT/corrupted_git"
mkdir -p "$CORRUPT/.git"
echo "not a valid git dir" > "$CORRUPT/.git/config"
if worktree_has_unsaved_work "$CORRUPT"; then
  ok "corrupted .git dir reported unsafe (rc 0)"
else
  bad "corrupted .git dir reported safe — CORRUPT METADATA OVERLOOKED"
fi

echo "── Case 9: Git status probe command failure is unsafe (rc 0, fail closed) ──"
# Build a fake git wrapper that fails on `status` or `rev-list`
FAKE_BIN="$TMPROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/git" <<'GIT_STUB'
#!/usr/bin/env bash
if [[ "$*" == *"status --porcelain"* ]]; then
  exit 128
fi
exec /usr/bin/git "$@"
GIT_STUB
chmod +x "$FAKE_BIN/git"

if ( PATH="$FAKE_BIN:$PATH" worktree_has_unsaved_work "$CLONE" ); then
  ok "git status probe failure reported unsafe (rc 0)"
else
  bad "git status probe failure reported safe — FAIL-OPEN ERROR"
fi

echo "── Case 10: Git rev-list probe command failure is unsafe (rc 0, fail closed) ──"
cat > "$FAKE_BIN/git" <<'GIT_STUB2'
#!/usr/bin/env bash
if [[ "$*" == *"rev-list"* ]]; then
  exit 128
fi
exec /usr/bin/git "$@"
GIT_STUB2
chmod +x "$FAKE_BIN/git"

if ( PATH="$FAKE_BIN:$PATH" worktree_has_unsaved_work "$CLONE" ); then
  ok "git rev-list probe failure reported unsafe (rc 0)"
else
  bad "git rev-list probe failure reported safe — FAIL-OPEN ERROR"
fi

echo "── Case 11: Missing git command on PATH is unsafe (rc 0, fail closed) ──"
if ( PATH="/nonexistent" worktree_has_unsaved_work "$CLONE" ); then
  ok "missing git command reported unsafe (rc 0)"
else
  bad "missing git command reported safe — FAIL-OPEN ERROR"
fi

echo ""
echo "=== Test Results: $PASS pass, $FAIL fail ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

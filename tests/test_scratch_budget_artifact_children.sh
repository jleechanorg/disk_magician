#!/usr/bin/env bash
# scratch_budget_artifact_children: a directory's newest-content age is an AGGREGATE,
# so one freshly written child shelters every stale sibling. This helper must surface
# the individual artifact-shaped children so each can be judged on its own age --
# measured 2026-11-03: 23.7 GiB of 39-41h Android build dirs were hidden inside a
# 35 GiB tree whose aggregate read as "0h old".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/scratch_budget.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/sb-children.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Fixture: a build root with a stale sibling next to a fresh one, source trees with
# directory- and file-form .git markers that must never be entered, a non-artifact
# dir that must be ignored, a symlink that must not be followed, and an artifact
# beyond the depth bound.
B="$T/build"
mkdir -p "$B/android-native-1/isolated-stale" "$B/android-native-1/isolated-fresh" \
         "$B/android-native-1/android-sdk" "$B/src-tree/.git" "$B/src-tree/dist" \
         "$B/file-git-tree/dist" "$B/root-git-dir/.git" "$B/root-git-dir/dist" \
         "$B/root-git-file/dist" "$B/dangling-git-tree/dist" "$B/ordinary-dir" \
         "$B/depth-1/depth-2/depth-3/depth-4/dist"
printf 'gitdir: /outside\n' >"$B/file-git-tree/.git"
printf 'gitdir: /outside\n' >"$B/root-git-file/.git"
ln -s "$T/missing-git-target" "$B/dangling-git-tree/.git"
echo old >"$B/android-native-1/isolated-stale/blob"
echo old >"$B/android-native-1/android-sdk/blob"
echo fresh >"$B/android-native-1/isolated-fresh/blob"
echo old >"$B/src-tree/.git/config"
echo old >"$B/src-tree/dist/blob"
echo old >"$B/file-git-tree/dist/blob"
echo old >"$B/root-git-dir/dist/blob"
echo old >"$B/root-git-file/dist/blob"
echo old >"$B/dangling-git-tree/dist/blob"
echo old >"$B/ordinary-dir/blob"
echo old >"$B/depth-1/depth-2/depth-3/depth-4/dist/blob"
touch -d '40 hours ago' "$B/android-native-1/isolated-stale/blob" "$B/android-native-1/android-sdk/blob" \
    "$B/src-tree/dist/blob" "$B/file-git-tree/dist/blob" "$B/root-git-dir/dist/blob" \
    "$B/root-git-file/dist/blob" "$B/dangling-git-tree/dist/blob" "$B/ordinary-dir/blob" \
    "$B/depth-1/depth-2/depth-3/depth-4/dist/blob" 2>/dev/null || true
ln -s "$B/android-native-1/isolated-stale" "$B/link-to-stale"

out="$(scratch_budget_artifact_children "$B" 3 2>/dev/null)"

# 1. Stale artifact sibling discovered even though a fresh sibling exists
grep -q 'isolated-stale$' <<<"$out" \
  && ok "stale sibling discovered despite a fresh sibling in the same tree" \
  || bad "stale sibling masked by a fresh sibling"
# 2. Fresh sibling also enumerated (it is the pruner's age test that protects it)
grep -q 'isolated-fresh$' <<<"$out" \
  && ok "fresh sibling enumerated for its own age test" || bad "fresh sibling not enumerated"
# 3. Build-output basenames are picked up at depth
grep -q 'android-sdk$' <<<"$out" \
  && ok "android-sdk enumerated" || bad "android-sdk not enumerated"
# 4. A directory-form .git ancestor is never entered
grep -q 'src-tree/dist$' <<<"$out" \
  && bad "descended into a directory-form .git working tree" || ok "directory-form .git tree not descended"
# 5. A file-form .git ancestor is never entered
grep -q 'file-git-tree/dist$' <<<"$out" \
  && bad "descended into a file-form .git worktree" || ok "file-form .git tree not descended"
# 6. A root containing a directory-form .git is never entered
root_git_dir_out="$(scratch_budget_artifact_children "$B/root-git-dir" 3 2>/dev/null)"
grep -q 'root-git-dir/dist$' <<<"$root_git_dir_out" \
  && bad "entered a root containing a directory-form .git" || ok "root directory-form .git preserved"
# 7. A root containing a file-form .git is never entered
root_git_file_out="$(scratch_budget_artifact_children "$B/root-git-file" 3 2>/dev/null)"
grep -q 'root-git-file/dist$' <<<"$root_git_file_out" \
  && bad "entered a root containing a file-form .git" || ok "root file-form .git preserved"
# 8. A dangling .git link also preserves the whole subtree
grep -q 'dangling-git-tree/dist$' <<<"$out" \
  && bad "entered a tree with a dangling .git link" || ok "dangling .git tree preserved"
# 9. Ordinary (non artifact-shaped) directories are not candidates
grep -q 'ordinary-dir' <<<"$out" \
  && bad "ordinary directory enqueued as an artifact" || ok "ordinary directory ignored"
# 10. Symlinks are never followed
grep -q 'link-to-stale' <<<"$out" \
  && bad "followed a symlink" || ok "symlink not followed"
# 11. Depth bound respected (nothing at depth 4)
grep -q 'depth-4/dist$' <<<"$out" \
  && bad "depth bound violated" || ok "depth bound respected"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

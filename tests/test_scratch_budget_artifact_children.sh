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
         "$B/depth-1/depth-2/target" "$B/depth-1/depth-2/depth-3/depth-4/dist" \
         "$B/.cache/build" "$B/unreadable-parent/target"
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
echo old >"$B/depth-1/depth-2/target/blob"
echo old >"$B/depth-1/depth-2/depth-3/depth-4/dist/blob"
echo old >"$B/.cache/build/blob"
touch -d '40 hours ago' "$B/android-native-1/isolated-stale/blob" "$B/android-native-1/android-sdk/blob" \
    "$B/src-tree/dist/blob" "$B/file-git-tree/dist/blob" "$B/root-git-dir/dist/blob" \
    "$B/root-git-file/dist/blob" "$B/dangling-git-tree/dist/blob" "$B/ordinary-dir/blob" \
    "$B/depth-1/depth-2/target/blob" \
    "$B/depth-1/depth-2/depth-3/depth-4/dist/blob" 2>/dev/null || true
ln -s "$B/android-native-1/isolated-stale" "$B/link-to-stale"

single_output="$T/single-output.bin"
scratch_budget_artifact_children "$B" 3 >"$single_output" 2>/dev/null
out="$(tr '\0' '\n' <"$single_output")"

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
root_git_dir_file="$T/root-git-dir.bin"
scratch_budget_artifact_children "$B/root-git-dir" 3 >"$root_git_dir_file" 2>/dev/null
root_git_dir_out="$(tr '\0' '\n' <"$root_git_dir_file")"
grep -q 'root-git-dir/dist$' <<<"$root_git_dir_out" \
  && bad "entered a root containing a directory-form .git" || ok "root directory-form .git preserved"
# 7. A root containing a file-form .git is never entered
root_git_file_file="$T/root-git-file.bin"
scratch_budget_artifact_children "$B/root-git-file" 3 >"$root_git_file_file" 2>/dev/null
root_git_file_out="$(tr '\0' '\n' <"$root_git_file_file")"
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
# 12. The exact max-depth boundary is still included.
grep -q 'depth-2/target$' <<<"$out" \
  && ok "depth-3 boundary is included" || bad "depth-3 boundary was skipped"
# 13. Hidden artifact basenames are traversed but not emitted, matching find's
# ! -name '.*' -print0 behavior.
grep -q '/.cache$' <<<"$out" \
  && bad "hidden artifact basename was emitted" || ok "hidden artifact basename is not emitted"
grep -q '/.cache/build$' <<<"$out" \
  && ok "non-hidden artifact under hidden parent is emitted" || bad "hidden parent was not traversed"
# 14. max_depth=0 preserves the prior empty result.
zero_depth_file="$T/zero-depth.bin"
scratch_budget_artifact_children "$B" 0 >"$zero_depth_file" 2>/dev/null
[[ ! -s "$zero_depth_file" ]] && ok "zero depth emits no children" || bad "zero depth emitted children"
# 15. An unreadable marker check fails closed rather than treating the marker as absent.
chmod 000 "$B/unreadable-parent"
scratch_budget_artifact_children "$B" 3 >/dev/null 2>&1
unreadable_rc=$?
chmod 700 "$B/unreadable-parent"
if [[ "$(id -u)" == 0 ]]; then
  ok "unreadable-directory case skipped under privileged test user"
elif [[ "$unreadable_rc" == 1 ]]; then
  ok "unreadable marker check fails closed"
else
  bad "unreadable marker check fails closed (rc=$unreadable_rc)"
fi
# 16. Expansion reports an expired actuator deadline distinctly from an empty list.
expired_deadline="$(python3 -c 'import time; print(time.monotonic()-1)')"
expired_file="$T/expired.bin"
ACT_DEADLINE_AT="$expired_deadline" scratch_budget_artifact_children "$B" 3 >"$expired_file" 2>/dev/null
rc=$?
[[ "$rc" == 124 && ! -s "$expired_file" ]] && ok "expired discovery deadline returns 124 with no partial output" || bad "expired discovery deadline returns 124 with no partial output (rc=$rc)"

# Batch protocol preserves arbitrary filename bytes and emits one complete header.
P1="$T/candidate-one"
P2="$T/candidate-$'line\nname\tpart'"
mkdir -p "$P1/dist" "$P2/build"
candidate_input="$T/candidates.bin"
batch_output="$T/batch.bin"
expected_batch="$T/expected-batch.bin"
printf '%s\0' "$P1" "$P2" >"$candidate_input"
scratch_budget_artifact_children_batch 3 <"$candidate_input" >"$batch_output"
printf 'diskm-artifact-children-v1\0' >"$expected_batch"
printf '2\0%s\0%s\0%s\0%s\0' "$P1" "$P1/dist" "$P2" "$P2/build" >>"$expected_batch"
cmp -s "$batch_output" "$expected_batch" && ok "batch protocol preserves order and newline/tab paths byte-for-byte" || bad "batch protocol framing mismatch"
single_special="$T/single-special.bin"
scratch_budget_artifact_children "$P2" 3 >"$single_special"
printf '%s\0' "$P2/build" >"$T/expected-single-special.bin"
cmp -s "$single_special" "$T/expected-single-special.bin" && ok "single-candidate NUL output round-trips newline/tab paths" || bad "single-candidate NUL output mismatch"
empty_batch="$T/empty-batch.bin"
empty_expected="$T/empty-expected.bin"
scratch_budget_artifact_children_batch 3 </dev/null >"$empty_batch"
printf 'diskm-artifact-children-v1\0' >"$empty_expected"
printf '0\0' >>"$empty_expected"
cmp -s "$empty_batch" "$empty_expected" && ok "empty input emits a valid zero-pair header" || bad "empty batch framing mismatch"
unterminated_batch="$T/unterminated-batch.bin"
printf '%s' "$P1" >"$unterminated_batch"
scratch_budget_artifact_children_batch 3 <"$unterminated_batch" >"$T/unterminated-output.bin" 2>/dev/null
rc=$?
[[ "$rc" == 1 && ! -s "$T/unterminated-output.bin" ]] && ok "unterminated input fails with no partial output" || bad "unterminated input not rejected (rc=$rc)"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

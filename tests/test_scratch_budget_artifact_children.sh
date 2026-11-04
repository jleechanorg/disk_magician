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

# Fixture: a build root with a stale sibling next to a fresh one, a source tree with
# a .git that must never be entered, a non-artifact dir that must be ignored, and a
# symlink that must not be followed.
B="$T/build"
mkdir -p "$B/android-native-1/isolated-stale" "$B/android-native-1/isolated-fresh" \
         "$B/android-native-1/android-sdk" "$B/src-tree/.git" "$B/src-tree/nested-dist" \
         "$B/ordinary-dir"
echo old >"$B/android-native-1/isolated-stale/blob"
echo old >"$B/android-native-1/android-sdk/blob"
echo fresh >"$B/android-native-1/isolated-fresh/blob"
echo old >"$B/src-tree/.git/config"
echo old >"$B/src-tree/nested-dist/blob"
echo old >"$B/ordinary-dir/blob"
touch -d '40 hours ago' "$B/android-native-1/isolated-stale/blob" "$B/android-native-1/android-sdk/blob" \
    "$B/src-tree/nested-dist/blob" "$B/ordinary-dir/blob" 2>/dev/null || true
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
# 4. A .git-bearing working tree is never entered
grep -q 'src-tree/nested-dist' <<<"$out" \
  && bad "descended into a .git working tree" || ok ".git-bearing tree not descended"
# 5. Ordinary (non artifact-shaped) directories are not candidates
grep -q 'ordinary-dir' <<<"$out" \
  && bad "ordinary directory enqueued as an artifact" || ok "ordinary directory ignored"
# 6. Symlinks are never followed
grep -q 'link-to-stale' <<<"$out" \
  && bad "followed a symlink" || ok "symlink not followed"
# 7. Depth bound respected (nothing at depth 4)
grep -q 'nested-dist/blob' <<<"$out" \
  && bad "depth bound violated" || ok "depth bound respected"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

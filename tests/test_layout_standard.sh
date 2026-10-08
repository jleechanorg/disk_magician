#!/usr/bin/env bash
# test_layout_standard.sh — the machine-wide layout standard (spec 2026-10-05
# D1): worktrees under ~/.worktrees, evidence under /tmp/<repo>/evidence or GCS.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}
assert_true() { if "$@"; then ok "true: ${*:2}"; else bad "expected true: ${*:2}"; fi; }
assert_false() { if "$@"; then bad "expected false: ${*:2}"; else ok "false: ${*:2}"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_HOME="$TMPROOT/home"
mkdir -p "$FAKE_HOME/.worktrees/r"

echo "== defaults"
(
    unset STANDARD_WORKTREE_ROOT EVIDENCE_TMP_ROOT EVIDENCE_GCS_PREFIX
    HOME="$FAKE_HOME"
    # shellcheck source=scripts/lib/layout_standard.sh
    source "$REPO_ROOT/scripts/lib/layout_standard.sh"
    echo "$STANDARD_WORKTREE_ROOT|$EVIDENCE_TMP_ROOT|$EVIDENCE_GCS_PREFIX|$(standard_worktree_path myrepo feat-x)"
) > "$TMPROOT/out" 2>&1
assert_eq "$(cat "$TMPROOT/out")" \
    "$FAKE_HOME/.worktrees|/tmp|gs://wa-test-evidence/agent-evidence|$FAKE_HOME/.worktrees/myrepo/feat-x" \
    "default roots and standard_worktree_path"

echo "== env overrides"
out="$(STANDARD_WORKTREE_ROOT=/x/wt EVIDENCE_GCS_PREFIX=gs://b/p HOME="$FAKE_HOME" bash -c \
    'source "$1"; echo "$STANDARD_WORKTREE_ROOT|$EVIDENCE_GCS_PREFIX"' _ "$REPO_ROOT/scripts/lib/layout_standard.sh")"
assert_eq "$out" "/x/wt|gs://b/p" "env overrides win"

echo "== standard_worktree_path rejects unsafe components"
HOME="$FAKE_HOME"
unset STANDARD_WORKTREE_ROOT
# shellcheck source=scripts/lib/layout_standard.sh
source "$REPO_ROOT/scripts/lib/layout_standard.sh"
assert_false standard_worktree_path "" x
assert_false standard_worktree_path r ..
assert_false standard_worktree_path r a/b
assert_eq "$(standard_worktree_path r feat/x-y)" "" "slash in name rejected (empty stdout)"

echo "== path_is_under_standard_root"
assert_true path_is_under_standard_root "$FAKE_HOME/.worktrees/r/a"
assert_true path_is_under_standard_root "$FAKE_HOME/.worktrees/r/not-yet-created/deeper"
assert_false path_is_under_standard_root "$FAKE_HOME/.worktrees"
assert_false path_is_under_standard_root "$FAKE_HOME/.worktreesX/a"
assert_false path_is_under_standard_root "/tmp/a"
assert_false path_is_under_standard_root "$FAKE_HOME/.worktrees/r/../../projects/x"
assert_false path_is_under_standard_root "relative/path"
ln -s "$TMPROOT" "$FAKE_HOME/.worktrees/r/escape"
assert_false path_is_under_standard_root "$FAKE_HOME/.worktrees/r/escape/x"

echo
echo "layout_standard: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

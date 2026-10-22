#!/usr/bin/env bash
# test_cleanup_worktree_venvs_tracked.sh — a venv tracked by git is never stripped
#
# A committed venv is repo content: stripping it leaves tracked `D` entries that keep
# the worktree dirty forever. Fixture repos only.
#
# Run: bash tests/test_cleanup_worktree_venvs_tracked.sh
set -uo pipefail
export TMPDIR=/tmp
PYTHON_BIN="$(dirname "$(command -v python3 2>/dev/null || echo "/usr/bin/python3")")"
GIT_BIN="$(dirname "$(command -v git 2>/dev/null || echo "/usr/bin/git")")"
TEST_PATH="$PYTHON_BIN:$GIT_BIN:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_worktree_venvs.sh"

TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_venvs.XXXXXX)" && pwd -P)
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
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_fail "$name" "unexpected: $needle"
  else
    record_pass "$name"
  fi
}

# mk_worktree <path> — fake linked-worktree shape: a .git POINTER FILE (not a
# real git admin dir — matches test_worktree_recency.sh's mk_worktree; neither
# is_likely_worktree() nor worktree_age_days() need a real git repo).
mk_worktree() {
  local wt="$1"
  mkdir -p "$wt"
  echo "gitdir: /fake/admin/$(basename "$wt")" > "$wt/.git"
}

# age_path_days_ago <path> <days> — backdate a single path's mtime.
age_path_days_ago() {
  local path="$1" days="$2" ts
  ts=$(date -v-"${days}"d +%Y%m%d%H%M 2>/dev/null || date -d "-${days} days" +%Y%m%d%H%M)
  touch -t "$ts" "$path"
}

STATE_DIR="$TMP_ROOT/state"
ROOTS_DIR="$TMP_ROOT/roots"
mkdir -p "$STATE_DIR" "$ROOTS_DIR"

echo "=== a venv whose files are tracked by git is never stripped ==="
mk_real_wt() {  # <name> <tracked:yes|no> -> prints worktree path
  local base="$TMP_ROOT/$1-base" wt="$ROOTS_DIR/$1"
  git init -q -b main "$base"
  : > "$base/README.md"
  if [[ "$2" == yes ]]; then mkdir "$base/.venv"; : > "$base/.venv/pyvenv.cfg"; fi
  git -C "$base" -c user.name=t -c user.email=t@t add -A
  git -C "$base" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$base" -c user.name=t -c user.email=t@t worktree add -q -b "$1-branch" "$wt"
  [[ "$2" == yes ]] || { mkdir "$wt/.venv"; : > "$wt/.venv/pyvenv.cfg"; }
  find "$wt" -path "$wt/.git" -prune -o -type f -print | while read -r f; do age_path_days_ago "$f" 30; done
  age_path_days_ago "$wt/.git" 30
  printf '%s' "$wt"
}
TRACKED_WT="$(mk_real_wt trk_wt yes)"
UNTRACKED_WT="$(mk_real_wt untrk_wt no)"
OUT12="$TMP_ROOT/out12.txt"
env -i HOME="$TMP_ROOT/home" PATH="$TEST_PATH" \
  DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  DISK_MAGICIAN_LOAD5_OVERRIDE="0.1000" \
  bash "$TARGET_SCRIPT" --roots "$ROOTS_DIR" --min-age 14 --dry-run >"$OUT12" 2>&1
OUT12_CONTENT=$(cat "$OUT12")
assert_contains "tracked .venv is skipped" "skip (tracked by git): $TRACKED_WT/.venv" "$OUT12_CONTENT"
assert_not_contains "tracked .venv is not a strip candidate" "would strip $TRACKED_WT/.venv" "$OUT12_CONTENT"
assert_contains "untracked .venv is still a strip candidate" "would strip $UNTRACKED_WT/.venv" "$OUT12_CONTENT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_symlink_shared_venvs.sh — TDD contract test for scripts/symlink-shared-venvs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYMLINK_SCRIPT="$REPO_ROOT/scripts/symlink-shared-venvs.sh"

WORK="$(mktemp -d -t test_shared_venvs.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

# ─────────────────────────────────────────────────────────────
section "1. Basic venv deduplication (dry-run vs clean)"
TEST_REPO="$WORK/test-repo"
mkdir -p "$TEST_REPO/base_repo/venv"
mkdir -p "$TEST_REPO/base_repo/worktree_1/venv"

echo "home = /usr/bin" > "$TEST_REPO/base_repo/venv/pyvenv.cfg"
echo "home = /usr/bin" > "$TEST_REPO/base_repo/worktree_1/venv/pyvenv.cfg"

# Add payload to make base_repo/venv larger
dd if=/dev/zero of="$TEST_REPO/base_repo/venv/lib.so" bs=1024 count=100 >/dev/null 2>&1
dd if=/dev/zero of="$TEST_REPO/base_repo/worktree_1/venv/lib.so" bs=1024 count=10 >/dev/null 2>&1

OUT_DRY="$WORK/dry.log"
"$SYMLINK_SCRIPT" --dry-run --roots "$TEST_REPO" > "$OUT_DRY" 2>&1

if grep -q "would rename" "$OUT_DRY" && grep -q "would ln -sfn" "$OUT_DRY"; then
  ok "dry-run reports proposed rename and symlink"
else
  bad "dry-run failed to report proposed action"
fi

if [[ -d "$TEST_REPO/base_repo/worktree_1/venv" ]] && [[ ! -L "$TEST_REPO/base_repo/worktree_1/venv" ]]; then
  ok "dry-run left target venv as directory (no changes made)"
else
  bad "dry-run modified target venv directory"
fi

OUT_CLEAN="$WORK/clean.log"
"$SYMLINK_SCRIPT" --clean --roots "$TEST_REPO" > "$OUT_CLEAN" 2>&1

if [[ -L "$TEST_REPO/base_repo/worktree_1/venv" ]]; then
  ok "clean mode replaced worktree venv with symlink"
else
  bad "clean mode failed to replace worktree venv with symlink"
fi

# ─────────────────────────────────────────────────────────────
section "2. Idempotence — repeated runs skip existing symlinks"
OUT_IDEM="$WORK/idem.log"
"$SYMLINK_SCRIPT" --clean --roots "$TEST_REPO" > "$OUT_IDEM" 2>&1

if grep -q "already-symlinked" "$OUT_IDEM" || grep -q "skip (already symlink)" "$OUT_IDEM"; then
  ok "repeated run skipped already-symlinked venv"
else
  bad "repeated run failed to skip already-symlinked venv"
fi

# ─────────────────────────────────────────────────────────────
section "3. Python version mismatch protection"
TEST_REPO_MISMATCH="$WORK/mismatch-repo"
mkdir -p "$TEST_REPO_MISMATCH/repo2/venv"
mkdir -p "$TEST_REPO_MISMATCH/repo2/worktree_diff/venv"

echo "home = /usr/local/bin/python3.11" > "$TEST_REPO_MISMATCH/repo2/venv/pyvenv.cfg"
echo "home = /usr/local/bin/python3.12" > "$TEST_REPO_MISMATCH/repo2/worktree_diff/venv/pyvenv.cfg"

dd if=/dev/zero of="$TEST_REPO_MISMATCH/repo2/venv/lib.so" bs=1024 count=100 >/dev/null 2>&1
dd if=/dev/zero of="$TEST_REPO_MISMATCH/repo2/worktree_diff/venv/lib.so" bs=1024 count=10 >/dev/null 2>&1

OUT_MISMATCH="$WORK/mismatch.log"
"$SYMLINK_SCRIPT" --clean --roots "$TEST_REPO_MISMATCH" > "$OUT_MISMATCH" 2>&1

if [[ -d "$TEST_REPO_MISMATCH/repo2/worktree_diff/venv" ]] && [[ ! -L "$TEST_REPO_MISMATCH/repo2/worktree_diff/venv" ]]; then
  ok "python version mismatch safely skipped symlinking"
else
  bad "python version mismatch improperly replaced venv"
fi

# ─────────────────────────────────────────────────────────────
section "4. Purge old backup venvs (--purge-bak-days)"
BAK_DIR="$TEST_REPO/base_repo/worktree_1/venv.bak.20260101-000000"
mkdir -p "$BAK_DIR"
dd if=/dev/zero of="$BAK_DIR/dummy" bs=1024 count=5 >/dev/null 2>&1

# Backdate mtime to 10 days ago
touch -t 202601010000 "$BAK_DIR"

OUT_PURGE="$WORK/purge.log"
"$SYMLINK_SCRIPT" --clean --purge-bak-days 1 --roots "$TEST_REPO" > "$OUT_PURGE" 2>&1

if [[ ! -e "$BAK_DIR" ]]; then
  ok "purge-bak-days 1 removed old backup venv directory"
else
  bad "purge-bak-days 1 failed to remove old backup venv directory"
fi

# ─────────────────────────────────────────────────────────────
section "Summary"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi

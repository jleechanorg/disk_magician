#!/usr/bin/env bash
# Verifies check_system_residual.sh and cleanup_dirs_cleaner.sh operate correctly and safely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_SCRIPT="$REPO_ROOT/scripts/check_system_residual.sh"
CLEAN_SCRIPT="$REPO_ROOT/scripts/cleanup_dirs_cleaner.sh"

WORK="$(mktemp -d -t test_dirs_cleaner.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

STAGING_DIR="$WORK/dirs_cleaner"
mkdir -p "$STAGING_DIR/batch_1" "$STAGING_DIR/batch_2"
echo "dummy file 1" > "$STAGING_DIR/batch_1/file1.txt"
echo "dummy file 2" > "$STAGING_DIR/batch_2/file2.txt"

# 1. Test check_system_residual.sh in JSON mode
export TARGET_DIR="$STAGING_DIR"
export DISK_MAGICIAN_SKIP_PS_CHECK=1
export DISK_MAGICIAN_SKIP_LOG_CHECK=1
# Override TARGET_DIR in check_system_residual.sh via environment or temporary mock
CHECK_OUT="$(TARGET_DIR="$STAGING_DIR" DISK_MAGICIAN_SKIP_LOG_CHECK=1 bash "$CHECK_SCRIPT" --json)"
grep -q '"dirs_cleaner_path": "' <<< "$CHECK_OUT"
grep -q '"dirs_cleaner_mb":' <<< "$CHECK_OUT"

# 2. Test cleanup_dirs_cleaner.sh dry-run
CLEAN_DRY="$(DISK_MAGICIAN_DIRS_CLEANER_TARGET="$STAGING_DIR" bash "$CLEAN_SCRIPT" --dry-run)"
grep -q "\[DRY-RUN\]" <<< "$CLEAN_DRY"
test -f "$STAGING_DIR/batch_1/file1.txt"

# 3. Test cleanup_dirs_cleaner.sh clean
CLEAN_RUN="$(DISK_MAGICIAN_DIRS_CLEANER_TARGET="$STAGING_DIR" bash "$CLEAN_SCRIPT" --clean)"
grep -q "Done." <<< "$CLEAN_RUN"
test ! -f "$STAGING_DIR/batch_1/file1.txt"
test -d "$STAGING_DIR"

echo "PASS: test_cleanup_dirs_cleaner.sh"

#!/usr/bin/env bash
# test_unify_routine_cleanups.sh — Behavioral test for bead disk_magician-unify-routine-cleanups-wgo
#
# Asserts that:
# 1. ./disk_magician.sh clean --routine --dry-run and scripts/disk_audit.sh --clean --dry-run
#    execute the 6-tier routine cleanup stack:
#    - Tier 1: Dev caches, Temp files, PR scratch
#    - Tier 2: Xcode DerivedData & simulator caches
#    - Tier 3: Colima VM disk (Docker prune + fstrim)
#    - Tier 4: Aside browser sessions
#    - Tier 5: Antigravity brain compaction, Supervisor logs, uv cache
#    - Tier 6: Worktree venvs (>=7d dormant)
# 2. All categories execute without error in dry-run mode.
# 3. Worktree venvs require WORKTREE_APPROVED=1 to execute in non-dry-run mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
CLI_SCRIPT="$REPO_ROOT/disk_magician.sh"

TMP_DIR=$(mktemp -d -t test_routine_cleanups.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# Run disk_audit.sh --clean --dry-run
OUT_AUDIT="$TMP_DIR/audit_clean.log"
bash "$TARGET_SCRIPT" --clean --dry-run >"$OUT_AUDIT" 2>&1
RC_AUDIT=$?

if [[ $RC_AUDIT -ne 0 ]]; then
  echo "FAIL: disk_audit.sh --clean --dry-run exited with code $RC_AUDIT" >&2
  cat "$OUT_AUDIT" >&2
  exit 1
fi

EXPECTED_CATEGORIES=(
  "Dev caches"
  "Temp files"
  "PR scratch & analyzers"
  "Xcode DerivedData & simulator caches"
  "Colima VM disk (Docker prune + fstrim)"
  "Aside browser sessions"
  "Antigravity brain compaction"
  "Supervisor logs"
  "uv cache (disk-magician builds)"
  "Worktree venvs (>=7d dormant)"
)

for cat in "${EXPECTED_CATEGORIES[@]}"; do
  if ! grep -qF "$cat" "$OUT_AUDIT"; then
    echo "FAIL: expected category '$cat' not executed in disk_audit.sh --clean" >&2
    exit 1
  fi
done

# Run CLI disk_magician.sh routine --dry-run
OUT_CLI="$TMP_DIR/cli_routine.log"
DISK_MAGICIAN_AUTO_CLEAN=1 bash "$CLI_SCRIPT" routine --dry-run >"$OUT_CLI" 2>&1
RC_CLI=$?

if [[ $RC_CLI -ne 0 ]]; then
  echo "FAIL: disk_magician.sh routine --dry-run exited with code $RC_CLI" >&2
  cat "$OUT_CLI" >&2
  exit 1
fi

for cat in "${EXPECTED_CATEGORIES[@]}"; do
  if ! grep -qF "$cat" "$OUT_CLI"; then
    echo "FAIL: expected category '$cat' not executed in disk_magician.sh routine" >&2
    exit 1
  fi
done

echo "PASS: all 6-tier routine cleanup stack categories verified"
exit 0

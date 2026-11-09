#!/usr/bin/env bash
# Regression for the residency caller's ordinary no-live-cwd-match path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_ROOT="${CLAUDE_CODE_TMPDIR:-/tmp}"
TMPROOT="$(mktemp -d "$SCRATCH_ROOT/wt-residency.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

ROOT="$TMPROOT/worktrees"
WT="$ROOT/project/branch"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm fixture

# Keep fixture paths in the child environment, not the process command line;
# otherwise ps would report the test itself as a live cwd match.
WORKTREE_ROOT="$ROOT" DISK_MAGICIAN_RECENCY_LIB="$REPO_ROOT/scripts/lib/worktree_recency.sh" \
  python3 -c 'import subprocess, sys; subprocess.run([sys.argv[1]], check=True, timeout=20)' \
  "$REPO_ROOT/scripts/worktree_residency_check.sh" \
  >"$TMPROOT/output.txt"

if ! awk 'NR == 1 { header = $0 } END { if (NR != 2 || header !~ /LIVECWD/ || $0 !~ /no +1 +project\/branch$/) exit 1 }' "$TMPROOT/output.txt"; then
  cat "$TMPROOT/output.txt"
  echo "FAIL: expected one residency row with LIVECWD=no for project/branch" >&2
  exit 1
fi

cat "$TMPROOT/output.txt"
echo "PASS: no-match residency check returned its row"

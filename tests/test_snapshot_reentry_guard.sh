#!/usr/bin/env bash
# Regression: a nested snapshot writer must fail before it measures or writes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/../scripts/disk_snapshot.sh"

out="$(DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH=1 bash "$SNAPSHOT" --dry-run 2>&1)"
rc=$?

[[ "$rc" -eq 75 ]] || { echo "FAIL: expected re-entry rc 75, got $rc: $out"; exit 1; }
[[ "$out" == *"nested snapshot invocation"* ]] || { echo "FAIL: missing re-entry diagnostic: $out"; exit 1; }
echo "PASS: nested snapshot invocation is rejected"

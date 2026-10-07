#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DM="$REPO_ROOT/src/disk_magician/disk_magician.sh"

set +e
output=$(bash "$DM" correlate-swings --help 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q -- '--min-swing-gib' <<<"$output" && grep -q -- '--max-window-minutes' <<<"$output"; then
  echo "PASS: correlate-swings routes to the packaged correlator"
else
  echo "FAIL: correlate-swings did not expose correlator options" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

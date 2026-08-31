#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DM="$REPO_ROOT/src/disk_magician/disk_magician.sh"

set +e
output=$(bash "$DM" frontier --help 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q -- '--output-default' <<<"$output" && grep -q -- '--wall-clock-cap' <<<"$output"; then
  echo "PASS: frontier command routes to the packaged scanner"
else
  echo "FAIL: frontier command did not expose scanner options" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

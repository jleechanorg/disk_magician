#!/usr/bin/env bash
# Public dispatcher fixtures: recency preservation must not conceal >=100MiB leaves.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T/ptmp" DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$T/utmp"
mkdir -p "$HOME/.ao-sessions/recent/deep" "$HOME/dd_recent/Build" "$HOME/dd_recent/Index.noindex" "$HOME/.aside/u/test/sessions/recent/deep" "$T/ptmp" "$T/utmp"
for path in "$HOME/.ao-sessions/recent/deep/exact.bin" "$HOME/dd_recent/Build/exact.bin" "$HOME/.aside/u/test/sessions/recent/deep/exact.bin"; do python3 -c 'import sys; open(sys.argv[1], "wb").truncate(104857600)' "$path"; done
fail=0
for command in cleanup-xcode cleanup-sessions prune-aside-sessions; do
  bash "$ROOT/disk_magician.sh" "$command" --dry-run >"$T/$command.out" 2>&1 || { cat "$T/$command.out"; exit 1; }
  grep -F 'exact.bin' "$T/$command.out" >/dev/null && grep -F 'measurement_status=complete' "$T/$command.out" >/dev/null || { echo "FAIL: $command hides granular measurement"; fail=1; }
done
find "$HOME" -name exact.bin | grep -c . | grep -qx 3
exit "$fail"

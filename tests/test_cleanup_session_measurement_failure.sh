#!/usr/bin/env bash
# Expired shared deadline must preserve a failed unit and surface retryable failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T/ptmp" DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$T/utmp"
mkdir -p "$HOME/.ao-sessions/recent/deep" "$HOME/dd_recent/Build" "$HOME/dd_recent/Index.noindex" "$HOME/.aside/u/test/sessions/recent/deep" "$T/ptmp" "$T/utmp"
for path in "$HOME/.ao-sessions/recent/deep/exact.bin" "$HOME/dd_recent/Build/exact.bin" "$HOME/.aside/u/test/sessions/recent/deep/exact.bin"; do truncate -s 104857600 "$path"; done
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/xcrun"
chmod +x "$T/bin/xcrun"
export PATH="$T/bin:$PATH"
failed=0
for command in cleanup-xcode cleanup-sessions prune-aside-sessions; do
  rc=0
  ACT_DEADLINE_AT=0 bash "$ROOT/disk_magician.sh" "$command" --clean >"$T/$command.failed" 2>&1 || rc=$?
  if (( rc == 0 )); then echo "FAIL: $command concealed deadline failure"; failed=1; fi
  grep -F 'measurement_status=incomplete' "$T/$command.failed" >/dev/null
  # Same unit, fresh invocation with deadline removed; no cursor may skip it.
  env -u ACT_DEADLINE_AT bash "$ROOT/disk_magician.sh" "$command" --dry-run >"$T/$command.retry" 2>&1
  grep -F 'exact.bin' "$T/$command.retry" >/dev/null
  grep -F 'measurement_status=complete' "$T/$command.retry" >/dev/null
done
find "$HOME" -name exact.bin | grep -c . | grep -qx 3
exit "$failed"

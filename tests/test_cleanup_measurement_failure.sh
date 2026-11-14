#!/usr/bin/env bash
# Public CLI must preserve failed measurement units and retry them next pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state"
mkdir -p "$HOME/.cache/huggingface/hub/model/deep"
python3 -c 'import sys; open(sys.argv[1], "wb").truncate(104857600)' "$HOME/.cache/huggingface/hub/model/deep/exact.bin"
set +e
ACT_DEADLINE_AT=0 bash "$ROOT/disk_magician.sh" cleanup-dev-caches --clean >"$T/failed" 2>&1
rc=$?
set -e
cat "$T/failed"
test "$rc" -eq 124
grep -F 'measurement_status=incomplete rc=124' "$T/failed"
test -f "$HOME/.cache/huggingface/hub/model/deep/exact.bin"
bash "$ROOT/disk_magician.sh" cleanup-dev-caches --dry-run >"$T/retry" 2>&1
grep -F "$HOME/.cache/huggingface/hub/model/deep/exact.bin" "$T/retry"
grep -F 'measurement_status=complete' "$T/retry"

# The agent-artifacts reporter uses echo substitutions for size context;
# measurement failures must propagate in the parent shell, not be swallowed.
mkdir -p "$HOME/.claude/debug/deep"
printf fixture > "$HOME/.claude/debug/deep/keep"
set +e
ACT_DEADLINE_AT=0 bash "$ROOT/disk_magician.sh" cleanup-agent-artifacts --clean >"$T/artifacts-failed" 2>&1
rc=$?
set -e
test "$rc" -eq 124
grep -F 'measurement_status=incomplete rc=124' "$T/artifacts-failed"
test -f "$HOME/.claude/debug/deep/keep"
bash "$ROOT/disk_magician.sh" cleanup-agent-artifacts --dry-run >"$T/artifacts-retry" 2>&1
grep -F 'measurement_status=complete' "$T/artifacts-retry"

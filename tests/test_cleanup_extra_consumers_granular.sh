#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.claude/debug/deep" "$T/state"
python3 -c 'import sys; open(sys.argv[1], "wb").truncate(104857600)' "$T/home/.claude/debug/deep/exact.bin"
HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" bash "$ROOT/disk_magician.sh" cleanup-agent-artifacts --dry-run >"$T/out" 2>&1
cat "$T/out"
grep -F "$T/home/.claude/debug/deep/exact.bin" "$T/out"
grep -F 'measurement_status=complete' "$T/out"
test -f "$T/home/.claude/debug/deep/exact.bin"

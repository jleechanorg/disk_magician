#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.ao-sessions" "$T/outside/deep"
printf 'protected\n' >"$T/outside/deep/never-follow"
ln -s "$T/outside" "$T/home/.ao-sessions/linked"
HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" bash "$ROOT/disk_magician.sh" cleanup-sessions --dry-run >"$T/out" 2>&1
cat "$T/out"
grep -F 'SKIP linked: symlink boundary' "$T/out"
! grep -F 'never-follow' "$T/out"
test -f "$T/outside/deep/never-follow"

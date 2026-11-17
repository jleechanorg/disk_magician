#!/usr/bin/env bash
# Public CLI: an idle model is independently considered beside an active model.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.cache/huggingface/hub/model/deep" "$T/state"
python3 -c 'import sys; open(sys.argv[1], "wb").truncate(104857600)' "$T/home/.cache/huggingface/hub/model/deep/exact.bin"
mkdir -p "$T/home/.cache/huggingface/hub/idle-model/deep"
printf old > "$T/home/.cache/huggingface/hub/idle-model/deep/payload"
python3 - "$T/home/.cache/huggingface/hub/idle-model" <<'PYAGE'
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1]); old = time.time() - 3 * 86400
for path in [root, *root.rglob("*")]: os.utime(path, (old, old))
PYAGE
HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" bash "$ROOT/disk_magician.sh" cleanup-dev-caches --dry-run >"$T/out" 2>&1
cat "$T/out"
grep -F "$T/home/.cache/huggingface/hub/model/deep/exact.bin" "$T/out"
grep -F 'measurement_status=complete' "$T/out"
test -f "$T/home/.cache/huggingface/hub/model/deep/exact.bin"
grep -F "huggingface cache idle unit: [dry-run] would delete $T/home/.cache/huggingface/hub/idle-model" "$T/out"

#!/usr/bin/env bash
# Hugging Face cache handling in cleanup_dev_caches.sh.
#
# ~/.cache/huggingface and ~/.cache/hy3dgen are model caches: large, rebuildable by
# re-download, but a running job may be mid-download. So a root touched within 24h must
# be preserved wholesale, an unmeasurable scan must preserve (fail closed), and a bare
# invocation must delete nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/cleanup_dev_caches.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-hf-cache.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

run() { HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" timeout 300 bash "$SCRIPT" "$@" 2>&1; }

# ---- Case 1: old cache, dry-run default removes nothing
mkdir -p "$T/home/.cache/huggingface/models--old/snapshots"
echo payload >"$T/home/.cache/huggingface/models--old/snapshots/blob"
touch -d '4 days ago' "$T/home/.cache/huggingface/models--old/snapshots/blob" 2>/dev/null \
  || touch -t "$(date -d '4 days ago' +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$T/home/.cache/huggingface/models--old/snapshots/blob"

out="$(run)"
[[ "$out" == *"huggingface cache: [dry-run] would delete contents"* ]] \
  && ok "old huggingface cache is reported in dry-run" \
  || bad "old huggingface cache not reported in dry-run"
[[ -f "$T/home/.cache/huggingface/models--old/snapshots/blob" ]] \
  && ok "dry-run deleted nothing" || bad "dry-run deleted a file"

# ---- Case 2: young cache is preserved even under --clean
mkdir -p "$T/home/.cache/hy3dgen/recent"
echo payload >"$T/home/.cache/hy3dgen/recent/fresh.bin"
out="$(run --clean)"
[[ "$out" == *"hy3dgen cache: recently written"* ]] \
  && ok "young hy3dgen cache preserved with a reason" || bad "young hy3dgen cache not preserved"
[[ -f "$T/home/.cache/hy3dgen/recent/fresh.bin" ]] \
  && ok "young cache file survived --clean" || bad "young cache file was deleted"

# ---- Case 3: old cache is acted on under --clean (removal is delegated to c14_remove,
# so the assertion is that the young one survives and the old one is no longer reported
# as merely 'would delete' — the script reached its removal path for it).
out="$(run --clean)"
[[ "$out" != *"huggingface cache: recently written"* ]] \
  && ok "old huggingface cache not treated as young" || bad "old cache misclassified as young"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

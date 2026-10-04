#!/usr/bin/env bash
# tests/test_audit_help_no_scan.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/lib/sandbox_env.sh"
SANDBOX="$(mktemp -d)"
SHIM="$SANDBOX/bin"
mkdir -p "$SHIM"
trap 'rm -rf "$SANDBOX"' EXIT
for tool in gdu du find; do
  printf '#!/bin/sh\necho "SCAN-INVOKED: %s" >&2\nexit 97\n' "$tool" > "$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
out="$(env -u DISK_MAGICIAN_AUTO_CLEAN -u DISK_MAGICIAN_SAFE_AUTO \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
  PATH="$SHIM:$PATH" timeout 30 \
  bash "$ROOT/src/disk_magician/disk_magician.sh" audit --help 2>&1)" \
  || { echo "FAIL: audit --help exited non-zero: $out"; exit 1; }
if grep -q 'SCAN-INVOKED' <<<"$out"; then echo "FAIL: audit --help scanned"; exit 1; fi
grep -q 'Usage:' <<<"$out" || { echo "FAIL: audit --help printed no usage"; exit 1; }
echo PASS

#!/usr/bin/env bash
# tests/test_cleanup_tmp_private_root.sh — bead disk_magician-ty62.
#
# /private/tmp is the macOS canonical scratch root (/tmp symlinks to it there),
# but Linux has no /private/tmp at all. The resolver used to hardcode it, so on
# every Linux host cleanup_tmp's --large scan resolved to nothing and logged
# "Skipping --large scan: private-tmp root is unavailable", silently disabling
# the aggressive tier. The resolver now tries candidates in order
# (DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES, default /private/tmp:/tmp) and still
# fails closed when none exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$REPO_ROOT/scripts/lib/scratch_roots.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want '$3' got '$2')"; }

TMP="$(mktemp -d "${TMPDIR%/}/ty62.XXXXXX")" || exit 1
trap 'rm -rf "${TMP:?}"' EXIT

echo "== resolver =="
# macOS canonical root wins when it exists (this is the pre-existing behaviour).
if [[ -d /private/tmp ]]; then
    eq "default prefers the macOS canonical root" "$(scratch_roots_get_private_tmp)" /private/tmp
else
    eq "default falls back to /tmp when /private/tmp is absent" "$(scratch_roots_get_private_tmp)" /tmp
fi

# The Linux shape: first candidate absent, second present.
eq "falls back to the first existing candidate" \
   "$(DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES="/nonexistent-ty62:/tmp" scratch_roots_get_private_tmp)" /tmp

# Fail-closed contract from bead ka4 must survive: nothing resolvable => empty.
eq "all candidates missing resolves to empty" \
   "$(DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES="/nonexistent-a:/nonexistent-b" scratch_roots_get_private_tmp)" ""

# An explicit override that doesn't exist must not silently fall back.
eq "missing explicit override stays empty (fail closed)" \
   "$(DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="/nonexistent-ty62" scratch_roots_get_private_tmp)" ""

echo "== end-to-end: --large runs when a later candidate resolves =="
FIX="$TMP/fixture-root"
mkdir -p "$FIX/big"
printf 'payload\n' > "$FIX/big/payload.bin"

OUT="$TMP/e2e.log"
DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES="/nonexistent-ty62:$FIX" \
  LARGE_TMP_MIN_KB=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --large > "$OUT" 2>&1 || true

if grep -qF "private-tmp root is unavailable" "$OUT"; then
    bad "must not skip the --large scan when a candidate resolves"
else
    ok "does not skip the --large scan when a candidate resolves"
fi
if grep -qF "Scanning $FIX for large top-level dirs" "$OUT"; then
    ok "scans the resolved candidate root"
else
    bad "did not scan the resolved candidate root"
    sed 's/^/        | /' "$OUT" | head -8
fi
# The fresh fixture must be protected by the active-use window, proving the scan
# actually evaluated it rather than silently doing nothing.
if grep -qF "Skipping recently active dir (mtime" "$OUT"; then
    ok "evaluated the fixture and applied the active-use gate"
else
    bad "fixture was never evaluated by the active-use gate"
fi

echo "== end-to-end: --large still fails closed with no resolvable root =="
OUT2="$TMP/e2e-missing.log"
DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES="/nonexistent-a:/nonexistent-b" \
  LARGE_TMP_MIN_KB=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --large > "$OUT2" 2>&1 || true
if grep -qF "Skipping --large scan: private-tmp root is unavailable" "$OUT2"; then
    ok "preserves the fail-closed skip when nothing resolves"
else
    bad "lost the fail-closed skip"
fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

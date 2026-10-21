#!/usr/bin/env bash
# tests/test_degraded_gate.sh — bead disk_magician-kub3 (silent no-op guard).
#
# Root cause 2026-10-21: on jeff-ubuntu the scheduled 6-tier cleaner printed
#   Categories attempted: 18
#   All attempted categories completed without error.
# and exited 0 while the host sat at 98% with swap exhausted. Every candidate had
# been refused as kept:cwd-unknown, so the automation reported health while
# reclaiming nothing. A run that had eligible candidates and reclaimed zero must
# not report success.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/degraded_gate.sh
source "$REPO_ROOT/scripts/lib/degraded_gate.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want '$3' got '$2')"; }

TMP="$(mktemp -d "${TMPDIR%/}/deg-gate.XXXXXX")" || exit 1
trap 'rm -rf "${TMP:?}"' EXIT

echo "== gate_refusal_count =="
CLEAN_LOG="$TMP/clean.log"
printf 'Total freed: 4096 KB\nDirs removed: 12\n' > "$CLEAN_LOG"
eq "clean log counts 0" "$(gate_refusal_count "$CLEAN_LOG")" 0

C14_LOG="$TMP/c14.log"
{
  printf 'Preserving (C14 kept:cwd-unknown): /tmp/a\n'
  printf 'Preserving (C14 kept:cwd-unknown): /tmp/b\n'
  printf 'kept:cwd-unknown\n'
} > "$C14_LOG"
eq "both spellings counted" "$(gate_refusal_count "$C14_LOG")" 3

eq "missing file counts 0" "$(gate_refusal_count "$TMP/nope.log")" 0
eq "empty path counts 0" "$(gate_refusal_count "")" 0

NOISY_LOG="$TMP/noisy.log"
printf 'kept:dirty\nkept:recent-activity\nkept:check-failed\n' > "$NOISY_LOG"
eq "unrelated kept reasons not counted" "$(gate_refusal_count "$NOISY_LOG")" 0

echo "== gate_is_degraded =="
if gate_is_degraded 4; then bad "4 refusals must not degrade at the default threshold 5"; else ok "4 refusals below default threshold 5"; fi
if gate_is_degraded 5; then ok "5 refusals reach the default threshold"; else bad "5 refusals should degrade"; fi
if gate_is_degraded 0; then bad "0 refusals must never degrade"; else ok "0 refusals never degrade"; fi
if DISK_MAGICIAN_DEGRADED_REFUSALS=0 gate_is_degraded 500; then bad "threshold 0 must disable the gate"; else ok "threshold 0 disables the gate"; fi
if DISK_MAGICIAN_DEGRADED_REFUSALS=1 gate_is_degraded 1; then ok "env threshold 1 degrades on a single refusal"; else bad "env threshold 1 should degrade"; fi

echo "== end-to-end: driver exits non-zero when a category is degraded =="
# Copy the driver into a stub tree so a fake category can emit gate refusals
# without touching the real sweepers.
drive() {  # drive <stub-body> <label>
  local body="$1" name="$2" tree rc
  tree="$(mktemp -d "$TMP/tree.$name.XXXXXX")" || return 99
  mkdir -p "$tree/scripts/lib"
  cp "$REPO_ROOT/scripts/disk_audit.sh" "$tree/scripts/"
  cp "$REPO_ROOT/scripts/lib/degraded_gate.sh" "$tree/scripts/lib/"
  printf '%s\n' "$body" > "$tree/scripts/cleanup_dev_caches.sh"
  chmod +x "$tree/scripts/cleanup_dev_caches.sh"
  ( cd "$tree/scripts" && timeout 180 bash disk_audit.sh clean --no-history --skip-directory-breakdown ) \
      > "$tree/out.log" 2>&1
  rc=$?
  printf '%s' "$tree" > "$TMP/last_tree"
  return $rc
}

DEGRADED_BODY='#!/usr/bin/env bash
for i in 1 2 3 4 5 6; do echo "Preserving (C14 kept:cwd-unknown): /tmp/x$i"; done
echo "Total freed: 0 KB"
exit 0'
if drive "$DEGRADED_BODY" degraded; then
  bad "degraded category run must exit non-zero"
else
  ok "degraded category run exits non-zero"
fi
TREE="$(cat "$TMP/last_tree")"
grep -qF "CATEGORY DEGRADED" "$TREE/out.log" && ok "logs CATEGORY DEGRADED" || bad "missing CATEGORY DEGRADED line"
grep -qF "categories DEGRADED" "$TREE/out.log" && ok "summary reports the degraded count" || bad "missing degraded summary"
if grep -qF "All attempted categories completed without error." "$TREE/out.log"; then
  bad "must not claim success on a degraded run"
else
  ok "does not claim success on a degraded run"
fi

CLEAN_BODY='#!/usr/bin/env bash
echo "Total freed: 4096 KB"
exit 0'
if drive "$CLEAN_BODY" clean; then
  ok "clean category run still exits zero"
else
  bad "clean category run must exit zero"
fi
TREE="$(cat "$TMP/last_tree")"
grep -qF "All attempted categories completed without error." "$TREE/out.log" && ok "clean run still reports success" || bad "clean run lost its success line"
grep -qF "DEGRADED" "$TREE/out.log" && bad "clean run must not be marked degraded" || ok "clean run is not marked degraded"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

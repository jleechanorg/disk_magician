#!/bin/bash
# test_sim_lifecycle.sh — behaviour contract for `diskm sim`.
#
# TDD note: written before scripts/sim_lifecycle.sh exists. Every case below is
# expected to FAIL until the implementation lands. The suite never touches a real
# simulator: it drives the module against a fixture root via
# DISK_MAGICIAN_SIM_FIXTURE_ROOT, so CoreSimulator is never invoked.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/scripts/sim_lifecycle.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

[[ -f "$MODULE" ]] || { echo "MISSING MODULE: $MODULE (expected before implementation)"; echo "=== Summary: 0 passed, 1 failed ==="; exit 1; }

# shellcheck source=/dev/null
source "$MODULE"

TMP="${TMPDIR:-/tmp}/sim-lifecycle-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "${TMP:?}"' EXIT

export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"

echo "== 1. status reports the required keys for every device =="
fixture="$TMP/fixture"
mkdir -p "$fixture/pool-a"
# two fixture devices: one booted, one shutdown
sim_fixture_device "$fixture" "AAAAAAAA-1111-2222-3333-444444444444" "wai-shared-ios-26-5-a" "Booted"  10
sim_fixture_device "$fixture" "BBBBBBBB-1111-2222-3333-444444444444" "task-named-old"         "Shutdown" 100
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_status_json 2>/dev/null)"
if printf '%s' "$out" | grep -q '"udid"' && \
   printf '%s' "$out" | grep -q '"state"' && \
   printf '%s' "$out" | grep -q '"lease_owner"'; then
    ok "status JSON carries udid/state/lease_owner"
else
    bad "status JSON missing required keys (got: ${out:0:120})"
fi

echo "== 2. lease never returns an already-leased UDID =="
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_lease --wait-seconds 0 >"$TMP/l1" 2>"$TMP/e1"
rc1=$?
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_lease --wait-seconds 0 >"$TMP/l2" 2>"$TMP/e2"
rc2=$?
if [[ "$rc1" -eq 0 ]] && [[ "$rc2" -ne 0 ]]; then
    ok "second concurrent lease refused rather than double-returning"
elif [[ "$rc1" -ne 0 ]] && [[ "$rc2" -ne 0 ]]; then
    ok "no free slot refused both leases (fail closed)"
else
    u1="$(grep -oE '"[0-9A-F-]{8,}"' "$TMP/l1" 2>/dev/null | head -1)"
    u2="$(grep -oE '"[0-9A-F-]{8,}"' "$TMP/l2" 2>/dev/null | head -1)"
    [[ -n "$u1" && "$u1" != "$u2" ]] && ok "distinct UDIDs leased" || bad "lease returned the same device twice"
fi

# release any lease taken in case 2 so later cases see a free pool slot
for lf in "$TMP/l1" "$TMP/l2"; do
  [[ -f "$lf" ]] || continue
  t="$(grep -oE 'lt_[A-Za-z0-9_]+' "$lf" 2>/dev/null | head -1)"
  u="$(grep -oE '"[0-9A-F-]{8,}"' "$lf" 2>/dev/null | head -1 | tr -d '"')"
  [[ -n "$t" && -n "$u" ]] || continue
  DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "$u" --token "$t" >/dev/null 2>&1 || true
done

echo "== 3. release requires a token (never defaults) =="
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "AAAAAAAA-1111-2222-3333-444444444444" >/dev/null 2>"$TMP/e3"
rc=$?
[[ "$rc" -ne 0 ]] && ok "release without --token refused" || bad "release without a token was accepted"

echo "== 4. a stale-generation token fails closed and writes no receipt =="
tok_old="lt_stale_generation"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "AAAAAAAA-1111-2222-3333-444444444444" --token "$tok_old" >/dev/null 2>&1
rc=$?
receipts_before=$(find "$DISK_MAGICIAN_STATE_DIR" -name '*release*' 2>/dev/null | wc -l | tr -d ' ')
[[ "$rc" -ne 0 ]] && ok "stale token refused (exit $rc)" || bad "stale token was accepted"
[[ "$receipts_before" -eq 0 ]] && ok "no receipt written for a stale token" || bad "stale token wrote a receipt"

echo "== 5. prune preserves Booted, leased, young, and unreleased devices =="
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_prune --dry-run 2>/dev/null)"
if printf '%s' "$out" | grep -q 'AAAAAAAA-1111-2222-3333-444444444444'; then
    bad "prune proposed removing the Booted device"
else
    ok "Booted device excluded"
fi
if printf '%s' "$out" | grep -q 'BBBBBBBB-1111-2222-3333-444444444444'; then
    bad "prune proposed removing a device with no release receipt"
else
    ok "unreleased task-named device excluded (age is not proof)"
fi

echo "== 6. unmeasurable mtime fails closed =="
sim_fixture_device "$fixture" "CCCCCCCC-1111-2222-3333-444444444444" "unmeasurable" "Shutdown" -1
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_prune --dry-run 2>/dev/null)"
printf '%s' "$out" | grep -q 'CCCCCCCC-1111-2222-3333-444444444444' && bad "unmeasurable device proposed for removal" || ok "unmeasurable mtime preserved"

echo "== 7. release writes exactly one receipt line and is generation-fenced =="
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_lease --wait-seconds 0 >"$TMP/l7" 2>/dev/null
tok="$(grep -oE 'lt_[A-Za-z0-9_]+' "$TMP/l7" 2>/dev/null | head -1)"
udid="$(grep -oE '"[0-9A-F-]{8,}"' "$TMP/l7" 2>/dev/null | head -1 | tr -d '"')"
if [[ -n "$tok" && -n "$udid" ]]; then
    DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "$udid" --token "$tok" >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 0 ]] && ok "release with the current token succeeded" || bad "valid release rejected (rc=$rc)"
    # a second release with the same (now superseded) token must fail
    DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "$udid" --token "$tok" >/dev/null 2>&1
    [[ "$?" -ne 0 ]] && ok "replayed token refused after supersession" || bad "replayed token accepted"
else
    bad "could not lease a device to test release fencing"
fi

echo "== 8. token is not written into receipts (credential hygiene) =="
if grep -rqs 'lt_' "$DISK_MAGICIAN_STATE_DIR"/receipts 2>/dev/null; then
    bad "raw lease token found in a receipt"
else
    ok "no raw token in receipts"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

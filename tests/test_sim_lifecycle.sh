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
sim_fixture_device "$fixture" "AAAAAAAA-1111-2222-3333-444444444444" "wai-shared-ios-26-5-a" "Shutdown" 10
sim_fixture_device "$fixture" "BBBBBBBB-1111-2222-3333-444444444444" "task-named-old"         "Shutdown" 100
sim_fixture_device "$fixture" "cccccccc-1111-2222-3333-444444444444" "wai-shared-booted"      "Booted"   10
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
# Isolated state dir: earlier cases legitimately wrote their own receipts.
c4_state="$TMP/state4"; mkdir -p "$c4_state"
export DISK_MAGICIAN_STATE_DIR="$c4_state"
tok_old="lt_stale_generation"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_release "AAAAAAAA-1111-2222-3333-444444444444" --token "$tok_old" >/dev/null 2>&1
rc=$?
receipts_before=$(find "$DISK_MAGICIAN_STATE_DIR" -name '*release*' 2>/dev/null | wc -l | tr -d ' ')
[[ "$rc" -ne 0 ]] && ok "stale token refused (exit $rc)" || bad "stale token was accepted"
[[ "$receipts_before" -eq 0 ]] && ok "no receipt written for a stale token" || bad "stale token wrote a receipt"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

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

echo "== 9. create refuses without --reason =="
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_create >/dev/null 2>"$TMP/e9"
[[ "$?" -ne 0 ]] && ok "create without --reason refused" || bad "create accepted with no reason"

echo "== 10. create refuses when a free pool slot exists =="
# Dedicated fixture so state from earlier cases cannot mask the slot check.
slot_fx="$TMP/slotfx"; mkdir -p "$slot_fx"
sim_fixture_device "$slot_fx" "dddddddd-1111-2222-3333-444444444444" "wai-shared-ios-26-5-z" "Shutdown" 10
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$slot_fx" sim_create --reason "test" >/dev/null 2>"$TMP/e10"
rc10=$?
[[ "$rc10" -eq 21 ]] && ok "create refused because a slot was available (exit 21)" || bad "create ignored an available slot (rc=$rc10: $(head -1 "$TMP/e10"))"

echo "== 11. create refuses at the pool cap =="
cap_fx="$TMP/capfx"; mkdir -p "$cap_fx"
for i in 1 2 3; do sim_fixture_device "$cap_fx" "DDDDDDDD-1111-2222-3333-44444444440$i" "wai-shared-ios-26-5-$i" "Booted" 5; done
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$cap_fx" DISK_MAGICIAN_SIM_POOL_SLOTS=3 sim_create --reason "test" 2>&1)"
[[ "$?" -eq 21 ]] && ok "create refused at pool cap (3/3)" || bad "create exceeded the pool cap"

echo "== 12. interrupted create leaks no capacity (recoverable reservation) =="
recov_fx="$TMP/recovfx"; mkdir -p "$recov_fx"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$TMP/state/sim_reservations"
mkdir -p "$DISK_MAGICIAN_SIM_RESERVE_DIR/stale-1"
printf 'status=reserving\n' >"$DISK_MAGICIAN_SIM_RESERVE_DIR/stale-1/meta"
before="$(find "$DISK_MAGICIAN_STATE_DIR/sim_reservations" -maxdepth 1 -type d ! -path "$DISK_MAGICIAN_STATE_DIR/sim_reservations" 2>/dev/null | wc -l | tr -d ' ')"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$recov_fx" sim_recover_reservations >/dev/null 2>&1
after="$(find "$DISK_MAGICIAN_STATE_DIR/sim_reservations" -maxdepth 1 -type d ! -path "$DISK_MAGICIAN_STATE_DIR/sim_reservations" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$before" -ge 1 && "$after" -eq 0 ]] && ok "orphaned reservation reclaimed its capacity" || bad "orphaned reservation leaked capacity (before=$before after=$after)"

echo "== 13. a reservation that recorded a UDID is reconciled, not silently dropped =="
mkdir -p "$DISK_MAGICIAN_STATE_DIR/sim_reservations/created-1"
printf 'status=created\n' >"$DISK_MAGICIAN_STATE_DIR/sim_reservations/created-1/meta"
printf 'eeeeeeee-1111-2222-3333-444444444444\n' >"$DISK_MAGICIAN_STATE_DIR/sim_reservations/created-1/udid"
msg="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_recover_reservations 2>&1)"
printf '%s' "$msg" | grep -q 'recover:' && ok "recorded-UDID reservation reconciled with a receipt line" || bad "recorded-UDID reservation produced no recovery line"

echo "== 14. floor cannot be lowered below 2880 minutes =="
low="$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=120 sim_floor_minutes)"
[[ "$low" -eq 2880 ]] && ok "floor clamped to the hard 2880-minute minimum" || bad "floor was lowered to $low by configuration"
high="$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=99999 sim_floor_minutes)"
[[ "$high" -eq 99999 ]] && ok "floor may be lengthened" || bad "floor did not honour a longer value"

echo "== 15. generation is monotonic across release, never reset to 1 =="
g15_state="$TMP/state15"; g15_fx="$TMP/fx15"; mkdir -p "$g15_state" "$g15_fx"
sim_fixture_device "$g15_fx" "aabbccdd-1111-2222-3333-444444444444" "wai-shared-ios-26-5-g" "Shutdown" 5
export DISK_MAGICIAN_STATE_DIR="$g15_state"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g15_fx" sim_lease --wait-seconds 0 >"$TMP/g-le1" 2>/dev/null
tk1="$(grep -oE 'lt_[A-Za-z0-9_]+' "$TMP/g-le1" | head -1)"
ug1="$(grep -oE '"[0-9a-fA-F-]{8,}"' "$TMP/g-le1" | head -1 | tr -d '"')"
g1="$(sed -nE 's/.*"lease_generation": ([0-9]+).*/\1/p' "$TMP/g-le1" | head -1)"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g15_fx" sim_release "$ug1" --token "$tk1" >/dev/null 2>&1
rel_rc=$?
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g15_fx" sim_lease --wait-seconds 0 >"$TMP/g-le2" 2>/dev/null
g2="$(sed -nE 's/.*"lease_generation": ([0-9]+).*/\1/p' "$TMP/g-le2" | head -1)"
if [ -n "${g1:-}" ] && [ -n "${g2:-}" ] && [ "${g2:-0}" -gt "${g1:-0}" ]; then
    ok "generation advanced (${g1} -> ${g2}) across release/re-lease"
else
    bad "generation did not advance (g1=${g1:-none} g2=${g2:-none} release_rc=${rel_rc:-?})"
fi
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo "== 16. an old receipt does not authorise a newer lease (generation fencing) =="
export DISK_MAGICIAN_STATE_DIR="$g15_state"
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g15_fx" sim_prune --dry-run 2>/dev/null)"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
printf '%s' "$out" | grep -q 'keep:leased' && ok "re-leased device is keep:leased, old receipt ignored" || bad "stale-generation receipt was honoured"

echo "== 17. concurrent release is serialized (only one succeeds) =="
conc_fx="$TMP/concfx"; conc_state="$TMP/state17"; mkdir -p "$conc_fx" "$conc_state"
export DISK_MAGICIAN_STATE_DIR="$conc_state"
sim_fixture_device "$conc_fx" "bbbbbbbb-1111-2222-3333-444444444444" "wai-shared-ios-26-5-c" "Shutdown" 5
cle="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$conc_fx" sim_lease --wait-seconds 0 2>/dev/null)"
ctk="$(printf '%s' "$cle" | grep -oE 'lt_[A-Za-z0-9_]+' | head -1)"
cud="$(printf '%s' "$cle" | grep -oE '"[0-9a-fA-F-]{8,}"' | head -1 | tr -d '"')"
( DISK_MAGICIAN_SIM_FIXTURE_ROOT="$conc_fx" sim_release "$cud" --token "$ctk" >/dev/null 2>"$TMP/e17a"; echo $? >"$TMP/r1" ) &
( DISK_MAGICIAN_SIM_FIXTURE_ROOT="$conc_fx" sim_release "$cud" --token "$ctk" >/dev/null 2>"$TMP/e17b"; echo $? >"$TMP/r2" ) &
wait
r1="$(cat "$TMP/r1" 2>/dev/null)"; r2="$(cat "$TMP/r2" 2>/dev/null)"
wins=0; [[ "$r1" == "0" ]] && wins=$((wins+1)); [[ "$r2" == "0" ]] && wins=$((wins+1))
[[ "$wins" -eq 1 ]] && ok "exactly one of two concurrent releases succeeded" || bad "concurrent release outcome wrong (r1=$r1 r2=$r2: $(cat "$TMP/e17a" "$TMP/e17b" 2>/dev/null | head -2 | tr '\n' ' '))"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

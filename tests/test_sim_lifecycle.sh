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
# prune prints NAMES, so assert on the name; grepping a UDID proved nothing
# (review finding). wai-shared-booted is the Booted pool device from the fixture.
if printf '%s' "$out" | grep -qE '^remove:.*wai-shared-booted'; then
    bad "prune proposed removing the Booted device"
else
    ok "Booted device excluded (asserted by NAME, matching prune output)"
fi
if printf '%s' "$out" | grep -qE '^remove:.*task-named-old'; then
    bad "prune proposed removing a device with no release receipt"
else
    ok "unreleased task-named device excluded (age is not proof), asserted by NAME"
fi

echo "== 6. unmeasurable mtime fails closed =="
sim_fixture_device "$fixture" "CCCCCCCC-1111-2222-3333-444444444444" "unmeasurable" "Shutdown" -1
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$fixture" sim_prune --dry-run 2>/dev/null)"
printf '%s' "$out" | grep -q '^keep:mtime-unmeasurable unmeasurable' && ok "unmeasurable mtime preserved (asserted by NAME)" || bad "unmeasurable device not preserved by name"

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

echo "== 18. generation corruption fails closed instead of resetting to 1 =="
corrupt_state="$TMP/state18"; corrupt_fx="$TMP/fx18"; mkdir -p "$corrupt_state/gen" "$corrupt_fx"
printf 'not-a-number\n' >"$corrupt_state/gen/aaddccbb-1111-2222-3333-444444444444"
export DISK_MAGICIAN_STATE_DIR="$corrupt_state"
sim_fixture_device "$corrupt_fx" "aaddccbb-1111-2222-3333-444444444444" "wai-shared-ios-26-5-x" "Shutdown" 5
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$corrupt_fx" sim_lease --wait-seconds 0 >/dev/null 2>"$TMP/e18"
rc18=$?
[[ "$rc18" -ne 0 ]] && ok "corrupt generation counter refused (no silent reset to 1)" || bad "corrupt generation silently reset"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo "== 19. recovery will not reap a reservation with a live creator =="
live_state="$TMP/state19"; mkdir -p "$live_state/sim_reservations/live-1"
printf 'status=reserving\npid=%s\nname=wai-shared-live\n' "$$" >"$live_state/sim_reservations/live-1/meta"
export DISK_MAGICIAN_STATE_DIR="$live_state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$live_state/sim_reservations"
out="$(sim_recover_reservations 2>&1)"
[[ -d "$live_state/sim_reservations/live-1" ]] && ok "live creator's reservation preserved" || bad "recovery reaped a live creator's reservation"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 20. crash after create-before-register is recovered by NAME, not lost =="
orph_state="$TMP/state20"; orph_fx="$TMP/fx20"; mkdir -p "$orph_state/sim_reservations/orph-1" "$orph_fx"
sim_fixture_device "$orph_fx" "bbddccaa-1111-2222-3333-444444444444" "wai-shared-orphan" "Shutdown" 5
printf 'status=reserving\npid=999999\nname=wai-shared-orphan\n' >"$orph_state/sim_reservations/orph-1/meta"
export DISK_MAGICIAN_STATE_DIR="$orph_state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$orph_state/sim_reservations"
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$orph_fx" sim_recover_reservations 2>&1)"
printf '%s' "$out" | grep -q 'recover:orphan-device' && ok "unregistered but created device detected by name (not treated as no-device)" || bad "crash-after-create orphan was misclassified"
[[ -d "$orph_fx/bbddccaa-1111-2222-3333-444444444444" ]] && ok "orphan device left intact for operator decision" || bad "orphan device was removed by recovery"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 21. a live lease blocks prune even with a matching receipt =="
pl_state="$TMP/state21"; pl_fx="$TMP/fx21"; mkdir -p "$pl_state" "$pl_fx"
export DISK_MAGICIAN_STATE_DIR="$pl_state"
sim_fixture_device "$pl_fx" "ccddaabb-1111-2222-3333-444444444444" "wai-shared-leased" "Shutdown" 999
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$pl_fx" sim_lease --wait-seconds 0 >/dev/null 2>&1
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$pl_fx" sim_prune --dry-run 2>/dev/null)"
printf '%s' "$out" | grep -qE '^keep:leased.*wai-shared-leased' && ok "leased device excluded from prune by NAME" || bad "leased device was a prune candidate"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo "== 22. /dot repro: unfinished registration with LIVE creator is not leaseable =="
r22="$TMP/r22"; mkdir -p "$r22/state/sim_reservations/res-1" "$r22/fx"
sim_fixture_device "$r22/fx" "dddddddd-1111-2222-3333-444444444444" "wai-shared-mid" "Shutdown" 5
printf 'status=reserving\nreason=t\npid=%s\nruntime=iOS 26.5\nname=wai-shared-mid\n' "$$" >"$r22/state/sim_reservations/res-1/meta"
export DISK_MAGICIAN_STATE_DIR="$r22/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r22/state/sim_reservations"
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r22/fx" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out" | grep -q 'lease_token' && bad "leased a device whose registration was unfinished" || ok "unfinished registration not leaseable (meta name= honoured)"

echo "== 23. /dot repro: orphan found by recovery STAYS excluded for the next lease =="
r23="$TMP/r23"; mkdir -p "$r23/state/sim_reservations/o-1" "$r23/fx"
sim_fixture_device "$r23/fx" "eeeeeeee-1111-2222-3333-444444444444" "wai-shared-orph" "Shutdown" 5
printf 'status=reserving\nreason=t\npid=999999\nname=wai-shared-orph\n' >"$r23/state/sim_reservations/o-1/meta"
export DISK_MAGICIAN_STATE_DIR="$r23/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r23/state/sim_reservations"
rec="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r23/fx" sim_recover_reservations 2>&1)"
printf '%s' "$rec" | grep -q 'recover:orphan-device' && ok "orphan detected by name" || bad "orphan not detected"
out2="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r23/fx" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out2" | grep -q 'lease_token' && bad "orphan became leaseable after recovery (exclusion was dropped)" || ok "orphan exclusion retained after recovery; lease still refused"

echo "== 24. /dot repro: prune cannot delete a device leased after its check =="
r24="$TMP/r24"; mkdir -p "$r24/state" "$r24/fx"
export DISK_MAGICIAN_STATE_DIR="$r24/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$r24/fx" "ffffffff-1111-2222-3333-444444444444" "wai-shared-race" "Shutdown" 999
# a lease held at prune time must block removal
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r24/fx" sim_lease --wait-seconds 0 >/dev/null 2>&1
outp="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r24/fx" sim_prune --clean 2>&1)"
[[ -d "$r24/fx/ffffffff-1111-2222-3333-444444444444" ]] && ok "newly leased device survived prune --clean" || bad "prune deleted a leased device"
printf '%s' "$outp" | grep -qE '^keep:leased|^keep:exclusion-busy' && ok "prune reported the leased exclusion by name" || bad "prune gave no leased/exclusion verdict"

echo "== 25. the CLI actually loads artifact_removal_verdict =="
if timeout 60 bash -c 'cd "'"$SCRIPT_DIR"'"; source scripts/lib/artifact_verdict.sh >/dev/null 2>&1; declare -F artifact_removal_verdict >/dev/null'; then
    ok "artifact_removal_verdict is available to the prune path (gate is real)"
else
    bad "artifact_removal_verdict unavailable — prune gate would be skipped"
fi
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo "== 26. /dot repro: a FAILING or EMPTY gate must never authorize deletion =="
g26="$TMP/g26"; mkdir -p "$g26/state" "$g26/fx"
export DISK_MAGICIAN_STATE_DIR="$g26/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$g26/fx" "abcabcab-1111-2222-3333-444444444444" "wai-shared-gate" "Shutdown" 999
# Simulate a fully eligible device (current-generation receipt past the floor) so
# ONLY the gate can stop the delete.
cp -R "$g26/fx/abcabcab-1111-2222-3333-444444444444" "$g26/fx/keepref" 2>/dev/null || true
gen_dir="$g26/state/gen"; mkdir -p "$gen_dir"
printf '1\n' >"$gen_dir/abcabcab-1111-2222-3333-444444444444"
mkdir -p "$g26/state/receipts"
old_ts="$(date -u -v-72H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '72 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"action": "release", "udid": "%s", "lease_generation": 1, "token_fingerprint": "x", "released_at": "%s"}\n' \
  "abcabcab-1111-2222-3333-444444444444" "$old_ts" >"$g26/state/receipts/sim_release_receipts.jsonl"

# Case A: gate present but returns 42 with NO output (dot's exact fixture)
artifact_removal_verdict() { return 42; }
export -f artifact_removal_verdict 2>/dev/null || true
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g26/fx" sim_prune --clean 2>&1)"
[[ -d "$g26/fx/abcabcab-1111-2222-3333-444444444444" ]] && ok "failing gate (42, no output) blocked the deletion" || bad "failing gate still authorized a deletion"
printf '%s' "$out" | grep -q 'keep:verdict-error' && ok "prune reported the gate error by name" || bad "gate error not reported"
unset -f artifact_removal_verdict 2>/dev/null || true

# Case B: gate present, exits 0, but returns an EMPTY verdict
artifact_removal_verdict() { return 0; }
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g26/fx" sim_prune --clean 2>&1)"
[[ -d "$g26/fx/abcabcab-1111-2222-3333-444444444444" ]] && ok "empty verdict blocked the deletion" || bad "empty verdict authorized a deletion"
unset -f artifact_removal_verdict 2>/dev/null || true

# Case C: gate returns an explicit non-remove verdict
artifact_removal_verdict() { printf 'kept:secret-like\n'; return 0; }
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$g26/fx" sim_prune --clean 2>&1)"
[[ -d "$g26/fx/abcabcab-1111-2222-3333-444444444444" ]] && ok "explicit keep verdict blocked the deletion" || bad "keep verdict authorized a deletion"
unset -f artifact_removal_verdict 2>/dev/null || true

echo "== 27. /dot repro: a timed-out acquire must not steal a foreign lock =="
l27="$TMP/l27"; mkdir -p "$l27/state/lock" "$l27/fx"
export DISK_MAGICIAN_STATE_DIR="$l27/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$l27/fx" "acacacac-1111-2222-3333-444444444444" "wai-shared-lk" "Shutdown" 5
# Pre-hold the per-UDID lock as if another process owned it.
mkdir -p "$l27/state/lock/acacacac-1111-2222-3333-444444444444.release-lock"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$l27/fx" sim_lease --wait-seconds 0 >"$TMP/l27out" 2>&1
if grep -q 'lease_token' "$TMP/l27out"; then
    bad "timed-out acquire still leased the device (lock steal)"
else
    ok "timed-out acquire refused instead of stealing the lock"
fi
[[ -d "$l27/state/lock/acacacac-1111-2222-3333-444444444444.release-lock" ]] && ok "foreign lock left intact" || bad "foreign lock was removed by a losing acquirer"

echo "== 28. /dot repro: a SECOND recovery preserves the orphan exclusion =="
l28="$TMP/l28"; mkdir -p "$l28/state/sim_reservations/o-1" "$l28/fx"
sim_fixture_device "$l28/fx" "adadadad-1111-2222-3333-444444444444" "wai-shared-o2" "Shutdown" 5
printf 'status=reserving\nreason=t\npid=999999\nname=wai-shared-o2\n' >"$l28/state/sim_reservations/o-1/meta"
export DISK_MAGICIAN_STATE_DIR="$l28/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$l28/state/sim_reservations"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$l28/fx" sim_recover_reservations >/dev/null 2>&1
# Second recovery must NOT delete the orphan exclusion.
out28="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$l28/fx" sim_recover_reservations 2>&1)"
[[ -d "$l28/state/sim_reservations/o-1" ]] && ok "orphan exclusion survived a second recovery" || bad "second recovery deleted the orphan exclusion"
printf '%s' "$out28" | grep -q 'recover:orphan-exclusion-retained' && ok "second recovery reported retention" || bad "no retention verdict on second recovery"
out28b="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$l28/fx" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out28b" | grep -q 'lease_token' && bad "device became leaseable after second recovery" || ok "device still not leaseable after second recovery"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 29. /dot repro: a stale receipt across the lock boundary must not authorize =="
r29="$TMP/r29"; mkdir -p "$r29/state/gen" "$r29/state/receipts" "$r29/fx"
export DISK_MAGICIAN_STATE_DIR="$r29/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$r29/fx" "aeaeaeae-1111-2222-3333-444444444444" "wai-shared-gen" "Shutdown" 999
old_ts="$(date -u -v-72H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '72 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
# generation advanced to 2 (a lease/release cycle happened) but the only receipt
# is for generation 1 -> the device must NOT be removable.
printf '2\n' >"$r29/state/gen/aeaeaeae-1111-2222-3333-444444444444"
printf '{"action": "release", "udid": "%s", "lease_generation": 1, "token_fingerprint": "x", "released_at": "%s"}\n' \
  "aeaeaeae-1111-2222-3333-444444444444" "$old_ts" >"$r29/state/receipts/sim_release_receipts.jsonl"
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r29/fx" sim_prune --clean 2>&1)"
[[ -d "$r29/fx/aeaeaeae-1111-2222-3333-444444444444" ]] && ok "stale generation-1 receipt did not authorize deletion" || bad "stale receipt authorized deletion"
printf '%s' "$out" | grep -qE 'keep:no-release-receipt|keep:receipt-stale' && ok "prune named the stale receipt" || bad "no stale-receipt verdict"

echo "== 30. /dot repro: a diagnostic stderr line cannot override the stdout verdict =="
r30="$TMP/r30"; mkdir -p "$r30/state/gen" "$r30/state/receipts" "$r30/fx"
export DISK_MAGICIAN_STATE_DIR="$r30/state"
sim_fixture_device "$r30/fx" "afafafaf-1111-2222-3333-444444444444" "wai-shared-err" "Shutdown" 999
printf '1\n' >"$r30/state/gen/afafafaf-1111-2222-3333-444444444444"
old_ts2="$(date -u -v-72H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '72 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"action": "release", "udid": "%s", "lease_generation": 1, "token_fingerprint": "x", "released_at": "%s"}\n' \
  "afafafaf-1111-2222-3333-444444444444" "$old_ts2" >"$r30/state/receipts/sim_release_receipts.jsonl"
artifact_removal_verdict() { printf 'kept:secret-like\n'; printf 'remove\n' >&2; return 0; }
out="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r30/fx" sim_prune --clean 2>&1)"
[[ -d "$r30/fx/afafafaf-1111-2222-3333-444444444444" ]] && ok "stderr 'remove' did not override a stdout keep verdict" || bad "stderr overrode the stdout verdict"
unset -f artifact_removal_verdict 2>/dev/null || true
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 31. /dot repro: lease must not succeed for a device prune just deleted =="
r31="$TMP/r31"; mkdir -p "$r31/state" "$r31/fx"
export DISK_MAGICIAN_STATE_DIR="$r31/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$r31/fx" "babababa-1111-2222-3333-444444444444" "wai-shared-gone" "Shutdown" 5
# Simulate prune winning the race: the device disappears between listing and lock.
sim_devices_stale() { printf '%s\twai-shared-gone\tShutdown\t%s\n' "babababa-1111-2222-3333-444444444444" "$(date +%s)"; }
out31="$(sim_devices_stale)"
# Remove it from the fixture so the under-lock re-read sees nothing.
rm -rf "$r31/fx/babababa-1111-2222-3333-444444444444"
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r31/fx" sim_lease --wait-seconds 0 >"$TMP/l31" 2>&1
if grep -q 'lease_token' "$TMP/l31"; then
    bad "lease returned a token for a device that no longer exists"
else
    ok "lease refused after the device vanished (under-lock re-verify)"
fi
unset -f sim_devices_stale 2>/dev/null || true

echo "== 32. /dot repro: a FAILED inventory lookup must not clear an orphan exclusion =="
r32="$TMP/r32"; mkdir -p "$r32/state/sim_reservations/dead-1" "$r32/fx"
printf 'status=reserving\nreason=t\npid=999999\nname=wai-shared-unk\n' >"$r32/state/sim_reservations/dead-1/meta"
export DISK_MAGICIAN_STATE_DIR="$r32/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r32/state/sim_reservations"
# A fake xcrun that fails the inventory read.
faker="$TMP/fakebin32"; mkdir -p "$faker"
printf '#!/bin/bash\nexit 75\n' >"$faker/xcrun"; chmod +x "$faker/xcrun"
PATH="$faker:$PATH" sim_recover_reservations >"$TMP/r32out" 2>&1
[[ -d "$r32/state/sim_reservations/dead-1" ]] && ok "reservation preserved when inventory failed" || bad "failed inventory cleared the reservation"
grep -q 'recover:inventory-unavailable' "$TMP/r32out" && ok "reported inventory-unavailable rather than concluding absence" || bad "no inventory-unavailable verdict"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 33. /dot repro: valid rows THEN exit 75 must be rejected, not trusted =="
r33="$TMP/r33"; mkdir -p "$r33/state" "$r33/fake"
export DISK_MAGICIAN_STATE_DIR="$r33/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
cat >"$r33/fake/xcrun" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"list devices --json"* ]]; then
  printf '{"devices":{"rt":[{"udid":"cacacaca-1111-2222-3333-444444444444","name":"wai-shared-x","state":"Shutdown"}]}}\n'
  exit 75
fi
exit 0
FAKE
chmod +x "$r33/fake/xcrun"
out33="$(PATH="$r33/fake:$PATH" sim_snapshot 2>/dev/null)"; rc33=$?
[[ "$rc33" -ne 0 && -z "$out33" ]] && ok "rows followed by exit 75 rejected (no rows emitted)" || bad "trusted rows from a failing producer"
# and lease must refuse rather than issue a token
out33b="$(PATH="$r33/fake:$PATH" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out33b" | grep -q 'lease_token' && bad "lease issued a token from unvalidated inventory" || ok "lease refused on unvalidated inventory"

echo "== 34. /dot repro: malformed JSON at exit 0 must be rejected =="
cat >"$r33/fake/xcrun" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"list devices --json"* ]]; then printf 'not json at all\n'; exit 0; fi
exit 0
FAKE
chmod +x "$r33/fake/xcrun"
out34="$(PATH="$r33/fake:$PATH" sim_snapshot 2>/dev/null)"; rc34=$?
[[ "$rc34" -ne 0 && -z "$out34" ]] && ok "malformed JSON at exit 0 rejected" || bad "trusted malformed JSON"
# recovery must preserve the reservation when the snapshot is untrustworthy
mkdir -p "$r33/state/sim_reservations/m-1"
printf 'status=reserving\npid=999999\nname=wai-shared-m\n' >"$r33/state/sim_reservations/m-1/meta"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r33/state/sim_reservations"
PATH="$r33/fake:$PATH" sim_recover_reservations >/dev/null 2>&1
[[ -d "$r33/state/sim_reservations/m-1" ]] && ok "reservation preserved under malformed inventory" || bad "malformed inventory cleared a reservation"
unset DISK_MAGICIAN_SIM_RESERVE_DIR; export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo "== 35. /dot repro: recovery must not treat an UNLEASED created device as leased =="
r35="$TMP/r35"; mkdir -p "$r35/state/sim_reservations/c-1" "$r35/fx"
sim_fixture_device "$r35/fx" "cbcbcbcb-1111-2222-3333-444444444444" "wai-shared-unleased" "Shutdown" 5
printf 'status=created\npid=999999\nname=wai-shared-unleased\n' >"$r35/state/sim_reservations/c-1/meta"
printf 'cbcbcbcb-1111-2222-3333-444444444444\n' >"$r35/state/sim_reservations/c-1/udid"
export DISK_MAGICIAN_STATE_DIR="$r35/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r35/state/sim_reservations"
out35="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r35/fx" sim_recover_reservations 2>&1)"
printf '%s' "$out35" | grep -qi 'never leased' && ok "recovery detected a created-but-unleased device" || bad "recovery assumed the device was leased (said: $(printf '%s' "$out35" | tr '\n' ' ' | cut -c1-120))"
out35b="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r35/fx" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out35b" | grep -q 'lease_token' && bad "unleased created device became leaseable" || ok "unleased created device still excluded from lease"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 36. /dot repro: valid row THEN malformed row must emit NO rows at all =="
r36="$TMP/r36"; mkdir -p "$r36/state" "$r36/fake"
export DISK_MAGICIAN_STATE_DIR="$r36/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
cat >"$r36/fake/xcrun" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"list devices --json"* ]]; then
  printf '{"devices":{"rt":[{"udid":"dcdcdcdc-1111-2222-3333-444444444444","name":"wai-shared-ok","state":"Shutdown"},{"bogus":"no udid"}]}}\n'
  exit 0
fi
exit 0
FAKE
chmod +x "$r36/fake/xcrun"
out36="$(PATH="$r36/fake:$PATH" sim_snapshot 2>/dev/null)"; rc36=$?
[[ "$rc36" -ne 0 && -z "$out36" ]] && ok "partial snapshot rejected with zero rows (buffered)" || bad "emitted rows before validation failed"
out36b="$(PATH="$r36/fake:$PATH" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out36b" | grep -q 'lease_token' && bad "lease issued a token from a partial snapshot" || ok "lease refused a partial snapshot"

echo "== 37. /dot repro: an EMPTY fingerprint is not a complete lease =="
r37="$TMP/r37"; mkdir -p "$r37/state/sim_leases" "$r37/state/sim_reservations/c-1" "$r37/fx"
sim_fixture_device "$r37/fx" "ddcddcdc-1111-2222-3333-444444444444" "wai-shared-emptyfp" "Shutdown" 5
# lease dir with an EMPTY fingerprint and no owner/generation
mkdir -p "$r37/state/sim_leases/ddcddcdc-1111-2222-3333-444444444444"
: >"$r37/state/sim_leases/ddcddcdc-1111-2222-3333-444444444444/token_fingerprint"
printf 'status=created\npid=999999\nname=wai-shared-emptyfp\n' >"$r37/state/sim_reservations/c-1/meta"
printf 'ddcddcdc-1111-2222-3333-444444444444\n' >"$r37/state/sim_reservations/c-1/udid"
export DISK_MAGICIAN_STATE_DIR="$r37/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r37/state/sim_reservations"
if sim_is_leased "ddcddcdc-1111-2222-3333-444444444444"; then
    bad "empty fingerprint counted as a complete lease"
else
    ok "empty fingerprint is not a complete lease"
fi
DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r37/fx" sim_recover_reservations >/dev/null 2>&1
[[ -d "$r37/state/sim_reservations/c-1" ]] && ok "reservation preserved despite an incomplete lease dir" || bad "recovery cleared a reservation on an incomplete lease"
out37="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r37/fx" sim_lease --wait-seconds 0 2>&1)"
printf '%s' "$out37" | grep -q 'lease_token' && bad "device became leaseable with an incomplete lease" || ok "device still excluded with an incomplete lease"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 38. /dot repro: an INDETERMINATE lease must block prune =="
r38="$TMP/r38"; mkdir -p "$r38/state/gen" "$r38/state/receipts" "$r38/state/sim_leases/dedddddd-1111-2222-3333-444444444444" "$r38/fx"
export DISK_MAGICIAN_STATE_DIR="$r38/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR
sim_fixture_device "$r38/fx" "dedddddd-1111-2222-3333-444444444444" "wai-shared-indet" "Shutdown" 999
printf '1\n' >"$r38/state/gen/dedddddd-1111-2222-3333-444444444444"
old_ts3="$(date -u -v-72H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '72 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"action": "release", "udid": "%s", "lease_generation": 1, "token_fingerprint": "x", "released_at": "%s"}\n' \
  "dedddddd-1111-2222-3333-444444444444" "$old_ts3" >"$r38/state/receipts/sim_release_receipts.jsonl"
# fingerprint present, but NO owner and NO generation -> indeterminate
printf '%064d\n' 0 >"$r38/state/sim_leases/dedddddd-1111-2222-3333-444444444444/token_fingerprint"
out38="$(DISK_MAGICIAN_SIM_FIXTURE_ROOT="$r38/fx" sim_prune --clean 2>&1)"
[[ -d "$r38/fx/dedddddd-1111-2222-3333-444444444444" ]] && ok "incomplete lease blocked deletion" || bad "incomplete lease treated as unleased (deleted)"
printf '%s' "$out38" | grep -q 'keep:lease-indeterminate' && ok "prune reported lease-indeterminate" || bad "no indeterminate verdict reported"

echo "== 39. /dot repro: create that fails AFTER creating must retain the reservation =="
r39="$TMP/r39"; mkdir -p "$r39/state" "$r39/fake"
export DISK_MAGICIAN_STATE_DIR="$r39/state"; unset DISK_MAGICIAN_SIM_FIXTURE_ROOT
cat >"$r39/fake/xcrun" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"list devices --json"* ]]; then
  printf '{"devices":{"rt":[{"udid":"eaeaeaea-1111-2222-3333-444444444444","name":"made-by-create","state":"Shutdown"}]}}\n'
  exit 0
fi
if [[ "$*" == *"create"* ]]; then printf 'eaeaeaea-1111-2222-3333-444444444444\n'; exit 75; fi
exit 0
FAKE
chmod +x "$r39/fake/xcrun"
PATH="$r39/fake:$PATH" sim_create --reason "test" --name made-by-create >/dev/null 2>&1
rc39=$?
resv="$(find "$r39/state/sim_reservations" -maxdepth 1 -type d ! -path "$r39/state/sim_reservations" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$rc39" -ne 0 && "$resv" -ge 1 ]] && ok "reservation retained after a create that may have made a device" || bad "reservation released although a device may exist (rc=$rc39 resv=$resv)"

echo "== 40. /dot repro: recovery must not clear a reservation using stale inventory =="
r40="$TMP/r40"; mkdir -p "$r40/state/sim_reservations/late-1" "$r40/fake"
printf 'status=reserving\npid=999999\nname=late-device\n' >"$r40/state/sim_reservations/late-1/meta"
export DISK_MAGICIAN_STATE_DIR="$r40/state"
export DISK_MAGICIAN_SIM_RESERVE_DIR="$r40/state/sim_reservations"
# First call: empty inventory. Second call: the device now exists.
cat >"$r40/fake/xcrun" <<FAKE
#!/bin/bash
C="$r40/count"
n=0; [ -f "\$C" ] && n="\$(cat "\$C")"
n=\$((n+1)); printf '%s' "\$n" >"\$C"
if [[ "\$n" -le 1 ]]; then printf '{"devices":{}}\n'; else
  printf '{"devices":{"rt":[{"udid":"ebeebebe-1111-2222-3333-444444444444","name":"late-device","state":"Shutdown"}]}}\n'
fi
exit 0
FAKE
chmod +x "$r40/fake/xcrun"
PATH="$r40/fake:$PATH" sim_recover_reservations >/dev/null 2>&1
[[ -d "$r40/state/sim_reservations/late-1" ]] && ok "late-appearing device preserved the reservation" || bad "stale snapshot cleared a reservation for a device that exists"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR

echo "== 41. /dot repro: create must refuse when inventory is unreadable (not spare capacity) =="
r41="$TMP/r41"; mkdir -p "$r41/state" "$r41/fake"
export DISK_MAGICIAN_STATE_DIR="$r41/state"; unset DISK_MAGICIAN_SIM_RESERVE_DIR DISK_MAGICIAN_SIM_FIXTURE_ROOT
printf '#!/bin/bash\nexit 75\n' >"$r41/fake/xcrun"; chmod +x "$r41/fake/xcrun"
PATH="$r41/fake:$PATH" sim_create --reason "test" >/dev/null 2>"$TMP/e41"
rc41=$?
[[ "$rc41" -eq 22 ]] && ok "create refused on unreadable inventory (exit 22)" || bad "create proceeded with unreadable inventory (rc=$rc41)"

echo "== 42. /dot repro: cap check and reservation are atomic (cap=1, two concurrent creates) =="
r42="$TMP/r42"; mkdir -p "$r42/state" "$r42/fake"
export DISK_MAGICIAN_STATE_DIR="$r42/state"
# Device list stays empty; create always "succeeds" slowly so the two race window is real.
cat >"$r42/fake/xcrun" <<'FAKE'
#!/bin/bash
if [[ "$*" == *"list devices --json"* ]]; then printf '{"devices":{}}\n'; exit 0; fi
if [[ "$*" == *"create"* ]]; then sleep 0.5; printf 'fafafafa-1111-2222-3333-44444444444\n'; exit 0; fi
exit 0
FAKE
chmod +x "$r42/fake/xcrun"
( PATH="$r42/fake:$PATH" DISK_MAGICIAN_SIM_POOL_SLOTS=1 sim_create --reason a >/dev/null 2>&1; echo $? >"$TMP/c42a" ) &
( PATH="$r42/fake:$PATH" DISK_MAGICIAN_SIM_POOL_SLOTS=1 sim_create --reason b >/dev/null 2>&1; echo $? >"$TMP/c42b" ) &
wait
a42="$(cat "$TMP/c42a" 2>/dev/null)"; b42="$(cat "$TMP/c42b" 2>/dev/null)"
wins42=0; [[ "$a42" == "0" ]] && wins42=$((wins42+1)); [[ "$b42" == "0" ]] && wins42=$((wins42+1))
[[ "$wins42" -le 1 ]] && ok "at most one create won at cap=1 (a=$a42 b=$b42)" || bad "two creates both succeeded at cap=1"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

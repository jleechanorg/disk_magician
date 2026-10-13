#!/usr/bin/env bash
# test_c14_wrapper_scope.sh — wrapper C14 ledger scope (main_sweeper/pressure_sweep).
#
# Proves two layers:
#   (a) the shared scope helper: a unique per-run ledger, the wrapper job owns
#       it and folds it once into its terminal receipt, a nested Tier receipt
#       with a different job never double-folds, two runs are isolated, the
#       ephemeral ledger is released after the receipt persists, and
#       budget_status exposes the wrapper receipt separately; and
#   (b) the actual wrapper glue: real main_sweeper.sh / pressure_sweep.sh runs
#       under an isolated fixture HOME/state whose downstream adapters call the
#       real c14_probe.py account producer and the real job_receipt.py store.
#       Failure of terminal persistence must retain the raw scoped ledger.
#
# State isolation (hard): every receipt reader/writer child runs with the same
# explicit DISK_MAGICIAN_STATE_DIR under this test's own /tmp fixture. The live
# state root is never a target, and an ambient wrong value (or an ambient
# stale DISK_MAGICIAN_C14_LEDGER) can never capture a write or leak keeps.
# Incident disk_magician-cuea.10 (synthetic live receipts from an unexported
# fixture state) is the reason these guards abort before any writer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Explicit, validated /tmp allocation. Abort BEFORE installing any cleanup trap
# so a failed allocation never resolves to an empty string / cwd.
TMP="$(mktemp -d /tmp/disk-magician-wrapper-scope.XXXXXX)" || {
  echo "FATAL: could not allocate /tmp fixture root" >&2; exit 2;
}
if [[ -z "$TMP" || ! -d "$TMP" ]]; then
  echo "FATAL: empty or invalid fixture root '$TMP'" >&2; exit 2
fi
TMP_REAL="$(cd "$TMP" && pwd -P)"
case "$TMP_REAL" in
  /tmp/*|/private/tmp/*) ;;
  *) echo "FATAL: fixture root not under /tmp: '$TMP_REAL'" >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$(( PASS + 1 )); }
bad() { echo "FAIL $1"; FAIL=$(( FAIL + 1 )); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

# ---------------------------------------------------------------------------
# Fixture isolation guards (must hold before any writer subprocess runs).
# ---------------------------------------------------------------------------
STATE="$TMP/state"; mkdir -p "$STATE"
STATE_REAL="$(cd "$STATE" && pwd -P)"

# 1. The measured fixture root must live under /tmp (or its /private/tmp alias).
#    Abort, do not merely count a FAIL, before any writer can run.
case "$STATE_REAL" in
  /tmp/*|/private/tmp/*) ok "fixture state path is under /tmp" ;;
  *) echo "FATAL: fixture state not under /tmp: '$STATE_REAL'" >&2; exit 2 ;;
esac
echo "fixture_state=$STATE_REAL"

# 2. The test's state must never be the caller's ambient state, and the
#    explicit export must override whatever the caller had.
AMBIENT_STATE="$TMP/ambient-wrong-state"; mkdir -p "$AMBIENT_STATE"
export DISK_MAGICIAN_STATE_DIR="$AMBIENT_STATE"   # simulate a wrong ambient value
DISK_MAGICIAN_STATE_DIR="$AMBIENT_STATE" python3 "$ROOT/scripts/job_receipt.py" \
  read --job ambient_guard >/dev/null 2>&1 || true
export DISK_MAGICIAN_STATE_DIR="$STATE"           # this test's own explicit state
python3 "$ROOT/scripts/job_receipt.py" begin --job ambient_guard >/dev/null
[[ -f "$STATE/receipts/ambient_guard.json" ]] \
  && ok "ambient wrong state overridden by fixture state" \
  || bad "ambient wrong state overridden by fixture state"
[[ ! -e "$AMBIENT_STATE/receipts/ambient_guard.json" ]] \
  && ok "ambient wrong state captured no receipt" \
  || bad "ambient wrong state captured no receipt"

# 3. Every receipt child must resolve to the fixture, never the implicit default.
RESOLVED_STATE="$(PYTHONPATH="$ROOT/scripts" python3 -c \
  'from job_receipt import resolve_state_dir; print(resolve_state_dir())')"
eq "job_receipt resolves the fixture state (no implicit default)" "$RESOLVED_STATE" "$STATE_REAL"

# 4. Isolate package config resolution from the live ~/.config so budget_status
#    cannot read (or be steered by) a real config during the fixture test.
export DISK_MAGICIAN_CONFIG="$TMP/config.json"
printf '{"budgets":{"classes":{}}}\n' > "$DISK_MAGICIAN_CONFIG"

source "$ROOT/scripts/lib/actuator_receipt.sh"
RECEIPT="$ROOT/scripts/job_receipt.py"
PROBE="$ROOT/scripts/c14_probe.py"

# ---------------------------------------------------------------------------
# (a) Helper-layer checks: scope allocation + fold/no-double-fold/release.
# ---------------------------------------------------------------------------
run_once() {  # $1 = kept file bytes; prints the scoped ledger path
  local bytes="$1" inv="$TMP/inv.json" ledger rid
  c14_scope_open "$STATE" main_sweeper
  ledger="$C14_SCOPE_LEDGER"
  printf '[{"type":"file","size":%s}]' "$bytes" > "$inv"
  python3 "$PROBE" account "$inv" "$ledger" "unproven-content" >/dev/null
  rid="$(python3 "$RECEIPT" begin --job main_sweeper --trigger scheduled)"
  python3 "$RECEIPT" finish --job main_sweeper --run-id "$rid" --outcome success \
    --candidates '{"removed_count":0,"deferred_count":0,"interrupted_count":0}' \
    --postcondition '{"df_delta_bytes":0,"freed_bytes":0}' >/dev/null
  # A nested Tier receipt inherits the ledger path but not the owner.
  rid="$(python3 "$RECEIPT" begin --job cleanup_tmp --trigger govern)"
  python3 "$RECEIPT" finish --job cleanup_tmp --run-id "$rid" --outcome success \
    --candidates '{"removed_count":0,"deferred_count":0,"interrupted_count":0}' \
    --postcondition '{"df_delta_bytes":0,"freed_bytes":0}' >/dev/null
  printf '%s\n' "$ledger"
  c14_scope_release
}

# Ambient stale-ledger leakage must be overridden by c14_scope_open.
STALE_LEDGER="$TMP/stale-ledger.jsonl"
printf '{"reason":"stale-leak","bytes":999999}\n' > "$STALE_LEDGER"
export DISK_MAGICIAN_C14_LEDGER="$STALE_LEDGER"
export DISK_MAGICIAN_C14_LEDGER_OWNER="nonowner"
L0="$(run_once 321)"
[[ "$L0" != "$STALE_LEDGER" ]] && ok "c14_scope_open overrides ambient stale ledger" \
  || bad "c14_scope_open overrides ambient stale ledger"
unset DISK_MAGICIAN_C14_LEDGER DISK_MAGICIAN_C14_LEDGER_OWNER

L1="$(run_once 500)"
L2="$(run_once 900)"
[[ "$L1" != "$L2" ]] && ok "two runs get distinct ledgers" || bad "two runs get distinct ledgers"
[[ ! -e "$L1" && ! -e "$L2" ]] && ok "ephemeral ledgers released after persist" || bad "ephemeral ledgers released after persist"

# Every writer must have landed in the fixture receipt dir.
[[ -f "$STATE/receipts/main_sweeper.json" ]] \
  && ok "main_sweeper receipt written in fixture state" \
  || bad "main_sweeper receipt written in fixture state"
[[ -f "$STATE/receipts/cleanup_tmp.json" ]] \
  && ok "cleanup_tmp receipt written in fixture state" \
  || bad "cleanup_tmp receipt written in fixture state"

WRAP="$(python3 "$RECEIPT" read --job main_sweeper --last)"
NEST="$(python3 "$RECEIPT" read --job cleanup_tmp --last)"
if python3 - "$WRAP" "$NEST" <<'PY'
import json,sys
w=json.loads(sys.argv[1]); n=json.loads(sys.argv[2])
assert w["postcondition"]["c14_kept_bytes"] == {"unproven-content": 900}, w["postcondition"]
assert w["postcondition"]["c14_ledger_status"] == "ok", w["postcondition"]
assert "c14_kept_bytes" not in n["postcondition"], n["postcondition"]
PY
then ok "wrapper folds own ledger once; nested Tier does not double-fold"
else bad "wrapper folds own ledger once; nested Tier does not double-fold"
fi

# Ambient stale ledger content must never appear in the folded receipt.
grep -q 'stale-leak' "$STATE/receipts/main_sweeper.json" \
  && bad "no stale ambient ledger content folded" \
  || ok "no stale ambient ledger content folded"

# ---------------------------------------------------------------------------
# (b) Actual wrapper glue: real main_sweeper.sh / pressure_sweep.sh with
#     fixture downstream adapters that use the real producer + real store.
# ---------------------------------------------------------------------------
FIX="$TMP/fixture-repo"; mkdir -p "$FIX/scripts"

make_adapter() {  # $1 = script filename
  cat > "$FIX/scripts/$1" <<'ADAPTER'
#!/usr/bin/env bash
# Fixture downstream adapter: never touches operational data. It only exercises
# the real C14 account producer and (optionally) the real receipt store.
set -euo pipefail
real="${DISK_MAGICIAN_TEST_REAL_ROOT:?DISK_MAGICIAN_TEST_REAL_ROOT unset}"
state="${DISK_MAGICIAN_STATE_DIR:?DISK_MAGICIAN_STATE_DIR unset}"
jname="$(basename "$0" .sh)"
reason="${DISK_MAGICIAN_TEST_KEEP_REASON:-keep-${jname}}"
bytes="${DISK_MAGICIAN_TEST_KEEP_BYTES:-0}"
[[ -n "${DISK_MAGICIAN_C14_LEDGER:-}" ]] || { echo "adapter: no scoped ledger" >&2; exit 3; }
inv="$(mktemp /tmp/disk-magician-adapter-inv.XXXXXX)"
printf '[{"type":"file","size":%s}]' "$bytes" > "$inv"
python3 "$real/scripts/c14_probe.py" account "$inv" "$DISK_MAGICIAN_C14_LEDGER" "$reason" >/dev/null
rm -f "$inv"
if [[ "${DISK_MAGICIAN_TEST_MALFORMED:-0}" == 1 ]]; then
  printf 'not-json\n' >> "$DISK_MAGICIAN_C14_LEDGER"
fi
if [[ -n "${DISK_MAGICIAN_TEST_OBSERVED:-}" ]]; then
  printf '%s\n%s\n' "${DISK_MAGICIAN_C14_LEDGER:-}" "${DISK_MAGICIAN_C14_LEDGER_OWNER:-}" \
    > "$DISK_MAGICIAN_TEST_OBSERVED"
fi
if [[ "${DISK_MAGICIAN_TEST_NESTED_RECEIPT:-0}" == 1 ]]; then
  rid="$(python3 "$real/scripts/job_receipt.py" begin --job "$jname" --trigger govern)"
  python3 "$real/scripts/job_receipt.py" finish --job "$jname" --run-id "$rid" --outcome success \
    --candidates '{"removed_count":0,"deferred_count":0,"interrupted_count":0}' \
    --postcondition '{"df_delta_bytes":0,"freed_bytes":0}' >/dev/null
fi
if [[ "${DISK_MAGICIAN_TEST_BREAK_STORE:-0}" == 1 ]]; then
  chmod 0555 "$state/receipts"
fi
exit 0
ADAPTER
  chmod +x "$FIX/scripts/$1"
}
for a in cleanup_tmp.sh cleanup_colima.sh cleanup_code_sign_clones.sh; do make_adapter "$a"; done
# pressure_sweep.sh resolves REPO_ROOT from its own SCRIPT_DIR (it does not honor
# DISK_MAGICIAN_REPO_ROOT), so run a self-contained mini-repo copy whose tier
# scripts are fixtures. This guarantees no real cleanup script is ever invoked.
cp -p "$ROOT/scripts/pressure_sweep.sh" "$FIX/scripts/pressure_sweep.sh"
cp -p "$ROOT/scripts/job_receipt.py" "$FIX/scripts/job_receipt.py"
cp -p "$ROOT/scripts/c14_probe.py" "$FIX/scripts/c14_probe.py"
mkdir -p "$FIX/scripts/lib"
cp -p "$ROOT/scripts/lib/actuator_receipt.sh" "$FIX/scripts/lib/actuator_receipt.sh"

MAIN_HOME="$TMP/main-home"; PRES_HOME="$TMP/pres-home"; mkdir -p "$MAIN_HOME" "$PRES_HOME"

run_main() {  # $1 = state, $2 = observed, rest = extra args
  local state="$1" observed="$2"; shift 2
  HOME="$MAIN_HOME" DISK_MAGICIAN_STATE_DIR="$state" DISK_MAGICIAN_REPO_ROOT="$FIX" \
    DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=100 \
    DISK_MAGICIAN_TEST_REAL_ROOT="$ROOT" DISK_MAGICIAN_TEST_OBSERVED="$observed" \
    DISK_MAGICIAN_MAIN_SWEEPER_LOG="$state/main.log" \
    bash "$ROOT/scripts/main_sweeper.sh" --skip-snapshot --skip-health "$@"
}
run_pressure() {  # $1 = state, $2 = observed
  local state="$1" observed="$2"
  HOME="$PRES_HOME" DISK_MAGICIAN_STATE_DIR="$state" \
    DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=5 \
    DISK_MAGICIAN_TEST_REAL_ROOT="$ROOT" DISK_MAGICIAN_TEST_OBSERVED="$observed" \
    DISK_MAGICIAN_PRESSURE_LOG="$state/pressure.log" \
    bash "$FIX/scripts/pressure_sweep.sh"
}

# --- Real main_sweeper.sh: producer -> wrapper -> real receipt -> status ----
M_STATE="$TMP/main-state"; mkdir -p "$M_STATE"
M_OBS="$TMP/main-observed"; M_LOG="$TMP/main-run.log"
RC=0
DISK_MAGICIAN_TEST_KEEP_BYTES=500 DISK_MAGICIAN_TEST_NESTED_RECEIPT=1 \
  run_main "$M_STATE" "$M_OBS" >"$M_LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && ok "actual main_sweeper.sh exits 0" \
  || { bad "actual main_sweeper.sh exits 0 (rc=$RC)"; sed -n '1,40p' "$M_LOG"; }
M_LEDGER="$(sed -n '1p' "$M_OBS")"; M_OWNER="$(sed -n '2p' "$M_OBS")"
eq "actual main_sweeper adapter owns scope" "$M_OWNER" "main_sweeper"
[[ -n "$M_LEDGER" && ! -e "$M_LEDGER" ]] \
  && ok "actual main_sweeper releases scoped ledger after persist" \
  || bad "actual main_sweeper releases scoped ledger after persist (ledger='$M_LEDGER')"

if python3 - "$M_STATE" "$ROOT" <<'PY'
import json,sys
state,root=sys.argv[1],sys.argv[2]
sys.path.insert(0,root+"/scripts")
import job_receipt
w=job_receipt.get_last_receipt("main_sweeper", state)
n=job_receipt.get_last_receipt("cleanup_tmp", state)
assert w and w["outcome"]=="success", w
assert w["postcondition"]["c14_kept_bytes"]=={"keep-cleanup_tmp":500,
        "keep-cleanup_colima":500,"keep-cleanup_code_sign_clones":500}, w["postcondition"]
assert w["postcondition"]["c14_ledger_status"]=="ok", w["postcondition"]
assert not (n and "c14_kept_bytes" in n["postcondition"]), n
PY
then ok "actual main_sweeper folds once via real store; nested Tier does not"
else bad "actual main_sweeper folds once via real store; nested Tier does not"
fi

M_STATUS="$(HOME="$MAIN_HOME" DISK_MAGICIAN_STATE_DIR="$M_STATE" \
  DISK_MAGICIAN_CONFIG="$DISK_MAGICIAN_CONFIG" \
  python3 "$ROOT/scripts/budget_status.py" status 2>&1 || true)"
grep -Eq 'wrapper job=main_sweeper scope=wrapper .*keep-cleanup_tmp:500' <<<"$M_STATUS" \
  && ok "actual main_sweeper wrapper row exposed by budget_status" \
  || bad "actual main_sweeper wrapper row exposed by budget_status: $M_STATUS"
grep -Eq '(^| )c14 class=main_sweeper ' <<<"$M_STATUS" \
  && bad "actual main_sweeper not mislabeled as governed class" \
  || ok "actual main_sweeper not mislabeled as governed class"

# --- Real pressure_sweep.sh: 3 steps -> wrapper -> real receipt -> status ---
P_STATE="$TMP/pres-state"; mkdir -p "$P_STATE"
P_OBS="$TMP/pres-observed"; P_LOG="$TMP/pres-run.log"
RC=0
DISK_MAGICIAN_TEST_KEEP_BYTES=111 DISK_MAGICIAN_TEST_NESTED_RECEIPT=1 \
  run_pressure "$P_STATE" "$P_OBS" >"$P_LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && ok "actual pressure_sweep.sh exits 0" \
  || { bad "actual pressure_sweep.sh exits 0 (rc=$RC)"; sed -n '1,50p' "$P_LOG"; }
P_OWNER="$(sed -n '2p' "$P_OBS")"
eq "actual pressure_sweep adapter owns scope" "$P_OWNER" "pressure_sweep"

if python3 - "$P_STATE" "$ROOT" <<'PY'
import json,sys
state,root=sys.argv[1],sys.argv[2]
sys.path.insert(0,root+"/scripts")
import job_receipt
w=job_receipt.get_last_receipt("pressure_sweep", state)
assert w and w["outcome"]=="success", w
assert w["postcondition"]["c14_kept_bytes"]=={"keep-cleanup_tmp":111,
        "keep-cleanup_colima":111,"keep-cleanup_code_sign_clones":111}, w["postcondition"]
assert w["postcondition"]["c14_ledger_status"]=="ok", w["postcondition"]
for job in ("cleanup_tmp","cleanup_colima","cleanup_code_sign_clones"):
    n=job_receipt.get_last_receipt(job, state)
    assert not (n and "c14_kept_bytes" in n["postcondition"]), (job, n)
PY
then ok "actual pressure_sweep aggregates 3 steps once; nested do not double-fold"
else bad "actual pressure_sweep aggregates 3 steps once; nested do not double-fold"
fi

P_STATUS="$(HOME="$PRES_HOME" DISK_MAGICIAN_STATE_DIR="$P_STATE" \
  DISK_MAGICIAN_CONFIG="$DISK_MAGICIAN_CONFIG" \
  python3 "$ROOT/scripts/budget_status.py" status 2>&1 || true)"
grep -Eq 'wrapper job=pressure_sweep scope=wrapper .*c14_kept_bytes=partial\(|.*keep-cleanup_colima:111' <<<"$P_STATUS" \
  && ok "actual pressure_sweep wrapper row exposed by budget_status" \
  || bad "actual pressure_sweep wrapper row exposed by budget_status: $P_STATUS"

# --- Incomplete ledger path through the actual wrapper -----------------------
I_STATE="$TMP/inc-state"; mkdir -p "$I_STATE"
I_OBS="$TMP/inc-observed"; I_LOG="$TMP/inc-run.log"
RC=0
DISK_MAGICIAN_TEST_KEEP_BYTES=222 DISK_MAGICIAN_TEST_MALFORMED=1 DISK_MAGICIAN_TEST_NESTED_RECEIPT=1 \
  run_main "$I_STATE" "$I_OBS" >"$I_LOG" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && ok "actual main_sweeper incomplete-ledger run exits 0" \
  || { bad "actual main_sweeper incomplete-ledger run exits 0 (rc=$RC)"; sed -n '1,40p' "$I_LOG"; }
if python3 - "$I_STATE" "$ROOT" <<'PY'
import json,sys
state,root=sys.argv[1],sys.argv[2]
sys.path.insert(0,root+"/scripts")
import job_receipt
w=job_receipt.get_last_receipt("main_sweeper", state)
assert w and w["postcondition"]["c14_ledger_status"]=="incomplete", w
assert w["postcondition"]["c14_kept_bytes"]=={"keep-cleanup_tmp":222,
        "keep-cleanup_colima":222,"keep-cleanup_code_sign_clones":222}, w["postcondition"]
PY
then ok "actual main_sweeper surfaces incomplete ledger with valid partial keeps"
else bad "actual main_sweeper surfaces incomplete ledger with valid partial keeps"
fi
I_STATUS="$(HOME="$MAIN_HOME" DISK_MAGICIAN_STATE_DIR="$I_STATE" \
  DISK_MAGICIAN_CONFIG="$DISK_MAGICIAN_CONFIG" \
  python3 "$ROOT/scripts/budget_status.py" status 2>&1 || true)"
grep -Eq 'ledger_status=incomplete c14_kept_bytes=partial\(.*keep-cleanup_tmp:222' <<<"$I_STATUS" \
  && ok "budget_status renders incomplete partial with explicit partial() marker" \
  || bad "budget_status renders incomplete partial with explicit partial() marker: $I_STATUS"

# --- Failure terminal persistence retains the raw scoped ledger --------------
F_STATE="$TMP/fail-state"; mkdir -p "$F_STATE"
F_OBS="$TMP/fail-observed"; F_LOG="$TMP/fail-run.log"
RC=0
DISK_MAGICIAN_TEST_KEEP_BYTES=444 DISK_MAGICIAN_TEST_BREAK_STORE=1 \
  run_main "$F_STATE" "$F_OBS" >"$F_LOG" 2>&1 || RC=$?
# The fixture adapter accounts a real keep, then makes the receipt store
# unwritable so the wrapper's terminal finish fails. The raw ledger must stay.
[[ "$RC" -ne 0 ]] && ok "actual main_sweeper surfaces failed terminal persistence (rc=$RC)" \
  || bad "actual main_sweeper surfaces failed terminal persistence (rc=$RC)"
grep -q 'failed to persist main_sweeper terminal receipt' "$F_LOG" \
  && ok "actual main_sweeper logs preserved scoped ledger on failure" \
  || { bad "actual main_sweeper logs preserved scoped ledger on failure"; sed -n '1,40p' "$F_LOG"; }
F_LEDGER="$(sed -n '1p' "$F_OBS" 2>/dev/null || true)"
[[ -n "$F_LEDGER" && -s "$F_LEDGER" ]] \
  && ok "failed terminal retains the raw scoped ledger with keeps" \
  || bad "failed terminal retains the raw scoped ledger with keeps (ledger='$F_LEDGER')"
chmod 0755 "$F_STATE/receipts" 2>/dev/null || true

# Direct helper-level failure-shape check: account, do not release, then release.
H_STATE="$TMP/helper-fail-state"; mkdir -p "$H_STATE"
c14_scope_open "$H_STATE" main_sweeper
H_LEDGER="$C14_SCOPE_LEDGER"
printf '[{"type":"file","size":7}]' > "$TMP/hinv.json"
python3 "$PROBE" account "$TMP/hinv.json" "$H_LEDGER" "unproven-content" >/dev/null
[[ -s "$H_LEDGER" ]] && ok "failed terminal keeps raw scoped ledger before release" \
  || bad "failed terminal keeps raw scoped ledger before release"
c14_scope_release
[[ ! -e "$H_LEDGER" ]] && ok "explicit release removes retained ledger" \
  || bad "explicit release removes retained ledger"

# --- Source wiring checks (supplement, not substitute for the runs above) ---
grep -q 'c14_scope_open "\$STATE_DIR" main_sweeper' "$ROOT/scripts/main_sweeper.sh" \
  && ok "main_sweeper opens a scoped ledger" || bad "main_sweeper opens a scoped ledger"
grep -q 'c14_scope_release' "$ROOT/scripts/main_sweeper.sh" \
  && ok "main_sweeper releases the scoped ledger" || bad "main_sweeper releases the scoped ledger"
grep -q 'c14_scope_open "\$STATE_DIR" pressure_sweep' "$ROOT/scripts/pressure_sweep.sh" \
  && ok "pressure_sweep opens a scoped ledger" || bad "pressure_sweep opens a scoped ledger"
grep -q 'c14_scope_release' "$ROOT/scripts/pressure_sweep.sh" \
  && ok "pressure_sweep releases the scoped ledger" || bad "pressure_sweep releases the scoped ledger"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

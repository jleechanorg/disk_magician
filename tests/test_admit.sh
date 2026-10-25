#!/usr/bin/env bash
# test_admit.sh — `diskm admit` (plan Task 3, spec §7.1 C2).
#
# A fake `df` (DISK_MAGICIAN_DF_BIN) reports a chosen free size; all state lives
# in a temp DISK_MAGICIAN_STATE_DIR. Nothing touches the live machine's state.
# Without D2 (admission_enforcement) the rc is always 0 and the table decision is
# asserted from admission/events.jsonl; DISK_MAGICIAN_POLICY_FILE is a temp file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

T="$(mktemp -d)"
export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export DISK_MAGICIAN_STATE_DIR="$T/state"
export DISK_MAGICIAN_DF_BIN="$T/bin/df"
export DISK_MAGICIAN_POLICY_FILE="$T/policy.json"  # absent: D2 not recorded
EVENTS="$T/state/admission/events.jsonl"

fake_df() {  # fake_df <free_gib> | fake_df fail
  if [[ "$1" == fail ]]; then printf '#!/bin/sh\nexit 1\n' > "$T/bin/df"
  else
    local kb=$(( $1 * 1024 * 1024 ))
    printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/disk3s5 999999999 1 %s 1%% /"\n' "$kb" > "$T/bin/df"
  fi
  chmod +x "$T/bin/df"
}
config() {  # config <stage>
  python3 - "$REPO_ROOT/config.json.template" "$T/config.json" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["budgets"]["enforcement"] = sys.argv[3]
json.dump(c, open(sys.argv[2], "w"))
PY
  export DISK_MAGICIAN_CONFIG="$T/config.json"
}
last() { tail -1 "$EVENTS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))"; }
budget_json() {  # budget_json <age_s> <zone> <free_gib>
  python3 - "$T/state/budget.json" "$@" <<'PY'
import json, sys, time
p, age, zone, free = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
at = time.time() - age
json.dump({"zone": zone, "zone_at": at, "free_bytes": free << 30, "classes": {
  "worktrees": {"used_gb": 99, "budget_gb": 35, "measured_at": time.time() - 7200}}}, open(p, "w"))
PY
}

echo "── 1. admit logs one event and prints admit_id; never invokes du ──"
fake_df 150; config observe
printf '#!/bin/sh\necho du-called >&2; exit 99\n' > "$T/bin/du"; chmod +x "$T/bin/du"
export DISK_MAGICIAN_DU_BIN="$T/bin/du"
start=$(python3 -c 'import time; print(time.monotonic())')
out=$("$DISKM" admit --class worktrees --est-gb 1 --dest "$T/x" --producer worktree-new 2>"$T/err"); rc=$?
ms=$(python3 -c "import time; print(int((time.monotonic() - $start) * 1000))")
assert_eq "$rc" 0 "admit rc"
[[ "$out" == admit_id=* ]] && ok "prints admit_id" || bad "prints admit_id: $out"
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" 1 "one event line"
assert_eq "$(last decision)" 0 "GREEN decision"
assert_eq "$(last est_bytes)" $((1 << 30)) "est_bytes"
assert_eq "$(last df_free_bytes)" $((150 << 30)) "df_free_bytes"
assert_eq "$(last producer)" worktree-new "producer recorded"
[[ "$out" == "admit_id=$(last admit_id)" ]] && ok "logged admit_id matches" || bad "admit_id mismatch"
[[ ! -s "$T/err" ]] && ok "du never invoked, no stderr" || bad "stderr: $(cat "$T/err")"
(( ms < 1000 )) && ok "admit took ${ms} ms" || bad "admit slow: ${ms} ms"

echo "── 2. unknown class and missing estimate are usage errors, nothing logged ──"
"$DISKM" admit --class nope --est-gb 1 >/dev/null 2>&1; assert_eq "$?" 2 "unknown class rc"
"$DISKM" admit --class worktrees >/dev/null 2>&1; assert_eq "$?" 2 "missing --est-gb rc"
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" 1 "still one event line"

echo "── 2b. a winning config without a budgets block falls back to the packaged template ──"
echo '{"state_repo_path": "/nonexistent"}' > "$T/user_config.json"
DISK_MAGICIAN_CONFIG="$T/user_config.json" "$DISKM" admit --class worktrees --est-gb 1 >/dev/null 2>"$T/err"
assert_eq "$?" 0 "admit rc with budget-less user config"
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" 2 "event logged with template budgets"
config observe

echo "── 2c. non-finite or negative --est-gb is a usage error, nothing logged ──"
for v in nan inf -inf -1 -0.5; do
  "$DISKM" admit --class worktrees --est-gb="$v" >/dev/null 2>&1; assert_eq "$?" 2 "--est-gb $v rc"
done
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" 2 "no event for rejected estimates"

echo "── 2d. corrupt budget.json or a partial budgets block → blind 10, rc 0, no traceback ──"
for body in '{not json' '[]' '{"zone_at": "x"}' '{"classes": {"worktrees": 5}}'; do
  printf '%s' "$body" > "$T/state/budget.json"
  "$DISKM" admit --class worktrees --est-gb 1 >/dev/null 2>"$T/err"; assert_eq "$?" 0 "rc with budget.json $body"
  assert_eq "$(last decision)" 10 "blind decision with budget.json $body"
  [[ "$(cat "$T/err")" == *admission_degraded:blind* && "$(cat "$T/err")" != *Traceback* ]] &&
    ok "admission_degraded:blind, no traceback" || bad "stderr: $(cat "$T/err")"
done
rm -f "$T/state/budget.json"
for partial in '{"enforcement": "observe"}' '{"classes": {"worktrees": {}}}'; do
  echo "{\"budgets\": $partial}" > "$T/partial.json"
  DISK_MAGICIAN_CONFIG="$T/partial.json" "$DISKM" admit --class worktrees --est-gb 1 >/dev/null 2>"$T/err"
  assert_eq "$?" 0 "rc with partial budgets $partial"
  assert_eq "$(last decision)" 10 "blind decision with partial budgets $partial"
  [[ "$(cat "$T/err")" == *admission_degraded:blind* && "$(cat "$T/err")" != *Traceback* ]] &&
    ok "partial budgets degraded, no traceback" || bad "stderr: $(cat "$T/err")"
done

echo "── 3. --dry-run decides without logging ──"
n=$(wc -l < "$EVENTS" | tr -d ' ')
"$DISKM" admit --class worktrees --est-gb 1 --dry-run >/dev/null; assert_eq "$?" 0 "dry-run rc"
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" "$n" "dry-run logged nothing"

echo "── 4. RED in refuse_red → 75 whatever the class terms; not degraded ──"
budget_json 60 RED 45; fake_df 45; config refuse_red
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>"$T/err"; assert_eq "$?" 0 "observe-only rc stays 0"
assert_eq "$(last decision)" 75 "RED refuse_red decision"
assert_eq "$(last zone)" RED "zone"
[[ "$(cat "$T/err")" != *admission_degraded* ]] && ok "no admission_degraded" || bad "unexpected degraded"

echo "── 5. ORANGE over-budget class: fresh → 75 in refuse_orange, >3 h stale → 10 ──"
fake_df 80; config refuse_orange
budget_json 60 ORANGE 80
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$(last decision)" 75 "fresh overage refuses"
python3 - "$T/state/budget.json" <<'PY'
import json, sys, time
p = sys.argv[1]; b = json.load(open(p)); b["classes"]["worktrees"]["measured_at"] = time.time() - 4 * 3600
json.dump(b, open(p, "w"))
PY
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$(last decision)" 10 "stale overage term dropped"

echo "── 6. df fails: ≤15 min tick free → stale_df; older GREEN → 10 blind; recent BLACK → 76 ──"
fake_df fail; config refuse_red
budget_json 300 RED 45
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>"$T/err"
assert_eq "$(last decision)" 75 "stale_df decides on last tick's free"
[[ "$(cat "$T/err")" == *admission_degraded:stale_df* ]] && ok "stale_df on stderr" || bad "missing stale_df"
assert_eq "$(last degraded)" stale_df "stale_df logged"
budget_json 1800 GREEN 150
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>"$T/err"
assert_eq "$(last decision)" 10 "blind → 10, never 0"
[[ "$(cat "$T/err")" == *admission_degraded:blind* ]] && ok "blind on stderr" || bad "missing blind"
budget_json 1800 BLACK 20
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1
assert_eq "$(last decision)" 10 "recent BLACK without D2 → 10 (76 once D2 is recorded)"
assert_eq "$(last zone)" BLACK "recent BLACK zone carried"
rm -f "$T/state/budget.json"
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1
assert_eq "$(last decision)" 10 "no budget.json at all → blind 10"

echo "── 7. 20 concurrent admits → 20 complete lines, 20 distinct ids, lock order ──"
fake_df 105; config observe; rm -f "$EVENTS"
for _ in $(seq 20); do "$DISKM" admit --class worktrees --est-gb 10 >/dev/null 2>&1 & done
wait
python3 - "$EVENTS" <<'PY' && ok "20 parseable events, 20 distinct admit_ids, ordered" || bad "concurrent event log"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert len(rows) == 20, len(rows)
assert len({r["admit_id"] for r in rows}) == 20
assert all(r["decision"] == 0 for r in rows)
ats = [r["at"] for r in rows]; assert ats == sorted(ats), ats
PY

echo "── 9. wrong-type budget.json / config values degrade to blind 10, rc 0, no traceback (yzky) ──"
fake_df fail; config refuse_red
check_blind() {  # check_blind <label> [admit args...]
  local label="$1"; shift
  "$DISKM" admit --class worktrees --est-gb 0 "$@" >/dev/null 2>"$T/err"; assert_eq "$?" 0 "rc: $label"
  assert_eq "$(last decision)" 10 "blind decision: $label"
  [[ "$(cat "$T/err")" == *admission_degraded:blind* && "$(cat "$T/err")" != *Traceback* ]] &&
    ok "degraded, no traceback: $label" || bad "stderr ($label): $(cat "$T/err")"
}
python3 -c 'import json,sys,time; json.dump({"zone":"RED","zone_at":time.time()-60,"free_bytes":"x"}, open(sys.argv[1],"w"))' "$T/state/budget.json"
check_blind 'free_bytes "x" on the stale_df path'
python3 -c 'import json,sys,time; json.dump({"zone":[1],"zone_at":time.time()-1800,"free_bytes":1}, open(sys.argv[1],"w"))' "$T/state/budget.json"
check_blind 'zone [1] on the blind path'
for zbad in '[]' '{}' '0' 'false' 'null' '"BOGUS"'; do
  python3 -c "import json,sys,time; json.dump({'zone':json.loads(sys.argv[2]),'zone_at':time.time()-1800,'free_bytes':1}, open(sys.argv[1],'w'))" "$T/state/budget.json" "$zbad"
  check_blind "zone $zbad on the blind path"
done
rm -f "$T/state/budget.json"; fake_df 150
for sbad in '{"zone": "BOGUS"}' '{"zone_at": true}' '{"free_bytes": true}' '{"free_bytes": -1}' \
            '{"classes": {"worktrees": {"used_gb": "x"}}}' '{"classes": {"worktrees": {"measured_at": true}}}' \
            '{"classes": {"worktrees": {"used_gb": true}}}'; do
  printf '%s' "$sbad" > "$T/state/budget.json"
  check_blind "state field $sbad"
done
rm -f "$T/state/budget.json"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["budgets"]["concurrency_margin_gb"]="10"; json.dump(c, open(sys.argv[2],"w"))' \
  "$REPO_ROOT/config.json.template" "$T/strmargin.json"
DISK_MAGICIAN_CONFIG="$T/strmargin.json" check_blind 'string concurrency_margin_gb'
for cbad in '[]' '{bad' '{"budgets": {}}' '{"budgets": []}' '{"budgets": null}' \
            '{"budgets": {"enforcement": "observe", "concurrency_margin_gb": 10, "classes": [1, "a"]}}' \
            '{"budgets": {"enforcement": "observe", "concurrency_margin_gb": 10, "classes": {"worktrees": {"measure": "du", "budget_gb": "x"}}}}' \
            '{"budgets": {"enforcement": "observe", "concurrency_margin_gb": 10, "classes": {"worktrees": {"measure": 123, "budget_gb": 10}}}}'; do
  printf '%s' "$cbad" > "$T/badcfg.json"
  DISK_MAGICIAN_CONFIG="$T/badcfg.json" check_blind "config $cbad"
done

# A present-but-malformed persisted stage/margin override is conservative too;
# only an *absent* override may fall through to the configured value.
config refuse_red; fake_df 150
for bad in '{"stage": null}' '{"margin_gb": null}' '{"stage": "bogus"}' '{"stage": 5}' '{"margin_gb": "x"}' '{"margin_gb": true}'; do
  printf '%s' "$bad" > "$T/state/budget.json"
  "$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>"$T/err"; assert_eq "$?" 0 "rc: persisted override $bad"
  assert_eq "$(last decision)" 10 "blind: persisted override $bad"
  [[ "$(cat "$T/err")" == *admission_degraded:blind* && "$(cat "$T/err")" != *Traceback* ]] &&
    ok "degraded, no traceback: $bad" || bad "stderr ($bad): $(cat "$T/err")"
done
rm -f "$T/state/budget.json"

echo "── 10. a df_delta_only class never counts as over budget ──"
fake_df 80; config refuse_orange
python3 -c 'import json,sys,time; t=time.time(); json.dump({"zone":"ORANGE","zone_at":t,"free_bytes":80<<30,"classes":{"codex_documents":{"used_gb":99,"budget_gb":3,"measured_at":t}}}, open(sys.argv[1],"w"))' "$T/state/budget.json"
"$DISKM" admit --class codex_documents --est-gb 0 >/dev/null 2>&1; assert_eq "$(last decision)" 10 "df_delta_only overage ignored in ORANGE"

echo "── 11. D2 recorded: rc is the decision; degraded is never 0; revoke restores observe-only rc ──"
d2() { echo "{\"admission_enforcement\": {\"id\": \"admission_enforcement\", \"revoked_at\": $1}}" > "$DISK_MAGICIAN_POLICY_FILE"; }
d2 null; rm -f "$T/state/budget.json"
fake_df 45; config refuse_red
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 75 "RED refuse_red rc with D2"
fake_df 25; config observe
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 76 "BLACK rc with D2"
fake_df 10
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 75 "FLOOR rc with D2"
fake_df 80
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 0 "ORANGE observe rc with D2"
fake_df fail
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 10 "blind rc with D2 is 10, never 0"
printf '{bad' > "$T/state/budget.json"
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 10 "corrupt budget.json rc with D2 is 10"
rm -f "$T/state/budget.json"
d2 1; fake_df 25
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>&1; assert_eq "$?" 0 "revoked D2 → rc 0"
printf '{bad' > "$DISK_MAGICIAN_POLICY_FILE"
"$DISKM" admit --class worktrees --est-gb 0 >/dev/null 2>"$T/err"; assert_eq "$?" 0 "unreadable policy file → not approved, rc 0"
[[ "$(cat "$T/err")" != *Traceback* ]] && ok "no traceback on unreadable policy" || bad "stderr: $(cat "$T/err")"

echo "── 12. --probe: emergency_probe line, not an admit birth; rc 76 when projected − margin = 20 with D2 ──"
d2 null; fake_df 105; config observe
"$DISKM" admit --class worktrees --est-gb 75 --probe >/dev/null 2>&1; assert_eq "$?" 76 "probe rc"
assert_eq "$(last event)" emergency_probe "probe event"
assert_eq "$(last zone)" BLACK "probe zone"
"$DISKM" admit --class worktrees --est-gb 1 --probe --dry-run >/dev/null 2>&1; assert_eq "$?" 2 "--probe with --dry-run is a usage error"
rm -f "$DISK_MAGICIAN_POLICY_FILE"

echo "── 13. --confirm / --confirm-tool-use log admit_confirm with dev + inode; missing dest → rc 2, nothing logged ──"
fake_df 150; config observe
id=$("$DISKM" admit --class worktrees --est-gb 1 --dest "$T/made" --tool-use-id tu-1 2>/dev/null); id=${id#admit_id=}
n=$(wc -l < "$EVENTS" | tr -d ' ')
"$DISKM" admit --confirm "$id" >/dev/null 2>&1; assert_eq "$?" 2 "confirm with dest absent rc"
assert_eq "$(wc -l < "$EVENTS" | tr -d ' ')" "$n" "nothing logged for absent dest"
"$DISKM" admit --confirm no-such-id >/dev/null 2>&1; assert_eq "$?" 2 "unknown admit_id rc"
mkdir "$T/made"
"$DISKM" admit --confirm "$id" >/dev/null 2>&1; assert_eq "$?" 0 "confirm rc"
assert_eq "$(last event)" admit_confirm "admit_confirm logged"
assert_eq "$(last admit_id)" "$id" "confirm carries admit_id"
assert_eq "$(last inode)" "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$T/made")" "inode"
assert_eq "$(last dev)" "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$T/made")" "dev"
"$DISKM" admit --confirm-tool-use tu-1 >/dev/null 2>&1; assert_eq "$?" 0 "confirm-tool-use rc"
assert_eq "$(last admit_id)" "$id" "confirm-tool-use resolves the admit"
"$DISKM" admit --confirm-tool-use tu-none >/dev/null 2>&1; assert_eq "$?" 2 "unknown tool_use_id rc"
"$DISKM" admit --confirm "$id" --confirm-tool-use tu-1 >/dev/null 2>&1; assert_eq "$?" 2 "both confirm forms is a usage error"

echo "── 8. event-log ENOSPC keeps the decision, writes admission_degraded:log ──"
echo "14. scratch quota admission reclaims once and enforces fresh volume headroom"
mkdir -p "$T/scratch"
python3 - "$REPO_ROOT/config.json.template" "$T/volume-config.json" "$T/scratch" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["budgets"]["enforcement"] = "observe"
config["volumes"]["classes"]["scratch"]["mountpoint"] = sys.argv[3]
json.dump(config, open(sys.argv[2], "w"))
PY
cat > "$T/bin/disk-magician-volume" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "volume status --json --snapshot")
    calls="$T/volume-status-count"
    n=0; [[ -f "$calls" ]] && n=$(cat "$calls")
    n=$((n + 1)); printf '%s\n' "$n" > "$calls"
    used_gib="$FAKE_VOLUME_FIRST_GIB"
    (( n > 1 )) && used_gib="$FAKE_VOLUME_AFTER_GIB"
    used=$(( used_gib * 1073741824 ))
    printf '{"ok":true,"measured_at":"now","volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":32212254720,"filesystem_id":"vol-1","path":"%s"}]}\n' "$used" "$T/scratch"
    exit 1
    ;;
  "volume reclaim --clean")
    echo reclaim >> "$T/reclaim-calls"
    exit 0
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/disk-magician-volume"
fake_df 150; config observe
export DISK_MAGICIAN_CONFIG="$T/volume-config.json"
export DISK_MAGICIAN_DISKM_BIN="$T/bin/disk-magician-volume"
export FAKE_VOLUME_FIRST_GIB=28 FAKE_VOLUME_AFTER_GIB=26
rm -f "$T/volume-status-count" "$T/reclaim-calls"
"$DISKM" admit --class worktrees --est-gb 2 --dest "$T/scratch/job" >/dev/null 2>"$T/err"
assert_eq "$?" 0 "admit after one reclaim with fresh headroom"
assert_eq "$(wc -l < "$T/reclaim-calls" | tr -d ' ')" 1 "one reclaim invocation"
assert_eq "$(last decision)" 0 "volume admit event decision"
assert_eq "$(last volume_gate)" None "volume admit event gate"
export FAKE_VOLUME_AFTER_GIB=28
rm -f "$T/volume-status-count" "$T/reclaim-calls"
"$DISKM" admit --class worktrees --est-gb 1 --dest "$T/scratch/job" >/dev/null 2>"$T/err"
assert_eq "$?" 75 "post-reclaim high water forces refusal"
assert_eq "$(wc -l < "$T/reclaim-calls" | tr -d ' ')" 1 "high water reclaims only once"
[[ "$(cat "$T/err")" == *volume_full:scratch* ]] && ok "high-water denial is explicit" || bad "missing volume_full reason"
export FAKE_VOLUME_FIRST_GIB=26 FAKE_VOLUME_AFTER_GIB=26
rm -f "$T/volume-status-count" "$T/reclaim-calls"
: > "$T/reclaim-calls"
"$DISKM" admit --class worktrees --est-gb 3.1 --dest "$T/scratch/job" >/dev/null 2>"$T/err"
assert_eq "$?" 75 "less than one GiB quota headroom refuses"
assert_eq "$(wc -l < "$T/reclaim-calls" | tr -d ' ')" 0 "low-water case does not reclaim"
[[ "$(cat "$T/err")" == *volume_headroom:scratch* ]] && ok "headroom denial is explicit" || bad "missing volume_headroom reason"
unset DISK_MAGICIAN_DISKM_BIN

if command -v hdiutil >/dev/null 2>&1; then
  hdiutil create -size 2m -fs HFS+ -volname admitfull "$T/full.dmg" >/dev/null &&
    hdiutil attach -nobrowse -mountpoint "$T/mnt" "$T/full.dmg" >/dev/null
  if [[ -d "$T/mnt" ]]; then
    mkdir -p "$T/mnt/admission"; : > "$T/mnt/state.lock"  # the lock file persists from earlier admits
    dd if=/dev/zero of="$T/mnt/fill" bs=64k 2>/dev/null
    dd if=/dev/zero of="$T/mnt/fill2" bs=512 2>/dev/null; dd if=/dev/zero of="$T/mnt/fill3" bs=1 2>/dev/null
    DISK_MAGICIAN_STATE_DIR="$T/mnt" "$DISKM" admit --class worktrees --est-gb 1 >/dev/null 2>"$T/err"
    assert_eq "$?" 0 "rc unchanged on full log volume"
    [[ "$(cat "$T/err")" == *admission_degraded:log* ]] && ok "admission_degraded:log" || bad "stderr: $(cat "$T/err")"
    hdiutil detach "$T/mnt" >/dev/null 2>&1 || hdiutil detach -force "$T/mnt" >/dev/null 2>&1
  else bad "hdiutil attach failed"; fi
else echo "  SKIP: hdiutil unavailable (not macOS)"; fi

echo
echo "test_admit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/scratch_budget.sh"
source "$SCRIPT_DIR/lib/actuator_deadline.sh"
clean=false
available_floor=false
for arg in "$@"; do
 case "$arg" in --clean) clean=true;; --available-floor) available_floor=true;;
 *) echo "usage: volume reclaim [--clean] [--available-floor]" >&2; exit 2;; esac
done
if [[ "$available_floor" == true && -z "$ACT_DEADLINE_AT" ]]; then
 ACT_DEADLINE_AT="$(python3 -c 'import time; print(time.monotonic()+300)')" || exit 75
 export ACT_DEADLINE_AT
fi
if [[ "$clean" == true ]]; then source "$SCRIPT_DIR/lib/scratch_lock.sh"; scratch_lock_acquire volume_reclaim "$@" || exit $?; fi
diskm="${DISK_MAGICIAN_DISKM_BIN:-$SCRIPT_DIR/../disk_magician.sh}"
status_json() {
 local output rc
 output="$("$diskm" volume status --json --snapshot 2>/dev/null)"; rc=$?
 (( rc == 0 || rc == 1 )) || return "$rc"
 printf '%s\n' "$output"
}
usage_pair() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=next(x for x in d["volumes"] if x.get("class")=="scratch"); u=r["allocated_bytes"]; q=r["quota_bytes"]; assert isinstance(u,int) and isinstance(q,int) and q>0; print(u,q)' <<<"$1"; }
reserve_available() { python3 -c 'import json,sys; d=json.load(sys.stdin); r=next(x for x in d["volumes"] if x.get("class")=="scratch"); print("1" if r.get("available") is True else "0")' <<<"$1"; }
pressure_failure() {
 if [[ "$available_floor" == true ]]; then
  local failure_id
  failure_id="${DISK_MAGICIAN_RECLAIM_RECEIPT_ID:-}"
  [[ -n "$failure_id" ]] || failure_id="$(python3 "$SCRIPT_DIR/job_receipt.py" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-manual}" --precondition '{"policy":"available-floor","available_floor_bytes":53687091200}')" || return 1
  python3 "$SCRIPT_DIR/job_receipt.py" finish --job volume_reclaim --run-id "$failure_id" --outcome error --reason "$1" --postcondition '{"available_bytes_after":null,"target_reached":null}' >/dev/null || return 1
 fi
}
# Recover only our durable prior-release obligation while holding the same
# cleanup lock as producers of that obligation. Low space permits C14 work,
# but forbids another reserve release until recovery completes.
pending_ballast=false
if [[ "$available_floor" == true && "$clean" == true ]]; then
 recovery_rc=0
 "$diskm" volume ballast recover scratch >/dev/null 2>&1 || recovery_rc=$?
 case "$recovery_rc" in
  0) ;;
  76) pending_ballast=true ;;
  *) pressure_failure pending-ballast-recovery-failed; exit 75 ;;
 esac
fi
root="$("$diskm" volume path scratch --for-reclaim 2>/dev/null)"; rc=$?
if [[ $rc -ne 0 || ! -d "$root" ]]; then echo skipped:unavailable; pressure_failure unavailable; [[ "$available_floor" == true ]] && exit 75; exit 0; fi
"$diskm" volume verify-mount "$root" >/dev/null 2>&1 || { echo skipped:unavailable; pressure_failure unavailable; [[ "$available_floor" == true ]] && exit 75; exit 0; }
# Scheduled pressure mode never performs even reserve/trim maintenance above
# the floor. Revalidate mount and availability before each destructive unit.
free_bytes=""
free_before=""
pressure_measure() {
 "$diskm" volume verify-mount "$root" >/dev/null 2>&1 || return 75
 free_bytes="$(python3 "$SCRIPT_DIR/scratch_pressure.py" "$root")" || return 75
 [[ "$free_bytes" =~ ^[0-9]+$ ]] || return 75
}
if [[ "$available_floor" == true ]]; then
 pressure_measure || { echo skipped:measurement-unavailable; pressure_failure measurement-unavailable; exit 75; }
 free_before="$free_bytes"
 if (( free_bytes >= 53687091200 )); then
  receipt="$SCRIPT_DIR/job_receipt.py"
  condition="{\"policy\":\"available-floor\",\"available_bytes\":$free_bytes,\"available_floor_bytes\":53687091200}"
  run_id="${DISK_MAGICIAN_RECLAIM_RECEIPT_ID:-}"
  [[ -n "$run_id" ]] || run_id="$(python3 "$receipt" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-manual}" --precondition "$condition")" || exit 1
  python3 "$receipt" finish --job volume_reclaim --run-id "$run_id" --outcome success_noop --reason available-floor --candidates '{"aged_scanned":0,"removed":0,"ballast_restore_failures":0,"top_kept_reason":"available-floor"}' --postcondition "$condition" >/dev/null || exit 1
  echo "skipped:available-floor:$free_bytes"; exit 0
 fi
fi
before="$(status_json)" || { echo skipped:measurement-unavailable; pressure_failure measurement-unavailable; [[ "$available_floor" == true ]] && exit 75; exit 0; }
read -r used quota < <(usage_pair "$before" 2>/dev/null) || { echo skipped:measurement-unavailable; pressure_failure measurement-unavailable; [[ "$available_floor" == true ]] && exit 75; exit 0; }
pct=$((used * 100 / quota))
trigger_pct="${DISK_MAGICIAN_SCRATCH_TRIGGER_PCT:-}"
target_pct="${DISK_MAGICIAN_SCRATCH_TARGET_PCT:-}"
if [[ -z "$trigger_pct" || -z "$target_pct" ]]; then
 read -r cfg_trig cfg_targ < <(python3 -c '
import json, os, sys
try:
    import resolve_config
    cfg_path = os.environ.get("DISK_MAGICIAN_CONFIG") or resolve_config.resolve()
    doc = json.loads(open(cfg_path).read())
    scratch = doc.get("volumes", {}).get("classes", {}).get("scratch", {})
    trig = scratch.get("trigger_pct", 70)
    targ = scratch.get("target_pct", 50)
    print(trig, targ)
except Exception:
    print(70, 50)
' 2>/dev/null || echo "70 50")
 trigger_pct="${trigger_pct:-$cfg_trig}"
 target_pct="${target_pct:-$cfg_targ}"
fi
if ! [[ "$trigger_pct" =~ ^[0-9]+$ && "$target_pct" =~ ^[0-9]+$ ]] || (( trigger_pct <= 0 || target_pct <= 0 || target_pct >= trigger_pct || trigger_pct > 100 )); then
 trigger_pct=70
 target_pct=50
fi
reserve_before="$(reserve_available "$before" 2>/dev/null)" || reserve_before=0
reserve_before_json=false
[[ "$reserve_before" == 1 ]] && reserve_before_json=true
AGED=0 REMOVED=0 BALLAST_RELEASE_ATTEMPTED=0 BALLAST_RESTORE_FAILURES=0 TOP_REASON=none AFTER_PCT=$pct now_used=$used now_quota=$quota measurement_error=0 pressure_failed=0 reserve_after=$reserve_before reserve_after_json=$reserve_before_json
receipt="$SCRIPT_DIR/job_receipt.py"
precondition="{\"allocated_bytes\":$used,\"quota_bytes\":$quota,\"used_pct\":$pct,\"reserve_available\":$reserve_before_json}"
run_id="${DISK_MAGICIAN_RECLAIM_RECEIPT_ID:-}"
[[ -n "$run_id" ]] || run_id="$(python3 "$receipt" begin --job volume_reclaim --trigger "${DISK_MAGICIAN_TRIGGER:-manual}" --precondition "$precondition")" || { echo kept:receipt-begin-failed; exit 1; }
[[ -n "$run_id" ]] || { echo kept:receipt-begin-failed; exit 1; }
below_trigger=false
crossed_trigger=false
if [[ "$available_floor" != true ]] && (( used * 100 < quota * trigger_pct )); then
 below_trigger=true
 TOP_REASON="below-trigger"
fi
ACT_CURSOR_SOURCE="volume_reclaim:v1:$root"
cursor_error=0
if [[ "$below_trigger" != true && "$clean" == true && -n "$ACT_CURSOR" ]]; then
 act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" >/dev/null || { cursor_error=1; TOP_REASON=cursor-invalid; }
 if (( ! cursor_error )); then act_cursor_reset_once "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" || { cursor_error=1; TOP_REASON=cursor-reset-failed; }; fi
fi
reclaim_one() {
 local candidate="$1" diag result state_dir diag_dir root_dev diag_dev
 state_dir="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
 mkdir -p "$state_dir" 2>/dev/null || { echo kept:diagnostic-create-failed; return; }
 diag_dir="$state_dir"
 root_dev="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$root" 2>/dev/null)"
 diag_dev="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$diag_dir" 2>/dev/null)"
 if [[ -z "$root_dev" || -z "$diag_dev" || "$root_dev" == "$diag_dev" ]]; then
  diag_dir=/var/tmp
  diag_dev="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$diag_dir" 2>/dev/null)"
  [[ -n "$root_dev" && -n "$diag_dev" && "$root_dev" != "$diag_dev" ]] || { echo kept:diagnostic-filesystem-unavailable; return; }
 fi
 diag="$(mktemp "$diag_dir/dm-c14-diagnostic.XXXXXX")" || { echo kept:diagnostic-create-failed; return; }
 chmod 600 "$diag" || { echo kept:diagnostic-create-failed; return; }
 : >"$diag"
 result="$(TMPDIR="$diag_dir" DISK_MAGICIAN_C14_DIAGNOSTIC_OUT="$diag" scratch_budget_quarantine_remove "$candidate")"
 if [[ "$result" == kept:intent-write-failed && "$pending_ballast" != true ]] && python3 - "$diag" <<'PYDIAG'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(1)
raise SystemExit(0 if d == {"operation":"intent_write","errno":28,"errno_name":"ENOSPC"} else 1)
PYDIAG
 then
  local release_rc=0
  "$diskm" volume ballast release scratch >/dev/null 2>&1 || release_rc=$?
  if (( release_rc == 0 )); then
   local retry_allowed=true
   if [[ "$available_floor" == true ]]; then
    if ! pressure_measure; then
     result=kept:measurement-unavailable; retry_allowed=false
    elif (( free_bytes >= 53687091200 )); then
     result=kept:available-floor; retry_allowed=false
    fi
   fi
   if [[ "$retry_allowed" == true ]]; then
    result="$(TMPDIR="$diag_dir" DISK_MAGICIAN_C14_DIAGNOSTIC_OUT="$diag" scratch_budget_quarantine_remove "$candidate")"
   fi
  fi
  # Signal the parent shell to restore once the pass has made all possible room.
  result="${result}:ballast-release-attempted"
 fi
 python3 -c 'import os,sys; os.unlink(sys.argv[1])' "$diag" 2>/dev/null || true
 printf '%s\n' "$result"
}
if [[ "$below_trigger" != true ]] && (( ! cursor_error )); then
while IFS=$'\t' read -r newest entry; do
 [[ -n "$entry" ]] || continue
 if [[ "$available_floor" == true ]]; then
  pressure_measure || { TOP_REASON=measurement-unavailable; measurement_error=1; pressure_failed=1; break; }
  (( free_bytes < 53687091200 )) || break
 fi
 AGED=$((AGED+1))
 if [[ "$clean" != true ]]; then echo "would_check:$entry"; continue; fi
 result="$(reclaim_one "$entry")"
 if [[ "$result" == *:ballast-release-attempted ]]; then
  BALLAST_RELEASE_ATTEMPTED=1
  result="${result%:ballast-release-attempted}"
 fi
 [[ "$result" == kept:measurement-unavailable ]] && { pressure_failed=1; measurement_error=1; }
 case "$result" in removed:*) REMOVED=$((REMOVED+1));; *) TOP_REASON="${result#kept:}"; echo "$result:$entry";; esac
 [[ "$result" == deferred:deadline-before-unit ]] && { TOP_REASON=deadline-before-unit; break; }
 current="$(status_json)" || { TOP_REASON=measurement-unavailable; measurement_error=1; break; }
 read -r now_used now_quota < <(usage_pair "$current" 2>/dev/null) || { TOP_REASON=measurement-unavailable; measurement_error=1; break; }
 [[ "$now_quota" -eq "$quota" ]] || { TOP_REASON=quota-changed; measurement_error=1; break; }
 AFTER_PCT=$((now_used * 100 / now_quota))
 if [[ "$available_floor" == true ]]; then
  pressure_measure || { TOP_REASON=measurement-unavailable; measurement_error=1; pressure_failed=1; break; }
  (( free_bytes < 53687091200 )) || break
 else
  (( now_used * 100 > now_quota * target_pct )) || break
 fi
done < <(
 while IFS= read -r -d '' entry; do
  rel="${entry#"$root"/}"
  [[ "$rel" =~ ^[^./][^/]*/(evidence|build)/[^./][^/]*$ ]] || continue
  newest="$(scratch_budget_content_mtime "$entry" --strict 2>/dev/null)" || continue
  [[ "$newest" =~ ^[0-9]+$ ]] || continue
  (( $(date +%s) - newest > 172800 )) || continue
  printf '%s\t%s\n' "$newest" "$entry"
 done < <(find "$root" -mindepth 3 -maxdepth 3 -type d ! -name '.*' -print0 2>/dev/null) | sort -n -k1,1
)
fi
# Every clean pass ends by running the idempotent reserve ensure. It physically
# validates or recreates the reserve after reclaim and before success is recorded.
if [[ "$clean" == true ]]; then
 if [[ "$pending_ballast" == true ]]; then
  "$diskm" volume ballast recover scratch >/dev/null 2>&1 || BALLAST_RESTORE_FAILURES=1
 elif [[ "$available_floor" != true ]] || (( BALLAST_RELEASE_ATTEMPTED )); then
  "$diskm" volume ballast ensure scratch >/dev/null 2>&1 || BALLAST_RESTORE_FAILURES=1
 fi
 # Manual quota mode can recover a transient probe; scheduled policy retains
 # a failed in-pass probe rather than reporting a successful partial scan.
 # A successful final measurement supersedes an earlier transient probe error;
 # an unknown final allocation remains fail-closed.
 if [[ "$available_floor" == true ]]; then pressure_failed=$measurement_error; fi
 measurement_error=0
 current="$(status_json)" || { TOP_REASON=measurement-unavailable; measurement_error=1; }
 if (( ! measurement_error )); then
  read -r now_used now_quota < <(usage_pair "$current" 2>/dev/null) || { TOP_REASON=measurement-unavailable; measurement_error=1; }
 fi
 if (( ! measurement_error )) && [[ "$now_quota" -ne "$quota" ]]; then TOP_REASON=quota-changed; measurement_error=1; fi
 if (( ! measurement_error )); then
  reserve_after="$(reserve_available "$current" 2>/dev/null)" || reserve_after=0
  reserve_after_json=false
  [[ "$reserve_after" == 1 ]] && reserve_after_json=true
  if [[ "$reserve_after" != 1 ]]; then TOP_REASON=ballast-restore-failed; BALLAST_RESTORE_FAILURES=1; fi
 fi
 if (( ! measurement_error )); then AFTER_PCT=$((now_used * 100 / now_quota)); fi
 # Usage can cross the trigger during reserve maintenance; the final high-water
 # measurement, not the first, decides whether below-trigger is truthful.
 if (( ! measurement_error )) && [[ "$below_trigger" == true ]] && (( now_used * 100 >= quota * trigger_pct )); then
  crossed_trigger=true; TOP_REASON=trim-target-not-reached
  echo "trim_target_not_reached before_bytes=$used after_bytes=$now_used quota_bytes=$quota target_pct=$target_pct"
 fi
 if (( ! measurement_error && now_used * 100 > quota * target_pct )) && [[ "$below_trigger" != true && "$available_floor" != true ]]; then
  echo "trim_target_not_reached before_bytes=$used after_bytes=$now_used quota_bytes=$quota target_pct=$target_pct"
 fi
 if (( BALLAST_RESTORE_FAILURES > 0 )); then TOP_REASON=ballast-restore-failed; echo kept:ballast-restore-failed; fi
fi
target_reached=$(( now_used * 100 <= quota * 80 ))
target_reached=$(( now_used * 100 <= quota * target_pct ))
if [[ "$available_floor" == true ]]; then
 (( pressure_failed )) && { TOP_REASON=measurement-unavailable; measurement_error=1; }
 pressure_measure || { TOP_REASON=measurement-unavailable; measurement_error=1; }
 target_reached=0
 if (( ! measurement_error && free_bytes >= 53687091200 )); then target_reached=1; fi
fi
trim_failed=0
trim_done=0
if [[ "$clean" == true && "$available_floor" != true && "$(uname -s)" == Linux ]]; then
 trim_output="$("$diskm" volume trim-auto scratch --clean 2>&1)" || trim_failed=1
 if (( trim_failed )); then
  TOP_REASON=host-trim-unavailable
  echo "degraded:host-trim-unavailable:$trim_output" >&2
 else
  if python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if isinstance(d,dict) and d.get("status")=="trimmed" else 1)' <<<"$trim_output" 2>/dev/null; then trim_done=1; fi
  printf '%s\n' "$trim_output"
 fi
fi
outcome=success_noop
reason=dry-run
if (( measurement_error )); then outcome=error; reason=measurement-unavailable; fi
if [[ "$below_trigger" == true ]]; then reason=below-trigger; fi
if [[ "$clean" == true ]]; then
 outcome=success; reason="$TOP_REASON"
 if (( trim_failed || measurement_error )); then outcome=error; reason="$TOP_REASON"; elif (( BALLAST_RESTORE_FAILURES > 0 )); then outcome=partial; reason=ballast-restore-failed; elif [[ "$crossed_trigger" == true ]]; then outcome=partial; reason=trim-target-not-reached; elif [[ "$below_trigger" == true && "$trim_done" == 1 ]]; then outcome=success; reason=host-trimmed; elif [[ "$below_trigger" == true ]]; then outcome=success_noop; reason=below-trigger; elif (( target_reached )); then outcome=success; else outcome=partial; fi
 if (( ! measurement_error )) && [[ "$below_trigger" != true ]] && ! python3 - "$AGED" "$REMOVED" "$TOP_REASON" "$used" "$now_used" "$quota" "$target_pct" "$available_floor" "$free_before" "$free_bytes" "$target_reached" <<'PYREC'
import json,os,sys,tempfile
from datetime import datetime,timezone
from pathlib import Path
state=Path(os.environ.get("DISK_MAGICIAN_STATE_DIR",Path.home()/".disk_magician_state"))/"volumes"
state.mkdir(parents=True,exist_ok=True); p=state/"reclaim_runs.json"
try:
 data=json.loads(p.read_text()) if p.exists() else {"runs":[]}
 if not isinstance(data,dict) or not isinstance(data.get("runs",[]),list): raise ValueError("invalid history")
except Exception as e:
 print(f"reclaim_runs.json unreadable; preserving: {e}",file=sys.stderr); raise SystemExit(1)
before,after,quota,targ_pct=map(int,sys.argv[4:8])
data.setdefault("runs",[]).append({"at":datetime.now(timezone.utc).isoformat(),"quota_used_before_pct":before*100//quota,"quota_used_after_pct":after*100//quota,"allocated_bytes_before":before,"allocated_bytes_after":after,"quota_bytes":quota,"aged_scanned":int(sys.argv[1]),"removed":int(sys.argv[2]),"target_pct":targ_pct,"target_reached":after*100<=quota*targ_pct,"top_kept_reason":sys.argv[3]})
if sys.argv[8] == "true":
 data["runs"][-1].update(policy="available-floor", target_pct=None,
     available_floor_bytes=53687091200, available_bytes_before=int(sys.argv[9]),
     available_bytes_after=int(sys.argv[10]), target_reached=sys.argv[11] == "1")
data["runs"]=data["runs"][-2:]
fd,tmp=tempfile.mkstemp(dir=state,prefix=".reclaim_runs.",suffix=".tmp")
with os.fdopen(fd,"w") as f:
 json.dump(data,f,sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.replace(tmp,p)
PYREC
 then outcome=error; reason=history-write-failed; fi
fi
candidates="{\"aged_scanned\":$AGED,\"removed\":$REMOVED,\"ballast_restore_failures\":$BALLAST_RESTORE_FAILURES,\"top_kept_reason\":\"$TOP_REASON\"}"
if (( measurement_error )); then post="{\"allocated_bytes_after\":null,\"quota_bytes\":$quota,\"target_reached\":null,\"reserve_available_before\":$reserve_before_json,\"reserve_available_after\":null}"; else post="{\"allocated_bytes_after\":$now_used,\"quota_bytes\":$quota,\"target_reached\":$target_reached,\"reserve_available_before\":$reserve_before_json,\"reserve_available_after\":$reserve_after_json}"; fi
if [[ "$available_floor" == true ]]; then
 precondition="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(policy="available-floor",available_floor_bytes=53687091200,available_bytes_before=int(sys.argv[2])); print(json.dumps(d))' "$precondition" "$free_before")"
 post="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(available_bytes_after=None if sys.argv[3]=="1" else int(sys.argv[2])); print(json.dumps(d))' "$post" "$free_bytes" "$measurement_error")"
fi
if ! python3 "$receipt" finish --job volume_reclaim --run-id "$run_id" --outcome "$outcome" --reason "$reason" --candidates "$candidates" --precondition "$precondition" --postcondition "$post" >/dev/null; then
 echo kept:receipt-finish-failed >&2; exit 1
fi
if [[ "$below_trigger" == true && "$outcome" == success_noop && "$trim_done" == 0 ]]; then echo "skipped:below-trigger:$pct"; fi
[[ "$outcome" != error ]]

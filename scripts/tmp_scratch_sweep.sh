#!/usr/bin/env bash
# tmp_scratch_sweep.sh — hourly tmp-scratch job entry point (bead disk_magician-isw
# scheduling gap). Wraps cleanup_tmp.sh (--aged, under LARGE_TMP_APPROVED=1
# when cleaning) then cleanup_claude_state.sh (invoked report-only with
# --dry-run; unattended deletions of ~/.claude/state remain strictly forbidden),
# failure-continuing between steps but propagating a nonzero exit if either step
# failed, so an unattended launchd job doesn't silently look healthy when a
# step is broken.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/actuator_deadline.sh"
act_parse_deadline_args "$@" || exit 2
# Bash 3.2 with nounset treats an empty array expansion as an unbound variable.
if ((${#ACT_ARGS[@]})); then set -- "${ACT_ARGS[@]}"; else set --; fi
clean_flag="${1:---dry-run}"
if [[ $# -gt 1 || ( "$clean_flag" != "--clean" && "$clean_flag" != "--dry-run" ) ]]; then
  echo "Usage: $(basename "$0") [--clean|--dry-run] [--deadline-at MONOTONIC] [--cursor PATH]" >&2
  exit 2
fi
governor_args=()
[[ -n "$ACT_DEADLINE_AT" ]] && governor_args+=(--deadline-at "$ACT_DEADLINE_AT")
[[ -n "$ACT_CURSOR" ]] && governor_args+=(--cursor "$ACT_CURSOR")

RECEIPT_HELPER="${DISK_MAGICIAN_RECEIPT_HELPER:-$SCRIPT_DIR/job_receipt.py}"
_df_free_bytes() {
  df -kP "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4 * 1024}'
}
FREE_BEFORE="$(_df_free_bytes)"
[[ "$FREE_BEFORE" =~ ^[0-9]+$ ]] || FREE_BEFORE=""
PRECONDITION='{}'
[[ -n "$FREE_BEFORE" ]] && PRECONDITION="{\"free_bytes_before\":${FREE_BEFORE}}"

# Record started before work
TRIGGER="${clean_flag#--}"
RECEIPT_RUN_ID=$(python3 "$RECEIPT_HELPER" begin --job tmp_scratch_sweep --trigger "$TRIGGER" --precondition "$PRECONDITION") || {
  echo "[tmp_scratch_sweep] ERROR: failed to record receipt begin" >&2
  exit 1
}

CHILD_TRIGGER="tmp_scratch_sweep:${RECEIPT_RUN_ID}"
# This run owns the shared C14 ledger; the nested cleanup_tmp receipt inherits
# the path but a different owner, so it cannot double-count the same kept bytes.
: "${DISK_MAGICIAN_C14_LEDGER_OWNER:=tmp_scratch_sweep}"
export DISK_MAGICIAN_C14_LEDGER_OWNER
OLD_CHILD_ID="$(python3 "$RECEIPT_HELPER" read --job cleanup_tmp --last 2>/dev/null | python3 -c 'import json,sys; x=json.load(sys.stdin); print(x.get("id", "") if x else "")' 2>/dev/null || true)"
OLD_VOLUME_ID="$(python3 "$RECEIPT_HELPER" read --job volume_reclaim --last 2>/dev/null | python3 -c 'import json,sys; x=json.load(sys.stdin); print(x.get("id", "") if x else "")' 2>/dev/null || true)"
run_cleanup_tmp() {
  if [[ -n "$ACT_DEADLINE_AT" || -n "$ACT_CURSOR" ]]; then
    DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" "$@" ${governor_args[@]+"${governor_args[@]}"}
  else
    DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" "$@"
  fi
}

rc=0
tmp_rc=0
TMP_LOCK_SKIPPED=false
if [[ "$clean_flag" == "--clean" ]]; then
  if [[ -n "$ACT_DEADLINE_AT" || -n "$ACT_CURSOR" ]]; then
    env LARGE_TMP_APPROVED=1 DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" --clean --aged ${governor_args[@]+"${governor_args[@]}"} || tmp_rc=$?
  else
    env LARGE_TMP_APPROVED=1 DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" --clean --aged || tmp_rc=$?
  fi
  if [[ $tmp_rc -eq 75 ]]; then
    TMP_LOCK_SKIPPED=true
  elif [[ $tmp_rc -ne 0 ]]; then
    rc=1
  fi
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
else
  run_cleanup_tmp --dry-run --aged || tmp_rc=$?
  if [[ $tmp_rc -eq 75 ]]; then
    TMP_LOCK_SKIPPED=true
  elif [[ $tmp_rc -ne 0 ]]; then
    rc=1
  fi
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
fi
# The installed hourly entry point also drives quota-volume C14 reclaim.
volume_args=(volume reclaim)
[[ "$clean_flag" == "--clean" ]] && volume_args+=(--clean)
VOLUME_TIMEOUT_BIN="${DISK_MAGICIAN_VOLUME_TIMEOUT_BIN:-}"
if [[ -z "$VOLUME_TIMEOUT_BIN" ]]; then
  for candidate in "$(command -v timeout 2>/dev/null || true)" "$(command -v gtimeout 2>/dev/null || true)" /opt/homebrew/bin/timeout /opt/homebrew/bin/gtimeout /usr/local/bin/timeout /usr/local/bin/gtimeout; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then VOLUME_TIMEOUT_BIN="$candidate"; break; fi
  done
fi
VOLUME_TIMEOUT_SEC="${DISK_MAGICIAN_VOLUME_RECLAIM_TIMEOUT_SECONDS:-300}"
if [[ -n "$ACT_DEADLINE_AT" ]]; then
  VOLUME_TIMEOUT_SEC="$(python3 - "$ACT_DEADLINE_AT" <<'PY'
import sys,time
try: remaining=max(0.0,float(sys.argv[1])-time.monotonic())
except (TypeError,ValueError): remaining=0.0
print(f"{remaining+15.0:.3f}")
PY
)"
elif ! [[ "$VOLUME_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]]; then
  VOLUME_TIMEOUT_SEC=0
fi
VOLUME_CURSOR=""
[[ -n "$ACT_CURSOR" ]] && VOLUME_CURSOR="${ACT_CURSOR}.volume-reclaim"
VOLUME_OUTPUT=""
VOLUME_RC=0
VOLUME_COMMAND_STARTED=false
if [[ -z "$VOLUME_TIMEOUT_BIN" || ! -x "$VOLUME_TIMEOUT_BIN" || "$VOLUME_TIMEOUT_SEC" == 0 ]]; then
  VOLUME_OUTPUT="skipped:bounded-runtime-unavailable"
  VOLUME_RC=124
else
  VOLUME_COMMAND_STARTED=true
  VOLUME_OUTPUT="$(ACT_DEADLINE_AT="$ACT_DEADLINE_AT" ACT_CURSOR="$VOLUME_CURSOR" DISK_MAGICIAN_TRIGGER="$CHILD_TRIGGER" \
    "$VOLUME_TIMEOUT_BIN" --signal=TERM --kill-after=2s "${VOLUME_TIMEOUT_SEC}s" \
    "$SCRIPT_DIR/../disk_magician.sh" "${volume_args[@]}" 2>&1)"
  VOLUME_RC=$?
fi
if (( VOLUME_RC == 124 || VOLUME_RC == 137 || VOLUME_RC == 143 )); then
  VOLUME_TIMEOUT_REASON="${VOLUME_OUTPUT:-volume reclaim exceeded bounded runtime}"
  VOLUME_OUTPUT="${VOLUME_OUTPUT:+$VOLUME_OUTPUT$'\n'}skipped:runtime-timeout"
  VOLUME_BALLAST_FAILURES=0
  if [[ "$clean_flag" == "--clean" && "$VOLUME_COMMAND_STARTED" == true ]]; then
    "$VOLUME_TIMEOUT_BIN" --signal=TERM --kill-after=2s 12s "$SCRIPT_DIR/../disk_magician.sh" volume ballast ensure scratch >/dev/null 2>&1 || VOLUME_BALLAST_FAILURES=1
  fi
  VOLUME_ACTIVE="$(python3 "$RECEIPT_HELPER" read --job volume_reclaim --active 2>/dev/null || true)"
  VOLUME_RUN_IDS="$(python3 - "$VOLUME_ACTIVE" "$CHILD_TRIGGER" <<'PY'
import json,sys
try: rows=json.loads(sys.argv[1])
except Exception: rows=[]
if isinstance(rows,dict): rows=rows.get("active",[])
for row in rows if isinstance(rows,list) else []:
    if isinstance(row,dict) and row.get("trigger")==sys.argv[2] and isinstance(row.get("id"),str): print(row["id"])
PY
)"
  if [[ -z "$VOLUME_RUN_IDS" ]]; then
    VOLUME_RUN_IDS="$(python3 "$RECEIPT_HELPER" begin --job volume_reclaim --trigger "$CHILD_TRIGGER" --precondition '{}')" || VOLUME_RUN_IDS=""
  fi
  for volume_run_id in $VOLUME_RUN_IDS; do
    [[ -n "$volume_run_id" ]] || continue
    python3 "$RECEIPT_HELPER" finish --job volume_reclaim --run-id "$volume_run_id" --outcome timeout \
      --reason "bounded runtime expired: $VOLUME_TIMEOUT_REASON" --trigger "$CHILD_TRIGGER" \
      --candidates "{\"aged_scanned\":null,\"removed\":null,\"top_kept_reason\":\"runtime-timeout\",\"ballast_restore_failures\":$VOLUME_BALLAST_FAILURES}" \
      --postcondition '{"allocated_bytes_after":null,"target_reached":null}' >/dev/null 2>&1 || true
  done
fi
[[ -n "$VOLUME_OUTPUT" ]] && printf '%s\n' "$VOLUME_OUTPUT"
if [[ $VOLUME_RC -ne 0 ]]; then
  echo "[tmp_scratch_sweep] ERROR: volume reclaim failed" >&2
  rc=1
fi
VOLUME_RECEIPT="$(python3 "$RECEIPT_HELPER" read --job volume_reclaim --last 2>/dev/null || true)"
VOLUME_METRICS="$(python3 - "$VOLUME_RECEIPT" "$OLD_VOLUME_ID" "$CHILD_TRIGGER" "$VOLUME_OUTPUT" "$clean_flag" <<'PYV'
import json,sys
try: r=json.loads(sys.argv[1])
except Exception: r={}
if isinstance(r,dict) and r.get("id")!=sys.argv[2] and r.get("trigger")==sys.argv[3]:
 c=r.get("candidates") or {}; p=r.get("postcondition") or {}
 print(json.dumps({"valid":True,"outcome":r.get("outcome"),"aged_scanned":c.get("aged_scanned"),"removed":c.get("removed"),"target_reached":(p.get("target_reached") if sys.argv[5]=="--clean" else None),"top_kept_reason":c.get("top_kept_reason"),"ballast_restore_failures":c.get("ballast_restore_failures",0)},separators=(",",":")))
elif sys.argv[4].strip() in ("skipped:unavailable","skipped:measurement-unavailable") or sys.argv[4].strip().startswith("skipped:below-trigger:"):
 print(json.dumps({"valid":True,"outcome":"skipped","skip_reason":sys.argv[4].strip(),"aged_scanned":0,"removed":0,"target_reached":None,"top_kept_reason":None},separators=(",",":")))
else:
 print(json.dumps({"valid":False,"outcome":"error","aged_scanned":None,"removed":None,"target_reached":None,"top_kept_reason":"bound-receipt-unavailable"},separators=(",",":")))
PYV
)"
read -r VOLUME_VALID VOLUME_OUTCOME VOLUME_AGED VOLUME_REMOVED VOLUME_TARGET VOLUME_BALLAST_FAILURES VOLUME_REASON <<<"$(python3 - "$VOLUME_METRICS" <<'PYV'
import json,sys
try: x=json.loads(sys.argv[1])
except Exception: x={}
for k in ("valid","outcome","aged_scanned","removed","target_reached","ballast_restore_failures","top_kept_reason"):
 v=x.get(k,0) if k=="ballast_restore_failures" else x.get(k)
 print(str(v).lower() if isinstance(v,bool) else (v if isinstance(v,(str,int)) and v is not None else "null"),end=" ")
PYV
)"
VOLUME_REASON_JSON="$(python3 -c 'import json,sys; print(json.dumps(None if sys.argv[1]=="null" else sys.argv[1]))' "$VOLUME_REASON")"
if [[ "$VOLUME_VALID" != true || "$VOLUME_OUTCOME" == error || "$VOLUME_OUTCOME" == timeout ]]; then rc=1; fi

if [[ $rc -ne 0 ]]; then
  OUTCOME="error"
  REASON="one or more sweep steps failed"
elif [[ "$TMP_LOCK_SKIPPED" == true && "$VOLUME_REMOVED" =~ ^[0-9]+$ && "$VOLUME_REMOVED" -gt 0 ]]; then
  OUTCOME="partial"
  REASON="cleanup_tmp skipped on scratch lock; volume reclaim removed ${VOLUME_REMOVED} artifacts"
elif [[ "$TMP_LOCK_SKIPPED" == true ]]; then
  OUTCOME="skipped_lock"
  REASON="scratch lock held"
elif [[ "$clean_flag" == "--dry-run" ]]; then
  OUTCOME="success_noop"
  REASON="dry-run sweep completed without deletions"
else
  OUTCOME="success"
  REASON="clean sweep completed"
fi

CHILD_RECEIPT="$(python3 "$RECEIPT_HELPER" read --job cleanup_tmp --last 2>/dev/null || true)"
CHILD_METRICS="$(python3 - "$CHILD_RECEIPT" "$OLD_CHILD_ID" "$CHILD_TRIGGER" <<'PY'
import json, sys
try:
    rec=json.loads(sys.argv[1])
except Exception:
    print("{}"); raise SystemExit
if not isinstance(rec,dict) or rec.get("id")==sys.argv[2] or rec.get("trigger")!=sys.argv[3]:
    print("{}"); raise SystemExit
c=rec.get("candidates") or {}
p=rec.get("postcondition") or {}
print(json.dumps({
    "removed_count": c.get("removed_count"),
    "deferred_count": c.get("deferred_count"),
    "interrupted_count": c.get("interrupted_count"),
    "df_delta_bytes": p.get("df_delta_bytes"),
},separators=(",",":")))
PY
)"
read -r REMOVED_COUNT DEFERRED_COUNT INTERRUPTED_COUNT CHILD_DELTA <<<"$(python3 - "$CHILD_METRICS" <<'PY'
import json,sys
try: x=json.loads(sys.argv[1])
except Exception: x={}
for k in ("removed_count","deferred_count","interrupted_count","df_delta_bytes"):
    v=x.get(k)
    print(v if isinstance(v,int) and not isinstance(v,bool) else "null", end=" ")
PY
)"
FREE_AFTER="$(_df_free_bytes)"
[[ "$FREE_AFTER" =~ ^[0-9]+$ ]] || FREE_AFTER=""
DF_DELTA="null"
FREED_BYTES="null"
if [[ -n "$FREE_BEFORE" && -n "$FREE_AFTER" ]]; then
  DF_DELTA=$(( FREE_AFTER - FREE_BEFORE ))
  FREED_BYTES=$(( DF_DELTA > 0 ? DF_DELTA : 0 ))
  # A dry-run or lock-skipped sweep deletes nothing, so any positive df delta is
  # unrelated system activity and must never be reported as reclaimed bytes.
  [[ "$clean_flag" == "--dry-run" || ( "$TMP_LOCK_SKIPPED" == true && "$VOLUME_REMOVED" != "null" && "$VOLUME_REMOVED" -eq 0 ) ]] && FREED_BYTES=0
fi
# Lock contention needs no child receipt, but wrapper df evidence is still required.
if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 && "$DF_DELTA" != null ]]; then
  REMOVED_COUNT=0
  DEFERRED_COUNT=0
  INTERRUPTED_COUNT=0
elif [[ "$REMOVED_COUNT" == null || "$DEFERRED_COUNT" == null || "$INTERRUPTED_COUNT" == null || "$DF_DELTA" == null ]]; then
  rc=1
  OUTCOME="error"
  REASON="adapter receipt or df postcondition unavailable"
  REMOVED_COUNT="${REMOVED_COUNT/null/0}"
  DEFERRED_COUNT="${DEFERRED_COUNT/null/0}"
  INTERRUPTED_COUNT="${INTERRUPTED_COUNT/null/0}"
elif [[ $rc -eq 0 && ( "$INTERRUPTED_COUNT" -gt 0 || "$DEFERRED_COUNT" -gt 0 || "$VOLUME_OUTCOME" == partial || "$VOLUME_TARGET" == False || "$VOLUME_TARGET" == false || "$VOLUME_BALLAST_FAILURES" != 0 ) ]]; then
  OUTCOME="partial"
  REASON="sweep completed with candidate deferrals, volume target unmet, or ballast restore failure"
fi

if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 && ( "$VOLUME_REMOVED" == "null" || "$VOLUME_REMOVED" -eq 0 ) ]]; then
  SAFETY='{"status": "not_applicable", "reason": "scratch_lock_contention_no_mutation", "delegated": false}'
elif [[ "$clean_flag" == "--dry-run" ]]; then
  SAFETY='{"status": "no_mutation", "reason": "dry-run sweep completed without deletions", "delegated": false}'
else
  SAFETY='{"status": "delegated", "reason": "delegated to cleanup_tmp, cleanup_claude_state, and quota volume reclaim", "delegated": true}'
fi
LOCK_ARGS=()
if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 ]]; then
  LOCK_ARGS=(--lock '{"held": true, "acquired": false, "reason": "scratch lock held"}')
fi
CANDIDATES="{\"count\":null,\"bytes\":null,\"removed_count\":${REMOVED_COUNT},\"deferred_count\":${DEFERRED_COUNT},\"interrupted_count\":${INTERRUPTED_COUNT},\"volume_aged_scanned\":${VOLUME_AGED},\"volume_removed\":${VOLUME_REMOVED},\"volume_target_reached\":${VOLUME_TARGET},\"volume_top_kept_reason\":${VOLUME_REASON_JSON},\"volume_ballast_restore_failures\":${VOLUME_BALLAST_FAILURES}}"
POSTCONDITION="{\"free_bytes_before\":${FREE_BEFORE:-null},\"free_bytes_after\":${FREE_AFTER:-null},\"df_delta_bytes\":${DF_DELTA},\"freed_bytes\":${FREED_BYTES}}"

if ! python3 "$RECEIPT_HELPER" finish --job tmp_scratch_sweep \
  --run-id "$RECEIPT_RUN_ID" \
  --outcome "$OUTCOME" \
  --reason "$REASON" \
  ${LOCK_ARGS[@]+"${LOCK_ARGS[@]}"} \
  --safety "$SAFETY" \
  --candidates "$CANDIDATES" \
  --postcondition "$POSTCONDITION"; then
  echo "[tmp_scratch_sweep] ERROR: failed to record receipt finish" >&2
  exit 1
fi

exit "$rc"

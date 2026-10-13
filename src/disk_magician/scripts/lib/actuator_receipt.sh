#!/usr/bin/env bash
# Shared terminal receipt support for atomic governed adapters.
actuator_receipt_begin() {
  local script_dir="$1" job="$2" state_dir="$3"
  ACTUATOR_RECEIPT_SCRIPT_DIR="$script_dir"
  ACTUATOR_RECEIPT_STATE_DIR="$state_dir"
  ACTUATOR_RECEIPT_JOB="$job"
  ACTUATOR_RECEIPT_RUN_ID="$(PYTHONPATH="$script_dir" python3 - "$state_dir" "$job" <<'PY'
import sys
from job_receipt import JobReceiptStore
print(JobReceiptStore(state_dir=sys.argv[1]).begin(sys.argv[2], trigger="act"))
PY
)" || return 1
  ACTUATOR_REMOVED_COUNT=0
  ACTUATOR_DEFERRED_COUNT=0
  ACTUATOR_INTERRUPTED_COUNT=0
  ACTUATOR_VACUUMED_COUNT=0
  ACTUATOR_OUTCOME=""
  ACTUATOR_REASON=""
  ACTUATOR_FREE_BEFORE="$(df -kP "$HOME" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}')"
  trap 'actuator_receipt_exit $?' EXIT
}
actuator_receipt_exit() {
  local rc="$1" outcome reason free_after delta freed
  trap - EXIT
  if [[ -z "${ACTUATOR_RECEIPT_RUN_ID:-}" ]]; then return "$rc"; fi
  outcome="${ACTUATOR_OUTCOME:-success}"
  reason="${ACTUATOR_REASON:-actuator_completed}"
  if (( rc != 0 )); then
    if [[ "$outcome" != error ]]; then outcome=error; fi
    [[ -n "${ACTUATOR_REASON:-}" ]] || reason="adapter_rc:$rc"
  fi
  if (( rc >= 128 )); then ACTUATOR_INTERRUPTED_COUNT=1; fi
  free_after="$(df -kP "$HOME" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}')"
  delta=null; freed=null
  if [[ "${ACTUATOR_FREE_BEFORE:-}" =~ ^[0-9]+$ && "$free_after" =~ ^[0-9]+$ ]]; then
    delta=$((free_after - ACTUATOR_FREE_BEFORE))
    (( delta > 0 )) && freed="$delta" || freed=0
  fi
  if ! PYTHONPATH="$ACTUATOR_RECEIPT_SCRIPT_DIR" python3 - "$ACTUATOR_RECEIPT_STATE_DIR" "$ACTUATOR_RECEIPT_JOB" "$ACTUATOR_RECEIPT_RUN_ID" "$outcome" "$reason" "$ACTUATOR_REMOVED_COUNT" "$ACTUATOR_DEFERRED_COUNT" "$ACTUATOR_INTERRUPTED_COUNT" "$ACTUATOR_VACUUMED_COUNT" "$delta" "$freed" <<'PY'
import sys
from job_receipt import JobReceiptStore
state,job,run,outcome,reason,removed,deferred,interrupted,vacuumed,delta,freed=sys.argv[1:]
post={"df_delta_bytes":None if delta=="null" else int(delta),
      "freed_bytes":None if freed=="null" else int(freed)}
JobReceiptStore(state_dir=state).finish(job, run_id=run, outcome=outcome, reason=reason,
    candidates={"removed_count":int(removed),"deferred_count":int(deferred),
                "interrupted_count":int(interrupted),"vacuumed_count":int(vacuumed)},
    postcondition=post)
PY
  then
    [[ "$rc" != 0 ]] || rc=3
  fi
  return "$rc"
}

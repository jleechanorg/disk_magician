#!/usr/bin/env bash
# tmp_scratch_sweep.sh — hourly tmp-scratch job entry point (bead disk_magician-isw
# scheduling gap). Wraps cleanup_tmp.sh (--large, under LARGE_TMP_APPROVED=1
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
    env LARGE_TMP_APPROVED=1 DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large ${governor_args[@]+"${governor_args[@]}"} || tmp_rc=$?
  else
    env LARGE_TMP_APPROVED=1 DISK_MAGICIAN_RECEIPT_TRIGGER="$CHILD_TRIGGER" "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large || tmp_rc=$?
  fi
  if [[ $tmp_rc -eq 75 ]]; then
    TMP_LOCK_SKIPPED=true
  elif [[ $tmp_rc -ne 0 ]]; then
    rc=1
  fi
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
else
  run_cleanup_tmp --dry-run --large || tmp_rc=$?
  if [[ $tmp_rc -eq 75 ]]; then
    TMP_LOCK_SKIPPED=true
  elif [[ $tmp_rc -ne 0 ]]; then
    rc=1
  fi
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
fi

if [[ $rc -ne 0 ]]; then
  OUTCOME="error"
  REASON="one or more sweep steps failed"
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
  [[ "$clean_flag" == "--dry-run" || "$TMP_LOCK_SKIPPED" == true ]] && FREED_BYTES=0
fi
if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 ]]; then
  REMOVED_COUNT=0
  DEFERRED_COUNT=0
  INTERRUPTED_COUNT=0
elif [[ "$REMOVED_COUNT" == null || "$DEFERRED_COUNT" == null || "$INTERRUPTED_COUNT" == null || "$DF_DELTA" == null ]]; then
  OUTCOME="error"
  REASON="adapter receipt or df postcondition unavailable"
  REMOVED_COUNT="${REMOVED_COUNT/null/0}"
  DEFERRED_COUNT="${DEFERRED_COUNT/null/0}"
  INTERRUPTED_COUNT="${INTERRUPTED_COUNT/null/0}"
elif [[ "$INTERRUPTED_COUNT" -gt 0 || "$DEFERRED_COUNT" -gt 0 ]]; then
  OUTCOME="partial"
  REASON="sweep completed with candidate deferrals or interruptions"
fi

if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 ]]; then
  SAFETY='{"status": "not_applicable", "reason": "scratch_lock_contention_no_mutation", "delegated": false}'
elif [[ "$clean_flag" == "--dry-run" ]]; then
  SAFETY='{"status": "no_mutation", "reason": "dry-run sweep completed without deletions", "delegated": false}'
else
  SAFETY='{"status": "delegated", "reason": "delegated to cleanup_tmp and cleanup_claude_state", "delegated": true}'
fi
LOCK_ARGS=()
if [[ "$TMP_LOCK_SKIPPED" == true && $rc -eq 0 ]]; then
  LOCK_ARGS=(--lock '{"held": true, "acquired": false, "reason": "scratch lock held"}')
fi
CANDIDATES="{\"count\":null,\"bytes\":null,\"removed_count\":${REMOVED_COUNT},\"deferred_count\":${DEFERRED_COUNT},\"interrupted_count\":${INTERRUPTED_COUNT}}"
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

#!/usr/bin/env bash
# tmp_scratch_sweep.sh — hourly tmp-scratch job entry point (bead disk_magician-isw
# scheduling gap). Wraps cleanup_tmp.sh (--large) then cleanup_claude_state.sh,
# each with its own explicit *_APPROVED=1 gate, failure-continuing between steps
# but propagating a nonzero exit if either step failed, so an unattended launchd
# job doesn't silently look healthy when cleanup is broken (round-1 /advice
# finding: Codex + Opus both flagged a hardcoded `exit 0` masking failures).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clean_flag="${1:---dry-run}"

RECEIPT_HELPER="${DISK_MAGICIAN_RECEIPT_HELPER:-$SCRIPT_DIR/job_receipt.py}"

# Record started before work
TRIGGER="${clean_flag#--}"
RECEIPT_RUN_ID=$(python3 "$RECEIPT_HELPER" begin --job tmp_scratch_sweep --trigger "$TRIGGER") || {
  echo "[tmp_scratch_sweep] ERROR: failed to record receipt begin" >&2
  exit 1
}

rc=0
if [[ "$clean_flag" == "--clean" ]]; then
  env LARGE_TMP_APPROVED=1 "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large || rc=1
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
else
  "$SCRIPT_DIR/cleanup_tmp.sh" --dry-run --large || rc=1
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
fi

if [[ $rc -ne 0 ]]; then
  OUTCOME="error"
  REASON="one or more sweep steps failed"
elif [[ "$clean_flag" == "--dry-run" ]]; then
  OUTCOME="success_noop"
  REASON="dry-run sweep completed without deletions"
else
  OUTCOME="success"
  REASON="clean sweep completed"
fi

if [[ "$clean_flag" == "--dry-run" ]]; then
  SAFETY='{"status": "no_mutation", "reason": "dry-run sweep completed without deletions", "delegated": false}'
else
  SAFETY='{"status": "delegated", "reason": "delegated to cleanup_tmp and cleanup_claude_state", "delegated": true}'
fi
CANDIDATES='{"count": null, "bytes": null}'
POSTCONDITION='{"freed_bytes": null}'

if ! python3 "$RECEIPT_HELPER" finish --job tmp_scratch_sweep \
  --run-id "$RECEIPT_RUN_ID" \
  --outcome "$OUTCOME" \
  --reason "$REASON" \
  --safety "$SAFETY" \
  --candidates "$CANDIDATES" \
  --postcondition "$POSTCONDITION"; then
  echo "[tmp_scratch_sweep] ERROR: failed to record receipt finish" >&2
  exit 1
fi

exit "$rc"

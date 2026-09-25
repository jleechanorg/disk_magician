#!/usr/bin/env bash
# tmp_scratch_sweep.sh — hourly tmp-scratch job entry point (bead disk_magician-isw
# scheduling gap). Wraps cleanup_tmp.sh (--large) then cleanup_claude_state.sh,
# each with its own explicit *_APPROVED=1 gate, failure-continuing between steps.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clean_flag="${1:---dry-run}"

if [[ "$clean_flag" == "--clean" ]]; then
  env LARGE_TMP_APPROVED=1 "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large
  env CLAUDE_STATE_APPROVED=1 "$SCRIPT_DIR/cleanup_claude_state.sh" --clean
else
  "$SCRIPT_DIR/cleanup_tmp.sh" --dry-run --large
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run
fi
exit 0

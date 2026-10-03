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
clean_flag="${1:---dry-run}"

rc=0
if [[ "$clean_flag" == "--clean" ]]; then
  env LARGE_TMP_APPROVED=1 "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large || rc=1
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
else
  "$SCRIPT_DIR/cleanup_tmp.sh" --dry-run --large || rc=1
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
fi
exit "$rc"

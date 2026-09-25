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

rc=0
if [[ "$clean_flag" == "--clean" ]]; then
  env LARGE_TMP_APPROVED=1 "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large || rc=1
  env CLAUDE_STATE_APPROVED=1 "$SCRIPT_DIR/cleanup_claude_state.sh" --clean || rc=1
else
  "$SCRIPT_DIR/cleanup_tmp.sh" --dry-run --large || rc=1
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || rc=1
fi
exit "$rc"

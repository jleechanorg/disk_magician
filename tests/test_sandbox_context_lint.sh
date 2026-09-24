#!/usr/bin/env bash
# test_sandbox_context_lint.sh — guard test (bead disk_magician-lsl /
# PR #71 /advice HOLD, Codex + Opus): any tests/*.sh file that resolves a
# script variable to cleanup_tmp.sh, cleanup_pr_scratch.sh, or
# pressure_sweep.sh AND invokes it with a destructive flag (--clean,
# --large, or --budget*) must also reference BOTH DISK_MAGICIAN_TEST_CONTEXT
# and DISK_MAGICIAN_TEST_SANDBOX somewhere in the same file. Without both,
# scripts/safety_lib.sh's sandbox_guard_roots() has nothing to confine
# destructive roots to, and a forgotten sandbox degrades from "test bug" to
# "runs against the real host" silently — see tests/lib/sandbox_env.sh for
# the pattern this enforces.
#
# This is a file-level check (both markers appear somewhere in the file),
# not a per-line linkage check: a file may legitimately confine roots via a
# CLI flag (cleanup_pr_scratch.sh's --tmp-dir) as its primary mechanism and
# carry DISK_MAGICIAN_TEST_SANDBOX as the mandated backstop.
#
# Run: bash tests/test_sandbox_context_lint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

# invokes_destructive_script <file> — true if the file both (a) points a
# shell variable at one of the target scripts and (b) invokes that variable
# with a destructive flag.
invokes_destructive_script() {
  local f="$1"
  grep -Eq '=.*"?\$\{?REPO_ROOT\}?"?/scripts/(cleanup_tmp\.sh|cleanup_pr_scratch\.sh|pressure_sweep\.sh)"?$' "$f" || return 1
  grep -Eq 'bash "\$[A-Za-z_]+"[^#]*--(clean|large|budget)' "$f"
}

while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [[ "$base" == "$SELF" ]] && continue
  if invokes_destructive_script "$f"; then
    missing=()
    grep -q 'DISK_MAGICIAN_TEST_CONTEXT' "$f" || missing+=("DISK_MAGICIAN_TEST_CONTEXT")
    grep -q 'DISK_MAGICIAN_TEST_SANDBOX' "$f" || missing+=("DISK_MAGICIAN_TEST_SANDBOX")
    if [[ "${#missing[@]}" -eq 0 ]]; then
      record_pass "$base: destructive invocation carries both sandbox env vars"
    else
      record_fail "$base: invokes a destructive cleanup path without: ${missing[*]} (see tests/lib/sandbox_env.sh)"
    fi
  fi
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.sh' -print0)

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

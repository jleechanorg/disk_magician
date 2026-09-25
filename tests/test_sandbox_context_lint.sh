#!/usr/bin/env bash
# test_sandbox_context_lint.sh — guard test (bead disk_magician-lsl /
# PR #71 /advice HOLD, Codex + Opus; extended twice more after PR #78's own
# /advice rounds: round 1 found this lint was shell-only and missed a
# Python destructive caller; round 2 found it only recognized the three CLI
# script names and missed direct scratch_budget_evict_root() library
# calls). Any tests/*.sh or tests/*.py file that either (a) resolves a
# script variable to cleanup_tmp.sh, cleanup_pr_scratch.sh, or
# pressure_sweep.sh and invokes it with a destructive flag (--clean,
# --apply, --large, or --budget*), or (b) sources scripts/lib/
# scratch_budget.sh and calls scratch_budget_evict_root() directly, must
# also reference BOTH DISK_MAGICIAN_TEST_CONTEXT and
# DISK_MAGICIAN_TEST_SANDBOX somewhere in the same file. Without both,
# scripts/safety_lib.sh's sandbox_guard_roots() has nothing to confine
# destructive roots to, and a forgotten sandbox degrades from "test bug" to
# "runs against the real host" silently — see tests/lib/sandbox_env.sh for
# the shell pattern this enforces (Python tests set the two env vars
# directly, e.g. tests/test_cleanup_pr_scratch.py's _run_script()).
#
# This is a file-level check (both markers appear somewhere in the file),
# not a per-line linkage check: a file may legitimately confine roots via a
# CLI flag (cleanup_pr_scratch.sh's --tmp-dir) as its primary mechanism and
# carry the mandated sandbox vars as the backstop.
#
# Run: bash tests/test_sandbox_context_lint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

# invokes_destructive_script_sh <file> — true if a shell test both (a)
# points a shell variable at one of the target scripts and (b) invokes that
# variable with a destructive flag.
invokes_destructive_script_sh() {
  local f="$1"
  grep -Eq '=.*"?\$\{?REPO_ROOT\}?"?/scripts/(cleanup_tmp\.sh|cleanup_pr_scratch\.sh|pressure_sweep\.sh)"?$' "$f" || return 1
  grep -Eq 'bash "\$[A-Za-z_]+"[^#]*--(clean|apply|large|budget)' "$f"
}

# invokes_destructive_library_call <file> — true if a shell test sources
# scripts/lib/scratch_budget.sh AND calls scratch_budget_evict_root()
# directly (bypassing the cleanup_tmp.sh/cleanup_pr_scratch.sh CLI entirely,
# e.g. tests/test_scratch_budget.sh's run_budget() harness). tests/lib/
# sandbox_env.sh names scratch_budget_evict_root as a covered destructive
# path (PR #78 /advice round 2, Codex) -- this closes the gap where the
# first two checks only recognized the three CLI script names.
invokes_destructive_library_call() {
  local f="$1"
  grep -Eq 'scripts/lib/scratch_budget\.sh' "$f" || return 1
  grep -Eq 'scratch_budget_evict_root' "$f"
}

# invokes_destructive_script_py <file> — true if a Python test both (a)
# names one of the target scripts (by basename, however the path is built)
# and (b) passes a destructive flag as a literal CLI argument.
invokes_destructive_script_py() {
  local f="$1"
  grep -Eq '"(cleanup_tmp|cleanup_pr_scratch|pressure_sweep)\.sh"' "$f" || return 1
  grep -Eq '"--(clean|apply|large|budget[a-zA-Z_-]*)"' "$f"
}

check_file() {
  local f="$1" base
  base="$(basename "$f")"
  local missing=()
  grep -q 'DISK_MAGICIAN_TEST_CONTEXT' "$f" || missing+=("DISK_MAGICIAN_TEST_CONTEXT")
  grep -q 'DISK_MAGICIAN_TEST_SANDBOX' "$f" || missing+=("DISK_MAGICIAN_TEST_SANDBOX")
  if [[ "${#missing[@]}" -eq 0 ]]; then
    record_pass "$base: destructive invocation carries both sandbox env vars"
  else
    record_fail "$base: invokes a destructive cleanup path without: ${missing[*]} (see tests/lib/sandbox_env.sh)"
  fi
}

while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  [[ "$base" == "$SELF" ]] && continue
  if invokes_destructive_script_sh "$f" || invokes_destructive_library_call "$f"; then
    check_file "$f"
  fi
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.sh' -print0)

while IFS= read -r -d '' f; do
  invokes_destructive_script_py "$f" && check_file "$f"
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'test_*.py' -print0)

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

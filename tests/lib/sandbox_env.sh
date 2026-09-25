# shellcheck shell=bash
# sandbox_env.sh — shared marker for tests that invoke a destructive cleanup
# path (cleanup_tmp.sh --clean/--large/--budget-gb, cleanup_pr_scratch.sh
# --clean, pressure_sweep.sh, or scripts/lib/scratch_budget.sh's
# scratch_budget_evict_root).
#
# Bead disk_magician-lsl / PR #71 /advice HOLD (Codex + Opus): the sandbox
# guard (scripts/safety_lib.sh:sandbox_guard_roots) used to be purely
# opt-in, so a test that forgot to set DISK_MAGICIAN_TEST_SANDBOX ran
# unconfined against real production roots. sandbox_guard_roots now treats
# DISK_MAGICIAN_TEST_CONTEXT=1 as a promise that IS enforced: if it's set
# with no DISK_MAGICIAN_TEST_SANDBOX, the guard aborts (rc=90) before any
# deletion instead of silently passing through.
#
# Source this file, then export both vars on every destructive invocation:
#   source "$SCRIPT_DIR/lib/sandbox_env.sh"
#   DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
#   DISK_MAGICIAN_TEST_SANDBOX="$MY_FIXTURE_ROOT" \
#   bash "$SOURCE_SCRIPT" --clean --large
#
# tests/test_sandbox_context_lint.sh greps tests/*.sh for exactly this
# pattern and fails the suite if a destructive invocation is found without
# both vars present in the same file.
DISK_MAGICIAN_TEST_CONTEXT=1

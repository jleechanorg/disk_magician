#!/usr/bin/env bash
# test_disk_diagnostic_scratch.sh — proves disk_diagnostic.sh allocates WORK via
# agent_scratch_create under managed root and cleans up on completion and failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/disk_diagnostic.sh"

# Source sandbox environment marker
# shellcheck source=tests/lib/sandbox_env.sh
source "$REPO_ROOT/tests/lib/sandbox_env.sh"

WORK="$(mktemp -d -t disk_diagnostic_scratch_test.XXXXXX)"
export AGENT_SCRATCH_ROOT="$WORK/scratch"
export DISK_MAGICIAN_TEST_SANDBOX="$WORK"
export DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT"
mkdir -p "$AGENT_SCRATCH_ROOT" "$WORK/home"

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "── 1. Static contract checks on scripts/disk_diagnostic.sh ──"
if grep -q 'mktemp -d -t disk_diagnostic' "$TARGET"; then
  record_fail "disk_diagnostic.sh still allocates WORK via bare mktemp"
else
  record_pass "disk_diagnostic.sh no longer uses bare mktemp for WORK"
fi

if grep -q 'agent_scratch_create "disk_diagnostic"' "$TARGET"; then
  record_pass "disk_diagnostic.sh calls agent_scratch_create with runtime=disk_diagnostic"
else
  record_fail "disk_diagnostic.sh does not call agent_scratch_create with runtime=disk_diagnostic"
fi

if grep -q 'agent_scratch_trap_cleanup' "$TARGET"; then
  record_pass "disk_diagnostic.sh calls agent_scratch_trap_cleanup"
else
  record_fail "disk_diagnostic.sh does not call agent_scratch_trap_cleanup"
fi

# Ensure explicit || exit guards are present on allocation and trap arming
if grep -E 'agent_scratch_create.*\|\| exit' "$TARGET" &&
   grep -E 'agent_scratch_trap_cleanup.*\|\| exit' "$TARGET"; then
  record_pass "disk_diagnostic.sh guards scratch allocation and arming with explicit || exit"
else
  record_fail "disk_diagnostic.sh lacks explicit || exit guard on scratch allocation/arming"
fi

echo "── 2. Dynamic execution with fixture stubs ──"
TREE="$WORK/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/config"
cp "$REPO_ROOT/scripts/disk_diagnostic.sh" "$TREE/scripts/"
cp "$REPO_ROOT/scripts/safety_lib.sh" "$TREE/scripts/"
if [[ -f "$REPO_ROOT/scripts/lib/agent_scratch.sh" ]]; then
  cp "$REPO_ROOT/scripts/lib/agent_scratch.sh" "$TREE/scripts/lib/"
fi
if [[ -f "$REPO_ROOT/safety.local.json.template" ]]; then
  cp "$REPO_ROOT/safety.local.json.template" "$TREE/"
fi

# Create mock stubs for the three lanes
cat > "$TREE/scripts/disk_frontier_scan.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
out = sys.argv[sys.argv.index("--output") + 1]
# Write a probe file indicating the scratch directory path
probe = os.environ.get("PROBE_SCRATCH_CAPTURE", "")
if probe:
    with open(probe, "w") as fh:
        fh.write(os.path.dirname(out))
gib = 1024 * 1024
data = {
  "mode": "partial", "disk_total_kb": 20*gib, "disk_used_kb": 10*gib,
  "disk_free_kb": 10*gib, "measured_total_kb": 6*gib,
  "purgeable_kb": 0, "residual_kb": 4*gib,
  "granularity_buckets": [
    {"path": "/fixture/test", "measured_kb": 3*gib}
  ],
  "granularity_bucket_total_kb": 3*gib, "granularity_tail_kb": 0,
  "sibling_volumes": {}, "frontier_unfinished": [],
  "accounting_equation": {"balanced": True, "displayed_balanced": True, "displayed_buckets_kb": 3*gib, "sub_granularity_tail_kb": 0},
  "config": {"max_nodes": 100, "scan_backend": "gdu_one_pass"},
  "apfs_accounting": {
    "physical_stores": [{"device": "disk0s2", "size_kb": 20*gib}],
    "container_capacity_kb": 20*gib, "container_free_kb": 10*gib,
    "volume_allocations_kb": 10*gib, "shared_allocation_kb": 0,
    "equation_balanced": True,
    "volumes": [{"name": "Data", "roles": ["Data"], "capacity_in_use_kb": 10*gib}],
  },
  "limits": {"sudo_used": False, "full_disk_access": "not_inferred"},
}
with open(out, "w") as fh:
    json.dump(data, fh)
PY
chmod +x "$TREE/scripts/disk_frontier_scan.py"

cat > "$TREE/scripts/disk_history.sh" <<'SH'
#!/usr/bin/env bash
echo "SNAPSHOT_DELTA_STUB"
SH
chmod +x "$TREE/scripts/disk_history.sh"

cat > "$TREE/scripts/disk_audit.sh" <<'SH'
#!/usr/bin/env bash
echo "QUICK_WIN_STUB"
SH
chmod +x "$TREE/scripts/disk_audit.sh"

cat > "$TREE/scripts/worktree_hygiene.sh" <<'SH'
#!/usr/bin/env bash
echo "WORKTREE_STUB"
SH
chmod +x "$TREE/scripts/worktree_hygiene.sh"

PROBE_FILE="$WORK/work_path.txt"
RUN_OUT="$WORK/run_out.txt"

HOME="$WORK/home" \
  PROBE_SCRATCH_CAPTURE="$PROBE_FILE" \
  AGENT_SCRATCH_ROOT="$AGENT_SCRATCH_ROOT" \
  DISK_MAGICIAN_TEST_SANDBOX="$WORK" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TOPDOWN_BUDGET_SECONDS=5 \
  /bin/bash "$TREE/scripts/disk_diagnostic.sh" >"$RUN_OUT" 2>&1
run_rc=$?

if [[ "$run_rc" -eq 0 ]]; then
  record_pass "diagnostic completed successfully with stubs"
else
  record_fail "diagnostic failed (rc=$run_rc): $(cat "$RUN_OUT")"
fi

allocated_scratch="$(cat "$PROBE_FILE" 2>/dev/null || true)"
if [[ -n "$allocated_scratch" && "$allocated_scratch" == "$AGENT_SCRATCH_ROOT/disk_diagnostic/"* ]]; then
  record_pass "allocated work path is strictly under $AGENT_SCRATCH_ROOT/disk_diagnostic/"
else
  record_fail "allocated work path was not under expected root: '$allocated_scratch'"
fi

if [[ -n "$allocated_scratch" && ! -d "$allocated_scratch" ]]; then
  record_pass "work directory was automatically cleaned up after successful execution"
else
  record_fail "work directory remained after successful execution: '$allocated_scratch'"
fi

echo "── 3. Failure path cleanup ──"
# Inject failure into scanner
cat > "$TREE/scripts/disk_frontier_scan.py" <<'PY'
#!/usr/bin/env python3
import os, sys
out = sys.argv[sys.argv.index("--output") + 1]
probe = os.environ.get("PROBE_SCRATCH_CAPTURE", "")
if probe:
    with open(probe, "w") as fh:
        fh.write(os.path.dirname(out))
sys.exit(3)
PY
chmod +x "$TREE/scripts/disk_frontier_scan.py"

FAIL_PROBE="$WORK/fail_work_path.txt"
FAIL_OUT="$WORK/fail_run_out.txt"

HOME="$WORK/home" \
  PROBE_SCRATCH_CAPTURE="$FAIL_PROBE" \
  AGENT_SCRATCH_ROOT="$AGENT_SCRATCH_ROOT" \
  DISK_MAGICIAN_TEST_SANDBOX="$WORK" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TOPDOWN_BUDGET_SECONDS=5 \
  /bin/bash "$TREE/scripts/disk_diagnostic.sh" >"$FAIL_OUT" 2>&1
fail_rc=$?

if [[ "$fail_rc" -ne 0 ]]; then
  record_pass "diagnostic exited nonzero on lane failure as expected"
else
  record_fail "diagnostic unexpectedly succeeded despite lane failure"
fi

fail_scratch="$(cat "$FAIL_PROBE" 2>/dev/null || true)"
if [[ -n "$fail_scratch" && "$fail_scratch" == "$AGENT_SCRATCH_ROOT/disk_diagnostic/"* ]]; then
  record_pass "failure path allocated work path under managed root"
else
  record_fail "failure path allocated unexpected work path: '$fail_scratch'"
fi

if [[ -n "$fail_scratch" && ! -d "$fail_scratch" ]]; then
  record_pass "work directory was cleaned up on failure exit"
else
  record_fail "work directory remained after failure exit: '$fail_scratch'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All disk_diagnostic_scratch tests passed."

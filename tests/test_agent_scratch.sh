#!/usr/bin/env bash
# test_agent_scratch.sh — Comprehensive tests for scripts/lib/agent_scratch.sh
# Tests Bash 3.2 compatibility, signal handling, trap preservation, and containment.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/agent_scratch.sh"

# Source sandbox environment marker
# shellcheck source=tests/lib/sandbox_env.sh
source "$REPO_ROOT/tests/lib/sandbox_env.sh"

FAKE_ROOT="$(mktemp -d -t agent_scratch_test.XXXXXX)"
export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
export DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT"

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; FAIL=$(( FAIL + 1 )); }

cleanup_test_env() {
  rm -rf "$FAKE_ROOT"
}
trap cleanup_test_env EXIT

echo "── 1. Library loading and creation tests ──"
if [[ ! -f "$LIB" ]]; then
  echo "Library missing: $LIB"
  record_fail "library exists"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# shellcheck source=scripts/lib/agent_scratch.sh
source "$LIB"

path=$(agent_scratch_create "testruntime" "run123")
if [[ -d "$path" ]]; then
  record_pass "scratch dir created"
else
  record_fail "scratch dir not created"
fi

if [[ "$path" == "$FAKE_ROOT/testruntime/run123" ]]; then
  record_pass "correct path shape"
else
  record_fail "wrong path shape: $path"
fi

echo "── 2. Input validation rejections ──"
if agent_scratch_create "" "run123" 2>/dev/null; then
  record_fail "empty runtime accepted"
else
  record_pass "empty runtime rejected"
fi

if agent_scratch_create "testruntime" "" 2>/dev/null; then
  record_fail "empty run-id accepted"
else
  record_pass "empty run-id rejected"
fi

if agent_scratch_create "testruntime" "../escape" 2>/dev/null; then
  record_fail "traversal in run-id accepted"
else
  record_pass "traversal in run-id rejected"
fi

if agent_scratch_create "../escape" "run123" 2>/dev/null; then
  record_fail "traversal in runtime accepted"
else
  record_pass "traversal in runtime rejected"
fi

if agent_scratch_create "testruntime" "/abs" 2>/dev/null; then
  record_fail "absolute run-id accepted"
else
  record_pass "absolute run-id rejected"
fi

if agent_scratch_create "test/sub" "run123" 2>/dev/null; then
  record_fail "multi-component runtime accepted"
else
  record_pass "multi-component runtime rejected"
fi

if agent_scratch_create "testruntime" "run/sub" 2>/dev/null; then
  record_fail "multi-component run-id accepted"
else
  record_pass "multi-component run-id rejected"
fi

echo "── 3. Refuse existing run leaf (atomic mkdir) ──"
if agent_scratch_create "testruntime" "run123" 2>/dev/null; then
  record_fail "duplicate run leaf accepted"
else
  record_pass "duplicate run leaf refused (atomic creation)"
fi

echo "── 4. Trap cleanup and status preservation on EXIT ──"
(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_CONTEXT=1
  trap 'echo caller-trap-ran > "'"$FAKE_ROOT"'/caller_trap_marker"' EXIT
  agent_scratch_trap_cleanup "$path"
  exit 0
)
if [[ -f "$FAKE_ROOT/caller_trap_marker" ]]; then
  record_pass "caller own EXIT trap still ran"
else
  record_fail "caller own EXIT trap was overwritten"
fi

if [[ ! -d "$path" ]]; then
  record_pass "trap cleanup removed the scratch dir"
else
  record_fail "trap cleanup did not remove the scratch dir"
fi

# Nonzero exit status preservation
path_nonzero=$(agent_scratch_create "testruntime" "run_nonzero")
sub_status=0
(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_CONTEXT=1
  trap 'echo caller-saw-$? > "'"$FAKE_ROOT"'/status_marker"' EXIT
  agent_scratch_trap_cleanup "$path_nonzero"
  exit 7
) || sub_status=$?

if [[ "$sub_status" -eq 7 ]]; then
  record_pass "subshell preserved exit status 7"
else
  record_fail "subshell exit status was $sub_status (expected 7)"
fi

if grep -q "caller-saw-7" "$FAKE_ROOT/status_marker" 2>/dev/null; then
  record_pass "caller trap received original nonzero \$?"
else
  record_fail "caller trap did not receive original nonzero \$?"
fi

if [[ ! -d "$path_nonzero" ]]; then
  record_pass "scratch dir removed on nonzero exit"
else
  record_fail "scratch dir remained after nonzero exit"
fi

echo "── 5. Signal handling (INT/TERM) and terminating behavior ──"
# INT signal test via real foreground Python subprocess
path_int=$(agent_scratch_create "testruntime" "run_int")
python3 - "$LIB" "$FAKE_ROOT" "$path_int" <<PY
import os, signal, subprocess, sys

lib = sys.argv[1]
fake_root = sys.argv[2]
path_int = sys.argv[3]

code = f"""
export AGENT_SCRATCH_ROOT="{fake_root}"
export DISK_MAGICIAN_TEST_SANDBOX="{fake_root}"
export DISK_MAGICIAN_TEST_CONTEXT=1
source "{lib}"
trap 'echo int-trap-ran > "{fake_root}/int_marker"' INT
trap 'echo exit-trap-ran > "{fake_root}/exit_marker"' EXIT
agent_scratch_trap_cleanup "{path_int}"
echo READY
while true; do sleep 0.1; done
echo UNREACHABLE > "{fake_root}/unreachable_int"
"""

proc = subprocess.Popen(["/bin/bash", "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
line = proc.stdout.readline()
if "READY" not in line:
    sys.exit(10)
proc.send_signal(signal.SIGINT)
stdout, stderr = proc.communicate(timeout=5)
# Returncode should indicate termination by SIGINT (-2 in Python)
if proc.returncode != -signal.SIGINT and proc.returncode != 130:
    sys.exit(11)
PY
int_rc=$?

if [[ "$int_rc" -eq 0 && -f "$FAKE_ROOT/int_marker" ]]; then
  record_pass "caller own INT trap ran on SIGINT"
else
  record_fail "caller own INT trap did not run on SIGINT (int_rc=$int_rc)"
fi

if [[ ! -d "$path_int" ]]; then
  record_pass "scratch dir removed on SIGINT"
else
  record_fail "scratch dir remained after SIGINT"
fi

if [[ -f "$FAKE_ROOT/unreachable_int" ]]; then
  record_fail "execution continued after SIGINT (swallowed signal)"
else
  record_pass "process terminated on SIGINT (re-raised signal)"
fi

# TERM signal test via real foreground Python subprocess
path_term=$(agent_scratch_create "testruntime" "run_term")
python3 - "$LIB" "$FAKE_ROOT" "$path_term" <<PY
import os, signal, subprocess, sys

lib = sys.argv[1]
fake_root = sys.argv[2]
path_term = sys.argv[3]

code = f"""
export AGENT_SCRATCH_ROOT="{fake_root}"
export DISK_MAGICIAN_TEST_SANDBOX="{fake_root}"
export DISK_MAGICIAN_TEST_CONTEXT=1
source "{lib}"
trap 'echo term-trap-ran > "{fake_root}/term_marker"' TERM
agent_scratch_trap_cleanup "{path_term}"
echo READY
while true; do sleep 0.1; done
echo UNREACHABLE > "{fake_root}/unreachable_term"
"""

proc = subprocess.Popen(["/bin/bash", "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
line = proc.stdout.readline()
if "READY" not in line:
    sys.exit(10)
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=5)
if proc.returncode != -signal.SIGTERM and proc.returncode != 143:
    sys.exit(11)
PY
term_rc=$?

if [[ "$term_rc" -eq 0 && -f "$FAKE_ROOT/term_marker" ]]; then
  record_pass "caller own TERM trap ran on SIGTERM"
else
  record_fail "caller own TERM trap did not run on SIGTERM (term_rc=$term_rc)"
fi

if [[ ! -d "$path_term" ]]; then
  record_pass "scratch dir removed on SIGTERM"
else
  record_fail "scratch dir remained after SIGTERM"
fi

if [[ -f "$FAKE_ROOT/unreachable_term" ]]; then
  record_fail "execution continued after SIGTERM"
else
  record_pass "process terminated on SIGTERM"
fi

echo "── 6. Containment and arming guard checks ──"
outside_dir="$(mktemp -d -t agent_scratch_outside.XXXXXX)"
if (AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$outside_dir" 2>/dev/null); then
  record_fail "trap_cleanup accepted a path outside AGENT_SCRATCH_ROOT"
else
  record_pass "trap_cleanup rejects a path outside AGENT_SCRATCH_ROOT"
fi
[[ -d "$outside_dir" ]] && record_pass "outside dir was not deleted" || record_fail "outside dir was deleted"
rm -rf "$outside_dir"

if (AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$FAKE_ROOT" 2>/dev/null); then
  record_fail "trap_cleanup accepted AGENT_SCRATCH_ROOT itself"
else
  record_pass "trap_cleanup rejects AGENT_SCRATCH_ROOT itself"
fi

mkdir -p "$FAKE_ROOT/bareruntime"
if (AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$FAKE_ROOT/bareruntime" 2>/dev/null); then
  record_fail "trap_cleanup accepted bare runtime dir"
else
  record_pass "trap_cleanup rejects bare runtime dir"
fi

mkdir -p "$FAKE_ROOT/testruntime/deep/nested"
if (AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$FAKE_ROOT/testruntime/deep/nested" 2>/dev/null); then
  record_fail "trap_cleanup accepted nested deeper path"
else
  record_pass "trap_cleanup rejects nested deeper path"
fi

# Arming refusal must not overwrite caller traps
(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  trap 'echo caller-refusal-trap-ran > "'"$FAKE_ROOT"'/refusal_marker"' EXIT
  agent_scratch_trap_cleanup "$FAKE_ROOT" 2>/dev/null || true
  exit 0
)
if [[ -f "$FAKE_ROOT/refusal_marker" ]]; then
  record_pass "arming refusal preserved caller trap"
else
  record_fail "arming refusal overwrote caller trap"
fi

echo "── 7. Leaf containing single quote ──"
quote_leaf=$(agent_scratch_create "testruntime" "run_quote")
mv "$quote_leaf" "${quote_leaf}o'clock" 2>/dev/null || true
if [[ -d "${quote_leaf}o'clock" ]]; then
  (
    export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
    export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
    export DISK_MAGICIAN_TEST_CONTEXT=1
    trap 'true' EXIT
    agent_scratch_trap_cleanup "${quote_leaf}o'clock"
    exit 0
  )
  if [[ ! -d "${quote_leaf}o'clock" ]]; then
    record_pass "trap_cleanup removes leaf containing single quote"
  else
    record_fail "trap_cleanup left leaf containing single quote"
  fi
else
  record_fail "filesystem setup could not rename quote path"
fi

echo "── 8. Cleanup-time safety: symlink swap and git preservation ──"
# Swapped symlink test
symlink_leaf="$FAKE_ROOT/testruntime/run_symlink"
mkdir -p "$symlink_leaf"
victim_dir="$FAKE_ROOT/victim"
mkdir -p "$victim_dir"
touch "$victim_dir/important_file"

(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_CONTEXT=1
  agent_scratch_trap_cleanup "$symlink_leaf"
  # Attacker swaps leaf for symlink pointing to victim_dir before exit
  rmdir "$symlink_leaf"
  ln -s "$victim_dir" "$symlink_leaf"
  exit 0
)

if [[ -f "$victim_dir/important_file" ]]; then
  record_pass "swapped symlink target was protected from deletion"
else
  record_fail "swapped symlink target was deleted"
fi
rm -rf "$symlink_leaf" "$victim_dir"

# Git repository protection
git_leaf=$(agent_scratch_create "testruntime" "run_git")
mkdir -p "$git_leaf/nested_repo/.git"
touch "$git_leaf/nested_repo/.git/config"
(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_CONTEXT=1
  agent_scratch_trap_cleanup "$git_leaf"
  exit 0
) 2>/dev/null || true

if [[ -d "$git_leaf" ]]; then
  record_pass "leaf containing nested .git repo was preserved"
  # clean up manually for test hygiene
  rm -rf "$git_leaf"
else
  record_fail "leaf containing nested .git repo was deleted"
fi

# Multiple unrelated leaves untouched
leaf_a=$(agent_scratch_create "testruntime" "run_a")
leaf_b=$(agent_scratch_create "testruntime" "run_b")
(
  export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_SANDBOX="$FAKE_ROOT"
  export DISK_MAGICIAN_TEST_CONTEXT=1
  agent_scratch_trap_cleanup "$leaf_a"
  exit 0
)
if [[ ! -d "$leaf_a" && -d "$leaf_b" ]]; then
  record_pass "cleanup removed target leaf and left unrelated leaf untouched"
else
  record_fail "unrelated leaf was deleted or target leaf was not deleted"
fi
rm -rf "$leaf_b"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
echo "All agent_scratch tests passed."

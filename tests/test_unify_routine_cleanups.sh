#!/bin/bash
# test_unify_routine_cleanups.sh — Bounded disposable fixture tests for routine cleanups
#
# Asserts that:
# 1. disk_audit.sh and CLI disk_magician.sh execute the 6-tier routine cleanup stack in dry-run mode:
#    - Tier 1: Dev caches, Temp files, PR scratch, LLM inspector
#    - Tier 2: Xcode DerivedData & simulator caches
#    - Tier 3: Colima VM disk (Docker prune + fstrim)
#    - Tier 4: Aside browser sessions
#    - Tier 5: Antigravity brain compaction, Codex SQLite vacuum, Supervisor logs, uv cache
#    - Tier 6: Worktree venvs (>=7d dormant), Claude state
# 2. Approval gates are strictly enforced in active clean mode:
#    - Worktrees and Worktree venvs require WORKTREE_APPROVED=1
#    - Claude state requires CLAUDE_STATE_APPROVED=1
#    - Agent artifacts and Dark Factory require AGENT_ARTIFACTS_APPROVED=1
# 3. All execution is bounded to disposable fixtures with recorded stubs,
#    touching no user data and running no live launchd/disk probes.
set -euo pipefail
export PATH="/bin:/usr/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_DIR=$(mktemp -d -t test_routine_cleanups.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_DIR="$TMP_DIR/fixture"
mkdir -p "$FIXTURE_DIR/scripts" "$FIXTURE_DIR/bin" "$FIXTURE_DIR/home"
INVOCATIONS_LOG="$TMP_DIR/invocations.log"

# Copy disk_audit.sh and disk_magician.sh to fixture
cp "$REPO_ROOT/scripts/disk_audit.sh" "$FIXTURE_DIR/scripts/disk_audit.sh"
cp "$REPO_ROOT/disk_magician.sh" "$FIXTURE_DIR/disk_magician.sh"
cp "$REPO_ROOT/config.json.template" "$FIXTURE_DIR/config.json.template"
mkdir -p "$FIXTURE_DIR/scripts/lib"
cp -r "$REPO_ROOT/scripts/lib/"* "$FIXTURE_DIR/scripts/lib/"
chmod +x "$FIXTURE_DIR/scripts/disk_audit.sh" "$FIXTURE_DIR/disk_magician.sh"

# Mock fleet check
cat > "$FIXTURE_DIR/scripts/check_launchd_fleet.sh" <<'EOF'
#!/bin/bash
echo "mock launchd fleet ok"
exit 0
EOF
chmod +x "$FIXTURE_DIR/scripts/check_launchd_fleet.sh"

# Mock system binaries
cat > "$FIXTURE_DIR/bin/df" <<'EOF'
#!/bin/bash
printf 'Filesystem     Size   Used  Avail Capacity Mounted on\n'
printf '/dev/mock      100G    50G    50G    50%% /\n'
EOF
cat > "$FIXTURE_DIR/bin/tmutil" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$FIXTURE_DIR/bin/getconf" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FIXTURE_DIR/bin/df" "$FIXTURE_DIR/bin/tmutil" "$FIXTURE_DIR/bin/getconf"

# Stub all category sub-scripts to record their invocation and args
CATEGORY_SCRIPTS=(
  cleanup_dev_caches.sh
  cleanup_tmp.sh
  cleanup_pr_scratch.sh
  cleanup_xcode.sh
  cleanup_colima.sh
  prune_aside_sessions.sh
  cleanup_antigravity_brain.sh
  cleanup_codex_db.sh
  cleanup_supervisor_logs.sh
  cleanup_uv_cache.sh
  post_job_docker_prune.sh
  cleanup_worktrees.sh
  cleanup_worktree_venvs.sh
  cleanup_claude_state.sh
  cleanup_llm_inspector.sh
  cleanup_agent_artifacts.sh
  cleanup_dark_factory.sh
)

for script_name in "${CATEGORY_SCRIPTS[@]}"; do
  cat > "$FIXTURE_DIR/scripts/$script_name" <<EOF
#!/bin/bash
echo "$script_name \$*" >> "$INVOCATIONS_LOG"
echo "stub $script_name \$*"
exit 0
EOF
  chmod +x "$FIXTURE_DIR/scripts/$script_name"
done

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS  $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $desc" >&2
    FAIL=$(( FAIL + 1 ))
  fi
}

check_absent() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file"; then
    echo "  FAIL  $desc" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "  PASS  $desc"
    PASS=$(( PASS + 1 ))
  fi
}

echo "=== test_unify_routine_cleanups.sh (bounded disposable fixture) ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: disk_audit.sh clean --dry-run executes all routine categories
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: routine dry-run executes 6-tier routine cleanup stack"
: > "$INVOCATIONS_LOG"
OUT1="$TMP_DIR/audit_clean_dry.log"
set +e
PATH="$FIXTURE_DIR/bin:/usr/bin:/bin" \
HOME="$FIXTURE_DIR/home" \
/bin/bash "$FIXTURE_DIR/scripts/disk_audit.sh" clean --dry-run --live --no-history >"$OUT1" 2>&1
RC1=$?
set -e

check "audit clean --dry-run exits 0" test "$RC1" -eq 0
check_absent "audit dry-run has no failed categories" "CATEGORY FAILED:" "$OUT1"
check "audit dry-run reports zero-failure summary" grep -qF "All attempted categories completed without error." "$OUT1"

EXPECTED_DRY_SCRIPTS=(
  "cleanup_dev_caches.sh --dry-run"
  "cleanup_tmp.sh --dry-run"
  "cleanup_pr_scratch.sh --dry-run"
  "cleanup_xcode.sh --dry-run"
  "cleanup_colima.sh --dry-run"
  "prune_aside_sessions.sh --dry-run"
  "cleanup_antigravity_brain.sh --dry-run"
  "cleanup_codex_db.sh --dry-run"
  "cleanup_supervisor_logs.sh --dry-run"
  "cleanup_uv_cache.sh --dry-run"
  "post_job_docker_prune.sh --dry-run"
  "cleanup_worktree_venvs.sh --dry-run"
  "cleanup_claude_state.sh --dry-run"
  "cleanup_llm_inspector.sh --dry-run"
)

for exp in "${EXPECTED_DRY_SCRIPTS[@]}"; do
  if grep -qF "$exp" "$INVOCATIONS_LOG"; then
    echo "  PASS  invoked $exp in dry-run"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  missing invocation $exp in dry-run" >&2
    FAIL=$(( FAIL + 1 ))
  fi
done

# In dry-run without opt-in: Worktrees and Agent artifacts / Dark Factory must be skipped
check "worktrees skipped in dry-run without WORKTREE_APPROVED" grep -q "Worktrees: skipped (requires WORKTREE_APPROVED=1)" "$OUT1"
check "agent artifacts skipped in dry-run without AGENT_ARTIFACTS_APPROVED" grep -q "Agent artifacts: skipped (requires AGENT_ARTIFACTS_APPROVED=1)" "$OUT1"
check "dark factory skipped in dry-run without AGENT_ARTIFACTS_APPROVED" grep -q "Dark Factory artifacts: skipped (requires AGENT_ARTIFACTS_APPROVED=1)" "$OUT1"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Active clean without approval tokens preserves safety gates
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: active clean without approvals enforces safety gates"
: > "$INVOCATIONS_LOG"
OUT2="$TMP_DIR/audit_clean_unapproved.log"
set +e
PATH="$FIXTURE_DIR/bin:/usr/bin:/bin" \
HOME="$FIXTURE_DIR/home" \
/bin/bash "$FIXTURE_DIR/scripts/disk_audit.sh" clean --live --no-history >"$OUT2" 2>&1
RC2=$?
set -e

check "audit clean exits 0" test "$RC2" -eq 0
check "worktrees skipped in clean without approval" grep -q "Worktrees: skipped (requires WORKTREE_APPROVED=1)" "$OUT2"
check "worktree venvs skipped in clean without approval" grep -q "Worktree venvs: skipped (requires WORKTREE_APPROVED=1)" "$OUT2"
check "claude state skipped in clean without approval" grep -q "Claude state (>=7d dormant): skipped (requires CLAUDE_STATE_APPROVED=1)" "$OUT2"
check "agent artifacts skipped in clean without approval" grep -q "Agent artifacts: skipped (requires AGENT_ARTIFACTS_APPROVED=1)" "$OUT2"
check "dark factory skipped in clean without approval" grep -q "Dark Factory artifacts: skipped (requires AGENT_ARTIFACTS_APPROVED=1)" "$OUT2"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Active clean with approval tokens runs approved categories
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: active clean with approvals invokes gated categories"
: > "$INVOCATIONS_LOG"
OUT3="$TMP_DIR/audit_clean_approved.log"
set +e
PATH="$FIXTURE_DIR/bin:/usr/bin:/bin" \
HOME="$FIXTURE_DIR/home" \
WORKTREE_APPROVED=1 \
CLAUDE_STATE_APPROVED=1 \
AGENT_ARTIFACTS_APPROVED=1 \
/bin/bash "$FIXTURE_DIR/scripts/disk_audit.sh" clean --live --no-history >"$OUT3" 2>&1
RC3=$?
set -e

check "approved audit clean exits 0" test "$RC3" -eq 0
check "worktrees executed with --clean" grep -qF "cleanup_worktrees.sh --clean" "$INVOCATIONS_LOG"
check "worktree venvs executed with --clean" grep -qF "cleanup_worktree_venvs.sh --clean" "$INVOCATIONS_LOG"
check "claude state executed with --clean" grep -qF "cleanup_claude_state.sh --clean" "$INVOCATIONS_LOG"
check "agent artifacts executed with --clean" grep -qF "cleanup_agent_artifacts.sh --clean" "$INVOCATIONS_LOG"
check "dark factory executed with --clean" grep -qF "cleanup_dark_factory.sh --clean" "$INVOCATIONS_LOG"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: CLI fixture dispatch test (disk_magician.sh routine --dry-run)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: CLI fixture dispatches routine command cleanly"
: > "$INVOCATIONS_LOG"
OUT4="$TMP_DIR/cli_routine.log"
set +e
PATH="$FIXTURE_DIR/bin:/usr/bin:/bin" \
HOME="$FIXTURE_DIR/home" \
DISK_MAGICIAN_AUTO_CLEAN=1 \
/bin/bash "$FIXTURE_DIR/disk_magician.sh" clean --routine --dry-run >"$OUT4" 2>&1
RC4=$?
set -e

check "CLI routine --dry-run exits 0" test "$RC4" -eq 0
check_absent "CLI routine has no failed categories" "CATEGORY FAILED:" "$OUT4"
check "CLI routine reports zero-failure summary" grep -qF "All attempted categories completed without error." "$OUT4"
check "CLI dispatched dev caches" grep -qF "cleanup_dev_caches.sh --dry-run" "$INVOCATIONS_LOG"
check "CLI dispatched codex vacuum" grep -qF "cleanup_codex_db.sh --dry-run" "$INVOCATIONS_LOG"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]

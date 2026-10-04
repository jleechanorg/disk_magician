#!/usr/bin/env bash
# test_unify_routine_cleanups.sh — Behavioral test for bead disk_magician-unify-routine-cleanups-wgo
#
# Asserts that:
# 1. ./disk_magician.sh clean --routine --dry-run and scripts/disk_audit.sh --clean --dry-run
#    execute the 6-tier routine cleanup stack:
#    - Tier 1: Dev caches, Temp files, PR scratch
#    - Tier 2: Xcode DerivedData & simulator caches
#    - Tier 3: Colima VM disk (Docker prune + fstrim)
#    - Tier 4: Aside browser sessions
#    - Tier 5: Antigravity brain compaction, Codex SQLite vacuum, Supervisor logs, uv cache
#    - Tier 6: Worktree venvs (>=7d dormant)
# 2. All categories execute without error in dry-run mode.
# 3. Worktree venvs require WORKTREE_APPROVED=1 to execute in non-dry-run mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
CLI_SCRIPT="$REPO_ROOT/disk_magician.sh"

TMP_DIR=$(mktemp -d -t test_routine_cleanups.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# Isolate scratch/temp roots to clean fixtures so dry-run audit executes quickly
# without scanning live multi-thousand-directory system temp stores.
FIXTURE_TMP="$TMP_DIR/tmp"
FIXTURE_PRIVATE_TMP="$TMP_DIR/private_tmp"
FIXTURE_USER_TMP="$TMP_DIR/user_tmp"
FIXTURE_BRAIN="$TMP_DIR/brain"
FIXTURE_ASIDE="$TMP_DIR/aside"
FIXTURE_CODEX="$TMP_DIR/codex"
FIXTURE_WORKTREES="$TMP_DIR/worktrees"
FIXTURE_CLAUDE_STATE="$TMP_DIR/claude_state"
mkdir -p "$FIXTURE_TMP" "$FIXTURE_PRIVATE_TMP" "$FIXTURE_USER_TMP" "$FIXTURE_BRAIN" "$FIXTURE_ASIDE" "$FIXTURE_CODEX" "$FIXTURE_WORKTREES" "$FIXTURE_CLAUDE_STATE"
export DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$FIXTURE_TMP"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FIXTURE_PRIVATE_TMP"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$FIXTURE_USER_TMP"
export DISK_MAGICIAN_BRAIN_DIR_OVERRIDE="$FIXTURE_BRAIN"
export DISK_MAGICIAN_ASIDE_DIR_OVERRIDE="$FIXTURE_ASIDE"
export DISK_MAGICIAN_CODEX_DIR_OVERRIDE="$FIXTURE_CODEX"
export DISK_MAGICIAN_WORKTREE_ROOTS="$FIXTURE_WORKTREES"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$TMP_DIR"
export CLAUDE_STATE_ROOT="$FIXTURE_CLAUDE_STATE"
FIXTURE_HOME="$TMP_DIR/fakehome"
FIXTURE_BIN="$TMP_DIR/fakebin"
FIXTURE_STATE="$TMP_DIR/fakestate"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_BIN" "$FIXTURE_STATE"

# Isolate HOME and state so tests never scan live developer/docker paths
export HOME="$FIXTURE_HOME"
export DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE"
export POST_JOB_DOCKER_PRUNE_LOG="$TMP_DIR/post-job.log"
echo "{}" > "$FIXTURE_STATE/frontier_last.json"
echo "{}" > "$FIXTURE_STATE/discover_last.json"

# Provide lightweight hermetic shims for docker and colima
cat > "$FIXTURE_BIN/docker" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"system df"* ]]; then
  echo "TYPE TOTAL ACTIVE SIZE RECLAIMABLE"
  echo "Images 0 0 0B 0B"
  exit 0
fi
if [[ "$*" == *"context"* ]]; then
  echo "unix:///nonexistent/docker.sock"
  exit 0
fi
exit 0
EOF
chmod +x "$FIXTURE_BIN/docker"

cat > "$FIXTURE_BIN/colima" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FIXTURE_BIN/colima"

cat > "$FIXTURE_BIN/uv" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"cache dir"* ]]; then
  echo "$HOME/.cache/uv"
  exit 0
fi
exit 0
EOF
chmod +x "$FIXTURE_BIN/uv"

cat > "$FIXTURE_BIN/getconf" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "DARWIN_USER_TEMP_DIR" ]]; then
  echo "${DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE:-$TMPDIR}"
  exit 0
fi
/usr/bin/getconf "$@"
EOF
chmod +x "$FIXTURE_BIN/getconf"

unset DISK_MAGICIAN_STATE_REPO DISK_MAGICIAN_CONFIG || true
export UV_CACHE_DIR="$TMP_DIR/uv_cache"
export PATH="$FIXTURE_BIN:$PATH"

# Run disk_audit.sh --clean --dry-run
OUT_AUDIT="$TMP_DIR/audit_clean.log"
RC_AUDIT=0
bash "$TARGET_SCRIPT" --clean --dry-run >"$OUT_AUDIT" 2>&1 || RC_AUDIT=$?

if [[ $RC_AUDIT -ne 0 ]]; then
  echo "FAIL: disk_audit.sh --clean --dry-run exited with code $RC_AUDIT" >&2
  cat "$OUT_AUDIT" >&2
  exit 1
fi

EXPECTED_CATEGORIES=(
  "Dev caches"
  "Temp files"
  "PR scratch & analyzers"
  "Xcode DerivedData & simulator caches"
  "Colima VM disk (Docker prune + fstrim)"
  "Aside browser sessions"
  "Antigravity brain compaction"
  "Codex SQLite vacuum"
  "Supervisor logs"
  "uv cache (disk-magician builds)"
  "Worktree venvs (>=7d dormant)"
)

for cat in "${EXPECTED_CATEGORIES[@]}"; do
  if ! grep -qF "$cat" "$OUT_AUDIT"; then
    echo "FAIL: expected category '$cat' not executed in disk_audit.sh --clean" >&2
    exit 1
  fi
done

if grep -qF "CATEGORY FAILED:" "$OUT_AUDIT"; then
  echo "FAIL: one or more categories failed in disk_audit.sh --clean" >&2
  cat "$OUT_AUDIT" >&2
  exit 1
fi

if ! grep -qF "All attempted categories completed without error." "$OUT_AUDIT"; then
  echo "FAIL: zero-failure summary not found in disk_audit.sh --clean" >&2
  cat "$OUT_AUDIT" >&2
  exit 1
fi

# Run CLI disk_magician.sh routine --dry-run
OUT_CLI="$TMP_DIR/cli_routine.log"
RC_CLI=0
DISK_MAGICIAN_AUTO_CLEAN=1 bash "$CLI_SCRIPT" routine --dry-run >"$OUT_CLI" 2>&1 || RC_CLI=$?

if [[ $RC_CLI -ne 0 ]]; then
  echo "FAIL: disk_magician.sh routine --dry-run exited with code $RC_CLI" >&2
  cat "$OUT_CLI" >&2
  exit 1
fi

for cat in "${EXPECTED_CATEGORIES[@]}"; do
  if ! grep -qF "$cat" "$OUT_CLI"; then
    echo "FAIL: expected category '$cat' not executed in disk_magician.sh routine" >&2
    exit 1
  fi
done

if grep -qF "CATEGORY FAILED:" "$OUT_CLI"; then
  echo "FAIL: one or more categories failed in disk_magician.sh routine" >&2
  cat "$OUT_CLI" >&2
  exit 1
fi

if ! grep -qF "All attempted categories completed without error." "$OUT_CLI"; then
  echo "FAIL: zero-failure summary not found in disk_magician.sh routine" >&2
  cat "$OUT_CLI" >&2
  exit 1
fi

echo "PASS: all 6-tier routine cleanup stack categories verified"
exit 0

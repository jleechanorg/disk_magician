#!/usr/bin/env bash
# test_cleanup_task_scratch.sh — Comprehensive RED->GREEN test suite for cleanup_task_scratch.sh
#
# Tests:
# 1. CLI dispatch via disk_magician.sh cleanup-task-scratch --help / --dry-run and python3 -m disk_magician.cli
# 2. Dry-run vs --clean behavior (default is dry-run, no deletion, no manifest write)
# 3. Skipping real top-level git repos and linked worktrees in ~/projects (and non-matching dir names)
# 4. Skipping task-scratch containers touched <12h ago
# 5. Preserving containers with dirty nested repo, unpushed nested repo, secret-like files, or open files
# 6. Removing clean aged task-scratch containers (clean linked worktree + non-git scratch files/dirs)
#    and recording manifest entries in $DISK_MAGICIAN_STATE_DIR/task_scratch_cleanup_manifest.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_task_scratch.sh"
ORCHESTRATOR="$REPO_ROOT/disk_magician.sh"

export TMPDIR=/tmp
TMP_TEST_ROOT="$(cd "$(mktemp -d /tmp/test_task_scratch.XXXXXX)" && pwd -P)"
trap 'rm -rf "$TMP_TEST_ROOT"' EXIT

export HOME="$TMP_TEST_ROOT/home"
export DISK_MAGICIAN_STATE_DIR="$TMP_TEST_ROOT/state"
export DISK_MAGICIAN_DELETION_LOG="$TMP_TEST_ROOT/deletions.log"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$TMP_TEST_ROOT"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test"
export GIT_COMMITTER_EMAIL="test@example.com"

mkdir -p "$HOME/projects" "$HOME/projects_other" "$DISK_MAGICIAN_STATE_DIR"

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected rc=$expected, got rc=$actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output to contain: $needle"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  fi
}

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected path to exist: $path"
  fi
}

assert_missing() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected path to be absent: $path"
  fi
}

set_old_mtime() {
  local target="$1"
  /usr/bin/find "$target" -exec touch -h -t 202001010000 {} + 2>/dev/null || find "$target" -exec touch -t 202001010000 {} +
}

echo "=== Running cleanup_task_scratch.sh test suite ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: CLI Dispatch (--help and --dry-run)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: CLI Dispatch (--help and --dry-run)"
HELP_RC=0
HELP_OUT="$(bash "$ORCHESTRATOR" cleanup-task-scratch --help 2>&1)" || HELP_RC=$?
assert_rc "T1: disk_magician.sh cleanup-task-scratch --help exits 0" 0 "$HELP_RC"
assert_contains "T1: --help output describes usage" "Usage:" "$HELP_OUT"

ORCH_HELP_OUT="$(bash "$ORCHESTRATOR" --help 2>&1)" || true
assert_contains "T1: disk_magician.sh --help lists cleanup-task-scratch" "cleanup-task-scratch" "$ORCH_HELP_OUT"

PY_CLI_RC=0
PY_CLI_OUT="$(PYTHONPATH="$REPO_ROOT/src" python3 -m disk_magician.cli cleanup-task-scratch --help 2>&1)" || PY_CLI_RC=$?
assert_rc "T1: python3 -m disk_magician.cli cleanup-task-scratch --help exits 0" 0 "$PY_CLI_RC"

# ─────────────────────────────────────────────────────────────────────────────
# Shared bare remote and base repo for git worktree / clone fixtures
# ─────────────────────────────────────────────────────────────────────────────
BARE_REMOTE="$TMP_TEST_ROOT/remote.git"
BASE_REPO="$HOME/projects/real-project-repo"
git init -q --bare -b main "$BARE_REMOTE"
git clone -q "$BARE_REMOTE" "$BASE_REPO" 2>/dev/null
echo "initial" > "$BASE_REPO/README.md"
git -C "$BASE_REPO" add README.md
git -C "$BASE_REPO" commit -qm "initial commit"
git -C "$BASE_REPO" push -q origin HEAD:main
set_old_mtime "$BASE_REPO"

# Also create a top-level linked worktree in ~/projects whose name matches *-????????
TOP_WT="$HOME/projects/top-wt-1a2b3c4d"
git -C "$BASE_REPO" worktree add -q -b top-wt-branch "$TOP_WT" HEAD
git -C "$TOP_WT" push -q -u origin top-wt-branch
set_old_mtime "$TOP_WT"

# Also create a non-git directory whose name does NOT match scratch container patterns
NON_MATCH_DIR="$HOME/projects/regular_notes_folder"
mkdir -p "$NON_MATCH_DIR"
echo "keep me" > "$NON_MATCH_DIR/notes.txt"
set_old_mtime "$NON_MATCH_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Dry-run vs --clean and Top-Level Repo/Worktree Protection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: Dry-run vs --clean and Top-Level Repo/Worktree Protection"
DRY_CONTAINER="$HOME/projects/arcanum-gates-a1b2c3d4"
mkdir -p "$DRY_CONTAINER/sub"
echo '{"status":"ok"}' > "$DRY_CONTAINER/verdict.json"
echo "scratch note" > "$DRY_CONTAINER/sub/note.txt"
set_old_mtime "$DRY_CONTAINER"

MANIFEST_FILE="$DISK_MAGICIAN_STATE_DIR/task_scratch_cleanup_manifest.txt"
rm -f "$MANIFEST_FILE"

DRY_RC=0
DRY_OUT="$(bash "$ORCHESTRATOR" cleanup-task-scratch --dry-run 2>&1)" || DRY_RC=$?
assert_rc "T2: dry-run exits 0" 0 "$DRY_RC"
assert_contains "T2: dry-run logs preview for matching container" "DRY RUN" "$DRY_OUT"
assert_exists "T2: dry-run preserves matching container" "$DRY_CONTAINER"
assert_missing "T2: dry-run does not create manifest file" "$MANIFEST_FILE"

# Default invocation (no flags) must also be dry-run
DEF_RC=0
DEF_OUT="$(bash "$TARGET_SCRIPT" 2>&1)" || DEF_RC=$?
assert_rc "T2: default invocation exits 0" 0 "$DEF_RC"
assert_exists "T2: default invocation preserves container" "$DRY_CONTAINER"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Skipping task-scratch containers touched <12h ago
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Skipping task-scratch containers touched <12h ago"
RECENT_CONTAINER="$HOME/projects/pr9946-recent-scratch"
mkdir -p "$RECENT_CONTAINER/nested"
set_old_mtime "$RECENT_CONTAINER"
# Touch one nested file to current time (<12h)
touch "$RECENT_CONTAINER/nested/fresh.json"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Preserving containers with dirty/unpushed nested repo, secret-like files, or open files
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Preserving containers with dirty/unpushed nested repo, secret-like files, or open files"

# 4a. Dirty nested worktree
DIRTY_CONTAINER="$HOME/projects/ready-dirty-ef123456"
mkdir -p "$DIRTY_CONTAINER"
git -C "$BASE_REPO" worktree add -q -b dirty-wt-branch "$DIRTY_CONTAINER/worktree" HEAD
git -C "$DIRTY_CONTAINER/worktree" push -q -u origin dirty-wt-branch
echo "uncommitted work" > "$DIRTY_CONTAINER/worktree/dirty.txt"
echo "sibling scratch" > "$DIRTY_CONTAINER/scratch.json"
set_old_mtime "$DIRTY_CONTAINER"

# 4b. Unpushed nested clone
UNPUSHED_CONTAINER="$HOME/projects/advice-unpushed-999"
mkdir -p "$UNPUSHED_CONTAINER"
git clone -q "$BARE_REMOTE" "$UNPUSHED_CONTAINER/repo" 2>/dev/null
echo "local commit" >> "$UNPUSHED_CONTAINER/repo/README.md"
git -C "$UNPUSHED_CONTAINER/repo" commit -qam "local only commit"
set_old_mtime "$UNPUSHED_CONTAINER"

# 4c. Secret-like file inside container
SECRET_CONTAINER="$HOME/projects/pr-1001-secret"
mkdir -p "$SECRET_CONTAINER"
echo "API_KEY=secret" > "$SECRET_CONTAINER/.env.production"
echo "normal" > "$SECRET_CONTAINER/output.json"
set_old_mtime "$SECRET_CONTAINER"

# 4d. Open file inside container
OPEN_CONTAINER="$HOME/projects/ready-open-87654321"
mkdir -p "$OPEN_CONTAINER"
echo "busy" > "$OPEN_CONTAINER/busy.log"
set_old_mtime "$OPEN_CONTAINER"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Removing clean aged task-scratch containers + recording manifest
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Removing clean aged task-scratch containers and recording manifest"

# 5a. Container in ~/projects with a clean pushed linked worktree + non-git scratch files
CLEAN_WT_CONTAINER="$HOME/projects/rewards-stale-l6m5eogn"
mkdir -p "$CLEAN_WT_CONTAINER/sub"
git -C "$BASE_REPO" worktree add -q -b clean-wt-branch "$CLEAN_WT_CONTAINER/worktree" HEAD
git -C "$CLEAN_WT_CONTAINER/worktree" push -q -u origin clean-wt-branch
echo '{"ok":true}' > "$CLEAN_WT_CONTAINER/er-verdict.json"
echo "log data" > "$CLEAN_WT_CONTAINER/sub/run.log"
set_old_mtime "$CLEAN_WT_CONTAINER"

# 5b. Container in ~/projects_other matching ready-* pattern
CLEAN_OTHER_CONTAINER="$HOME/projects_other/ready-f4-retry-dmxq3hb4"
mkdir -p "$CLEAN_OTHER_CONTAINER"
echo "artifact" > "$CLEAN_OTHER_CONTAINER/packet.txt"
set_old_mtime "$CLEAN_OTHER_CONTAINER"

# 5c. A live descendant lease keeps a nested worktree. 5d receives a fresh
# C14 receipt under the shared registry
# lock. The after-verdict hook attempts the normal owner-birth path for a
# descendant; it must fail while the lock is held, then the eligible worktree
# must still be removed through WRH quarantine.
LIVE_CONTAINER="$HOME/projects/pr-5000-live-descendant"
mkdir -p "$LIVE_CONTAINER"
git -C "$BASE_REPO" worktree add -q -b live-desc-wt-branch "$LIVE_CONTAINER/worktree" HEAD
git -C "$LIVE_CONTAINER/worktree" push -q -u origin live-desc-wt-branch
mkdir -p "$LIVE_CONTAINER/worktree/descendant"
set_old_mtime "$LIVE_CONTAINER"
set_old_mtime "$LIVE_CONTAINER/worktree/descendant"
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
if lease_write "$LIVE_CONTAINER/worktree/descendant" --owner-pid "$$"; then
  record_pass "T5: live descendant lease fixture created"
else
  record_fail "T5: live descendant lease fixture created" "lease_write failed"
fi

# 5d. Nested worktree receives a fresh C14 receipt under the shared registry
RACE_CONTAINER="$HOME/projects/pr-5001-owner-race"
mkdir -p "$RACE_CONTAINER"
git -C "$BASE_REPO" worktree add -q -b race-wt-branch "$RACE_CONTAINER/worktree" HEAD
git -C "$RACE_CONTAINER/worktree" push -q -u origin race-wt-branch
mkdir -p "$RACE_CONTAINER/worktree/descendant"
set_old_mtime "$RACE_CONTAINER"
set_old_mtime "$RACE_CONTAINER/worktree/descendant"
OWNER_BIRTH_MARKER="$TMP_TEST_ROOT/owner-birth-blocked"
OWNER_BIRTH_HOOK="$TMP_TEST_ROOT/attempt-descendant-owner-birth.sh"
cat >"$OWNER_BIRTH_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
source "$TASK_SCRATCH_REPO_ROOT/scripts/lib/worktree_lease.sh"
if lease_write "$1/descendant"; then
  echo unexpected-owner-birth >"$TASK_SCRATCH_OWNER_BIRTH_MARKER"
else
  echo blocked-by-registry-lock >"$TASK_SCRATCH_OWNER_BIRTH_MARKER"
fi
HOOK
chmod +x "$OWNER_BIRTH_HOOK"
if lease_write "$RACE_CONTAINER/worktree/descendant"; then
  record_pass "T5: unlocked descendant owner birth control succeeds"
  rm -f -- "$(lease_path_for "$RACE_CONTAINER/worktree/descendant")"
else
  record_fail "T5: unlocked descendant owner birth control succeeds" "lease_write failed without registry lock"
fi

# Fix mtimes on BASE_REPO after worktree operations
set_old_mtime "$BASE_REPO"
export TASK_SCRATCH_REPO_ROOT="$REPO_ROOT"
export TASK_SCRATCH_OWNER_BIRTH_MARKER="$OWNER_BIRTH_MARKER"
export DISK_MAGICIAN_TEST_AFTER_TASK_SCRATCH_C14_VERDICT="$OWNER_BIRTH_HOOK"

# Hold an open file on OPEN_CONTAINER during --clean
tail -f "$OPEN_CONTAINER/busy.log" >/dev/null 2>&1 &
HOLDER_PID=$!
sleep 0.4

CLEAN_RC=0
CLEAN_OUT="$(bash "$ORCHESTRATOR" cleanup-task-scratch --clean 2>&1)" || CLEAN_RC=$?

kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

assert_rc "T5: --clean exits 0" 0 "$CLEAN_RC"
if [[ "$CLEAN_RC" -ne 0 || -d "$RACE_CONTAINER" ]]; then
  printf 'T5 cleaner output:\n%s\n' "$CLEAN_OUT"
  printf 'T5 WRH guard log:\n%s\n' "$(cat "$HOME/.disk_magician_state/worktree_guard.log" 2>/dev/null || true)"
fi

# Verify protected items are preserved:
assert_exists "T3/5: real top-level git repo preserved" "$BASE_REPO"
assert_exists "T3/5: top-level linked worktree preserved" "$TOP_WT"
assert_exists "T3/5: non-matching directory preserved" "$NON_MATCH_DIR"
assert_exists "T3/5: recent (<12h) container preserved" "$RECENT_CONTAINER"
assert_exists "T4a: dirty nested worktree container preserved" "$DIRTY_CONTAINER"
assert_exists "T4a: dirty nested worktree itself preserved" "$DIRTY_CONTAINER/worktree/dirty.txt"
assert_exists "T4b: unpushed nested repo container preserved" "$UNPUSHED_CONTAINER"
assert_exists "T4c: secret-like file container preserved" "$SECRET_CONTAINER"
assert_exists "T4d: open-file container preserved" "$OPEN_CONTAINER"
assert_exists "T5: live descendant lease preserves nested worktree container" "$LIVE_CONTAINER"
assert_exists "T5: live descendant lease preserves nested worktree" "$LIVE_CONTAINER/worktree"

# Verify eligible aged clean containers are removed:
assert_missing "T5: clean container in ~/projects removed" "$DRY_CONTAINER"
assert_missing "T5: clean worktree container in ~/projects removed" "$CLEAN_WT_CONTAINER"
assert_missing "T5: clean container in ~/projects_other removed" "$CLEAN_OTHER_CONTAINER"
assert_missing "T5: eligible nested worktree container removed after final C14" "$RACE_CONTAINER"
assert_contains "T5: descendant owner birth was blocked after final C14 verdict" "blocked-by-registry-lock" "$(cat "$OWNER_BIRTH_MARKER" 2>/dev/null || true)"

# Verify manifest file entries:
assert_exists "T5: manifest file created" "$MANIFEST_FILE"
MANIFEST_CONTENT="$(cat "$MANIFEST_FILE" 2>/dev/null || true)"
assert_contains "T5: manifest records removed-worktree" "removed-worktree $CLEAN_WT_CONTAINER/worktree" "$MANIFEST_CONTENT"
assert_contains "T5: manifest records rm of scratch file" "rm $CLEAN_WT_CONTAINER/er-verdict.json" "$MANIFEST_CONTENT"
assert_contains "T5: manifest records rmdir of container" "rmdir $CLEAN_WT_CONTAINER" "$MANIFEST_CONTENT"
assert_contains "T5: manifest records projects_other container" "$CLEAN_OTHER_CONTAINER" "$MANIFEST_CONTENT"

echo
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]

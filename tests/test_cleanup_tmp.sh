#!/usr/bin/env bash
# tests/test_cleanup_tmp.sh — regression suite for bead jleechan-i4h2:
# Guard scripts/cleanup_tmp.sh and scripts/lib/scratch_budget.sh so /tmp sweeps
# never traverse FUSE/child mountpoints or wedge on leaked mounts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Sandboxing compliance: tests/test_sandbox_context_lint.sh requirement
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMPDIR="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TMPDIR%/}/test_cleanup_tmp_mount_guard.XXXXXX")"
trap 'chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

export DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT"
export DISK_MAGICIAN_TEST_SANDBOX="$TEST_ROOT"

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1: $2"; FAIL=$(( FAIL + 1 )); }

# Source the scratch_budget library containing the filesystem/mountpoint helpers
source "$REPO_ROOT/scripts/lib/scratch_budget.sh"

echo "=== Unit Tests: is_different_filesystem ==="

# 1. Normal candidate on same filesystem
NORMAL_DIR="$TEST_ROOT/normal_candidate"
mkdir -p "$NORMAL_DIR"
if is_different_filesystem "$NORMAL_DIR" "$TEST_ROOT"; then
  record_fail "Test 1" "normal candidate reported as different filesystem"
else
  record_pass "Test 1: normal candidate on same filesystem returns false (is same fs)"
fi

# 2. Simulated leaked mountpoint in /proc/self/mountinfo format (exact match)
MOUNTINFO_FILE="$TEST_ROOT/mock_mountinfo"
LEAKED_MOUNT="$TEST_ROOT/mac-evidence-baseline-mount"
mkdir -p "$LEAKED_MOUNT"
cat > "$MOUNTINFO_FILE" <<EOF
36 35 98:0 / $LEAKED_MOUNT rw,noatime master:1 - fuse.rclone :sftp: rw
EOF

if DISK_MAGICIAN_TEST_MOUNTINFO="$MOUNTINFO_FILE" is_different_filesystem "$LEAKED_MOUNT" "$TEST_ROOT"; then
  record_pass "Test 2: exact mountpoint in mountinfo recognized as different filesystem"
else
  record_fail "Test 2" "exact mountpoint in mountinfo was not detected"
fi

# 3. Simulated nested mountpoint inside a container dir
CONTAINER_DIR="$TEST_ROOT/worldarchitect.ai"
SUBMOUNT_DIR="$CONTAINER_DIR/verify_10801-10870-10820-ba7"
mkdir -p "$SUBMOUNT_DIR"
cat > "$MOUNTINFO_FILE" <<EOF
36 35 98:0 / $SUBMOUNT_DIR rw,noatime master:1 - fuse.rclone :sftp: rw
EOF

if DISK_MAGICIAN_TEST_MOUNTINFO="$MOUNTINFO_FILE" is_different_filesystem "$CONTAINER_DIR" "$TEST_ROOT"; then
  record_pass "Test 3: parent directory containing a nested mountpoint recognized as different filesystem"
else
  record_fail "Test 3" "parent directory containing nested mountpoint was not detected"
fi

# 4. Simulated /proc/mounts format
PROCMOUNTS_FILE="$TEST_ROOT/mock_mounts"
SSHFS_MOUNT="$TEST_ROOT/sshfs_remote"
mkdir -p "$SSHFS_MOUNT"
cat > "$PROCMOUNTS_FILE" <<EOF
user@remote: $SSHFS_MOUNT fuse.sshfs rw,nosuid,nodev 0 0
EOF

if DISK_MAGICIAN_TEST_MOUNTINFO="$PROCMOUNTS_FILE" is_different_filesystem "$SSHFS_MOUNT" "$TEST_ROOT"; then
  record_pass "Test 4: mountpoint in /proc/mounts format recognized as different filesystem"
else
  record_fail "Test 4" "mountpoint in /proc/mounts was not detected"
fi

# 5. Mountpoint with escaped space (\040) in mountinfo
SPACE_MOUNT="$TEST_ROOT/my leaked mount"
mkdir -p "$SPACE_MOUNT"
SPACE_MOUNT_OCTAL="${SPACE_MOUNT// /\\040}"
cat > "$MOUNTINFO_FILE" <<EOF
42 35 98:0 / $SPACE_MOUNT_OCTAL rw,noatime master:1 - fuse.rclone :sftp: rw
EOF

if DISK_MAGICIAN_TEST_MOUNTINFO="$MOUNTINFO_FILE" is_different_filesystem "$SPACE_MOUNT" "$TEST_ROOT"; then
  record_pass "Test 5: mountpoint path with octal-escaped spaces recognized as different filesystem"
else
  record_fail "Test 5" "mountpoint with spaces was not detected"
fi

# 6. Dead mount simulation: stat timeout probe fails closed
DEAD_MOCK_BIN="$TEST_ROOT/mock_bin"
mkdir -p "$DEAD_MOCK_BIN"
cat > "$DEAD_MOCK_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
exit 124  # Simulate timeout kill
EOF
chmod +x "$DEAD_MOCK_BIN/timeout"

DEAD_MOUNT="$TEST_ROOT/hung_mount"
mkdir -p "$DEAD_MOUNT"
# When stat times out (rc=124), is_different_filesystem must fail closed (return 0)
if PATH="$DEAD_MOCK_BIN:$PATH" DISK_MAGICIAN_TEST_MOUNTINFO="/dev/null" is_different_filesystem "$DEAD_MOUNT" "$TEST_ROOT"; then
  record_pass "Test 6: hung/timed-out stat probe fails closed (treated as foreign fs/mountpoint)"
else
  record_fail "Test 6" "hung stat probe did not fail closed"
fi

echo "=== Integration: cleanup_tmp.sh mount guard ==="

TMP_FIXTURE="$TEST_ROOT/fixture_tmp"
mkdir -p "$TMP_FIXTURE"

# Create normal aged git clone (should be removed or dry-run would-remove)
VALID_CLONE="$TMP_FIXTURE/valid_clone"
mkdir -p "$VALID_CLONE/.git"
touch "$VALID_CLONE/file.txt"
# Backdate mtime beyond GIT_CLONE_MIN (240m = 4h)
python3 -c 'import os,time; t=time.time()-18000; os.utime("'"$VALID_CLONE"'", (t,t)); os.utime("'"$VALID_CLONE/.git"'", (t,t))'

# Create simulated leaked mountpoint clone (should be skipped)
LEAKED_CLONE="$TMP_FIXTURE/mac-evidence-baseline-mount"
mkdir -p "$LEAKED_CLONE/.git"
touch "$LEAKED_CLONE/file.txt"
python3 -c 'import os,time; t=time.time()-18000; os.utime("'"$LEAKED_CLONE"'", (t,t)); os.utime("'"$LEAKED_CLONE/.git"'", (t,t))'

# Create nested container with leaked submount
NESTED_CONTAINER="$TMP_FIXTURE/worldarchitect.ai"
NESTED_SUBMOUNT="$NESTED_CONTAINER/verify_10801"
mkdir -p "$NESTED_CONTAINER/.git" "$NESTED_SUBMOUNT"
touch "$NESTED_SUBMOUNT/file.txt"
python3 -c 'import os,time; t=time.time()-18000; os.utime("'"$NESTED_CONTAINER"'", (t,t)); os.utime("'"$NESTED_CONTAINER/.git"'", (t,t))'

# Register leaked mountpoints in mountinfo
FIXTURE_MOUNTINFO="$TEST_ROOT/cleanup_mountinfo"
cat > "$FIXTURE_MOUNTINFO" <<EOF
100 1 98:0 / $LEAKED_CLONE rw,noatime - fuse.rclone :sftp: rw
101 1 98:0 / $NESTED_SUBMOUNT rw,noatime - fuse.rclone :sftp: rw
EOF

OUT_LOG="$TEST_ROOT/cleanup_tmp.log"
HOME_MOCK="$TEST_ROOT/home"
mkdir -p "$HOME_MOCK"

set +e
env -i HOME="$HOME_MOCK" PATH="$PATH" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TEST_ROOT" \
  DISK_MAGICIAN_TEST_MOUNTINFO="$FIXTURE_MOUNTINFO" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$TMP_FIXTURE" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMP_FIXTURE" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_FIXTURE" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$TEST_ROOT/archive" \
  GIT_CLONE_MIN=60 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run > "$OUT_LOG" 2>&1
CLEANUP_RC=$?
set -e

if [[ "$CLEANUP_RC" -eq 0 ]]; then
  record_pass "Test 7: cleanup_tmp.sh dry run executed successfully"
else
  record_fail "Test 7" "cleanup_tmp.sh dry run failed with rc=$CLEANUP_RC (log follows): $(cat "$OUT_LOG")"
fi

# Verify skipped mountpoint log
if grep -Fq "Skipping mountpoint or foreign filesystem: $LEAKED_CLONE" "$OUT_LOG"; then
  record_pass "Test 8: leaked mountpoint was explicitly skipped and logged"
else
  record_fail "Test 8" "leaked mountpoint was not logged as skipped in: $(cat "$OUT_LOG")"
fi

# Verify container with submount was skipped
if grep -Fq "Skipping mountpoint or foreign filesystem: $NESTED_CONTAINER" "$OUT_LOG"; then
  record_pass "Test 9: directory containing nested mountpoint was explicitly skipped and logged"
else
  record_fail "Test 9" "container with nested mountpoint was not logged as skipped in: $(cat "$OUT_LOG")"
fi

# Verify normal candidate was evaluated
if grep -Fq "valid_clone" "$OUT_LOG"; then
  record_pass "Test 10: normal candidate was evaluated"
else
  record_fail "Test 10" "normal candidate was not evaluated in: $(cat "$OUT_LOG")"
fi

echo "=== Integration: scratch_budget_evict_root mount guard ==="

BUDGET_ROOT="$TEST_ROOT/budget_root"
mkdir -p "$BUDGET_ROOT"

# Normal candidate (100 KB, 3 hours old)
NORMAL_SCRATCH="$BUDGET_ROOT/normal_scratch"
mkdir -p "$NORMAL_SCRATCH"
dd if=/dev/zero of="$NORMAL_SCRATCH/payload.bin" bs=1024 count=100 2>/dev/null
python3 -c 'import os,time; t=time.time()-10800; os.utime("'"$NORMAL_SCRATCH/payload.bin"'", (t,t)); os.utime("'"$NORMAL_SCRATCH"'", (t,t))'

# Mountpoint candidate (100 KB, 5 hours old - older, so would sort first without guard)
MOUNT_SCRATCH="$BUDGET_ROOT/mount_scratch"
mkdir -p "$MOUNT_SCRATCH"
dd if=/dev/zero of="$MOUNT_SCRATCH/payload.bin" bs=1024 count=100 2>/dev/null
python3 -c 'import os,time; t=time.time()-18000; os.utime("'"$MOUNT_SCRATCH/payload.bin"'", (t,t)); os.utime("'"$MOUNT_SCRATCH"'", (t,t))'

# Register MOUNT_SCRATCH in mountinfo
BUDGET_MOUNTINFO="$TEST_ROOT/budget_mountinfo"
cat > "$BUDGET_MOUNTINFO" <<EOF
200 1 98:0 / $MOUNT_SCRATCH rw,noatime - fuse.rclone :sftp: rw
EOF

BUDGET_LOG="$TEST_ROOT/budget.log"
# Minimal harness logger and stubs for scratch_budget
log() { echo "$*" >> "$BUDGET_LOG"; }
path_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
is_protected_root() { return 1; }
is_protected_tmp_path() { return 1; }
has_open_files() { return 1; }
DRY_RUN=false
BUDGET_DIRS_DELETED=0
BUDGET_FILES_DELETED=0
BUDGET_KB_FREED=0

DISK_MAGICIAN_TEST_MOUNTINFO="$BUDGET_MOUNTINFO" \
  scratch_budget_evict_root "$BUDGET_ROOT" 50 60

if grep -Fq "scratch_budget: skipping mountpoint or foreign filesystem: $MOUNT_SCRATCH" "$BUDGET_LOG"; then
  record_pass "Test 11: scratch_budget skipped mountpoint candidate during enumeration"
else
  record_fail "Test 11" "scratch_budget did not skip mountpoint in: $(cat "$BUDGET_LOG")"
fi

if [[ -d "$MOUNT_SCRATCH" ]]; then
  record_pass "Test 12: mountpoint candidate was preserved (never evicted)"
else
  record_fail "Test 12" "mountpoint candidate was unexpectedly deleted!"
fi

echo "=== Structural Audit: -xdev presence ==="

# Check find calls in scripts/cleanup_tmp.sh and scripts/lib/scratch_budget.sh
TMP_MISSING_XDEV=$(grep -n "find \"\$tmp_dir\"" "$REPO_ROOT/scripts/cleanup_tmp.sh" | grep -v "\-xdev" || true)
if [[ -z "$TMP_MISSING_XDEV" ]]; then
  record_pass "Test 13: scripts/cleanup_tmp.sh uses -xdev for all find sweeps"
else
  record_fail "Test 13" "found find sweeps missing -xdev: $TMP_MISSING_XDEV"
fi

BUDGET_MISSING_XDEV=$(grep -n "find \"\$root\"" "$REPO_ROOT/scripts/lib/scratch_budget.sh" | grep -v "\-xdev" || true)
if [[ -z "$BUDGET_MISSING_XDEV" ]]; then
  record_pass "Test 14: scripts/lib/scratch_budget.sh uses -xdev for find root sweep"
else
  record_fail "Test 14" "found find root sweep missing -xdev: $BUDGET_MISSING_XDEV"
fi

echo
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

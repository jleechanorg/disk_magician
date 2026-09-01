#!/usr/bin/env bash
# test_cleanup_pr_scratch.sh — Comprehensive test suite for cleanup_pr_scratch.sh
#
# Tests:
# 1. Default dry-run behavior (no deletion, preview only)
# 2. --clean and --apply execution (deletes eligible stale items)
# 3. Pattern filtering (matches pr9*, pr-*, pr_*, pr[0-9]*, claude-*, claude_*)
# 4. Non-matching paths preservation
# 5. Age filtering (--min-age-hours and --min-age-days)
# 6. Nested file recency protection (directory with recent child file is preserved)
# 7. Marker protection (.in-use and .keep)
# 8. Open files protection (active process / lsof)
# 9. Fail-closed on lsof failure/error
# 10. Git worktree unsaved work protection
# 11. Protected roots and safety gate integration
# 12. Argument validation and error handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"

TMP_TEST_ROOT=$(mktemp -d -t test_pr_scratch.XXXXXX)
# chflags -R nouchg first: Test 12 deliberately sets the macOS uchg
# (immutable) flag to simulate a chmod-immune deletion target, and
# rm -rf cannot remove a uchg-flagged file even as the owner. Without
# this, an abnormal exit between "set uchg" and "clear uchg" leaks a
# permanently undeletable tree under TMPDIR (found in /advice review of
# PR #60 -- Opus found one such leaked tree still on disk from a prior
# run). command -v guards for non-macOS hosts where chflags may be absent.
# The whole chflags leg is wrapped in `( ... ) || true`, not cosmetic: this
# file has `set -euo pipefail` at the top, and a trap handler string
# executes as a script under the caller's active options -- a bare
# `A && B; C` does NOT protect C from errexit if A or B fails, because `;`
# is a sequence separator, not an errexit boundary. Without the `|| true`
# here, a missing `chflags` binary OR a failing `chflags` call would both
# abort the trap before `rm -rf` ever ran (found in /advice review of
# PR #60 -- Codex).
trap '(command -v chflags >/dev/null 2>&1 && chflags -R nouchg "$TMP_TEST_ROOT" 2>/dev/null) || true; rm -rf "$TMP_TEST_ROOT"' EXIT

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

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! grep -qF "$needle" <<<"$haystack"; then
    record_pass "$name"
  else
    record_fail "$name" "expected output NOT to contain: $needle"
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
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} + 2>/dev/null || find "$dir" -exec touch -t 202001010000 {} +
}

echo "=== Running cleanup_pr_scratch.sh test suite ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Default Dry Run Mode
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: Default Dry Run Mode"
T1_DIR="$TMP_TEST_ROOT/t1_tmp"
mkdir -p "$T1_DIR/pr9128-wizard" "$T1_DIR/pr-stale-run"
echo "data" > "$T1_DIR/pr9128-wizard/file.txt"
echo "log" > "$T1_DIR/pr54_output.log"
set_old_mtime "$T1_DIR"

T1_OUT=$(bash "$TARGET_SCRIPT" --tmp-dir "$T1_DIR" 2>&1)
assert_contains "T1: indicates dry run in log" "DRY RUN: would remove:" "$T1_OUT"
assert_exists "T1: directory preserved in dry run" "$T1_DIR/pr9128-wizard"
assert_exists "T1: file preserved in dry run" "$T1_DIR/pr54_output.log"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Clean and Apply Execution
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 2: Clean and Apply Execution"
T2_DIR="$TMP_TEST_ROOT/t2_tmp"
mkdir -p "$T2_DIR/pr9128-wizard" "$T2_DIR/pr-stale-run" "$T2_DIR/claude-session-old"
echo "data" > "$T2_DIR/pr9128-wizard/file.txt"
echo "log" > "$T2_DIR/pr-stale-run/log.txt"
echo "claude" > "$T2_DIR/claude-session-old/ctx.json"
echo "file" > "$T2_DIR/pr54_output.log"
set_old_mtime "$T2_DIR"

T2_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T2_DIR" 2>&1)
assert_contains "T2: indicates removal" "Removing:" "$T2_OUT"
assert_missing "T2: pr9* dir removed" "$T2_DIR/pr9128-wizard"
assert_missing "T2: pr-* dir removed" "$T2_DIR/pr-stale-run"
assert_missing "T2: claude-* dir removed" "$T2_DIR/claude-session-old"
assert_missing "T2: pr* file removed" "$T2_DIR/pr54_output.log"

# Also verify --apply alias
mkdir -p "$T2_DIR/pr_apply_test"
set_old_mtime "$T2_DIR/pr_apply_test"
T2_APPLY_OUT=$(bash "$TARGET_SCRIPT" --apply --tmp-dir "$T2_DIR" 2>&1)
assert_missing "T2: --apply removes target" "$T2_DIR/pr_apply_test"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Pattern Filtering
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 3: Pattern Filtering"
T3_DIR="$TMP_TEST_ROOT/t3_tmp"
mkdir -p "$T3_DIR/pr832-evidence-fix" \
         "$T3_DIR/pr-analyzer-123" \
         "$T3_DIR/pr_custom_debug" \
         "$T3_DIR/pr9001-deep-scan" \
         "$T3_DIR/claude-mcp-scratch" \
         "$T3_DIR/claude_ctx_temp" \
         "$T3_DIR/unrelated_user_code" \
         "$T3_DIR/system-cache"
echo "dummy" > "$T3_DIR/unrelated_file.txt"
echo "pr" > "$T3_DIR/pr9999_report.md"
set_old_mtime "$T3_DIR"

T3_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T3_DIR" 2>&1)
assert_missing "T3: pr[0-9]* matched and deleted" "$T3_DIR/pr832-evidence-fix"
assert_missing "T3: pr-* matched and deleted" "$T3_DIR/pr-analyzer-123"
assert_missing "T3: pr_* matched and deleted" "$T3_DIR/pr_custom_debug"
assert_missing "T3: pr9* matched and deleted" "$T3_DIR/pr9001-deep-scan"
assert_missing "T3: claude-* matched and deleted" "$T3_DIR/claude-mcp-scratch"
assert_missing "T3: claude_* matched and deleted" "$T3_DIR/claude_ctx_temp"
assert_missing "T3: pr9999_report.md file matched and deleted" "$T3_DIR/pr9999_report.md"
assert_exists "T3: unrelated_user_code preserved" "$T3_DIR/unrelated_user_code"
assert_exists "T3: unrelated_file.txt preserved" "$T3_DIR/unrelated_file.txt"
assert_exists "T3: system-cache preserved" "$T3_DIR/system-cache"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Age Thresholds & Recency Protection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 4: Age Thresholds & Recency Protection"
T4_DIR="$TMP_TEST_ROOT/t4_tmp"
mkdir -p "$T4_DIR/pr-fresh" "$T4_DIR/pr-stale" "$T4_DIR/pr-nested-active/subdir"
# pr-fresh has current mtime
touch "$T4_DIR/pr-fresh/fresh.txt"

# pr-stale is backdated
set_old_mtime "$T4_DIR/pr-stale"

# pr-nested-active is backdated at root, but has a fresh nested file
set_old_mtime "$T4_DIR/pr-nested-active"
touch "$T4_DIR/pr-nested-active/subdir/newfile.txt"

T4_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T4_DIR" --min-age-hours 48 2>&1)
assert_exists "T4: fresh dir preserved" "$T4_DIR/pr-fresh"
assert_contains "T4: logs recently active skip for fresh dir" "Skipping recently active path" "$T4_OUT"
assert_missing "T4: stale dir removed" "$T4_DIR/pr-stale"
assert_exists "T4: nested-active dir preserved" "$T4_DIR/pr-nested-active"

# Test --min-age-days flag
T4B_DIR="$TMP_TEST_ROOT/t4b_tmp"
mkdir -p "$T4B_DIR/pr-days-test"
set_old_mtime "$T4B_DIR/pr-days-test"
T4B_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T4B_DIR" --min-age-days 2 2>&1)
assert_missing "T4: --min-age-days 2 deletes stale directory" "$T4B_DIR/pr-days-test"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Active Markers (.in-use and .keep)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 5: Active Markers (.in-use and .keep)"
T5_DIR="$TMP_TEST_ROOT/t5_tmp"
mkdir -p "$T5_DIR/pr-inuse" "$T5_DIR/pr-keep" "$T5_DIR/pr-normal"
touch "$T5_DIR/pr-inuse/.in-use"
touch "$T5_DIR/pr-keep/.keep"
set_old_mtime "$T5_DIR"

T5_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T5_DIR" 2>&1)
assert_exists "T5: .in-use dir preserved" "$T5_DIR/pr-inuse"
assert_exists "T5: .keep dir preserved" "$T5_DIR/pr-keep"
assert_missing "T5: normal dir removed" "$T5_DIR/pr-normal"
assert_contains "T5: logs active marker skip" "Skipping active-use marker" "$T5_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Open Files (lsof) Protection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 6: Open Files (lsof) Protection"
T6_DIR="$TMP_TEST_ROOT/t6_tmp"
mkdir -p "$T6_DIR/pr-open-dir"
touch "$T6_DIR/pr-open-dir/busy.log"
set_old_mtime "$T6_DIR"

# Open background process holding the file
tail -f "$T6_DIR/pr-open-dir/busy.log" >/dev/null 2>&1 &
HOLDER_PID=$!

# Give lsof a moment to see the open file
sleep 0.5

T6_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T6_DIR" --min-age-hours 0 2>&1)
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

assert_exists "T6: open directory preserved" "$T6_DIR/pr-open-dir"
assert_contains "T6: logs open files skip" "Skipping in-use path (open files)" "$T6_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Fail-Closed on lsof Error / Unavailable
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 7: Fail-Closed on lsof Error"
T7_DIR="$TMP_TEST_ROOT/t7_tmp"
mkdir -p "$T7_DIR/pr-lsof-fail"
set_old_mtime "$T7_DIR"

# Create a failing lsof mock
FAKE_LSOF="$TMP_TEST_ROOT/fake_lsof_error.sh"
cat > "$FAKE_LSOF" <<'EOF'
#!/usr/bin/env bash
echo "lsof: fatal kernel error" >&2
exit 2
EOF
chmod +x "$FAKE_LSOF"

T7_OUT=$(DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" bash "$TARGET_SCRIPT" --clean --tmp-dir "$T7_DIR" --min-age-hours 0 2>&1)
assert_exists "T7: preserved when lsof errors (fail closed)" "$T7_DIR/pr-lsof-fail"
assert_contains "T7: logs fail-closed open-file check failure" "fail-closed, treating as active" "$T7_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Git Worktree with Unsaved Work Protection
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 8: Git Worktree Protection"
T8_DIR="$TMP_TEST_ROOT/t8_tmp"
mkdir -p "$T8_DIR/pr-git-uncommitted"
git init -q "$T8_DIR/pr-git-uncommitted"
echo "initial" > "$T8_DIR/pr-git-uncommitted/file.txt"
git -C "$T8_DIR/pr-git-uncommitted" add file.txt
git -C "$T8_DIR/pr-git-uncommitted" commit -q -m "init"
# Add uncommitted modification
echo "dirty" >> "$T8_DIR/pr-git-uncommitted/file.txt"
set_old_mtime "$T8_DIR"

T8_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T8_DIR" 2>&1)
assert_exists "T8: uncommitted worktree preserved" "$T8_DIR/pr-git-uncommitted"
assert_contains "T8: logs unsaved work skip" "Skipping scratch worktree with unsaved work" "$T8_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Protected Roots and Safety Gate Integration
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 9: Protected Roots and Safety Gate Integration"
T9_DIR="$TMP_TEST_ROOT/t9_tmp"
mkdir -p "$T9_DIR/worldarchitect.ai" "$T9_DIR/pr-custom-protected"
set_old_mtime "$T9_DIR"

T9_OUT=$(DISK_MAGICIAN_PROTECTED_TMP_ROOTS="worldarchitect.ai pr-custom-protected" bash "$TARGET_SCRIPT" --clean --tmp-dir "$T9_DIR" 2>&1)
assert_exists "T9: worldarchitect.ai preserved" "$T9_DIR/worldarchitect.ai"
assert_exists "T9: pr-custom-protected preserved" "$T9_DIR/pr-custom-protected"
assert_contains "T9: logs protected root skip" "Skipping protected root" "$T9_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Argument Validation
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 10: Argument Validation"
set +e
INV_OUT=$(bash "$TARGET_SCRIPT" --invalid-flag 2>&1)
INV_RC=$?
set -e
assert_rc "T10: invalid flag returns non-zero" 2 "$INV_RC"
assert_contains "T10: invalid flag shows error" "Unknown option: --invalid-flag" "$INV_OUT"

set +e
AGE_OUT=$(bash "$TARGET_SCRIPT" --min-age-hours abc 2>&1)
AGE_RC=$?
set -e
assert_rc "T10: non-integer min-age-hours returns non-zero" 2 "$AGE_RC"

HELP_OUT=$(bash "$TARGET_SCRIPT" --help 2>&1)
assert_contains "T10: --help displays usage" "Usage: cleanup_pr_scratch.sh" "$HELP_OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Read-only entry does not abort the whole sweep (bead disk_magician-qap)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 11: Read-Only Entry Does Not Abort Sweep"
T11_DIR="$TMP_TEST_ROOT/t11_tmp"
mkdir -p "$T11_DIR/pr-readonly-dir/nested" "$T11_DIR/pr-normal-dir"
echo "data" > "$T11_DIR/pr-readonly-dir/nested/file.txt"
echo "data" > "$T11_DIR/pr-normal-dir/file.txt"
chmod -w "$T11_DIR/pr-readonly-dir/nested"
set_old_mtime "$T11_DIR"

# set +e/-e around the capture, matching the T10 pattern above: without it,
# a regression to the pre-fix bare `rm -rf` (which exits non-zero here)
# kills this whole test script under set -euo pipefail instead of failing
# this one assertion cleanly -- and skips the chmod-restore below, leaking
# a permanently read-only tree in TMPDIR (found in /advice review of PR #60,
# reproduced by Opus against the pre-fix commit).
set +e
T11_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T11_DIR" 2>&1)
T11_RC=$?
set -e
chmod -R u+w "$T11_DIR" 2>/dev/null || true
assert_rc "T11: sweep exits 0 despite a read-only entry" 0 "$T11_RC"
assert_missing "T11: read-only dir still removed (chmod u+w recovers it)" "$T11_DIR/pr-readonly-dir"
assert_missing "T11: sibling dir also removed (sweep did not abort)" "$T11_DIR/pr-normal-dir"

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: chmod-immune entry (chflags uchg) is SKIP-logged, not fatal (bead disk_magician-qap)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 12: chmod-Immune Entry Is Skipped, Not Fatal"
if command -v chflags >/dev/null 2>&1; then
  T12_DIR="$TMP_TEST_ROOT/t12_tmp"
  mkdir -p "$T12_DIR/pr-immutable-dir" "$T12_DIR/pr-normal-dir2"
  echo "data" > "$T12_DIR/pr-immutable-dir/file.txt"
  echo "data" > "$T12_DIR/pr-normal-dir2/file.txt"
  set_old_mtime "$T12_DIR"
  # uchg (user immutable) survives chmod -- only chflags nouchg or root can
  # clear it, so this exercises the "chmod couldn't help, rm still fails"
  # branch that Test 11 alone does not reach. Applied AFTER set_old_mtime,
  # which touches every file and would itself fail on an already-uchg path.
  chflags uchg "$T12_DIR/pr-immutable-dir/file.txt"

  set +e
  T12_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T12_DIR" 2>&1)
  T12_RC=$?
  set -e
  chflags nouchg "$T12_DIR/pr-immutable-dir/file.txt" 2>/dev/null || true
  chmod -R u+w "$T12_DIR" 2>/dev/null || true
  assert_rc "T12: sweep exits 0 despite a chmod-immune entry" 0 "$T12_RC"
  assert_contains "T12: unremovable item is SKIP-logged" "SKIP (rm failed)" "$T12_OUT"
  assert_contains "T12: summary reports the RM_FAILED count" "Skipped (rm failed): 1" "$T12_OUT"
  assert_missing "T12: sibling dir still removed (sweep did not abort)" "$T12_DIR/pr-normal-dir2"
else
  record_pass "T12: chflags unavailable on this platform, skipping (not a failure)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: symlink target permissions untouched (bead disk_magician-qap)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 13: Symlink Target Permissions Are Not Modified"
T13_DIR="$TMP_TEST_ROOT/t13_tmp"
T13_EXTERNAL="$TMP_TEST_ROOT/t13_external_file.txt"
mkdir -p "$T13_DIR"
echo "external data" > "$T13_EXTERNAL"
chmod 444 "$T13_EXTERNAL"
ln -s "$T13_EXTERNAL" "$T13_DIR/pr-stale-symlink"
set_old_mtime "$T13_DIR"
# set_old_mtime's `touch -t` follows symlinks by default, so it only
# backdated $T13_EXTERNAL (the target); backdate the symlink's own mtime
# with `-h` so the recency check doesn't see it as freshly created.
touch -h -t 202001010000 "$T13_DIR/pr-stale-symlink"
T13_PERMS_BEFORE="$(stat -f '%Lp' "$T13_EXTERNAL" 2>/dev/null || stat -c '%a' "$T13_EXTERNAL")"

T13_OUT=$(bash "$TARGET_SCRIPT" --clean --tmp-dir "$T13_DIR" 2>&1)
T13_PERMS_AFTER="$(stat -f '%Lp' "$T13_EXTERNAL" 2>/dev/null || stat -c '%a' "$T13_EXTERNAL")"
chmod u+w "$T13_EXTERNAL" 2>/dev/null || true
assert_missing "T13: stale symlink itself removed" "$T13_DIR/pr-stale-symlink"
if [[ "$T13_PERMS_BEFORE" == "$T13_PERMS_AFTER" ]]; then
  record_pass "T13: external symlink target permissions unchanged ($T13_PERMS_BEFORE)"
else
  record_fail "T13: external symlink target permissions unchanged" "was $T13_PERMS_BEFORE, now $T13_PERMS_AFTER"
fi

echo
echo "=== Test Results: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

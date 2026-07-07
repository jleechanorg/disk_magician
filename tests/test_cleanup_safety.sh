#!/usr/bin/env bash
# test_cleanup_safety.sh — Regression coverage for cleanup safety gates.
#
# Run: bash tests/test_cleanup_safety.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT=$(mktemp -d -t cleanup_safety.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() {
  echo "  PASS  $1"
  PASS=$(( PASS + 1 ))
}

record_fail() {
  echo "  FAIL  $1"
  echo "        $2"
  FAIL=$(( FAIL + 1 ))
}

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
    sed 's/^/        | /' <<<"$haystack"
  fi
}

run_capture() {
  local out_file="$1"
  shift
  set +e
  "$@" >"$out_file" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

make_fake_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem     Size   Used  Avail Capacity Mounted on\n'
printf '/dev/mock      100G    50G    50G    50%% /\n'
EOF
  chmod +x "$bin_dir/df"

  cat > "$bin_dir/tmutil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/tmutil"
}

echo "=== cleanup safety regression tests ==="

echo "Test 1: cleanup_worktrees.sh --clean requires WORKTREE_APPROVED=1"
HOME1="$TMP_ROOT/home-worktrees"
mkdir -p "$HOME1/.gemini/antigravity/worktrees/project/branch"
OUT1="$TMP_ROOT/worktrees.out"
if run_capture "$OUT1" env -i HOME="$HOME1" PATH="/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" --clean; then
  RC1=0
else
  RC1=$?
fi
OUT1_CONTENT=$(cat "$OUT1")
assert_rc "cleanup_worktrees --clean refusal exits 0" 0 "$RC1"
assert_contains "cleanup_worktrees refuses without approval" "Refusing to delete worktrees: set WORKTREE_APPROVED=1" "$OUT1_CONTENT"

echo "Test 2: disk_audit.sh clean --dry-run skips opt-in cleanup classes"
AUDIT_FIXTURE="$TMP_ROOT/audit-fixture"
mkdir -p "$AUDIT_FIXTURE/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE/scripts/disk_audit.sh"
for child in cleanup_dev_caches.sh cleanup_tmp.sh cleanup_llm_inspector.sh cleanup_supervisor_logs.sh; do
  cat > "$AUDIT_FIXTURE/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child \$*"
EOF
  chmod +x "$AUDIT_FIXTURE/scripts/$child"
done
FAKE_BIN2="$TMP_ROOT/bin-audit"
make_fake_bin "$FAKE_BIN2"
OUT2="$TMP_ROOT/disk-audit.out"
if run_capture "$OUT2" env -i HOME="$TMP_ROOT/home-audit" PATH="$FAKE_BIN2:/usr/bin:/bin" bash "$AUDIT_FIXTURE/scripts/disk_audit.sh" clean --dry-run --live --no-history; then
  RC2=0
else
  RC2=$?
fi
OUT2_CONTENT=$(cat "$OUT2")
assert_rc "disk_audit clean --dry-run exits 0" 0 "$RC2"
assert_contains "disk_audit skips worktrees by default" "Worktrees: skipped (requires WORKTREE_APPROVED=1)" "$OUT2_CONTENT"
assert_contains "disk_audit skips agent artifacts by default" "Agent artifacts: skipped (requires AGENT_ARTIFACTS_APPROVED=1)" "$OUT2_CONTENT"

echo "Test 3: cleanup_tmp.sh --clean --large requires LARGE_TMP_APPROVED=1"
OUT3="$TMP_ROOT/tmp-clean-large.out"
if run_capture "$OUT3" env -i HOME="$TMP_ROOT/home-tmp-clean" PATH="/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --large; then
  RC3=0
else
  RC3=$?
fi
OUT3_CONTENT=$(cat "$OUT3")
assert_rc "cleanup_tmp --clean --large refusal exits 0" 0 "$RC3"
assert_contains "cleanup_tmp refuses large delete without approval" "Refusing large /private/tmp deletion: set LARGE_TMP_APPROVED=1" "$OUT3_CONTENT"

echo "Test 4: disk_audit.sh clean-all --dry-run skips sessions by default"
AUDIT_FIXTURE_ALL="$TMP_ROOT/audit-fixture-clean-all"
mkdir -p "$AUDIT_FIXTURE_ALL/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE_ALL/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE_ALL/scripts/disk_audit.sh"
for child in cleanup_tmp.sh cleanup_apfs_snapshots.sh cleanup_docker.sh cleanup_ollama.sh cleanup_xcode.sh; do
  cat > "$AUDIT_FIXTURE_ALL/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child \$*"
EOF
  chmod +x "$AUDIT_FIXTURE_ALL/scripts/$child"
done
cat > "$AUDIT_FIXTURE_ALL/scripts/cleanup_sessions.sh" <<'EOF'
#!/usr/bin/env bash
echo "SHOULD_NOT_RUN cleanup_sessions"
exit 9
EOF
chmod +x "$AUDIT_FIXTURE_ALL/scripts/cleanup_sessions.sh"
FAKE_BIN4="$TMP_ROOT/bin-audit-clean-all"
make_fake_bin "$FAKE_BIN4"
OUT4="$TMP_ROOT/disk-audit-clean-all.out"
if run_capture "$OUT4" env -i HOME="$TMP_ROOT/home-audit-clean-all" PATH="$FAKE_BIN4:/usr/bin:/bin" bash "$AUDIT_FIXTURE_ALL/scripts/disk_audit.sh" clean-all --dry-run --live --no-history; then
  RC4=0
else
  RC4=$?
fi
OUT4_CONTENT=$(cat "$OUT4")
assert_rc "disk_audit clean-all --dry-run exits 0" 0 "$RC4"
assert_contains "disk_audit skips sessions by default" "Sessions: skipped (requires SESSIONS_APPROVED=1)" "$OUT4_CONTENT"

echo "Test 5: cleanup_tmp.sh --dry-run --large skips wt_* temp worktree dirs"
FAKE_PRIVATE_TMP="$TMP_ROOT/private-tmp"
FAKE_EMPTY_TMP="$TMP_ROOT/empty-tmp"
FAKE_BIN5="$TMP_ROOT/bin-tmp"
mkdir -p "$FAKE_PRIVATE_TMP/wt_regression" "$FAKE_EMPTY_TMP" "$FAKE_BIN5"
cat > "$FAKE_BIN5/find" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  /private/tmp)
    shift
    exec /usr/bin/find "$FAKE_PRIVATE_TMP" "$@"
    ;;
  /tmp)
    shift
    exec /usr/bin/find "$FAKE_EMPTY_TMP" "$@"
    ;;
  *)
    exec /usr/bin/find "$@"
    ;;
esac
EOF
chmod +x "$FAKE_BIN5/find"
cat > "$FAKE_BIN5/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  exit 0
fi
exec /usr/bin/getconf "$@"
EOF
chmod +x "$FAKE_BIN5/getconf"
OUT5="$TMP_ROOT/tmp-dry-large.out"
if run_capture "$OUT5" env -i HOME="$TMP_ROOT/home-tmp-dry" FAKE_PRIVATE_TMP="$FAKE_PRIVATE_TMP" FAKE_EMPTY_TMP="$FAKE_EMPTY_TMP" PATH="$FAKE_BIN5:/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --large; then
  RC5=0
else
  RC5=$?
fi
OUT5_CONTENT=$(cat "$OUT5")
assert_rc "cleanup_tmp --dry-run --large exits 0" 0 "$RC5"
assert_contains "cleanup_tmp reports skipped wt_* temp worktree" "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $FAKE_PRIVATE_TMP/wt_regression" "$OUT5_CONTENT"

echo "Test 6: cleanup scripts accept --dry-run"
FAKE_BIN6="$TMP_ROOT/bin-dryrun"
make_fake_bin "$FAKE_BIN6"
for script in \
  cleanup_apfs_snapshots.sh \
  cleanup_llm_inspector.sh \
  cleanup_supervisor_logs.sh \
  cleanup_agent_artifacts.sh
do
  out="$TMP_ROOT/${script}.out"
  if run_capture "$out" env -i HOME="$TMP_ROOT/home-${script%.sh}" PATH="$FAKE_BIN6:/usr/bin:/bin" bash "$REPO_ROOT/scripts/$script" --dry-run; then
    rc=0
  else
    rc=$?
  fi
  assert_rc "$script accepts --dry-run" 0 "$rc"
done

echo "Test 7: disk_audit.sh clean --dry-run attempts and reports all non-gated categories"
AUDIT_FIXTURE7="$TMP_ROOT/audit-fixture-all-categories"
mkdir -p "$AUDIT_FIXTURE7/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE7/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE7/scripts/disk_audit.sh"
for child in cleanup_dev_caches.sh cleanup_tmp.sh cleanup_llm_inspector.sh cleanup_supervisor_logs.sh post_job_docker_prune.sh; do
  cat > "$AUDIT_FIXTURE7/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child ran with: \$*"
exit 0
EOF
  chmod +x "$AUDIT_FIXTURE7/scripts/$child"
done
FAKE_BIN7="$TMP_ROOT/bin-audit-all-categories"
make_fake_bin "$FAKE_BIN7"
OUT7="$TMP_ROOT/disk-audit-all-categories.out"
if run_capture "$OUT7" env -i HOME="$TMP_ROOT/home-audit-all-categories" PATH="$FAKE_BIN7:/usr/bin:/bin" bash "$AUDIT_FIXTURE7/scripts/disk_audit.sh" clean --dry-run --live --no-history; then
  RC7=0
else
  RC7=$?
fi
OUT7_CONTENT=$(cat "$OUT7")
assert_rc "disk_audit clean --dry-run exits 0 when all categories succeed" 0 "$RC7"
assert_contains "disk_audit ran dev caches category" "stub cleanup_dev_caches.sh ran with: --dry-run" "$OUT7_CONTENT"
assert_contains "disk_audit ran temp files category" "stub cleanup_tmp.sh ran with: --dry-run" "$OUT7_CONTENT"
assert_contains "disk_audit ran LLM inspector category" "stub cleanup_llm_inspector.sh ran with: --dry-run" "$OUT7_CONTENT"
assert_contains "disk_audit ran supervisor logs category" "stub cleanup_supervisor_logs.sh ran with: --dry-run" "$OUT7_CONTENT"
assert_contains "disk_audit ran post-job docker prune category" "stub post_job_docker_prune.sh ran with: --dry-run" "$OUT7_CONTENT"
assert_contains "disk_audit reports category summary header" "── Cleanup Category Summary ──" "$OUT7_CONTENT"
assert_contains "disk_audit reports all-clear when nothing failed" "All attempted categories completed without error." "$OUT7_CONTENT"

echo "Test 8: disk_audit.sh surfaces a failing category instead of silently swallowing it (bd-y74 regression)"
# Root cause of bd-y74: sub-scripts invoked via `\$clean_arg || true` where a
# sub-script only supports --clean (not --dry-run). The failure exited
# non-zero but `|| true` swallowed it with no visible signal, so the
# category silently never ran. This test recreates that exact failure mode
# and asserts the failure is now surfaced loudly instead of disappearing.
AUDIT_FIXTURE8="$TMP_ROOT/audit-fixture-failing-category"
mkdir -p "$AUDIT_FIXTURE8/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE8/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE8/scripts/disk_audit.sh"
for child in cleanup_dev_caches.sh cleanup_tmp.sh cleanup_supervisor_logs.sh; do
  cat > "$AUDIT_FIXTURE8/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child ran with: \$*"
exit 0
EOF
  chmod +x "$AUDIT_FIXTURE8/scripts/$child"
done
# Simulate a sub-script that only accepts --clean (the historical bd-y74 bug shape).
cat > "$AUDIT_FIXTURE8/scripts/cleanup_llm_inspector.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --clean) exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac
EOF
chmod +x "$AUDIT_FIXTURE8/scripts/cleanup_llm_inspector.sh"
FAKE_BIN8="$TMP_ROOT/bin-audit-failing-category"
make_fake_bin "$FAKE_BIN8"
OUT8="$TMP_ROOT/disk-audit-failing-category.out"
if run_capture "$OUT8" env -i HOME="$TMP_ROOT/home-audit-failing-category" PATH="$FAKE_BIN8:/usr/bin:/bin" bash "$AUDIT_FIXTURE8/scripts/disk_audit.sh" clean --dry-run --live --no-history; then
  RC8=0
else
  RC8=$?
fi
OUT8_CONTENT=$(cat "$OUT8")
# The audit as a whole must keep running (rc=0) so other categories still execute...
assert_rc "disk_audit clean --dry-run still completes when one category fails" 0 "$RC8"
# ...but the failure must no longer be silently swallowed by `|| true`.
assert_contains "disk_audit surfaces the failing category by name" "CATEGORY FAILED: LLM inspector (exit 2)" "$OUT8_CONTENT"
assert_contains "disk_audit summary counts the failure" "1 of" "$OUT8_CONTENT"
assert_contains "disk_audit still ran the category after the failing one" "stub cleanup_supervisor_logs.sh ran with: --dry-run" "$OUT8_CONTENT"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

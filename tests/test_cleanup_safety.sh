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

echo "Test 7: cleanup_tmp.sh guards OpenCode dylib cleanup and preserves open/unrelated files"
DYLIB_REAL="$TMP_ROOT/darwin-user-temp-real"
DYLIB_TMP="$TMP_ROOT/darwin-user-temp-alias"
FAKE_BIN7="$TMP_ROOT/bin-dylib"
mkdir -p "$DYLIB_REAL" "$FAKE_BIN7"
ln -s "$DYLIB_REAL" "$DYLIB_TMP"
DYLIB_REAL=$(cd "$DYLIB_REAL" && pwd -P)
CLOSED_DYLIB="$DYLIB_REAL/.bbc1111111111111-00000000.dylib"
OPEN_DYLIB="$DYLIB_REAL/.bbc2222222222222-00000000.dylib"
UNRELATED_DYLIB="$DYLIB_REAL/.bbc3333333333333-00000000.dylib"
RACE_DYLIB="$DYLIB_REAL/.bbc4444444444444-00000000.dylib"
FAIL_DYLIB="$DYLIB_REAL/.bbc5555555555555-00000000.dylib"
printf 'closed' > "$CLOSED_DYLIB"
printf 'open' > "$OPEN_DYLIB"
printf 'unrelated' > "$UNRELATED_DYLIB"

cat > "$FAKE_BIN7/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  printf '%s\n' "$FAKE_DYLIB_TMP"
  exit 0
fi
exec /usr/bin/getconf "$@"
EOF
cat > "$FAKE_BIN7/lsof" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_LSOF_FAIL:-0}" == "1" ]]; then
  exit 2
fi
if [[ -n "${FAKE_RACE_DYLIB:-}" ]]; then
  printf 'race' > "$FAKE_RACE_DYLIB"
fi
printf 'p123\n'
printf 'n%s\n' "$FAKE_OPEN_DYLIB"
EOF
cat > "$FAKE_BIN7/otool" <<'EOF'
#!/usr/bin/env bash
if /usr/bin/grep -q unrelated "${2:-}"; then
  printf '\t/usr/lib/libSystem.B.dylib\n'
else
  printf '@rpath/libopentui.dylib\n'
fi
EOF
chmod +x "$FAKE_BIN7/getconf" "$FAKE_BIN7/lsof" "$FAKE_BIN7/otool"

OUT7_REFUSE="$TMP_ROOT/dylib-refuse.out"
if run_capture "$OUT7_REFUSE" env -i HOME="$TMP_ROOT/home-dylib" \
  FAKE_DYLIB_TMP="$DYLIB_TMP" FAKE_OPEN_DYLIB="$OPEN_DYLIB" \
  PATH="$FAKE_BIN7:/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --opencode-dylibs; then
  RC7_REFUSE=0
else
  RC7_REFUSE=$?
fi
assert_rc "OpenCode dylib cleanup refusal exits 0" 0 "$RC7_REFUSE"
assert_contains "OpenCode dylib cleanup requires approval" \
  "Refusing OpenCode dylib cleanup: set OPENCODE_DYLIBS_APPROVED=1" "$(cat "$OUT7_REFUSE")"

OUT7_CLEAN="$TMP_ROOT/dylib-clean.out"
if run_capture "$OUT7_CLEAN" env -i HOME="$TMP_ROOT/home-dylib" \
  OPENCODE_DYLIBS_APPROVED=1 FAKE_DYLIB_TMP="$DYLIB_TMP" FAKE_OPEN_DYLIB="$OPEN_DYLIB" \
  FAKE_RACE_DYLIB="$RACE_DYLIB" \
  PATH="$FAKE_BIN7:/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --opencode-dylibs; then
  RC7_CLEAN=0
else
  RC7_CLEAN=$?
fi
assert_rc "approved OpenCode dylib cleanup exits 0" 0 "$RC7_CLEAN"
assert_missing "closed libopentui dylib is deleted" "$CLOSED_DYLIB"
assert_exists "open libopentui dylib is preserved" "$OPEN_DYLIB"
assert_exists "unrelated dylib is preserved" "$UNRELATED_DYLIB"
assert_exists "dylib created after candidate freeze is preserved" "$RACE_DYLIB"
assert_contains "open libopentui dylib is reported skipped" \
  "Skipping in-use OpenCode dylib: $OPEN_DYLIB" "$(cat "$OUT7_CLEAN")"

printf 'closed' > "$FAIL_DYLIB"
OUT7_LSOF_FAIL="$TMP_ROOT/dylib-lsof-fail.out"
if run_capture "$OUT7_LSOF_FAIL" env -i HOME="$TMP_ROOT/home-dylib" \
  OPENCODE_DYLIBS_APPROVED=1 FAKE_DYLIB_TMP="$DYLIB_TMP" FAKE_OPEN_DYLIB="$OPEN_DYLIB" \
  FAKE_LSOF_FAIL=1 PATH="$FAKE_BIN7:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --opencode-dylibs; then
  RC7_LSOF_FAIL=0
else
  RC7_LSOF_FAIL=$?
fi
assert_rc "OpenCode dylib cleanup fails closed when lsof errors" 0 "$RC7_LSOF_FAIL"
assert_exists "closed dylib is preserved when lsof errors" "$FAIL_DYLIB"
assert_contains "lsof failure is reported" "Skipping OpenCode dylibs: lsof failed" "$(cat "$OUT7_LSOF_FAIL")"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

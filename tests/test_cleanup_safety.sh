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
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    record_fail "$name" "expected output not to contain: $needle"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  else
    record_pass "$name"
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

echo "Test 8: cleanup_code_sign_clones.sh requires approval and respects dry-run"
CSC_PARENT="$TMP_ROOT/csc-parent"
CSC_X="$CSC_PARENT/X"
CSC_ACTIVE="$CSC_X/at.studio.Active App.code_sign_clone"
CSC_FOREIGN="$CSC_X/com.example.ForeignOwner.code_sign_clone"
CSC_RACE="$CSC_X/com.example.Race.code_sign_clone"
CSC_SYMLINK_TARGET="$TMP_ROOT/protected-clone-target"
CSC_SYMLINK="$CSC_X/com.example.Symlink.code_sign_clone"
mkdir -p "$CSC_PARENT/T" \
  "$CSC_X/at.studio.AsideBrowser.code_sign_clone" \
  "$CSC_ACTIVE" "$CSC_FOREIGN" "$CSC_RACE" \
  "$CSC_X/com.tiny.code_sign_clone" "$CSC_SYMLINK_TARGET"
ln -s "$CSC_SYMLINK_TARGET" "$CSC_SYMLINK"
CSC_X=$(cd "$CSC_X" && pwd -P)
CSC_ACTIVE="$CSC_X/at.studio.Active App.code_sign_clone"
CSC_FOREIGN="$CSC_X/com.example.ForeignOwner.code_sign_clone"
CSC_RACE="$CSC_X/com.example.Race.code_sign_clone"
CSC_SYMLINK="$CSC_X/com.example.Symlink.code_sign_clone"
head -c 200000 /dev/zero > "$CSC_X/at.studio.AsideBrowser.code_sign_clone/blob"
head -c 200000 /dev/zero > "$CSC_ACTIVE/blob"
head -c 200000 /dev/zero > "$CSC_FOREIGN/blob"
head -c 200000 /dev/zero > "$CSC_RACE/blob"
printf 'protected' > "$CSC_SYMLINK_TARGET/blob"
printf 'x' > "$CSC_X/com.tiny.code_sign_clone/x"
FAKE_BIN8="$TMP_ROOT/bin-csc"
mkdir -p "$FAKE_BIN8"
cat > "$FAKE_BIN8/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  printf '%s\n' "$FAKE_CSC_TMP"
  exit 0
fi
exec /usr/bin/getconf "$@"
EOF
chmod +x "$FAKE_BIN8/getconf"
cat > "$FAKE_BIN8/lsof" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_LSOF_FAIL:-0}" == "1" ]]; then
  echo "simulated lsof failure" >&2
  exit 2
fi
target="${!#}"
if [[ -n "${FAKE_LSOF_ACTIVE:-}" && "$target" == "$FAKE_LSOF_ACTIVE" ]]; then
  printf 'p4242\ncAsideBrowser\nn%s/blob\n' "$target"
  # macOS lsof can return 1 despite emitting valid +D matches.
  exit 1
fi
if [[ -n "${FAKE_LSOF_RACE_TARGET:-}" && "$target" == "$FAKE_LSOF_RACE_TARGET" ]]; then
  count=0
  [[ -f "$FAKE_LSOF_STATE" ]] && count=$(cat "$FAKE_LSOF_STATE")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAKE_LSOF_STATE"
  if [[ "$count" -eq 2 ]]; then
    rm -rf "$target"
    mkdir -p "$target"
    printf 'replacement' > "$target/replacement"
  fi
fi
exit 1
EOF
cat > "$FAKE_BIN8/stat" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
if [[ -n "${FAKE_FOREIGN_OWNER:-}" && "$target" == "$FAKE_FOREIGN_OWNER" ]]; then
  printf '1:2:0\n'
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$FAKE_BIN8/lsof" "$FAKE_BIN8/stat"
FAKE_BIN8_NO_LSOF="$TMP_ROOT/bin-csc-no-lsof"
mkdir -p "$FAKE_BIN8_NO_LSOF"
cp "$FAKE_BIN8/getconf" "$FAKE_BIN8/stat" "$FAKE_BIN8_NO_LSOF/"

OUT8_REFUSE="$TMP_ROOT/csc-refuse.out"
if run_capture "$OUT8_REFUSE" env -i HOME="$TMP_ROOT/home-csc" FAKE_CSC_TMP="$CSC_PARENT/T"   CODE_SIGN_CLONE_MIN_KB=1 PATH="$FAKE_BIN8:/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --clean; then
  RC8_REFUSE=0
else RC8_REFUSE=$?; fi
assert_rc "code_sign_clone clean requires approval" 0 "$RC8_REFUSE"
assert_contains "code_sign_clone refusal message" "Refusing code_sign_clone deletion" "$(cat "$OUT8_REFUSE")"
assert_exists "large clone preserved without approval" "$CSC_X/at.studio.AsideBrowser.code_sign_clone"

OUT8_DRY="$TMP_ROOT/csc-dry.out"
if run_capture "$OUT8_DRY" env -i HOME="$TMP_ROOT/home-csc" FAKE_CSC_TMP="$CSC_PARENT/T"   CODE_SIGN_CLONE_MIN_KB=1 PATH="$FAKE_BIN8:/usr/bin:/bin" bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --dry-run; then
  RC8_DRY=0
else RC8_DRY=$?; fi
assert_rc "code_sign_clone dry-run exits 0" 0 "$RC8_DRY"
assert_contains "code_sign_clone dry-run reports large clone" "AsideBrowser.code_sign_clone" "$(cat "$OUT8_DRY")"
assert_exists "code_sign_clone dry-run does not delete" "$CSC_X/at.studio.AsideBrowser.code_sign_clone"

OUT8_ACTIVE="$TMP_ROOT/csc-active.out"
if run_capture "$OUT8_ACTIVE" env -i HOME="$TMP_ROOT/home-csc" \
  FAKE_CSC_TMP="$CSC_PARENT/T" FAKE_LSOF_ACTIVE="$CSC_ACTIVE" \
  CODE_SIGN_CLONE_MIN_KB=150 PATH="$FAKE_BIN8:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --dry-run; then
  RC8_ACTIVE=0
else RC8_ACTIVE=$?; fi
assert_rc "code_sign_clone dry-run classifies active clone" 0 "$RC8_ACTIVE"
assert_contains "active code_sign_clone is reported as preserved" \
  "ACTIVE — preserving: $CSC_ACTIVE" "$(cat "$OUT8_ACTIVE")"
assert_contains "active code_sign_clone reports owner process" \
  "pid=4242 command=AsideBrowser" "$(cat "$OUT8_ACTIVE")"
assert_exists "active code_sign_clone with spaces is preserved" "$CSC_ACTIVE"

OUT8_NO_LSOF="$TMP_ROOT/csc-no-lsof.out"
if run_capture "$OUT8_NO_LSOF" env -i HOME="$TMP_ROOT/home-csc" \
  FAKE_CSC_TMP="$CSC_PARENT/T" CODE_SIGN_CLONE_MIN_KB=150 \
  PATH="$FAKE_BIN8_NO_LSOF:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --dry-run; then
  RC8_NO_LSOF=0
else RC8_NO_LSOF=$?; fi
assert_rc "code_sign_clone dry-run fails closed without lsof" 0 "$RC8_NO_LSOF"
assert_contains "missing lsof is reported as unknown, not removable" \
  "lsof unavailable — preserving all candidates" "$(cat "$OUT8_NO_LSOF")"
assert_exists "clone is preserved without lsof" "$CSC_X/at.studio.AsideBrowser.code_sign_clone"

OUT8_FOREIGN="$TMP_ROOT/csc-foreign-owner.out"
if run_capture "$OUT8_FOREIGN" env -i HOME="$TMP_ROOT/home-csc" \
  FAKE_CSC_TMP="$CSC_PARENT/T" FAKE_FOREIGN_OWNER="$CSC_FOREIGN" \
  CODE_SIGN_CLONE_MIN_KB=150 PATH="$FAKE_BIN8:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --dry-run; then
  RC8_FOREIGN=0
else RC8_FOREIGN=$?; fi
assert_rc "code_sign_clone dry-run rejects foreign-owned candidate" 0 "$RC8_FOREIGN"
assert_contains "foreign-owned candidate is reported unsafe" \
  "Unsafe candidate ownership or identity changed — preserving: $CSC_FOREIGN" "$(cat "$OUT8_FOREIGN")"
assert_exists "foreign-owned candidate is preserved" "$CSC_FOREIGN"
assert_exists "symlinked clone target is preserved" "$CSC_SYMLINK_TARGET/blob"

OUT8_LSOF_FAIL="$TMP_ROOT/csc-lsof-fail.out"
if run_capture "$OUT8_LSOF_FAIL" env -i HOME="$TMP_ROOT/home-csc" \
  CODE_SIGN_CLONES_APPROVED=1 FAKE_CSC_TMP="$CSC_PARENT/T" CODE_SIGN_CLONE_MIN_KB=150 FAKE_LSOF_FAIL=1 PATH="$FAKE_BIN8:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --clean; then
  RC8_LSOF_FAIL=0
else RC8_LSOF_FAIL=$?; fi
assert_rc "code_sign_clone clean skips when lsof fails" 0 "$RC8_LSOF_FAIL"
assert_contains "code_sign_clone lsof failure is reported" "Skipping code_sign_clones: lsof failed" "$(cat "$OUT8_LSOF_FAIL")"
assert_exists "code_sign_clone preserved when lsof fails" "$CSC_X/at.studio.AsideBrowser.code_sign_clone"

OUT8_RACE="$TMP_ROOT/csc-race.out"
if run_capture "$OUT8_RACE" env -i HOME="$TMP_ROOT/home-csc" \
  CODE_SIGN_CLONES_APPROVED=1 FAKE_CSC_TMP="$CSC_PARENT/T" \
  FAKE_LSOF_ACTIVE="$CSC_ACTIVE" FAKE_FOREIGN_OWNER="$CSC_FOREIGN" \
  FAKE_LSOF_RACE_TARGET="$CSC_RACE" FAKE_LSOF_STATE="$TMP_ROOT/csc-lsof-count" \
  CODE_SIGN_CLONE_MIN_KB=150 PATH="$FAKE_BIN8:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --clean; then
  RC8_RACE=0
else RC8_RACE=$?; fi
assert_rc "code_sign_clone clean detects replacement race" 0 "$RC8_RACE"
assert_contains "replacement candidate is reported and preserved" \
  "Candidate changed after lsof recheck — preserving: $CSC_RACE" "$(cat "$OUT8_RACE")"
assert_exists "replacement clone is preserved" "$CSC_RACE/replacement"

OUT8_CLEAN="$TMP_ROOT/csc-clean.out"
if run_capture "$OUT8_CLEAN" env -i HOME="$TMP_ROOT/home-csc" \
  CODE_SIGN_CLONES_APPROVED=1 FAKE_CSC_TMP="$CSC_PARENT/T" \
  FAKE_LSOF_ACTIVE="$CSC_ACTIVE" FAKE_FOREIGN_OWNER="$CSC_FOREIGN" \
  CODE_SIGN_CLONE_MIN_KB=150 PATH="$FAKE_BIN8:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --clean; then
  RC8_CLEAN=0
else RC8_CLEAN=$?; fi
assert_rc "code_sign_clone clean requires approval env" 0 "$RC8_CLEAN"
assert_missing "large clone removed during approved clean" "$CSC_X/at.studio.AsideBrowser.code_sign_clone"
assert_exists "active clone remains during approved clean" "$CSC_ACTIVE"
assert_exists "foreign-owned clone remains during approved clean" "$CSC_FOREIGN"
assert_exists "replacement clone remains during approved clean" "$CSC_RACE"
assert_exists "small clone preserved above threshold" "$CSC_X/com.tiny.code_sign_clone"


echo "Test 9: pressure_sweep passes --large and LARGE_TMP_APPROVED when cleaning"
PS_LOG="$TMP_ROOT/pressure-sweep.log"
PS_STATE="$TMP_ROOT/pressure-state"
mkdir -p "$PS_STATE"
OUT9="$TMP_ROOT/pressure.out"
if run_capture "$OUT9" env -i HOME="$TMP_ROOT/home-ps" \
  DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE=10 \
  DISK_MAGICIAN_STATE_DIR="$PS_STATE" \
  DISK_MAGICIAN_PRESSURE_LOG="$PS_LOG" \
  PATH="/usr/bin:/bin" bash "$REPO_ROOT/scripts/pressure_sweep.sh"; then
  RC9=0
else RC9=$?; fi
assert_rc "pressure_sweep triggered path exits 0" 0 "$RC9"
OUT9_CONTENT=$(cat "$OUT9")
assert_contains "pressure_sweep logs --large" "cleanup_tmp.sh --clean --large" "$OUT9_CONTENT"
assert_contains "pressure_sweep invokes cleanup_tmp step" "cleanup_tmp.sh" "$OUT9_CONTENT"

echo "Test 10: cleanup_colima trims through the proven active backend without an implicit restart"
COLIMA_HOME=$(mktemp -d /tmp/dm-colima.XXXXXX)
trap 'rm -rf "$TMP_ROOT" "$COLIMA_HOME"' EXIT
COLIMA_FAKE_BIN="$TMP_ROOT/bin-colima"
COLIMA_INVOCATIONS="$TMP_ROOT/colima-invocations.log"
COLIMA_SSH_DIR="$COLIMA_HOME/.colima/_lima/colima"
mkdir -p "$COLIMA_FAKE_BIN" "$COLIMA_HOME/.colima/default" "$COLIMA_SSH_DIR"
python3 - "$COLIMA_HOME/.colima/default/docker.sock" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY
touch "$COLIMA_SSH_DIR/ssh.sock"
cat > "$COLIMA_SSH_DIR/ssh.config" <<EOF
Host lima-colima
  ControlPath "$COLIMA_SSH_DIR/ssh.sock"
EOF

cat > "$COLIMA_FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$COLIMA_INVOCATIONS"
case "${1:-} ${2:-}" in
  "info ")
    if [[ "${FAKE_REQUIRE_EFFECTIVE_HOST:-0}" == "1" \
          && "${DOCKER_HOST:-}" != "unix://$HOME/.colima/default/docker.sock" ]]; then
      exit 1
    fi
    if [[ -n "${FAKE_DOCKER_INFO_FAIL_ONCE_STATE:-}" \
          && ! -e "$FAKE_DOCKER_INFO_FAIL_ONCE_STATE" ]]; then
      touch "$FAKE_DOCKER_INFO_FAIL_ONCE_STATE"
      exit 1
    fi
    exit "${FAKE_DOCKER_INFO_RC:-0}"
    ;;
  "context show") printf 'colima\n' ;;
  "context inspect") printf '%s\n' "${FAKE_DOCKER_HOST:-unix://$HOME/.colima/default/docker.sock}" ;;
  "system df") printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\n' ;;
  "ps -q")
    [[ "${FAKE_DOCKER_PS_RC:-0}" == "0" ]] || exit "$FAKE_DOCKER_PS_RC"
    [[ "${FAKE_DOCKER_RUNNING:-1}" == "1" ]] && printf 'running-container\n'
    ;;
esac
exit 0
EOF
cat > "$COLIMA_FAKE_BIN/colima" <<'EOF'
#!/usr/bin/env bash
printf 'colima %s\n' "$*" >> "$COLIMA_INVOCATIONS"
case "${1:-}" in
  status) exit 1 ;;
  ssh) exit 1 ;;
  stop|start) exit 0 ;;
esac
exit 0
EOF
cat > "$COLIMA_FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$COLIMA_INVOCATIONS"
if [[ "$*" == *" -O check "* ]]; then
  exit "${FAKE_SSH_CHECK_RC:-0}"
fi
if [[ "$*" == *"sudo fstrim -av"* ]]; then
  exit "${FAKE_SSH_TRIM_RC:-0}"
fi
exit 0
EOF
chmod +x "$COLIMA_FAKE_BIN/docker" "$COLIMA_FAKE_BIN/colima" "$COLIMA_FAKE_BIN/ssh"

OUT10_AUTOROUTE="$TMP_ROOT/colima-autoroute.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_AUTOROUTE" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" \
  FAKE_DOCKER_HOST="unix:///var/run/docker.sock" \
  FAKE_REQUIRE_EFFECTIVE_HOST=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --dry-run; then
  RC10_AUTOROUTE=0
else RC10_AUTOROUTE=$?; fi
assert_rc "cleanup_colima auto-routes to the proven Colima socket" 0 "$RC10_AUTOROUTE"
assert_contains "cleanup_colima reports safe Colima socket selection" \
  "Selected proven Colima Docker socket" "$(cat "$OUT10_AUTOROUTE")"
assert_contains "cleanup_colima reaches Docker inventory through selected socket" \
  "docker system df" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_MUX="$TMP_ROOT/colima-mux.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_MUX" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_MUX=0
else RC10_MUX=$?; fi
assert_rc "cleanup_colima active-backend fallback exits 0" 0 "$RC10_MUX"
assert_contains "cleanup_colima uses the proven Lima control master" \
  "fstrim via active Lima SSH control master" "$(cat "$OUT10_MUX")"
assert_contains "cleanup_colima invokes fstrim through direct SSH" \
  "sudo fstrim -av" "$(cat "$COLIMA_INVOCATIONS")"
assert_not_contains "cleanup_colima does not stop an active backend" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_CONTEXT="$TMP_ROOT/colima-context-mismatch.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_CONTEXT" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" \
  DOCKER_HOST="unix:///tmp/not-colima.sock" \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_CONTEXT=0
else RC10_CONTEXT=$?; fi
assert_rc "cleanup_colima context mismatch fails closed" 0 "$RC10_CONTEXT"
assert_contains "cleanup_colima reports unproven Docker backend" \
  "does not match the expected Colima socket" "$(cat "$OUT10_CONTEXT")"
assert_not_contains "cleanup_colima does not trim through an unproven backend" \
  "sudo fstrim -av" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_CONTEXT_PRECEDENCE="$TMP_ROOT/colima-context-precedence.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_CONTEXT_PRECEDENCE" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" \
  DOCKER_CONTEXT="explicit-remote" \
  DOCKER_HOST="unix://$COLIMA_HOME/.colima/default/docker.sock" \
  FAKE_DOCKER_HOST="unix:///tmp/not-colima.sock" \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_CONTEXT_PRECEDENCE=0
else RC10_CONTEXT_PRECEDENCE=$?; fi
assert_rc "cleanup_colima honors explicit Docker context precedence" 0 "$RC10_CONTEXT_PRECEDENCE"
assert_contains "cleanup_colima rejects an explicit non-Colima Docker context" \
  "does not match the expected Colima socket" "$(cat "$OUT10_CONTEXT_PRECEDENCE")"
assert_not_contains "cleanup_colima never inventories an explicit non-Colima context" \
  "docker system df" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_BLOCKED="$TMP_ROOT/colima-restart-blocked.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_BLOCKED" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_SSH_CHECK_RC=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_BLOCKED=0
else RC10_BLOCKED=$?; fi
assert_rc "cleanup_colima blocked recovery exits 0" 0 "$RC10_BLOCKED"
assert_contains "cleanup_colima requires the exact restart approval" \
  "VACATE_CI_RUNNERS_APPROVED=1" "$(cat "$OUT10_BLOCKED")"
assert_not_contains "cleanup_colima never restarts without approval" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_RUNNING="$TMP_ROOT/colima-restart-running.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_RUNNING" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_SSH_CHECK_RC=1 \
  VACATE_CI_RUNNERS_APPROVED=1 FAKE_DOCKER_RUNNING=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_RUNNING=0
else RC10_RUNNING=$?; fi
assert_rc "cleanup_colima approved recovery still preserves running containers" 0 "$RC10_RUNNING"
assert_contains "cleanup_colima reports running-container restart refusal" \
  "running containers remain" "$(cat "$OUT10_RUNNING")"
assert_not_contains "cleanup_colima does not stop with running containers" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_INITIAL_BLOCKED="$TMP_ROOT/colima-initial-docker-blocked.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_INITIAL_BLOCKED" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_DOCKER_INFO_RC=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_INITIAL_BLOCKED=0
else RC10_INITIAL_BLOCKED=$?; fi
assert_rc "cleanup_colima initial Docker failure exits safely" 0 "$RC10_INITIAL_BLOCKED"
assert_contains "cleanup_colima initial Docker failure reaches guarded recovery" \
  "VACATE_CI_RUNNERS_APPROVED=1" "$(cat "$OUT10_INITIAL_BLOCKED")"
assert_not_contains "cleanup_colima initial Docker failure never restarts without approval" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_INITIAL_UNPROVEN="$TMP_ROOT/colima-initial-docker-unproven.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_INITIAL_UNPROVEN" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_DOCKER_INFO_RC=1 \
  DOCKER_HOST="unix:///tmp/not-colima.sock" VACATE_CI_RUNNERS_APPROVED=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_INITIAL_UNPROVEN=0
else RC10_INITIAL_UNPROVEN=$?; fi
assert_rc "cleanup_colima initial Docker failure with unproven backend exits safely" 0 "$RC10_INITIAL_UNPROVEN"
assert_contains "cleanup_colima initial Docker failure reports unproven backend" \
  "does not match the expected Colima socket" "$(cat "$OUT10_INITIAL_UNPROVEN")"
assert_not_contains "cleanup_colima initial Docker failure never restarts an unproven backend" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_INITIAL_UNKNOWN="$TMP_ROOT/colima-initial-docker-container-state-unknown.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_INITIAL_UNKNOWN" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_DOCKER_INFO_RC=1 \
  FAKE_DOCKER_PS_RC=1 VACATE_CI_RUNNERS_APPROVED=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_INITIAL_UNKNOWN=0
else RC10_INITIAL_UNKNOWN=$?; fi
assert_rc "cleanup_colima initial Docker failure with unknown container state exits safely" 0 "$RC10_INITIAL_UNKNOWN"
assert_contains "cleanup_colima refuses restart when container state is unknown" \
  "could not prove that no containers are running" "$(cat "$OUT10_INITIAL_UNKNOWN")"
assert_not_contains "cleanup_colima never restarts with unknown container state" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_INITIAL_RUNNING="$TMP_ROOT/colima-initial-docker-running.out"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_INITIAL_RUNNING" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" FAKE_DOCKER_INFO_RC=1 \
  FAKE_DOCKER_RUNNING=1 VACATE_CI_RUNNERS_APPROVED=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_INITIAL_RUNNING=0
else RC10_INITIAL_RUNNING=$?; fi
assert_rc "cleanup_colima initial Docker failure with running containers exits safely" 0 "$RC10_INITIAL_RUNNING"
assert_contains "cleanup_colima initial Docker failure preserves running containers" \
  "running containers remain" "$(cat "$OUT10_INITIAL_RUNNING")"
assert_not_contains "cleanup_colima initial Docker failure never restarts with running containers" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"

OUT10_INITIAL_RECOVERED="$TMP_ROOT/colima-initial-docker-recovered.out"
INFO_FAIL_ONCE_STATE="$TMP_ROOT/colima-info-failed-once"
rm -f "$INFO_FAIL_ONCE_STATE"
: > "$COLIMA_INVOCATIONS"
if run_capture "$OUT10_INITIAL_RECOVERED" env -i HOME="$COLIMA_HOME" \
  COLIMA_INVOCATIONS="$COLIMA_INVOCATIONS" \
  FAKE_DOCKER_INFO_FAIL_ONCE_STATE="$INFO_FAIL_ONCE_STATE" \
  FAKE_DOCKER_RUNNING=0 VACATE_CI_RUNNERS_APPROVED=1 \
  PATH="$COLIMA_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_ROOT/scripts/cleanup_colima.sh" --clean; then
  RC10_INITIAL_RECOVERED=0
else RC10_INITIAL_RECOVERED=$?; fi
assert_rc "cleanup_colima approved initial Docker recovery exits 0" 0 "$RC10_INITIAL_RECOVERED"
assert_contains "cleanup_colima approved initial Docker recovery stops Colima once" \
  "colima stop" "$(cat "$COLIMA_INVOCATIONS")"
assert_contains "cleanup_colima approved initial Docker recovery starts Colima once" \
  "colima start" "$(cat "$COLIMA_INVOCATIONS")"
assert_contains "cleanup_colima approved initial Docker recovery trims after backend proof" \
  "sudo fstrim -av" "$(cat "$COLIMA_INVOCATIONS")"
echo "Test 11: disk_audit.sh clean --dry-run attempts and reports all non-gated categories"
AUDIT_FIXTURE_A7="$TMP_ROOT/audit-fixture-all-categories"
mkdir -p "$AUDIT_FIXTURE_A7/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE_A7/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE_A7/scripts/disk_audit.sh"
for child in cleanup_dev_caches.sh cleanup_tmp.sh cleanup_llm_inspector.sh cleanup_supervisor_logs.sh post_job_docker_prune.sh; do
  cat > "$AUDIT_FIXTURE_A7/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child ran with: \$*"
exit 0
EOF
  chmod +x "$AUDIT_FIXTURE_A7/scripts/$child"
done
FAKE_BIN_A7="$TMP_ROOT/bin-audit-all-categories"
make_fake_bin "$FAKE_BIN_A7"
OUT_A7="$TMP_ROOT/disk-audit-all-categories.out"
if run_capture "$OUT_A7" env -i HOME="$TMP_ROOT/home-audit-all-categories" PATH="$FAKE_BIN_A7:/usr/bin:/bin" bash "$AUDIT_FIXTURE_A7/scripts/disk_audit.sh" clean --dry-run --live --no-history; then
  RC7=0
else
  RC7=$?
fi
OUT_A7_CONTENT=$(cat "$OUT_A7")
assert_rc "disk_audit clean --dry-run exits 0 when all categories succeed" 0 "$RC7"
assert_contains "disk_audit ran dev caches category" "stub cleanup_dev_caches.sh ran with: --dry-run" "$OUT_A7_CONTENT"
assert_contains "disk_audit ran temp files category" "stub cleanup_tmp.sh ran with: --dry-run" "$OUT_A7_CONTENT"
assert_contains "disk_audit ran LLM inspector category" "stub cleanup_llm_inspector.sh ran with: --dry-run" "$OUT_A7_CONTENT"
assert_contains "disk_audit ran supervisor logs category" "stub cleanup_supervisor_logs.sh ran with: --dry-run" "$OUT_A7_CONTENT"
assert_contains "disk_audit ran post-job docker prune category" "stub post_job_docker_prune.sh ran with: --dry-run" "$OUT_A7_CONTENT"
assert_contains "disk_audit reports category summary header" "── Cleanup Category Summary ──" "$OUT_A7_CONTENT"
assert_contains "disk_audit reports all-clear when nothing failed" "All attempted categories completed without error." "$OUT_A7_CONTENT"

echo "Test 12: disk_audit.sh surfaces a failing category instead of silently swallowing it (bd-y74 regression)"
# Root cause of bd-y74: sub-scripts invoked via `\$clean_arg || true` where a
# sub-script only supports --clean (not --dry-run). The failure exited
# non-zero but `|| true` swallowed it with no visible signal, so the
# category silently never ran. This test recreates that exact failure mode
# and asserts the failure is now surfaced loudly instead of disappearing.
AUDIT_FIXTURE_A8="$TMP_ROOT/audit-fixture-failing-category"
mkdir -p "$AUDIT_FIXTURE_A8/scripts"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$AUDIT_FIXTURE_A8/scripts/disk_audit.sh"
chmod +x "$AUDIT_FIXTURE_A8/scripts/disk_audit.sh"
for child in cleanup_dev_caches.sh cleanup_tmp.sh cleanup_supervisor_logs.sh; do
  cat > "$AUDIT_FIXTURE_A8/scripts/$child" <<EOF
#!/usr/bin/env bash
echo "stub $child ran with: \$*"
exit 0
EOF
  chmod +x "$AUDIT_FIXTURE_A8/scripts/$child"
done
# Simulate a sub-script that only accepts --clean (the historical bd-y74 bug shape).
cat > "$AUDIT_FIXTURE_A8/scripts/cleanup_llm_inspector.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --clean) exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac
EOF
chmod +x "$AUDIT_FIXTURE_A8/scripts/cleanup_llm_inspector.sh"
FAKE_BIN_A8="$TMP_ROOT/bin-audit-failing-category"
make_fake_bin "$FAKE_BIN_A8"
OUT_A8="$TMP_ROOT/disk-audit-failing-category.out"
if run_capture "$OUT_A8" env -i HOME="$TMP_ROOT/home-audit-failing-category" PATH="$FAKE_BIN_A8:/usr/bin:/bin" bash "$AUDIT_FIXTURE_A8/scripts/disk_audit.sh" clean --dry-run --live --no-history; then
  RC8=0
else
  RC8=$?
fi
OUT_A8_CONTENT=$(cat "$OUT_A8")
# The audit as a whole must keep running (rc=0) so other categories still execute...
assert_rc "disk_audit clean --dry-run still completes when one category fails" 0 "$RC8"
# ...but the failure must no longer be silently swallowed by `|| true`.
assert_contains "disk_audit surfaces the failing category by name" "CATEGORY FAILED: LLM inspector (exit 2)" "$OUT_A8_CONTENT"
assert_contains "disk_audit summary counts the failure" "1 of" "$OUT_A8_CONTENT"
assert_contains "disk_audit still ran the category after the failing one" "stub cleanup_supervisor_logs.sh ran with: --dry-run" "$OUT_A8_CONTENT"

echo "Test A9: cleanup_tmp never archives an APPROVED worktree that has unsaved work (codex 2026-07-22 data-loss guard)"
GITBIN9="$(dirname "$(command -v git)")"
WTREPO9="$TMP_ROOT/wt-repo9"; mkdir -p "$WTREPO9"
git -C "$WTREPO9" init -q -b main
git -C "$WTREPO9" config user.email jleechan2015@users.noreply.github.com
git -C "$WTREPO9" config user.name jleechan2015
echo base > "$WTREPO9/f"; git -C "$WTREPO9" add f
git -C "$WTREPO9" commit -qm init
FAKE_PT9="$TMP_ROOT/private-tmp9"; FAKE_ET9="$TMP_ROOT/empty-tmp9"; FAKE_BIN9="$TMP_ROOT/bin9"
mkdir -p "$FAKE_PT9" "$FAKE_ET9" "$FAKE_BIN9"
git -C "$WTREPO9" worktree add -q "$FAKE_PT9/worktree_dirty" -b feat9
echo uncommitted > "$FAKE_PT9/worktree_dirty/untracked.txt"   # untracked -> unsafe
cat > "$FAKE_BIN9/find" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  /private/tmp) shift; exec /usr/bin/find "$FAKE_PT9" "$@" ;;
  /tmp) shift; exec /usr/bin/find "$FAKE_ET9" "$@" ;;
  *) exec /usr/bin/find "$@" ;;
esac
EOF
chmod +x "$FAKE_BIN9/find"
cat > "$FAKE_BIN9/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then exit 0; fi
exec /usr/bin/getconf "$@"
EOF
chmod +x "$FAKE_BIN9/getconf"
OUT9W="$TMP_ROOT/wt-approved-dirty.out"
if run_capture "$OUT9W" env -i HOME="$TMP_ROOT/home9" TMP_WORKTREES_APPROVED=1 LARGE_TMP_APPROVED=1 \
    FAKE_PT9="$FAKE_PT9" FAKE_ET9="$FAKE_ET9" PATH="$FAKE_BIN9:$GITBIN9:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --large; then
  RC9W=0
else
  RC9W=$?
fi
OUT9W_CONTENT=$(cat "$OUT9W")
assert_rc "cleanup_tmp --clean --large exits 0 (approved dirty worktree)" 0 "$RC9W"
assert_contains "approved worktree with unsaved work is skipped" "Skipping approved worktree with unsaved work" "$OUT9W_CONTENT"
if [[ -e "$FAKE_PT9/worktree_dirty/untracked.txt" ]]; then
  echo "  PASS  dirty worktree preserved on disk (not archived/purged)"; PASS=$(( PASS + 1 ))
else
  echo "  FAIL  dirty worktree preserved on disk (not archived/purged)"; FAIL=$(( FAIL + 1 ))
fi
git -C "$WTREPO9" worktree prune 2>/dev/null || true

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

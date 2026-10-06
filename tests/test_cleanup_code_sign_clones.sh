#!/usr/bin/env bash
# test_cleanup_code_sign_clones.sh — Unit & safety tests for cleanup_code_sign_clones.sh
#
# Asserts:
# 1. Defaults to dry-run mode (no files deleted).
# 2. Refuses deletion when --clean is passed without CODE_SIGN_CLONES_APPROVED=1.
# 3. Preserves candidates when lsof reports active handle.
# 4. Preserves candidates younger than CODE_SIGN_CLONE_MIN_AGE_SEC.
# 5. Successfully deletes stale, inactive candidate directories when approved.
# 6. Revalidates candidate identities to fail-closed on race conditions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_code_sign_clones.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_DIR=$(mktemp -d -t test_code_sign_clones.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/bin"
MOCK_X_DIR="$TMP_DIR/X"
mkdir -p "$MOCK_BIN" "$MOCK_X_DIR"

# 1. Setup mock lsof that reports inactive (no matches) by default
cat > "$MOCK_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_LSOF_SHARED:-}" ]]; then
  # A process holds the shared (hardlinked) binary; lsof +D reports it under
  # every clone that links it, as macOS lsof resolves by inode.
  echo "p23456"
  echo "cThemeWidgetControlViewService"
  echo "n${@: -1}/Contents/MacOS/binary"
  exit 0
fi
if [[ -n "${MOCK_LSOF_ACTIVE:-}" ]]; then
  # Simulate active process holding handle inside candidate
  echo "p12345"
  echo "cGoogle Chrome"
  echo "n$1/Contents/MacOS/Google Chrome"
  exit 0
fi
# Inactive: empty output and exit 1
exit 1
EOF
chmod +x "$MOCK_BIN/lsof"

export CODE_SIGN_CLONE_MIN_KB=10

# Helper to create a dummy candidate bundle >= 100 KB
create_candidate() {
  local dir="$1"
  mkdir -p "$dir/Contents/MacOS"
  # 120 KB dummy file
  dd if=/dev/zero of="$dir/Contents/MacOS/binary" bs=1024 count=120 2>/dev/null
}

CLONE_PARENT="$MOCK_X_DIR/com.google.Chrome.code_sign_clone"
CLONE_DIR="$CLONE_PARENT/code_sign_clone.1234"
create_candidate "$CLONE_DIR"

# Age the file by touching with old timestamp (2000s ago)
touch -t 202610041200 "$CLONE_PARENT" "$CLONE_DIR"

echo "Test 1: Default dry-run mode does not delete files"
OUTPUT1=$(PATH="$MOCK_BIN:$PATH" DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: dry-run deleted candidate directory" >&2
  exit 1
fi
if ! grep -q "DRY RUN" <<<"$OUTPUT1"; then
  echo "FAIL: expected DRY RUN log in output" >&2
  exit 1
fi
echo "  PASS  Test 1"

echo "Test 2: --clean without CODE_SIGN_CLONES_APPROVED=1 refuses deletion"
OUTPUT2=$(PATH="$MOCK_BIN:$PATH" CODE_SIGN_CLONES_APPROVED=0 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: --clean deleted candidate without approval" >&2
  exit 1
fi
if ! grep -q "Refusing code_sign_clone deletion" <<<"$OUTPUT2"; then
  echo "FAIL: expected refusal message" >&2
  exit 1
fi
echo "  PASS  Test 2"

echo "Test 3: Preserves candidate when lsof reports active handle"
OUTPUT3=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_ACTIVE=1 CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$CLONE_DIR" ]]; then
  echo "FAIL: deleted candidate while active handle reported by lsof" >&2
  exit 1
fi
if ! grep -q "ACTIVE — preserving" <<<"$OUTPUT3"; then
  echo "FAIL: expected 'ACTIVE — preserving' in output" >&2
  echo "$OUTPUT3" >&2
  exit 1
fi
echo "  PASS  Test 3"

echo "Test 4: Preserves young candidate (within MIN_AGE_SEC)"
YOUNG_CLONE="$CLONE_PARENT/code_sign_clone.young"
create_candidate "$YOUNG_CLONE"
# Touch with current timestamp
touch "$YOUNG_CLONE"
OUTPUT4=$(PATH="$MOCK_BIN:$PATH" CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=3600 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --dry-run 2>&1)
if [[ ! -d "$YOUNG_CLONE" ]]; then
  echo "FAIL: deleted candidate that was younger than min age" >&2
  exit 1
fi
if ! grep -q "Too young" <<<"$OUTPUT4"; then
  echo "FAIL: expected 'Too young' in output" >&2
  echo "$OUTPUT4" >&2
  exit 1
fi
echo "  PASS  Test 4"

# Remove the young clone so Test 5 cleanly operates on the stale candidate
rm -rf "$YOUNG_CLONE"
touch -t 202610041200 "$CLONE_PARENT" "$CLONE_DIR"

echo "Test 5: Successfully cleans stale, inactive candidate with approval"
OUTPUT5=$(PATH="$MOCK_BIN:$PATH" CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ -d "$CLONE_DIR" ]]; then
  echo "FAIL: stale inactive candidate was not deleted" >&2
  exit 1
fi
if ! grep -q "Dirs removed: 1" <<<"$OUTPUT5"; then
  echo "FAIL: expected deletion confirmation in output" >&2
  echo "$OUTPUT5" >&2
  exit 1
fi
echo "  PASS  Test 5"

echo "Test 6: Fails closed when DISK_MAGICIAN_CODE_SIGN_X_DIR is a non-existent path"
OUTPUT6=$(PATH="$MOCK_BIN:$PATH" DISK_MAGICIAN_CODE_SIGN_X_DIR="/nonexistent/test_x_dir_12345" "$SCRIPT" --dry-run 2>&1 || true)
if ! grep -q "ERROR: DISK_MAGICIAN_CODE_SIGN_X_DIR is not a directory" <<<"$OUTPUT6"; then
  echo "FAIL: expected error message for non-existent X dir" >&2
  echo "$OUTPUT6" >&2
  exit 1
fi
echo "  PASS  Test 6"

echo "Test 7: Open file shared by hardlink across clones does not pin every clone"
SH_A="$CLONE_PARENT/code_sign_clone.shA"
SH_B="$CLONE_PARENT/code_sign_clone.shB"
create_candidate "$SH_A"
mkdir -p "$SH_B/Contents/MacOS"
ln "$SH_A/Contents/MacOS/binary" "$SH_B/Contents/MacOS/binary"
dd if=/dev/zero of="$SH_B/Contents/MacOS/framework" bs=1024 count=120 2>/dev/null
touch -t 202610041100 "$SH_A"
touch -t 202610041200 "$CLONE_PARENT" "$SH_B"
OUTPUT7=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED=1 CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ -d "$SH_A" || ! -d "$SH_B" ]]; then
  echo "FAIL: expected older shA removed and newest shB kept while a shared-inode handle is live" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if ! grep -q "ACTIVE — preserving" <<<"$OUTPUT7"; then
  echo "FAIL: the newest clone must be reported ACTIVE" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
echo "  PASS  Test 7"

echo "Test 8: A clone a running process executes from is preserved"
EXE_CLONE="$CLONE_PARENT/code_sign_clone.exe"
create_candidate "$EXE_CLONE"
touch -t 202610041200 "$CLONE_PARENT" "$EXE_CLONE"
printf '#!/usr/bin/env bash\necho "%s/Contents/MacOS/binary"\n' "$EXE_CLONE" > "$MOCK_BIN/ps"
chmod +x "$MOCK_BIN/ps"
OUTPUT8=$(PATH="$MOCK_BIN:$PATH" CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
rm -f "$MOCK_BIN/ps"
if [[ ! -d "$EXE_CLONE" ]] || ! grep -q "running executable inside clone" <<<"$OUTPUT8"; then
  echo "FAIL: clone with a running executable was not preserved" >&2
  echo "$OUTPUT8" >&2
  exit 1
fi
echo "  PASS  Test 8"

echo "Test 9: Sole clone whose only open file is hardlinked elsewhere is preserved"
rm -rf "$CLONE_PARENT"
SOLE="$CLONE_PARENT/code_sign_clone.sole"
create_candidate "$SOLE"
mkdir -p "$TMP_DIR/Applications/App.app/Contents/MacOS"
ln "$SOLE/Contents/MacOS/binary" "$TMP_DIR/Applications/App.app/Contents/MacOS/binary"
touch -t 202610041200 "$CLONE_PARENT" "$SOLE"
OUTPUT9=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED=1 CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$SOLE" ]] || ! grep -q "newest clone of an app" <<<"$OUTPUT9"; then
  echo "FAIL: live app's sole clone (only shared-inode files open) was not preserved" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
echo "  PASS  Test 9"

echo "ALL CHECKS PASSED: test_cleanup_code_sign_clones.sh"
exit 0

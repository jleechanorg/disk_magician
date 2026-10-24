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

TMP_DIR=$(mktemp -d /tmp/test_code_sign_clones.XXXXXX) || exit 1
[[ "$TMP_DIR" == /tmp/test_code_sign_clones.* && -d "$TMP_DIR" && ! -L "$TMP_DIR" ]] || exit 1
export HOME="$TMP_DIR/home" DISK_MAGICIAN_STATE_DIR="$TMP_DIR/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/bin"
MOCK_X_DIR="$TMP_DIR/X"
mkdir -p "$MOCK_BIN" "$MOCK_X_DIR"

# 1. Setup mock lsof that reports inactive (no matches) by default
cat > "$MOCK_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
# The C14 live-cwd probe runs `lsof -n -P -d cwd -Fpn` and needs a valid
# record stream; the candidate open-file probe uses `+D <dir>`. Emit a
# synthetic cwd of "/" (never inside the fixture) for the former, and the
# inactive/active answer for the latter.
if [[ " $* " != *" +D "* ]]; then
  printf 'p%s\nfcwd\nn/\n' "$$"
  exit 0
fi
target="${!#}"
if [[ -n "${MOCK_LSOF_WARN:-}" ]]; then
  # rc=1 with EMPTY stdout and a warning on stderr: the inspection did not
  # complete, which must never be read as "nothing holds this clone".
  echo "lsof: WARNING: cannot statfs $target (probe)" >&2
  exit 1
fi
if [[ -n "${MOCK_LSOF_ACTIVE:-}" ]]; then
  # Simulate an active process whose only match is a path that does not exist
  # on disk: an open-but-unlinked file, which must always pin the clone.
  printf 'p12345\ncGoogle Chrome\nn/Contents/MacOS/Google Chrome\n'
  exit 0
fi
if [[ -n "${MOCK_LSOF_EXCL_TARGET:-}" && "$target" == "$MOCK_LSOF_EXCL_TARGET" ]]; then
  printf 'p555\ncAsideBrowser\nn%s/Contents/MacOS/exclusive\n' "$target"
  exit 0
fi
if [[ -n "${MOCK_LSOF_UNLINKED_TARGET:-}" && "$target" == "$MOCK_LSOF_UNLINKED_TARGET" ]]; then
  printf 'p556\ncAsideBrowser\nn%s/Contents/MacOS/gone\n' "$target"
  exit 0
fi
if [[ -n "${MOCK_LSOF_SHARED:-}" ]]; then
  # A hardlink-shared inode open elsewhere: lsof +D matches it by inode and
  # reports it for every clone even though the handle is on another path.
  for _pid in ${MOCK_LSOF_SHARED_PIDS:-4321}; do
    printf 'p%s\ncGoogle Chrome\nn%s\n' "$_pid" "$MOCK_LSOF_SHARED"
  done
  exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/lsof"

# Mock ps: only the clone gates' per-pid lookups are simulated — the launch
# path (`ps -p <pid> -o comm=`) and the process start time
# (`ps -p <pid> -o lstart=`). Every other invocation — pid liveness, the C14
# live-cwd probe — delegates to the real ps. `ps -Ao comm=` is never called: it
# costs 2m15s on this host with 2071 processes, which is why the script asks per
# pid instead.
REAL_PS=$(command -v ps)
cat > "$MOCK_BIN/ps" <<EOF
#!/usr/bin/env bash
args=" \$* "
pid=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-p" ]] && pid="\$a"; prev="\$a"; done
if [[ "\$args" == *" -o comm= "* ]]; then
  if [[ -n "\${MOCK_PS_EXEC_PATH:-}" ]]; then printf '%s\\n' "\$MOCK_PS_EXEC_PATH"; exit 0; fi
elif [[ "\$args" == *" -o lstart= "* ]]; then
  if [[ "\${MOCK_PS_NO_START:-}" == "1" ]]; then exit 1; fi
  var="MOCK_PS_START_\$pid"
  if [[ -n "\${!var:-}" ]]; then printf '%s\\n' "\${!var}"; exit 0; fi
  if [[ -n "\${MOCK_PS_START_STAMP:-}" ]]; then printf '%s\\n' "\$MOCK_PS_START_STAMP"; exit 0; fi
fi
exec "$REAL_PS" "\$@"
EOF
chmod +x "$MOCK_BIN/ps"

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
find "$CLONE_DIR" -exec touch -t 202610041200 {} + 2>/dev/null
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
find "$CLONE_DIR" -exec touch -t 202610041200 {} + 2>/dev/null
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

# ── Shared-inode regression fixtures ─────────────────────────────────────────
# Every Chromium clone hard-links the app's main executable, so one open handle
# makes lsof +D match *all* clones by inode. Only an exclusive (nlink 1) or
# unlinked handle proves a given clone is in use.
SHARED_APP="$TMP_DIR/Applications/App.app/Contents/MacOS"
mkdir -p "$SHARED_APP"
dd if=/dev/zero of="$SHARED_APP/binary" bs=1024 count=8 2>/dev/null

make_clone() {  # make_clone <dir> <mtime-stamp>
  local dir="$1" stamp="$2"
  create_candidate "$dir"
  ln "$SHARED_APP/binary" "$dir/Contents/MacOS/shared"
  # Age the whole tree, not just the directory: C14's newest-mtime floor and the
  # script's MIN_AGE_SEC both read content mtimes.
  find "$dir" -exec touch -t "$stamp" {} + 2>/dev/null
  touch -t "$stamp" "$dir"
}

echo "Test 7: Only a hardlink-shared inode open — never reported ACTIVE per clone"
SP="$MOCK_X_DIR/com.example.shared.code_sign_clone"
mkdir -p "$SP"
make_clone "$SP/code_sign_clone.old" 202610041100
make_clone "$SP/code_sign_clone.new" 202610051300
touch -t 202610051300 "$SP"
# The live holder started (Oct 05 11:30) after the old clone and before the new
# one, so only the old clone is provably not that holder's.
OUTPUT7=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_PS_START_4321="Mon Oct 05 11:30:00 2026" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$SP/code_sign_clone.old" || ! -d "$SP/code_sign_clone.new" ]]; then
  echo "FAIL: shared-inode-only clones must be preserved, not deleted" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if grep -q "ACTIVE — preserving: $SP/code_sign_clone.old" <<<"$OUTPUT7"; then
  echo "FAIL: a clone older than every live holder was reported ACTIVE" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if ! grep -q "SHARED-INODE — not a per-clone handle, not reclaimable: $SP/code_sign_clone.old" <<<"$OUTPUT7"; then
  echo "FAIL: expected the pre-holder clone classified SHARED-INODE and excluded from reclaim" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if ! grep -q "clone predates every live holder" <<<"$OUTPUT7"; then
  echo "FAIL: expected the pre-holder reason in the classification line" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if ! grep -q "SHARED-INODE — preserving: $SP/code_sign_clone.new" <<<"$OUTPUT7"; then
  echo "FAIL: a clone created after the live holder started must be preserved" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if ! grep -q "Dirs removed: 0" <<<"$OUTPUT7"; then
  echo "FAIL: shared-inode-only clones must not be counted as removed/reclaimable" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
echo "  PASS  Test 7"

echo "Test 8: Sole clone whose only open file is hardlink-shared is preserved"
SOLE_PARENT="$MOCK_X_DIR/at.studio.AsideBrowser.code_sign_clone"
mkdir -p "$SOLE_PARENT"
make_clone "$SOLE_PARENT/code_sign_clone.sole" 202610051300
touch -t 202610051300 "$SOLE_PARENT"
OUTPUT8=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_PS_START_4321="Mon Oct 05 11:30:00 2026" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$SOLE_PARENT/code_sign_clone.sole" ]]; then
  echo "FAIL: a live app's sole clone (only shared-inode handles) was deleted" >&2
  echo "$OUTPUT8" >&2
  exit 1
fi
echo "  PASS  Test 8"

echo "Test 9: Exclusive (single-link) open file inside a clone still pins it"
EXCL_PARENT="$MOCK_X_DIR/com.example.exclusive.code_sign_clone"
mkdir -p "$EXCL_PARENT"
make_clone "$EXCL_PARENT/code_sign_clone.old" 202610041100
make_clone "$EXCL_PARENT/code_sign_clone.excl" 202610051300
# An exclusive (nlink 1) file that is open inside the clone: unlike the
# hardlinked main executable, only this clone's path holds it.
dd if=/dev/zero of="$EXCL_PARENT/code_sign_clone.excl/Contents/MacOS/exclusive" bs=1024 count=4 2>/dev/null
touch -t 202610041100 "$EXCL_PARENT/code_sign_clone.excl/Contents/MacOS/exclusive"
OUTPUT9=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_LSOF_EXCL_TARGET="$EXCL_PARENT/code_sign_clone.excl" \
  MOCK_PS_START_4321="Mon Oct 05 11:30:00 2026" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$EXCL_PARENT/code_sign_clone.excl" ]]; then
  echo "FAIL: clone holding an exclusive open file was deleted" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
if ! grep -q "pid=555 command=AsideBrowser" <<<"$OUTPUT9"; then
  echo "FAIL: expected the exclusive-handle owner to be reported" >&2
  echo "$OUTPUT9" >&2
  exit 1
fi
echo "  PASS  Test 9"

echo "Test 10: Open-but-unlinked file inside a clone pins it (fail closed)"
UNL_PARENT="$MOCK_X_DIR/com.example.unlinked.code_sign_clone"
mkdir -p "$UNL_PARENT"
make_clone "$UNL_PARENT/code_sign_clone.old" 202610041100
make_clone "$UNL_PARENT/code_sign_clone.unl" 202610051300
OUTPUT10=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_LSOF_UNLINKED_TARGET="$UNL_PARENT/code_sign_clone.unl" \
  MOCK_PS_START_4321="Mon Oct 05 11:30:00 2026" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$UNL_PARENT/code_sign_clone.unl" ]]; then
  echo "FAIL: clone with an open-but-unlinked file was deleted" >&2
  echo "$OUTPUT10" >&2
  exit 1
fi
echo "  PASS  Test 10"

echo "Test 11: Running executable inside a clone pins it across the /private alias"
# /tmp is a symlink to /private/tmp on macOS: the candidate is spelled
# /private/var|tmp/... while ps reports the /tmp/... form. Both must match.
PRIV_X_DIR=""
if [[ -d "/private$MOCK_X_DIR" ]]; then PRIV_X_DIR="/private$MOCK_X_DIR"; fi
if [[ -z "$PRIV_X_DIR" ]]; then
  echo "  SKIP  Test 11 (/tmp is not a /private alias on this host)"
else
  EXE_PARENT="$PRIV_X_DIR/com.example.exec.code_sign_clone"
  mkdir -p "$EXE_PARENT"
  make_clone "$EXE_PARENT/code_sign_clone.exe" 202610041100
  touch -t 202610041100 "$EXE_PARENT"
  # ps reports the non-/private spelling of the same path while lsof matches
  # only the hardlink-shared inode: the launch path is what pins this clone.
  OUTPUT11=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
    MOCK_PS_EXEC_PATH="$MOCK_X_DIR/com.example.exec.code_sign_clone/code_sign_clone.exe/App.app.bundle/Contents/MacOS/App" \
    MOCK_PS_START_4321="Fri Oct 23 09:00:00 2026" \
    CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
    DISK_MAGICIAN_CODE_SIGN_X_DIR="$PRIV_X_DIR" "$SCRIPT" --clean 2>&1)
  if [[ ! -d "$EXE_PARENT/code_sign_clone.exe" ]] || ! grep -q "running executable inside clone" <<<"$OUTPUT11"; then
    echo "FAIL: an executable running out of the clone was not detected across the /private alias" >&2
    echo "$OUTPUT11" >&2
    exit 1
  fi
  # Negative control: SAME shared-handle evidence and the SAME known holder
  # start time as the positive case above, but the process was launched outside
  # every clone. Without MOCK_LSOF_SHARED the mock emitted no lsof records at
  # all, so the shared-inode/exec-path attribution was never exercised and this
  # clone was classified INACTIVE for a reason unrelated to the assertion.
  OUTPUT11B=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
    MOCK_PS_EXEC_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    MOCK_PS_START_4321="Fri Oct 23 09:00:00 2026" \
    CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
    DISK_MAGICIAN_CODE_SIGN_X_DIR="$PRIV_X_DIR" "$SCRIPT" --clean 2>&1)
  if [[ ! -d "$EXE_PARENT/code_sign_clone.exe" ]]; then
    echo "FAIL: a shared handle held by an outside executable must still preserve the clone" >&2
    echo "$OUTPUT11B" >&2
    exit 1
  fi
  if grep -q "running executable inside clone" <<<"$OUTPUT11B"; then
    echo "FAIL: exec-path check attributed an outside executable to the clone" >&2
    echo "$OUTPUT11B" >&2
    exit 1
  fi
  if grep -q "ACTIVE — preserving: $EXE_PARENT/code_sign_clone.exe" <<<"$OUTPUT11B"; then
    echo "FAIL: a shared-inode clone with an outside executable must not be ACTIVE" >&2
    echo "$OUTPUT11B" >&2
    exit 1
  fi
  if ! grep -q "SHARED-INODE — not a per-clone handle, not reclaimable: $EXE_PARENT/code_sign_clone.exe" <<<"$OUTPUT11B"; then
    echo "FAIL: expected the clone classified outside-executable (shared-inode, not ACTIVE)" >&2
    echo "$OUTPUT11B" >&2
    exit 1
  fi
  echo "  PASS  Test 11"
fi

echo "Test 12: Summary reports du bytes as APFS CoW, never as freed space"
if ! grep -q "APFS CoW shared blocks, NOT freed space" <<<"$OUTPUT7"; then
  echo "FAIL: the summary must label clone bytes as non-reclaimable APFS CoW blocks" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
if grep -q "Total freed:" <<<"$OUTPUT7"; then
  echo "FAIL: the summary must not quote clone du bytes as reclaimed space" >&2
  echo "$OUTPUT7" >&2
  exit 1
fi
echo "  PASS  Test 12"

echo "Test 13: Two live shared-handle holders — nothing created after either is unpinned"
# disk_magician-bd6 asked for exactly this: the oldest live holder's start bounds
# the keep-set, and it is a superset of the newest clone.
TWO_PARENT="$MOCK_X_DIR/com.example.twoholders.code_sign_clone"
mkdir -p "$TWO_PARENT"
make_clone "$TWO_PARENT/code_sign_clone.early" 202610051000
make_clone "$TWO_PARENT/code_sign_clone.mid" 202610051100
make_clone "$TWO_PARENT/code_sign_clone.late" 202610051300
touch -t 202610051300 "$TWO_PARENT"
OUTPUT13=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_LSOF_SHARED_PIDS="4321 4322" \
  MOCK_PS_START_4321="Mon Oct 05 10:30:00 2026" \
  MOCK_PS_START_4322="Mon Oct 05 12:30:00 2026" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$TWO_PARENT/code_sign_clone.early" || ! -d "$TWO_PARENT/code_sign_clone.mid" \
      || ! -d "$TWO_PARENT/code_sign_clone.late" ]]; then
  echo "FAIL: every clone of a two-holder parent must be preserved" >&2
  echo "$OUTPUT13" >&2
  exit 1
fi
if grep -q "ACTIVE — preserving: $TWO_PARENT/code_sign_clone.early" <<<"$OUTPUT13"; then
  echo "FAIL: pre-holder clone reported ACTIVE" >&2
  echo "$OUTPUT13" >&2
  exit 1
fi
if grep -q "ACTIVE — preserving: $TWO_PARENT/code_sign_clone.mid" <<<"$OUTPUT13"; then
  echo "FAIL: clone newer than the oldest holder must not be a per-clone ACTIVE" >&2
  echo "$OUTPUT13" >&2
  exit 1
fi
if ! grep -q "SHARED-INODE — preserving: $TWO_PARENT/code_sign_clone.late" <<<"$OUTPUT13"; then
  echo "FAIL: newest clone must be preserved" >&2
  echo "$OUTPUT13" >&2
  exit 1
fi
echo "  PASS  Test 13"

echo "Test 14: Unreadable holder start time fails closed (preserves)"
NOS_P="$MOCK_X_DIR/com.example.nostart.code_sign_clone"
mkdir -p "$NOS_P"
make_clone "$NOS_P/code_sign_clone.stale" 202001010000
touch -t 202001010000 "$NOS_P"
OUTPUT14=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_SHARED="$SHARED_APP/binary" \
  MOCK_PS_NO_START=1 \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if [[ ! -d "$NOS_P/code_sign_clone.stale" ]]; then
  echo "FAIL: unreadable holder start time must preserve the clone" >&2
  echo "$OUTPUT14" >&2
  exit 1
fi
if ! grep -q "holder start time unavailable" <<<"$OUTPUT14"; then
  echo "FAIL: expected the unreadable-start-time reason" >&2
  echo "$OUTPUT14" >&2
  exit 1
fi
echo "  PASS  Test 14"

echo "Test 15: Unreadable lsof diagnostics is an inspection error, not INACTIVE"
# P0 regression: the diagnostics capture was read as `cat ... || true`, so a
# failed read produced empty diagnostics and the rc=1 / empty-output /
# empty-stderr branch classified the clone as INACTIVE (deletable). Identical
# lsof behaviour must classify as an inspection error whether or not the
# capture can be read.
DIAG_PARENT="$MOCK_X_DIR/com.example.diag.code_sign_clone"
mkdir -p "$DIAG_PARENT"
create_candidate "$DIAG_PARENT/code_sign_clone.diag"
create_candidate "$DIAG_PARENT/code_sign_clone.nomatch"
find "$DIAG_PARENT" -exec touch -t 202610041100 {} + 2>/dev/null
touch -t 202610041100 "$DIAG_PARENT"

REAL_CAT=$(command -v cat)
CATFAIL_BIN="$TMP_DIR/catfail-bin"
mkdir -p "$CATFAIL_BIN"
cat > "$CATFAIL_BIN/cat" <<EOF
#!/usr/bin/env bash
last="\${!#}"
case "\$last" in
  *disk-magician-lsof*) echo "cat: \$last: Permission denied" >&2; exit 1 ;;
esac
exec "$REAL_CAT" "\$@"
EOF
chmod +x "$CATFAIL_BIN/cat"

# Control arm: the capture IS readable, lsof warned and exited 1.
OUTPUT15A=$(PATH="$MOCK_BIN:$PATH" MOCK_LSOF_WARN=1 \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
# Regressed arm: same lsof behaviour, capture unreadable.
OUTPUT15B=$(PATH="$CATFAIL_BIN:$MOCK_BIN:$PATH" MOCK_LSOF_WARN=1 \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --clean 2>&1)
if ! grep -q "Skipping code_sign_clones: lsof failed for $DIAG_PARENT/code_sign_clone.diag" <<<"$OUTPUT15A"; then
  echo "FAIL: a readable lsof warning must be reported as an inspection failure" >&2
  echo "$OUTPUT15A" >&2
  exit 1
fi
if ! grep -q "Skipping code_sign_clones: lsof failed for $DIAG_PARENT/code_sign_clone.diag.*unable to read captured lsof diagnostics" <<<"$OUTPUT15B"; then
  echo "FAIL: an unreadable diagnostics capture must be an inspection error" >&2
  echo "$OUTPUT15B" >&2
  exit 1
fi
if grep -q "INACTIVE candidate: $DIAG_PARENT/code_sign_clone.diag" <<<"$OUTPUT15B"; then
  echo "FAIL: unreadable diagnostics failed open and marked a clone INACTIVE" >&2
  echo "$OUTPUT15B" >&2
  exit 1
fi
if [[ ! -d "$DIAG_PARENT/code_sign_clone.diag" ]]; then
  echo "FAIL: candidate was removed despite an incomplete inspection" >&2
  exit 1
fi
# Do not weaken the normal no-match case: lsof rc=1 with empty stdout AND empty
# stderr, diagnostics readable, must STILL be return 1 (INACTIVE candidate).
OUTPUT15C=$(PATH="$MOCK_BIN:$PATH" \
  CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$MOCK_X_DIR" "$SCRIPT" --dry-run 2>&1)
if ! grep -q "INACTIVE candidate: $DIAG_PARENT/code_sign_clone.nomatch" <<<"$OUTPUT15C"; then
  echo "FAIL: the normal empty/no-match case must stay INACTIVE (return 1)" >&2
  echo "$OUTPUT15C" >&2
  exit 1
fi
echo "  PASS  Test 15"

echo "Test 16: --help performs no command substitution (never runs du or df)"
# The usage body used an unquoted heredoc delimiter, so the backticked `du` and
# `df` in the help text executed on --help and spliced their output into it.
HELP_BIN="$TMP_DIR/help-bin"
mkdir -p "$HELP_BIN"
for _cmd in du df; do
  cat > "$HELP_BIN/$_cmd" <<EOF
#!/usr/bin/env bash
echo invoked >> "$TMP_DIR/marker-$_cmd"
exit 0
EOF
  chmod +x "$HELP_BIN/$_cmd"
done
OUTPUT16=$(PATH="$HELP_BIN:$PATH" "$SCRIPT" --help 2>&1)
for _cmd in du df; do
  if [[ -f "$TMP_DIR/marker-$_cmd" ]]; then
    echo "FAIL: --help executed \`$_cmd\` via the usage heredoc" >&2
    echo "$OUTPUT16" >&2
    exit 1
  fi
done
for _line in "^Usage: " "Options:" "--clean" "--dry-run" "Measure reclaim with"; do
  if ! grep -qE -- "$_line" <<<"$OUTPUT16"; then
    echo "FAIL: --help no longer prints a usage line matching: $_line" >&2
    echo "$OUTPUT16" >&2
    exit 1
  fi
done
echo "  PASS  Test 16"

echo "ALL CHECKS PASSED: test_cleanup_code_sign_clones.sh"
exit 0

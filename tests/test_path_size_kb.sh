#!/usr/bin/env bash
# test_path_size_kb.sh — regression coverage for bead disk_magician-lsl:
# path_size_kb() breaking cleanup_tmp.sh's/cleanup_pr_scratch.sh's arithmetic
# when `du -sk` emits more than one line.
#
# Found by PR #71 evidence run: a real timed
# `bash scripts/cleanup_tmp.sh --dry-run --budget-gb 15` against a live,
# churning $TMPDIR produced:
#   scripts/lib/scratch_budget.sh: line 143: 0
#   0: arithmetic syntax error in expression (error token is "0")
# because path_size_kb() assumed `du -sk` always emits exactly one line;
# under TOCTOU races / BSD-du edge cases it can emit zero or multiple lines,
# and `awk '{print $1+0}'` echoes one line PER `du` output line, producing a
# multi-line "kb" value that breaks downstream `$(( total_kb + kb ))`
# arithmetic. Fix: take the first numeric field of the LAST line, default 0
# when there is no line at all.
#
# Run: bash tests/test_path_size_kb.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMP_ROOT=$(mktemp -d -t test_path_size_kb.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

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
  if grep -qF "$needle" <<<"$haystack"; then
    record_fail "$name" "expected output NOT to contain: $needle"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  else
    record_pass "$name"
  fi
}

# make_multiline_du_stub <bin_dir> <target_basename> <real_kb> — a `du` shim
# that emits a bogus extra line before the real total whenever its last
# argument ENDS WITH <target_basename> (matches regardless of whether the
# caller canonicalized/realpath'd the argument first), and defers to the
# real `du` for everything else. Mirrors the multi-line/error-line `du -sk`
# output the bead observed on a live, churning $TMPDIR.
make_multiline_du_stub() {
  local bin_dir="$1" target_basename="$2" real_kb="$3"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/du" <<EOF
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\$arg"; done
if [[ "\$last" == *"/$target_basename" ]]; then
  printf '999\t/bogus/unrelated/path\n'
  printf '%s\t%s\n' "$real_kb" "\$last"
  exit 0
fi
exec /usr/bin/du "\$@"
EOF
  chmod +x "$bin_dir/du"
}

echo "=== path_size_kb: multi-line du output (bead disk_magician-lsl) ==="

echo "Test 1: cleanup_tmp.sh --clean tolerates multi-line du output, takes the LAST line"
T1_PRIVATE_TMP="$TMP_ROOT/t1-private-tmp"
T1_TMP="$TMP_ROOT/t1-tmp"
T1_ARCHIVE="$TMP_ROOT/t1-archive"
T1_BIN="$TMP_ROOT/t1-bin"
mkdir -p "$T1_PRIVATE_TMP" "$T1_TMP"
mkdir -p "$T1_PRIVATE_TMP/pr9999-scratch"
head -c 2048 </dev/urandom > "$T1_PRIVATE_TMP/pr9999-scratch/payload.bin" 2>/dev/null \
  || printf 'x%.0s' {1..2048} > "$T1_PRIVATE_TMP/pr9999-scratch/payload.bin"
/usr/bin/find "$T1_PRIVATE_TMP/pr9999-scratch" -exec touch -t 202001010000 {} +
make_multiline_du_stub "$T1_BIN" "pr9999-scratch" 12345

T1_OUT="$TMP_ROOT/t1.out"
set +e
env -i HOME="$TMP_ROOT/t1-home" \
  PATH="$T1_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T1_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T1_TMP" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$T1_TMP" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T1_ARCHIVE" \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --large >"$T1_OUT" 2>&1
T1_RC=$?
set -e
T1_OUT_CONTENT="$(cat "$T1_OUT")"
assert_rc "Test 1: exits 0 (no arithmetic error abort)" 0 "$T1_RC"
assert_not_contains "Test 1: no arithmetic syntax error" "arithmetic syntax error" "$T1_OUT_CONTENT"
assert_not_contains "Test 1: no integer-comparison syntax error from a multi-line kb" \
  "syntax error in expression" "$T1_OUT_CONTENT"
assert_contains "Test 1: logs the LAST line's kb value (12345), not the bogus first line (999)" \
  "(12345 KB)" "$T1_OUT_CONTENT"
assert_not_contains "Test 1: does not report the bogus first-line value" "(999 KB)" "$T1_OUT_CONTENT"

echo "Test 2: cleanup_pr_scratch.sh --clean tolerates multi-line du output, takes the LAST line"
T2_DIR="$TMP_ROOT/t2-tmp"
mkdir -p "$T2_DIR/pr8888-scratch"
head -c 2048 </dev/urandom > "$T2_DIR/pr8888-scratch/payload.bin" 2>/dev/null \
  || printf 'x%.0s' {1..2048} > "$T2_DIR/pr8888-scratch/payload.bin"
/usr/bin/find "$T2_DIR/pr8888-scratch" -exec touch -t 202001010000 {} +
T2_BIN="$TMP_ROOT/t2-bin"
make_multiline_du_stub "$T2_BIN" "pr8888-scratch" 6789

T2_OUT="$TMP_ROOT/t2.out"
set +e
PATH="$T2_BIN:$PATH" \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$T2_DIR" \
  DISK_MAGICIAN_DELETION_LOG="$TMP_ROOT/t2-deletions.log" \
  bash "$REPO_ROOT/scripts/cleanup_pr_scratch.sh" --clean --tmp-dir "$T2_DIR" >"$T2_OUT" 2>&1
T2_RC=$?
set -e
T2_OUT_CONTENT="$(cat "$T2_OUT")"
assert_rc "Test 2: exits 0 (no arithmetic error abort)" 0 "$T2_RC"
assert_not_contains "Test 2: no arithmetic syntax error" "arithmetic syntax error" "$T2_OUT_CONTENT"
assert_contains "Test 2: logs the LAST line's kb value (6789), not the bogus first line (999)" \
  "6789" "$T2_OUT_CONTENT"
assert_not_contains "Test 2: does not report the bogus first-line value" "(999" "$T2_OUT_CONTENT"

echo "Test 3: cleanup_tmp.sh --clean tolerates du emitting NO output at all (default 0)"
T3_PRIVATE_TMP="$TMP_ROOT/t3-private-tmp"
T3_TMP="$TMP_ROOT/t3-tmp"
T3_ARCHIVE="$TMP_ROOT/t3-archive"
T3_BIN="$TMP_ROOT/t3-bin"
mkdir -p "$T3_PRIVATE_TMP" "$T3_TMP" "$T3_PRIVATE_TMP/pr7777-scratch"
touch "$T3_PRIVATE_TMP/pr7777-scratch/payload.bin"
/usr/bin/find "$T3_PRIVATE_TMP/pr7777-scratch" -exec touch -t 202001010000 {} +
mkdir -p "$T3_BIN"
cat > "$T3_BIN/du" <<EOF
#!/usr/bin/env bash
last=""
for arg in "\$@"; do last="\$arg"; done
if [[ "\$last" == "$T3_PRIVATE_TMP/pr7777-scratch" ]]; then
  exit 1
fi
exec /usr/bin/du "\$@"
EOF
chmod +x "$T3_BIN/du"

T3_OUT="$TMP_ROOT/t3.out"
set +e
env -i HOME="$TMP_ROOT/t3-home" \
  PATH="$T3_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T3_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$T3_TMP" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$T3_TMP" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$T3_ARCHIVE" \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --large >"$T3_OUT" 2>&1
T3_RC=$?
set -e
T3_OUT_CONTENT="$(cat "$T3_OUT")"
assert_rc "Test 3: exits 0 when du emits nothing at all" 0 "$T3_RC"
assert_not_contains "Test 3: no arithmetic syntax error" "arithmetic syntax error" "$T3_OUT_CONTENT"
# kb defaults to 0 (empty du output -> "not large enough"), so the item is
# quietly skipped by the LARGE_TMP_MIN_KB comparison rather than archived --
# the decisive regression signal is the ABSENCE of the integer-comparison
# crash `du -sk` emitting nothing used to cause (`[[ "" -lt 1 ]]` -> "integer
# expression expected"), not a specific "(0 KB)" log line.
assert_not_contains "Test 3: no integer-expression-expected crash from an empty kb" \
  "integer expression expected" "$T3_OUT_CONTENT"
assert_not_contains "Test 3: pr7777-scratch is not wrongly archived despite unmeasurable size" \
  "Archiving: $T3_PRIVATE_TMP/pr7777-scratch" "$T3_OUT_CONTENT"

echo
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

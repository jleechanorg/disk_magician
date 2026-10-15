#!/usr/bin/env bash
# test_lsof_skip_check_production_guard.sh — PR #71 /advice request-changes
# (Opus): cleanup_pr_scratch.sh's has_open_files() honored
# DISK_MAGICIAN_SKIP_LSOF_CHECK=1 unconditionally. That variable exists so
# tests can bypass a real lsof call; in production it must be IGNORED (with
# a logged warning), never allowed to disable the open-file safety check
# that stands between --clean and deleting an actively-open file.
#
# Restriction: the bypass now only takes effect when DISK_MAGICIAN_TEST_SANDBOX
# is also set (i.e. inside a real sandboxed test context, mirroring the
# mandatory sandbox_guard_roots enforcement in scripts/safety_lib.sh). Outside
# a sandbox, DISK_MAGICIAN_SKIP_LSOF_CHECK=1 is ignored and the real lsof
# check still runs.
#
# Run: bash tests/test_lsof_skip_check_production_guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/cleanup_pr_scratch.sh"
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMP_ROOT="$(mktemp -d /tmp/test_lsof_skip_guard.XXXXXX)" || exit 1
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" || "$TMP_ROOT" != /tmp/test_lsof_skip_guard.* ]]; then
  echo "FATAL: invalid fixture root: $TMP_ROOT" >&2
  exit 1
fi
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)" || exit 1
case "$TMP_ROOT" in
  /tmp/test_lsof_skip_guard.*|/private/tmp/test_lsof_skip_guard.*) ;;
  *) echo "FATAL: fixture root escaped /tmp: $TMP_ROOT" >&2; exit 1 ;;
esac
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_exists() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to exist: $path"; fi
}

assert_missing() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then record_pass "$name"; else record_fail "$name" "expected path to be gone: $path"; fi
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

# make_scoped_lsof <path> — an lsof stub with records matching the query.
# C14's open-file probe needs an open-file record, while cwd-oriented callers
# need a complete p/f/n record. Returning only a PID is too permissive: it can
# make a test pass without exercising the production parser's query boundary.
make_scoped_lsof() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
case " $* " in
  *" +D "*)
    printf 'p99999\nf3\nn%s/file.txt\n' "$target"
    ;;
  *" -d cwd "*)
    printf 'p99999\nfcwd\nn%s\n' "$target"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$path"
}

FAKE_LSOF="$TMP_ROOT/fake-lsof-open"
make_scoped_lsof "$FAKE_LSOF"

echo "Test 1: outside a sandbox, DISK_MAGICIAN_SKIP_LSOF_CHECK=1 is IGNORED -- the real (stubbed) lsof check still runs"
T1_DIR="$TMP_ROOT/t1_tmp"
T1_HOME="$TMP_ROOT/t1_home"
T1_STATE="$TMP_ROOT/t1_state"
mkdir -p "$T1_HOME" "$T1_STATE"
mkdir -p "$T1_DIR/pr-open-target"
touch "$T1_DIR/pr-open-target/file.txt"
/usr/bin/find "$T1_DIR" -exec touch -t 202001010000 {} +

# Deliberately NOT setting DISK_MAGICIAN_TEST_SANDBOX here -- this call must
# behave like production. Confinement is via --tmp-dir alone (cleanup_pr_scratch.sh
# replaces its whole root list with exactly this fixture dir when --tmp-dir is
# given), matching the pattern already used by the script's own dry-run/help
# invocations elsewhere in this test suite.
T1_OUT=$(env -u DISK_MAGICIAN_TEST_CONTEXT -u DISK_MAGICIAN_TEST_SANDBOX \
  HOME="$T1_HOME" DISK_MAGICIAN_STATE_DIR="$T1_STATE" \
  DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" DISK_MAGICIAN_SKIP_LSOF_CHECK=1 \
  bash "$TARGET_SCRIPT" --clean --tmp-dir "$T1_DIR" 2>&1)
assert_exists "T1: open-marked target is preserved (lsof bypass ignored outside sandbox)" "$T1_DIR/pr-open-target"
assert_contains "T1: logs that the skip flag was ignored outside a sandbox" \
  "DISK_MAGICIAN_SKIP_LSOF_CHECK=1 ignored" "$T1_OUT"

echo "Test 2: inside a sandbox, the legacy skip bypasses has_open_files but C14 still preserves open files"
T2_DIR="$TMP_ROOT/t2_tmp"
T2_HOME="$TMP_ROOT/t2_home"
T2_STATE="$TMP_ROOT/t2_state"
mkdir -p "$T2_HOME" "$T2_STATE"
mkdir -p "$T2_DIR/pr-open-target"
touch "$T2_DIR/pr-open-target/file.txt"
/usr/bin/find "$T2_DIR" -exec touch -t 202001010000 {} +

T2_OUT=$(HOME="$T2_HOME" DISK_MAGICIAN_STATE_DIR="$T2_STATE" \
  DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" DISK_MAGICIAN_SKIP_LSOF_CHECK=1 \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" DISK_MAGICIAN_TEST_SANDBOX="$T2_DIR" \
  bash "$TARGET_SCRIPT" --clean --tmp-dir "$T2_DIR" 2>&1)
assert_exists "T2: C14 preserves the open target despite the legacy skip flag" "$T2_DIR/pr-open-target"
assert_contains "T2: C14 reports the open-file keep reason" "kept:open-file" "$T2_OUT"

echo
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_cleanup_tmp_large_protections.sh — Regression coverage for the
# --large branch of cleanup_tmp.sh: active-use protection, protected-roots
# list, and archive-not-delete.
#
# Root cause under test: 9+ logged incidents (2026-07-13..15,
# ~/Library/Logs/disk-magician-pressure-sweep.log) where
# pressure_sweep.sh -> cleanup_tmp.sh --clean --large rm -rf'd
# /private/tmp/worldarchitect.ai (worldarchitect.ai's documented canonical
# evidence path) because it matched none of the skip patterns
# (com.apple.*/system-*/PowerlogHelperd*/wt_*/worktree_*) and
# LARGE_TMP_APPROVED=1 is auto-set by pressure_sweep.sh below the free-space
# threshold.
#
# RED section runs the pre-fix script content (git show at a pinned
# pre-fix SHA, before this PR's changes) against a fixture and proves it
# deletes the protected dir. GREEN section runs the current script and
# proves it does not.
#
# The pre-fix reference is pinned to a literal commit SHA (NOT "HEAD" and
# NOT "HEAD^") because once this PR's fix commit lands on the branch, HEAD
# (and, on any later commit, HEAD^ too) points at already-fixed code — a
# relative ref self-invalidates the moment the commit lands or the branch
# grows. A literal SHA of the last commit before the fix stays correct
# forever. A guard immediately below re-verifies the fetched content is
# actually the unfixed version (absence of the fixed-code marker
# `is_protected_root`), so a bad pin fails loudly instead of producing a
# confusing RED failure.
#
# Run: bash tests/test_cleanup_tmp_large_protections.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"

# Literal pre-fix SHA: the commit immediately before
# be1858a "fix(cleanup_tmp): add active-use protection to --large branch".
# Do not change to HEAD or HEAD^ — see comment block above.
PRE_FIX_SHA="b1a30f95d4a75dd52ed313b100629c9af783717c"

TMP_ROOT=$(mktemp -d /tmp/cleanup_tmp_large_protections.XXXXXX) || exit 1
[[ -d "$TMP_ROOT" && "$TMP_ROOT" == /tmp/cleanup_tmp_large_protections.* ]] || exit 1
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
  if grep -qF -- "$needle" <<<"$haystack"; then
    record_fail "$name" "unexpected output contained: $needle"
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

# make_find_shim <bin_dir> <fake_private_tmp> <fake_tmp>
# Redirects literal `find /private/tmp ...` / `find /tmp ...` calls (as used
# by the --large scan and the earlier git-clone/worktree scans) at fixture
# dirs, exactly like tests/test_cleanup_safety.sh Test 5.
make_find_shim() {
  local bin_dir="$1" fake_private_tmp="$2" fake_tmp="$3"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/find" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  /private/tmp)
    shift
    exec /usr/bin/find "$fake_private_tmp" "\$@"
    ;;
  /tmp)
    shift
    exec /usr/bin/find "$fake_tmp" "\$@"
    ;;
  *)
    if [[ -n "\${FAIL_FIND_ROOT:-}" && "\${1:-}" == "\$FAIL_FIND_ROOT" ]]; then
      exit 91
    fi
    exec /usr/bin/find "\$@"
    ;;
esac
EOF
  chmod +x "$bin_dir/find"

  cat > "$bin_dir/getconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "DARWIN_USER_TEMP_DIR" ]]; then
  exit 0
fi
exec /usr/bin/getconf "$@"
EOF
  chmod +x "$bin_dir/getconf"

  if command -v timeout >/dev/null 2>&1; then
    ln -sf "$(command -v timeout)" "$bin_dir/timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    ln -sf "$(command -v gtimeout)" "$bin_dir/timeout"
  elif [[ -x /opt/homebrew/bin/timeout ]]; then
    ln -sf /opt/homebrew/bin/timeout "$bin_dir/timeout"
  elif [[ -x /usr/local/bin/timeout ]]; then
    ln -sf /usr/local/bin/timeout "$bin_dir/timeout"
  else
    cat > "$bin_dir/timeout" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --kill-after=* ]] && shift
shift
exec "$@"
EOF
    chmod +x "$bin_dir/timeout"
  fi
}

make_du_probe() {
  local bin_dir="$1"
  cat > "$bin_dir/du" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do
  last="$arg"
done
if [[ -n "${DU_LOG:-}" ]]; then
  printf '%s\n' "$last" >> "$DU_LOG"
fi
if [[ -n "${DU_OPEN_ON_PATH:-}" && "$last" == "$DU_OPEN_ON_PATH" ]]; then
  /usr/bin/nohup /usr/bin/tail -f "$DU_OPEN_PATH" >/dev/null 2>&1 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" >"$DU_HOLDER_PID_FILE"
  for _ in 1 2 3 4 5; do
    [[ -n "$(/usr/sbin/lsof +D "$DU_OPEN_ON_PATH" 2>/dev/null || true)" ]] && break
    sleep 1
  done
fi
if [[ -n "${DU_FIXED_PATH:-}" && "$last" == "$DU_FIXED_PATH" ]]; then
  printf '4\t%s\n' "$last"
  exit 0
fi
exec /usr/bin/du "$@"
EOF
  chmod +x "$bin_dir/du"
}

make_lsof_failure_shim() {
  local shim_path="$1"
  cat > "$shim_path" <<'EOF'
#!/usr/bin/env bash
echo "lsof: cannot traverse requested tree" >&2
exit 1
EOF
  chmod +x "$shim_path"
}

make_large_dir() {
  # make_large_dir <dir> — a directory whose real du -sk size clears the
  # default 100MB LARGE_TMP_MIN_KB threshold isn't needed in tests: we
  # override LARGE_TMP_MIN_KB=1 so any non-empty dir counts as "large".
  local dir="$1"
  mkdir -p "$dir"
  head -c 2048 </dev/urandom > "$dir/payload.bin" 2>/dev/null || printf 'x%.0s' {1..2048} > "$dir/payload.bin"
}

ago_stamp() {
  # ago_stamp <minutes> — touch -t timestamp for <minutes> ago (BSD or GNU date).
  date -v-"$1"M '+%Y%m%d%H%M' 2>/dev/null || date -d "$1 minutes ago" '+%Y%m%d%H%M'
}

set_old_mtime() {
  # Backdate every entry under $1 (and $1 itself) well outside the default
  # 24h active-use window.
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
}

# make_c14_archive_entry <source> <entry> <retention_min> <private_tmp> <tmp_root>
# Builds a real E2 origin source and its matching archive receipt, then moves it
# to <entry>. Mirrors test_cleanup_tmp_archive_purge.sh: the receipt is written
# before the same-filesystem move, so its dev/ino/size still match the entry
# that C14 re-checks (approved contract E1). A raw directory with no receipt is
# deliberately not eligible.
make_c14_archive_entry() {
  local source="$1" entry="$2" retention="$3" private_tmp="$4" tmp_root="$5"
  local actual_retention archived_at
  # Canonicalize the E2 scratch roots: c14_ephemeral_retention resolves them
  # with `cd && pwd -P` (macOS /tmp -> /private/tmp), so the receipt's
  # original_path must be canonical for the row to match at verdict time.
  private_tmp="$(cd "$private_tmp" && pwd -P)"
  tmp_root="$(cd "$tmp_root" && pwd -P)"
  source="$tmp_root/${source##*/}"
  mkdir -p "$source" "${entry%/*}"
  printf 'archived fixture\n' >"$source/payload.bin"
  actual_retention="$(DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$private_tmp" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tmp_root" \
    bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2"' _ "$REPO_ROOT" "$source")"
  if [[ "$actual_retention" != "$retention" ]]; then
    record_fail "archive fixture retention for $source" "expected $retention, got '$actual_retention'"
    return 1
  fi
  archived_at="$(python3 -c 'import sys,time; print(int(time.time())-int(sys.argv[1])*3600)' "$(( retention / 60 + 25 ))")"
  python3 "$REPO_ROOT/scripts/c14_probe.py" archive-receipt "$source" "$entry.c14-origin.json" "$archived_at" "$retention" >/dev/null
  mv "$source" "$entry"
  set_old_mtime "$entry"
}

echo "=== cleanup_tmp.sh --large protection tests ==="

if [[ "$PRE_FIX_SHA" =~ ^[[:xdigit:]]{40}$ ]]; then
  record_pass "pre-fix SHA pin is a full 40-character object ID"
else
  record_fail "pre-fix SHA pin is a full 40-character object ID" \
    "got '$PRE_FIX_SHA' (${#PRE_FIX_SHA} characters)"
fi

# ─────────────────────── RED: prove the pre-fix bug ───────────────────────
echo "RED: pre-fix cleanup_tmp.sh deletes a protected-root-shaped large tmp dir"
RED_SCRIPT="$TMP_ROOT/red-cleanup_tmp.sh"
if git -C "$REPO_ROOT" show "$PRE_FIX_SHA:scripts/cleanup_tmp.sh" > "$RED_SCRIPT" 2>/dev/null; then
  chmod +x "$RED_SCRIPT"
  # Guard: the pinned pre-fix SHA must NOT contain the fixed-code marker.
  # If it does, the pin is wrong (points at or past the fix commit) and the
  # RED replay below would silently run already-fixed code instead of
  # reproducing the bug — fail loudly here instead of a confusing RED
  # assertion failure further down.
  if grep -q "is_protected_root" "$RED_SCRIPT"; then
    record_fail "RED: pre-fix SHA pin ($PRE_FIX_SHA) is stale" \
      "fetched script already contains the fixed-code marker 'is_protected_root' — update PRE_FIX_SHA to a commit before the fix"
    RED_GUARD_FAILED=1
  else
    RED_GUARD_FAILED=0
  fi
  if [[ "$RED_GUARD_FAILED" -eq 0 ]]; then
    RED_PRIVATE_TMP="$TMP_ROOT/red-private-tmp"
    RED_TMP="$TMP_ROOT/red-tmp"
    RED_BIN="$TMP_ROOT/red-bin"
    mkdir -p "$RED_PRIVATE_TMP" "$RED_TMP"
    make_find_shim "$RED_BIN" "$RED_PRIVATE_TMP" "$RED_TMP"
    make_large_dir "$RED_PRIVATE_TMP/worldarchitect.ai"
    set_old_mtime "$RED_PRIVATE_TMP/worldarchitect.ai"

    RED_OUT="$TMP_ROOT/red.out"
    if run_capture "$RED_OUT" env -i HOME="$TMP_ROOT/red-home" \
      PATH="$RED_BIN:/usr/bin:/bin" \
      LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
      bash "$RED_SCRIPT" --clean --large; then
      RED_RC=0
    else
      RED_RC=$?
    fi
    assert_rc "RED: pre-fix script exits 0" 0 "$RED_RC"
    assert_missing "RED: pre-fix script deletes /private/tmp/worldarchitect.ai (confirms historical bug)" \
      "$RED_PRIVATE_TMP/worldarchitect.ai"
  fi
else
  record_fail "RED: could not load $PRE_FIX_SHA:scripts/cleanup_tmp.sh" "git show failed — skipped RED proof"
fi

# ─────────────────────────── GREEN: fixed script ───────────────────────────

echo "GREEN 1: fresh-mtime large dir is skipped, not archived or deleted"
G1_PRIVATE_TMP="$TMP_ROOT/g1-private-tmp"
G1_TMP="$TMP_ROOT/g1-tmp"
G1_ARCHIVE="$TMP_ROOT/g1-archive"
G1_BIN="$TMP_ROOT/g1-bin"
mkdir -p "$G1_PRIVATE_TMP" "$G1_TMP"
make_find_shim "$G1_BIN" "$G1_PRIVATE_TMP" "$G1_TMP"
make_large_dir "$G1_PRIVATE_TMP/fresh_scratch_dir"
# Deliberately do NOT backdate — mtime is "now", inside the 24h window.

G1_OUT="$TMP_ROOT/g1.out"
if run_capture "$G1_OUT" env -i HOME="$TMP_ROOT/g1-home" \
  PATH="$G1_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G1_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G1_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G1_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G1_RC=0
else
  G1_RC=$?
fi
G1_OUT_CONTENT=$(cat "$G1_OUT")
assert_rc "GREEN 1: exits 0" 0 "$G1_RC"
assert_contains "GREEN 1: logs recently-active skip" \
  "Skipping recently active dir (mtime/ctime within 24h): $G1_PRIVATE_TMP/fresh_scratch_dir" "$G1_OUT_CONTENT"
assert_exists "GREEN 1: fresh dir untouched at original path" "$G1_PRIVATE_TMP/fresh_scratch_dir"

echo "GREEN 2: dir with .in-use marker is skipped even though mtime is old"
G2_PRIVATE_TMP="$TMP_ROOT/g2-private-tmp"
G2_TMP="$TMP_ROOT/g2-tmp"
G2_ARCHIVE="$TMP_ROOT/g2-archive"
G2_BIN="$TMP_ROOT/g2-bin"
mkdir -p "$G2_PRIVATE_TMP" "$G2_TMP"
make_find_shim "$G2_BIN" "$G2_PRIVATE_TMP" "$G2_TMP"
make_large_dir "$G2_PRIVATE_TMP/marked_in_use_dir"
touch "$G2_PRIVATE_TMP/marked_in_use_dir/.in-use"
set_old_mtime "$G2_PRIVATE_TMP/marked_in_use_dir"

G2_OUT="$TMP_ROOT/g2.out"
if run_capture "$G2_OUT" env -i HOME="$TMP_ROOT/g2-home" \
  PATH="$G2_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G2_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G2_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G2_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G2_RC=0
else
  G2_RC=$?
fi
G2_OUT_CONTENT=$(cat "$G2_OUT")
assert_rc "GREEN 2: exits 0" 0 "$G2_RC"
assert_contains "GREEN 2: logs .in-use skip" \
  "Skipping active-use marker (.in-use present): $G2_PRIVATE_TMP/marked_in_use_dir" "$G2_OUT_CONTENT"
assert_exists "GREEN 2: marked dir untouched at original path" "$G2_PRIVATE_TMP/marked_in_use_dir"

echo "GREEN 3: protected-root dir is skipped regardless of mtime/size"
G3_PRIVATE_TMP="$TMP_ROOT/g3-private-tmp"
G3_TMP="$TMP_ROOT/g3-tmp"
G3_ARCHIVE="$TMP_ROOT/g3-archive"
G3_BIN="$TMP_ROOT/g3-bin"
mkdir -p "$G3_PRIVATE_TMP" "$G3_TMP"
make_find_shim "$G3_BIN" "$G3_PRIVATE_TMP" "$G3_TMP"
make_large_dir "$G3_PRIVATE_TMP/worldarchitect.ai"
mkdir -p "$G3_PRIVATE_TMP/worldarchitect.ai/.git"
set_old_mtime "$G3_PRIVATE_TMP/worldarchitect.ai"

G3_OUT="$TMP_ROOT/g3.out"
if run_capture "$G3_OUT" env -i HOME="$TMP_ROOT/g3-home" \
  PATH="$G3_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G3_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G3_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G3_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G3_RC=0
else
  G3_RC=$?
fi
G3_OUT_CONTENT=$(cat "$G3_OUT")
assert_rc "GREEN 3: exits 0" 0 "$G3_RC"
assert_contains "GREEN 3: logs protected-root skip" \
  "Skipping protected root (in PROTECTED_TMP_ROOTS): $G3_PRIVATE_TMP/worldarchitect.ai" "$G3_OUT_CONTENT"
assert_exists "GREEN 3: worldarchitect.ai untouched at original path (the historical incident, now fixed)" \
  "$G3_PRIVATE_TMP/worldarchitect.ai"

echo "GREEN 3b: DISK_MAGICIAN_PROTECTED_TMP_ROOTS env override adds a custom protected root"
G3B_PRIVATE_TMP="$TMP_ROOT/g3b-private-tmp"
G3B_TMP="$TMP_ROOT/g3b-tmp"
G3B_ARCHIVE="$TMP_ROOT/g3b-archive"
G3B_BIN="$TMP_ROOT/g3b-bin"
mkdir -p "$G3B_PRIVATE_TMP" "$G3B_TMP"
make_find_shim "$G3B_BIN" "$G3B_PRIVATE_TMP" "$G3B_TMP"
make_large_dir "$G3B_PRIVATE_TMP/my_custom_root"
set_old_mtime "$G3B_PRIVATE_TMP/my_custom_root"

G3B_OUT="$TMP_ROOT/g3b.out"
if run_capture "$G3B_OUT" env -i HOME="$TMP_ROOT/g3b-home" \
  PATH="$G3B_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G3B_ARCHIVE" \
  DISK_MAGICIAN_PROTECTED_TMP_ROOTS="my_custom_root" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G3B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G3B_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G3B_RC=0
else
  G3B_RC=$?
fi
G3B_OUT_CONTENT=$(cat "$G3B_OUT")
assert_rc "GREEN 3b: exits 0" 0 "$G3B_RC"
assert_contains "GREEN 3b: logs env-configured protected-root skip" \
  "Skipping protected root (in PROTECTED_TMP_ROOTS): $G3B_PRIVATE_TMP/my_custom_root" "$G3B_OUT_CONTENT"
assert_exists "GREEN 3b: custom protected root untouched" "$G3B_PRIVATE_TMP/my_custom_root"

echo "GREEN 3c: unreadable activity subtree fails closed instead of being archived"
G3C_PRIVATE_TMP="$TMP_ROOT/g3c-private-tmp"
G3C_TMP="$TMP_ROOT/g3c-tmp"
G3C_ARCHIVE="$TMP_ROOT/g3c-archive"
G3C_BIN="$TMP_ROOT/g3c-bin"
mkdir -p "$G3C_PRIVATE_TMP" "$G3C_TMP"
make_find_shim "$G3C_BIN" "$G3C_PRIVATE_TMP" "$G3C_TMP"
make_du_probe "$G3C_BIN"
make_large_dir "$G3C_PRIVATE_TMP/unreadable_tree"
mkdir -p "$G3C_PRIVATE_TMP/unreadable_tree/blocked"
touch "$G3C_PRIVATE_TMP/unreadable_tree/blocked/hidden"
set_old_mtime "$G3C_PRIVATE_TMP/unreadable_tree"
chmod 000 "$G3C_PRIVATE_TMP/unreadable_tree/blocked"

G3C_OUT="$TMP_ROOT/g3c.out"
if run_capture "$G3C_OUT" env -i HOME="$TMP_ROOT/g3c-home" \
  PATH="$G3C_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DU_FIXED_PATH="$G3C_PRIVATE_TMP/unreadable_tree" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G3C_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G3C_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G3C_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G3C_RC=0
else
  G3C_RC=$?
fi
chmod 700 "$G3C_PRIVATE_TMP/unreadable_tree/blocked" 2>/dev/null || true
/usr/bin/find "$G3C_ARCHIVE" -type d -name blocked -exec chmod 700 {} + 2>/dev/null || true
G3C_OUT_CONTENT=$(cat "$G3C_OUT")
assert_rc "GREEN 3c: exits 0" 0 "$G3C_RC"
assert_contains "GREEN 3c: logs fail-closed activity probe" \
  "fail-closed, treating as active" "$G3C_OUT_CONTENT"
assert_exists "GREEN 3c: unreadable tree remains at original path" \
  "$G3C_PRIVATE_TMP/unreadable_tree"

echo "GREEN 3d: LARGE_TMP_ACTIVE_HOURS env overrides config"
G3D_PRIVATE_TMP="$TMP_ROOT/g3d-private-tmp"
G3D_TMP="$TMP_ROOT/g3d-tmp"
G3D_ARCHIVE="$TMP_ROOT/g3d-archive"
G3D_BIN="$TMP_ROOT/g3d-bin"
mkdir -p "$G3D_PRIVATE_TMP" "$G3D_TMP"
make_find_shim "$G3D_BIN" "$G3D_PRIVATE_TMP" "$G3D_TMP"
make_large_dir "$G3D_PRIVATE_TMP/env_active_window"
set_old_mtime "$G3D_PRIVATE_TMP/env_active_window"

G3D_OUT="$TMP_ROOT/g3d.out"
if run_capture "$G3D_OUT" env -i HOME="$TMP_ROOT/g3d-home" \
  PATH="$G3D_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ACTIVE_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G3D_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G3D_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G3D_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G3D_RC=0
else
  G3D_RC=$?
fi
G3D_OUT_CONTENT=$(cat "$G3D_OUT")
assert_rc "GREEN 3d: exits 0" 0 "$G3D_RC"
assert_contains "GREEN 3d: logs env-selected active window" \
  "mtime/ctime within 876000h" "$G3D_OUT_CONTENT"
assert_exists "GREEN 3d: env-selected active window preserves candidate" \
  "$G3D_PRIVATE_TMP/env_active_window"

echo "GREEN 4: old + unmarked large dir with a declared-ephemeral name is archived (moved, not rm -rf'd)"
G4_PRIVATE_TMP="$TMP_ROOT/g4-private-tmp"
G4_TMP="$TMP_ROOT/g4-tmp"
G4_ARCHIVE="$TMP_ROOT/g4-archive"
G4_BIN="$TMP_ROOT/g4-bin"
mkdir -p "$G4_PRIVATE_TMP" "$G4_TMP"
# Canonicalize the E2 scratch roots (c14_ephemeral_retention resolves them with
# `cd && pwd -P`) so the `pr_` candidate has a declared-ephemeral row: cleanup_tmp
# only quarantines candidates with a declared retention (bead
# disk_magician-archive-same-volume-regrowth-03bn).
G4_PRIVATE_TMP="$(cd "$G4_PRIVATE_TMP" && pwd -P)"
G4_TMP="$(cd "$G4_TMP" && pwd -P)"
make_find_shim "$G4_BIN" "$G4_PRIVATE_TMP" "$G4_TMP"
make_du_probe "$G4_BIN"
make_large_dir "$G4_PRIVATE_TMP/pr_stale_scratch_dir"
set_old_mtime "$G4_PRIVATE_TMP/pr_stale_scratch_dir"
G4_CANDIDATE_CANON="$(cd "$G4_PRIVATE_TMP/pr_stale_scratch_dir" && pwd -P)"
G4_DU_LOG="$TMP_ROOT/g4-du.log"
: > "$G4_DU_LOG"

G4_OUT="$TMP_ROOT/g4.out"
if run_capture "$G4_OUT" env -i HOME="$TMP_ROOT/g4-home" \
  PATH="$G4_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DU_LOG="$G4_DU_LOG" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G4_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G4_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G4_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G4_RC=0
else
  G4_RC=$?
fi
G4_OUT_CONTENT=$(cat "$G4_OUT")
assert_rc "GREEN 4: exits 0" 0 "$G4_RC"
assert_contains "GREEN 4: logs archiving (not 'Removing:')" \
  "Archiving: $G4_PRIVATE_TMP/pr_stale_scratch_dir ->" "$G4_OUT_CONTENT"
assert_missing "GREEN 4: original path is gone (moved)" "$G4_PRIVATE_TMP/pr_stale_scratch_dir"
G4_ARCHIVED_COUNT=$(/usr/bin/find "$G4_ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr_stale_scratch_dir 2>/dev/null | wc -l | tr -d ' ')
if [[ "$G4_ARCHIVED_COUNT" -eq 1 ]]; then
  record_pass "GREEN 4: exactly one archived copy exists under DISK_MAGICIAN_ARCHIVE_ROOT"
else
  record_fail "GREEN 4: exactly one archived copy exists under DISK_MAGICIAN_ARCHIVE_ROOT" \
    "found $G4_ARCHIVED_COUNT under $G4_ARCHIVE"
fi
assert_exists "GREEN 4: archived payload is still readable (data preserved, not lost)" \
  "$G4_ARCHIVE"/*/pr_stale_scratch_dir/payload.bin
G4_ENTRY=$(/usr/bin/find "$G4_ARCHIVE" -mindepth 2 -maxdepth 2 \
  -type d -name pr_stale_scratch_dir -print -quit 2>/dev/null || true)
if python3 - "$G4_ENTRY" "$G4_ENTRY.c14-origin.json" "$G4_CANDIDATE_CANON" <<'PY'
import json, os, sys
entry, receipt, original = sys.argv[1:]
st = os.lstat(entry)
data = json.load(open(receipt, encoding="utf-8"))
assert data["original_path"] == original
assert data["retention_minutes"] == 2880
assert (data["dev"], data["ino"], data["size"]) == (st.st_dev, st.st_ino, st.st_size)
assert type(data["archived_at"]) is int and data["archived_at"] > 0
PY
then
  record_pass "GREEN 4: archive origin receipt binds the canonical path with the declared retention"
else
  record_fail "GREEN 4: archive origin receipt binds the canonical path with the declared retention" "receipt missing, identity differs, or retention is not the declared 2880"
fi
G4_TARGET_DU_COUNT=$(grep -cFx "$G4_PRIVATE_TMP/pr_stale_scratch_dir" "$G4_DU_LOG" || true)
assert_rc "GREEN 4: candidate size is measured once" 1 "$G4_TARGET_DU_COUNT"
assert_contains "GREEN 4: archive move is not counted as a removed dir" \
  "Dirs removed: 0" "$G4_OUT_CONTENT"
assert_contains "GREEN 4: same-filesystem archive move reports zero reclaimed bytes" \
  "Total freed: 0 KB" "$G4_OUT_CONTENT"
assert_contains "GREEN 4: quarantine accounting is reported separately" \
  "Dirs archived: 1" "$G4_OUT_CONTENT"

echo "GREEN 4b: a receipt-write failure preserves the source and the run continues"
G4B_PRIVATE_TMP="$TMP_ROOT/g4b-private-tmp"
G4B_TMP="$TMP_ROOT/g4b-tmp"
G4B_ARCHIVE="$TMP_ROOT/g4b-archive"
G4B_BIN="$TMP_ROOT/g4b-bin"
mkdir -p "$G4B_PRIVATE_TMP" "$G4B_TMP" "$TMP_ROOT/g4b-home"
# Canonicalize the E2 scratch roots so both candidates carry a declared
# ephemeral `pr_` row (required before cleanup_tmp quarantines a candidate).
G4B_PRIVATE_TMP="$(cd "$G4B_PRIVATE_TMP" && pwd -P)"
G4B_TMP="$(cd "$G4B_TMP" && pwd -P)"
make_c14_archive_entry "$G4B_TMP/cli_validation_gemini_continue"   "$G4B_ARCHIVE/20200101T000000Z/cli_validation_gemini_continue" 60 "$G4B_PRIVATE_TMP" "$G4B_TMP"
make_find_shim "$G4B_BIN" "$G4B_PRIVATE_TMP" "$G4B_TMP"
make_large_dir "$G4B_PRIVATE_TMP/pr_fail_candidate"
make_large_dir "$G4B_PRIVATE_TMP/pr_ok_candidate"
set_old_mtime "$G4B_PRIVATE_TMP/pr_fail_candidate"
set_old_mtime "$G4B_PRIVATE_TMP/pr_ok_candidate"
REAL_PYTHON3="$(command -v python3)"
cat > "$G4B_BIN/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == *c14_probe.py && "\${2:-}" == "archive-receipt" && "\${3:-}" == *fail_candidate* ]]; then
  echo "injected archive receipt failure" >&2
  exit 1
fi
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$G4B_BIN/python3"
G4B_OUT="$TMP_ROOT/g4b.out"
if run_capture "$G4B_OUT" env -i HOME="$TMP_ROOT/g4b-home" \
  PATH="$G4B_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G4B_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G4B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G4B_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G4B_RC=0
else
  G4B_RC=$?
fi
G4B_OUT_CONTENT=$(cat "$G4B_OUT")
assert_rc "GREEN 4b: exits 0 after a receipt failure (no set -e abort)" 0 "$G4B_RC"
assert_exists "GREEN 4b: failed candidate path is intact" "$G4B_PRIVATE_TMP/pr_fail_candidate/payload.bin"
G4B_FAIL_ARCHIVED=$(/usr/bin/find "$G4B_ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr_fail_candidate 2>/dev/null | wc -l | tr -d ' ')
assert_rc "GREEN 4b: failed candidate was not moved" 0 "$G4B_FAIL_ARCHIVED"
assert_exists "GREEN 4b: later eligible candidate archived" "$G4B_ARCHIVE"/*/pr_ok_candidate/payload.bin
assert_contains "GREEN 4b: archive failure is logged honestly" "could not archive" "$G4B_OUT_CONTENT"
assert_contains "GREEN 4b: only the successful archive is counted" "Dirs archived: 1" "$G4B_OUT_CONTENT"
assert_missing "GREEN 4b: run continued to purge_aged_archives (valid E2 entry reclaimed)" \
  "$G4B_ARCHIVE/20200101T000000Z/cli_validation_gemini_continue"
assert_contains "GREEN 4b: aged E2 archive purge logged" \
  "archive after C14 approval" "$G4B_OUT_CONTENT"

echo "GREEN 5: an aged archive entry is purged (space actually reclaimed on a later run)"
echo "GREEN 5: an aged E2 archive entry with a matching origin receipt is purged"
G5_PRIVATE_TMP="$TMP_ROOT/g5-private-tmp"
G5_TMP="$TMP_ROOT/g5-tmp"
G5_ARCHIVE="$TMP_ROOT/g5-archive"
G5_BIN="$TMP_ROOT/g5-bin"
G5_ENTRY="$G5_ARCHIVE/20200101T000000Z/cli_validation_gemini_g5"
mkdir -p "$G5_PRIVATE_TMP" "$G5_TMP"
make_find_shim "$G5_BIN" "$G5_PRIVATE_TMP" "$G5_TMP"
make_c14_archive_entry "$G5_TMP/cli_validation_gemini_g5" "$G5_ENTRY" 60 "$G5_PRIVATE_TMP" "$G5_TMP"

G5_OUT="$TMP_ROOT/g5.out"
if run_capture "$G5_OUT" env -i HOME="$TMP_ROOT/g5-home" \
  PATH="$G5_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5_RC=0
else
  G5_RC=$?
fi
G5_OUT_CONTENT=$(cat "$G5_OUT")
assert_rc "GREEN 5: exits 0" 0 "$G5_RC"
assert_contains "GREEN 5: logs the C14-approved aged archive purge" \
  "Purged aged archive after C14 approval" "$G5_OUT_CONTENT"
assert_missing "GREEN 5: aged archive entry actually reclaimed" "$G5_ENTRY"
assert_contains "GREEN 5: actual purge is counted as a removed dir" \
  "Dirs removed: 1" "$G5_OUT_CONTENT"

echo "GREEN 5g: an aged archive entry whose receipt no longer matches its identity is kept"
G5G_PRIVATE_TMP="$TMP_ROOT/g5g-private-tmp"
G5G_TMP="$TMP_ROOT/g5g-tmp"
G5G_ARCHIVE="$TMP_ROOT/g5g-archive"
G5G_BIN="$TMP_ROOT/g5g-bin"
G5G_ENTRY="$G5G_ARCHIVE/20200101T000000Z/cli_validation_gemini_g5g"
mkdir -p "$G5G_PRIVATE_TMP" "$G5G_TMP"
make_find_shim "$G5G_BIN" "$G5G_PRIVATE_TMP" "$G5G_TMP"
make_c14_archive_entry "$G5G_TMP/cli_validation_gemini_g5g" "$G5G_ENTRY" 60 "$G5G_PRIVATE_TMP" "$G5G_TMP"
# Move the receipted entry out of the archive and put a fresh inode at the same
# path: the stale receipt still names the *old* dev/ino, so E1 must reject it
# (`kept:archive-identity`) rather than confer eligibility on the replacement.
mv "$G5G_ENTRY" "$TMP_ROOT/g5g-receipted-entry-removed"
mkdir -p "$G5G_ENTRY" && printf 'replacement\n' >"$G5G_ENTRY/payload.bin"
set_old_mtime "$G5G_ENTRY"

G5G_OUT="$TMP_ROOT/g5g.out"
if run_capture "$G5G_OUT" env -i HOME="$TMP_ROOT/g5g-home" \
  PATH="$G5G_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5G_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5G_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5G_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5G_RC=0
else
  G5G_RC=$?
fi
G5G_OUT_CONTENT=$(cat "$G5G_OUT")
assert_rc "GREEN 5g: exits 0" 0 "$G5G_RC"
assert_contains "GREEN 5g: mismatched receipt is rejected as archive-identity" \
  "kept:archive-identity" "$G5G_OUT_CONTENT"
assert_exists "GREEN 5g: replacement entry is preserved" "$G5G_ENTRY/payload.bin"

echo "GREEN 5b: LARGE_TMP_ARCHIVE_RETENTION_HOURS env overrides config"
G5B_PRIVATE_TMP="$TMP_ROOT/g5b-private-tmp"
G5B_TMP="$TMP_ROOT/g5b-tmp"
G5B_ARCHIVE="$TMP_ROOT/g5b-archive"
G5B_BIN="$TMP_ROOT/g5b-bin"
mkdir -p "$G5B_PRIVATE_TMP" "$G5B_TMP" "$G5B_ARCHIVE/20200101T000000Z/already_archived_dir"
touch "$G5B_ARCHIVE/20200101T000000Z/already_archived_dir/payload.bin"
set_old_mtime "$G5B_ARCHIVE/20200101T000000Z"
make_find_shim "$G5B_BIN" "$G5B_PRIVATE_TMP" "$G5B_TMP"

G5B_OUT="$TMP_ROOT/g5b.out"
if run_capture "$G5B_OUT" env -i HOME="$TMP_ROOT/g5b-home" \
  PATH="$G5B_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5B_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5B_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5B_RC=0
else
  G5B_RC=$?
fi
assert_rc "GREEN 5b: exits 0" 0 "$G5B_RC"
assert_exists "GREEN 5b: env-selected retention preserves archive" \
  "$G5B_ARCHIVE/20200101T000000Z"

echo "GREEN 5c: an aged archive reopened by a live process is preserved"
G5C_PRIVATE_TMP="$TMP_ROOT/g5c-private-tmp"
G5C_TMP="$TMP_ROOT/g5c-tmp"
G5C_ARCHIVE="$TMP_ROOT/g5c-archive"
G5C_BIN="$TMP_ROOT/g5c-bin"
G5C_PAYLOAD="$G5C_ARCHIVE/20200101T000000Z/already_archived_dir/payload.bin"
mkdir -p "$G5C_PRIVATE_TMP" "$G5C_TMP" "$(dirname "$G5C_PAYLOAD")"
touch "$G5C_PAYLOAD"
set_old_mtime "$G5C_ARCHIVE/20200101T000000Z"
make_find_shim "$G5C_BIN" "$G5C_PRIVATE_TMP" "$G5C_TMP"

/usr/bin/tail -f "$G5C_PAYLOAD" >/dev/null 2>&1 &
G5C_HOLDER_PID=$!
for _ in 1 2 3 4 5; do
  [[ -n "$(/usr/sbin/lsof +D "$G5C_ARCHIVE/20200101T000000Z" 2>/dev/null || true)" ]] && break
  sleep 1
done

G5C_OUT="$TMP_ROOT/g5c.out"
if run_capture "$G5C_OUT" env -i HOME="$TMP_ROOT/g5c-home" \
  PATH="$G5C_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5C_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5C_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5C_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5C_RC=0
else
  G5C_RC=$?
fi
G5C_OUT_CONTENT=$(cat "$G5C_OUT")
kill "$G5C_HOLDER_PID" 2>/dev/null || true
wait "$G5C_HOLDER_PID" 2>/dev/null || true
assert_rc "GREEN 5c: exits 0" 0 "$G5C_RC"
assert_contains "GREEN 5c: logs in-use archive skip" \
  "Skipping in-use aged archive" "$G5C_OUT_CONTENT"
assert_exists "GREEN 5c: open archived payload is preserved" "$G5C_PAYLOAD"

echo "GREEN 5d: an aged archive with a nested .in-use marker is preserved"
G5D_PRIVATE_TMP="$TMP_ROOT/g5d-private-tmp"
G5D_TMP="$TMP_ROOT/g5d-tmp"
G5D_ARCHIVE="$TMP_ROOT/g5d-archive"
G5D_BIN="$TMP_ROOT/g5d-bin"
G5D_ENTRY="$G5D_ARCHIVE/20200101T000000Z/already_archived_dir"
mkdir -p "$G5D_PRIVATE_TMP" "$G5D_TMP" "$G5D_ENTRY"
touch "$G5D_ENTRY/payload.bin" "$G5D_ENTRY/.in-use"
set_old_mtime "$G5D_ARCHIVE/20200101T000000Z"
make_find_shim "$G5D_BIN" "$G5D_PRIVATE_TMP" "$G5D_TMP"

G5D_OUT="$TMP_ROOT/g5d.out"
run_capture "$G5D_OUT" env -i HOME="$TMP_ROOT/g5d-home" \
  PATH="$G5D_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5D_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5D_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5D_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large
G5D_RC=$?
G5D_OUT_CONTENT=$(cat "$G5D_OUT")
assert_rc "GREEN 5d: exits 0" 0 "$G5D_RC"
assert_contains "GREEN 5d: logs marked-active archive skip" \
  "Skipping marked-active aged archive" "$G5D_OUT_CONTENT"
assert_exists "GREEN 5d: marked archived payload is preserved" "$G5D_ENTRY/payload.bin"

echo "GREEN 5e: an aged archive with recent nested activity is preserved"
G5E_PRIVATE_TMP="$TMP_ROOT/g5e-private-tmp"
G5E_TMP="$TMP_ROOT/g5e-tmp"
G5E_ARCHIVE="$TMP_ROOT/g5e-archive"
G5E_BIN="$TMP_ROOT/g5e-bin"
G5E_ENTRY="$G5E_ARCHIVE/20200101T000000Z/already_archived_dir"
mkdir -p "$G5E_PRIVATE_TMP" "$G5E_TMP" "$G5E_ENTRY"
touch "$G5E_ENTRY/payload.bin"
set_old_mtime "$G5E_ARCHIVE/20200101T000000Z"
touch "$G5E_ENTRY/payload.bin"
make_find_shim "$G5E_BIN" "$G5E_PRIVATE_TMP" "$G5E_TMP"

G5E_OUT="$TMP_ROOT/g5e.out"
run_capture "$G5E_OUT" env -i HOME="$TMP_ROOT/g5e-home" \
  PATH="$G5E_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5E_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5E_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5E_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large
G5E_RC=$?
G5E_OUT_CONTENT=$(cat "$G5E_OUT")
assert_rc "GREEN 5e: exits 0" 0 "$G5E_RC"
assert_contains "GREEN 5e: logs recently-active archive skip" \
  "Skipping recently-active aged archive" "$G5E_OUT_CONTENT"
assert_exists "GREEN 5e: recently-active archived payload is preserved" "$G5E_ENTRY/payload.bin"

echo "GREEN 5f: activity beginning during archive sizing is preserved"
G5F_PRIVATE_TMP="$TMP_ROOT/g5f-private-tmp"
G5F_TMP="$TMP_ROOT/g5f-tmp"
G5F_ARCHIVE="$TMP_ROOT/g5f-archive"
G5F_BIN="$TMP_ROOT/g5f-bin"
G5F_STAMP="$G5F_ARCHIVE/20200101T000000Z"
G5F_PAYLOAD="$G5F_STAMP/already_archived_dir/payload.bin"
G5F_PID_FILE="$TMP_ROOT/g5f-holder.pid"
mkdir -p "$G5F_PRIVATE_TMP" "$G5F_TMP" "$(dirname "$G5F_PAYLOAD")"
touch "$G5F_PAYLOAD"
set_old_mtime "$G5F_STAMP"
make_find_shim "$G5F_BIN" "$G5F_PRIVATE_TMP" "$G5F_TMP"
make_du_probe "$G5F_BIN"

G5F_OUT="$TMP_ROOT/g5f.out"
if run_capture "$G5F_OUT" env -i HOME="$TMP_ROOT/g5f-home" \
  PATH="$G5F_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DU_OPEN_ON_PATH="$G5F_STAMP/already_archived_dir" DU_OPEN_PATH="$G5F_PAYLOAD" \
  DU_HOLDER_PID_FILE="$G5F_PID_FILE" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5F_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G5F_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G5F_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5F_RC=0
else
  G5F_RC=$?
fi
G5F_OUT_CONTENT=$(cat "$G5F_OUT")
if [[ -s "$G5F_PID_FILE" ]]; then
  kill "$(cat "$G5F_PID_FILE")" 2>/dev/null || true
  wait "$(cat "$G5F_PID_FILE")" 2>/dev/null || true
fi
assert_rc "GREEN 5f: exits 0" 0 "$G5F_RC"
assert_contains "GREEN 5f: logs in-use archive skip after sizing" \
  "Skipping in-use aged archive" "$G5F_OUT_CONTENT"
assert_exists "GREEN 5f: payload opened during sizing is preserved" "$G5F_PAYLOAD"

echo "GREEN 6: lsof traversal failures fail closed for archive and purge"
G6_PRIVATE_TMP="$TMP_ROOT/g6-private-tmp"
G6_TMP="$TMP_ROOT/g6-tmp"
G6_ARCHIVE="$TMP_ROOT/g6-archive"
G6_BIN="$TMP_ROOT/g6-bin"
G6_CANDIDATE="$G6_PRIVATE_TMP/stale_candidate"
G6_AGED="$G6_ARCHIVE/20200101T000000Z/already_archived_dir"
mkdir -p "$G6_PRIVATE_TMP" "$G6_TMP" "$G6_AGED"
make_large_dir "$G6_CANDIDATE"
touch "$G6_AGED/payload.bin"
set_old_mtime "$G6_CANDIDATE"
set_old_mtime "$G6_ARCHIVE/20200101T000000Z"
make_find_shim "$G6_BIN" "$G6_PRIVATE_TMP" "$G6_TMP"
make_lsof_failure_shim "$G6_BIN/lsof-fail"

G6_OUT="$TMP_ROOT/g6.out"
if run_capture "$G6_OUT" env -i HOME="$TMP_ROOT/g6-home" \
  PATH="$G6_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_LSOF_BIN="$G6_BIN/lsof-fail" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G6_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G6_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G6_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G6_RC=0
else
  G6_RC=$?
fi
G6_OUT_CONTENT=$(cat "$G6_OUT")
assert_rc "GREEN 6: exits 0" 0 "$G6_RC"
assert_contains "GREEN 6: logs fail-closed lsof diagnostic" \
  "Open-file check failed" "$G6_OUT_CONTENT"
assert_exists "GREEN 6: initial archive candidate survives lsof failure" \
  "$G6_CANDIDATE/payload.bin"
assert_exists "GREEN 6: aged archive survives lsof failure" \
  "$G6_AGED/payload.bin"

echo "GREEN 7: over-cap archive entry with an active marker is KEPT (approved contract: no guard bypass)"
G7_PRIVATE_TMP="$TMP_ROOT/g7-private-tmp"
G7_TMP="$TMP_ROOT/g7-tmp"
G7_ARCHIVE="$TMP_ROOT/g7-archive"
G7_BIN="$TMP_ROOT/g7-bin"
G7_ENTRY="$G7_ARCHIVE/20200101T000000Z/already_archived_dir"
mkdir -p "$G7_PRIVATE_TMP" "$G7_TMP" "$G7_ENTRY"
touch "$G7_ENTRY/payload.bin" "$G7_ENTRY/.in-use"
set_old_mtime "$G7_ARCHIVE/20200101T000000Z"
make_find_shim "$G7_BIN" "$G7_PRIVATE_TMP" "$G7_TMP"

G7_OUT="$TMP_ROOT/g7.out"
if run_capture "$G7_OUT" env -i HOME="$TMP_ROOT/g7-home" \
  PATH="$G7_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=48 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G7_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G7_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G7_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G7_RC=0
else
  G7_RC=$?
fi
G7_OUT_CONTENT=$(cat "$G7_OUT")
assert_rc "GREEN 7: exits 0" 0 "$G7_RC"
assert_contains "GREEN 7: logs the marked-active skip" \
  "Skipping marked-active aged archive" "$G7_OUT_CONTENT"
assert_contains "GREEN 7: over-cap keep is surfaced with a reason" \
  "archive_overcap_kept" "$G7_OUT_CONTENT"
assert_exists "GREEN 7: over-cap marked entry is preserved" "$G7_ENTRY/payload.bin"

echo "GREEN 7b: under-cap long-lived skipped entry logs a loud warning"
G7B_PRIVATE_TMP="$TMP_ROOT/g7b-private-tmp"
G7B_TMP="$TMP_ROOT/g7b-tmp"
G7B_ARCHIVE="$TMP_ROOT/g7b-archive"
G7B_BIN="$TMP_ROOT/g7b-bin"
G7B_ENTRY="$G7B_ARCHIVE/20260101T000000Z/already_archived_dir"
mkdir -p "$G7B_PRIVATE_TMP" "$G7B_TMP" "$G7B_ENTRY"
touch "$G7B_ENTRY/payload.bin" "$G7B_ENTRY/.in-use"
# Age the entry ~4h: older than 2x the 1h retention (warning threshold) but
# far under the pinned hard cap.
G7B_STAMP="$(date -v-4H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')"
/usr/bin/find "$G7B_ARCHIVE/20260101T000000Z" -exec touch -t "$G7B_STAMP" {} +
make_find_shim "$G7B_BIN" "$G7B_PRIVATE_TMP" "$G7B_TMP"

G7B_OUT="$TMP_ROOT/g7b.out"
if run_capture "$G7B_OUT" env -i HOME="$TMP_ROOT/g7b-home" \
  PATH="$G7B_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G7B_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G7B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G7B_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G7B_RC=0
else
  G7B_RC=$?
fi
G7B_OUT_CONTENT=$(cat "$G7B_OUT")
assert_rc "GREEN 7b: exits 0" 0 "$G7B_RC"
assert_contains "GREEN 7b: logs marked-active skip" \
  "Skipping marked-active aged archive" "$G7B_OUT_CONTENT"
assert_contains "GREEN 7b: logs long-lived warning (>2x retention)" \
  "WARNING: archive entry still alive after" "$G7B_OUT_CONTENT"
assert_exists "GREEN 7b: under-cap entry preserved" "$G7B_ENTRY/payload.bin"

echo "GREEN 8a: worktree dir without TMP_WORKTREES_APPROVED logs Skipping and is untouched"
G8A_PRIVATE_TMP="$TMP_ROOT/g8a-private-tmp"
G8A_TMP="$TMP_ROOT/g8a-tmp"
G8A_ARCHIVE="$TMP_ROOT/g8a-archive"
G8A_BIN="$TMP_ROOT/g8a-bin"
mkdir -p "$G8A_PRIVATE_TMP" "$G8A_TMP"
make_find_shim "$G8A_BIN" "$G8A_PRIVATE_TMP" "$G8A_TMP"
make_large_dir "$G8A_PRIVATE_TMP/worktree_stale_dir"
set_old_mtime "$G8A_PRIVATE_TMP/worktree_stale_dir"

G8A_OUT="$TMP_ROOT/g8a.out"
if run_capture "$G8A_OUT" env -i HOME="$TMP_ROOT/g8a-home" \
  PATH="$G8A_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G8A_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G8A_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G8A_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G8A_RC=0
else
  G8A_RC=$?
fi
G8A_OUT_CONTENT=$(cat "$G8A_OUT")
assert_rc "GREEN 8a: exits 0" 0 "$G8A_RC"
assert_contains "GREEN 8a: logs Skipping (no TMP_WORKTREES_APPROVED)" \
  "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $G8A_PRIVATE_TMP/worktree_stale_dir" \
  "$G8A_OUT_CONTENT"
if [[ "$G8A_OUT_CONTENT" == *"Worktree dir approved"* ]]; then
  record_fail "GREEN 8a: does not log the approved fall-through line" "found 'Worktree dir approved' with no approval set"
else
  record_pass "GREEN 8a: does not log the approved fall-through line"
fi
assert_exists "GREEN 8a: dir untouched at original path" "$G8A_PRIVATE_TMP/worktree_stale_dir"

echo "GREEN 8b: worktree dir WITH TMP_WORKTREES_APPROVED logs the approved line, not Skipping, and reaches the archive gate"
G8B_PRIVATE_TMP="$TMP_ROOT/g8b-private-tmp"
G8B_TMP="$TMP_ROOT/g8b-tmp"
G8B_ARCHIVE="$TMP_ROOT/g8b-archive"
G8B_BIN="$TMP_ROOT/g8b-bin"
mkdir -p "$G8B_PRIVATE_TMP" "$G8B_TMP"
make_find_shim "$G8B_BIN" "$G8B_PRIVATE_TMP" "$G8B_TMP"
make_large_dir "$G8B_PRIVATE_TMP/worktree_stale_dir"
set_old_mtime "$G8B_PRIVATE_TMP/worktree_stale_dir"

G8B_OUT="$TMP_ROOT/g8b.out"
if run_capture "$G8B_OUT" env -i HOME="$TMP_ROOT/g8b-home" \
  PATH="$G8B_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 TMP_WORKTREES_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G8B_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G8B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G8B_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G8B_RC=0
else
  G8B_RC=$?
fi
G8B_OUT_CONTENT=$(cat "$G8B_OUT")
assert_rc "GREEN 8b: exits 0" 0 "$G8B_RC"
assert_contains "GREEN 8b: logs the distinct approved fall-through line" \
  "Worktree dir approved + clean, evaluating: $G8B_PRIVATE_TMP/worktree_stale_dir" \
  "$G8B_OUT_CONTENT"
if [[ "$G8B_OUT_CONTENT" == *"Skipping temp worktree dir"* ]]; then
  record_fail "GREEN 8b: does not log the misleading 'Skipping' line when approved" "found it anyway"
else
  record_pass "GREEN 8b: does not log the misleading 'Skipping' line when approved"
fi
assert_contains "GREEN 8b: approved dir reaches the archive gate (evaluation proceeded)" \
  "Skipping archive candidate (C14 kept:unproven-content): $G8B_PRIVATE_TMP/worktree_stale_dir" \
  "$G8B_OUT_CONTENT"
# A worktree_*-named candidate cannot carry a declared-ephemeral E2 row (the
# E2 `pr_`/`claude-` rows and the .git rules do not cover this name), so the
# archive gate keeps it in place instead of quarantining it with an
# unpurgeable retention-0 receipt (bead disk_magician-archive-same-volume-regrowth-03bn).
assert_exists "GREEN 8b: approved dir stays at its original path (no unpurgeable quarantine)" \
  "$G8B_PRIVATE_TMP/worktree_stale_dir/payload.bin"
assert_contains "GREEN 8b: approved but unproven dir is not counted as archived" \
  "Dirs archived: 0" "$G8B_OUT_CONTENT"

echo "GREEN 9a: an aged E2 archive entry with a matching receipt is purged without --large"
G9A_PRIVATE_TMP="$TMP_ROOT/g9a-private-tmp"
G9A_TMP="$TMP_ROOT/g9a-tmp"
G9A_ARCHIVE="$TMP_ROOT/g9a-archive"
G9A_BIN="$TMP_ROOT/g9a-bin"
G9A_ENTRY="$G9A_ARCHIVE/20200101T000000Z/cli_validation_gemini_g9a"
mkdir -p "$G9A_PRIVATE_TMP" "$G9A_TMP"
make_find_shim "$G9A_BIN" "$G9A_PRIVATE_TMP" "$G9A_TMP"
make_c14_archive_entry "$G9A_TMP/cli_validation_gemini_g9a" "$G9A_ENTRY" 60 "$G9A_PRIVATE_TMP" "$G9A_TMP"

G9A_OUT="$TMP_ROOT/g9a.out"
if run_capture "$G9A_OUT" env -i HOME="$TMP_ROOT/g9a-home" \
  PATH="$G9A_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G9A_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G9A_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G9A_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  G9A_RC=0
else
  G9A_RC=$?
fi
G9A_OUT_CONTENT=$(cat "$G9A_OUT")
assert_rc "GREEN 9a: exits 0" 0 "$G9A_RC"
assert_contains "GREEN 9a: logs the C14-approved aged archive purge without --large" \
  "Purged aged archive after C14 approval" "$G9A_OUT_CONTENT"
assert_missing "GREEN 9a: aged archive entry actually reclaimed without --large" "$G9A_ENTRY"
assert_contains "GREEN 9a: actual purge is counted as a removed dir without --large" \
  "Dirs removed: 1" "$G9A_OUT_CONTENT"

echo "GREEN 9b: over-cap archive entry with an active marker is KEPT without --large (approved contract)"
G9B_PRIVATE_TMP="$TMP_ROOT/g9b-private-tmp"
G9B_TMP="$TMP_ROOT/g9b-tmp"
G9B_ARCHIVE="$TMP_ROOT/g9b-archive"
G9B_BIN="$TMP_ROOT/g9b-bin"
G9B_ENTRY="$G9B_ARCHIVE/20200101T000000Z/already_archived_dir"
mkdir -p "$G9B_PRIVATE_TMP" "$G9B_TMP" "$G9B_ENTRY"
touch "$G9B_ENTRY/payload.bin" "$G9B_ENTRY/.in-use"
set_old_mtime "$G9B_ARCHIVE/20200101T000000Z"
make_find_shim "$G9B_BIN" "$G9B_PRIVATE_TMP" "$G9B_TMP"

G9B_OUT="$TMP_ROOT/g9b.out"
if run_capture "$G9B_OUT" env -i HOME="$TMP_ROOT/g9b-home" \
  PATH="$G9B_BIN:/usr/sbin:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_RETENTION_HOURS=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=48 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G9B_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G9B_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G9B_TMP" \
  bash "$SOURCE_SCRIPT" --clean; then
  G9B_RC=0
else
  G9B_RC=$?
fi
G9B_OUT_CONTENT=$(cat "$G9B_OUT")
assert_rc "GREEN 9b: exits 0" 0 "$G9B_RC"
assert_contains "GREEN 9b: logs the marked-active skip without --large" \
  "Skipping marked-active aged archive" "$G9B_OUT_CONTENT"
assert_contains "GREEN 9b: over-cap keep is surfaced without --large" \
  "archive_overcap_kept" "$G9B_OUT_CONTENT"
assert_exists "GREEN 9b: over-cap marked entry is preserved without --large" "$G9B_ENTRY/payload.bin"

echo "GREEN 9c: standard dry-run reports aged archive without deleting (bead disk_magician-f0f)"
G9C_PRIVATE_TMP="$TMP_ROOT/g9c-private-tmp"
G9C_TMP="$TMP_ROOT/g9c-tmp"
G9C_ARCHIVE="$TMP_ROOT/g9c-archive"
G9C_BIN="$TMP_ROOT/g9c-bin"
mkdir -p "$G9C_PRIVATE_TMP" "$G9C_TMP" "$G9C_ARCHIVE/20200101T000000Z/already_archived_dir"
touch "$G9C_ARCHIVE/20200101T000000Z/already_archived_dir/payload.bin"
set_old_mtime "$G9C_ARCHIVE/20200101T000000Z"
make_find_shim "$G9C_BIN" "$G9C_PRIVATE_TMP" "$G9C_TMP"

G9C_OUT="$TMP_ROOT/g9c.out"
if run_capture "$G9C_OUT" env -i HOME="$TMP_ROOT/g9c-home" \
  PATH="$G9C_BIN:/usr/bin:/bin" \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G9C_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G9C_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G9C_TMP" \
  bash "$SOURCE_SCRIPT" --dry-run; then
  G9C_RC=0
else
  G9C_RC=$?
fi
G9C_OUT_CONTENT=$(cat "$G9C_OUT")
assert_rc "GREEN 9c: exits 0" 0 "$G9C_RC"
assert_contains "GREEN 9c: logs DRY RUN preview of aged archive purge" \
  "DRY RUN: would purge aged archive" "$G9C_OUT_CONTENT"
assert_exists "GREEN 9c: entry is preserved during dry run" "$G9C_ARCHIVE/20200101T000000Z"

echo
G10_PRIVATE_TMP="$TMP_ROOT/g10-private-tmp"
G10_TMP="$TMP_ROOT/g10-tmp"
G10_ARCHIVE="$TMP_ROOT/g10-archive"
G10_BIN="$TMP_ROOT/g10-bin"
mkdir -p "$G10_PRIVATE_TMP" "$G10_TMP"
make_find_shim "$G10_BIN" "$G10_PRIVATE_TMP" "$G10_TMP"
make_large_dir "$G10_PRIVATE_TMP/worldarchitect.ai/evidence"
make_large_dir "$G10_PRIVATE_TMP/worldarchitect.ai/stale_child"
set_old_mtime "$G10_PRIVATE_TMP/worldarchitect.ai"
G10_OUT="$TMP_ROOT/g10.out"
if run_capture "$G10_OUT" env -i HOME="$TMP_ROOT/g10-home" \
  PATH="$G10_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G10_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G10_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G10_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G10_RC=0
else
  G10_RC=$?
fi
G10_OUT_CONTENT=$(cat "$G10_OUT")
assert_rc "GREEN 10: exits 0" 0 "$G10_RC"
assert_exists "GREEN 10: protected root itself preserved" "$G10_PRIVATE_TMP/worldarchitect.ai"
assert_exists "GREEN 10: canonical evidence child preserved" "$G10_PRIVATE_TMP/worldarchitect.ai/evidence"
assert_exists "GREEN 10: stale non-evidence child stays at its original path" "$G10_PRIVATE_TMP/worldarchitect.ai/stale_child"
assert_contains "GREEN 10: logs the protected-child skip" \
  "Skipping protected child of a protected root: $G10_PRIVATE_TMP/worldarchitect.ai/evidence" "$G10_OUT_CONTENT"
# A child of a protected root is nested one level below a scratch root, so no
# E2/E3 declared-ephemeral row can match it: the archive gate keeps it in place
# rather than quarantining it with an unpurgeable retention-0 receipt (bead
# disk_magician-archive-same-volume-regrowth-03bn). Nothing is deleted and
# nothing is hidden.
assert_exists "GREEN 10: stale non-evidence child stays visible inside the protected root" \
  "$G10_PRIVATE_TMP/worldarchitect.ai/stale_child/payload.bin"
assert_contains "GREEN 10: nested child is rejected as unproven content before the move" \
  "Skipping archive candidate (C14 kept:unproven-content): $G10_PRIVATE_TMP/worldarchitect.ai/stale_child" \
  "$G10_OUT_CONTENT"
assert_contains "GREEN 10: nested unproven child is not counted as archived" \
  "Dirs archived: 0" "$G10_OUT_CONTENT"

echo "GREEN 11: dir-mtime-only touch is STALE, not active (bead disk_magician-7871)"
# The recency probe used to be satisfied by the directory's OWN mtime, so any
# touch (child create/delete/rename) kept a stale multi-GB tree protected
# forever: /private/tmp/worldai_frontend sat at 20+ GiB with 8.7h-old content
# and a fresh dir mtime and was skipped every pass. The probe must measure
# entry mtimes UNDER the dir (-mindepth 1).
G11_PRIVATE_TMP="$TMP_ROOT/g11-private-tmp"
G11_TMP="$TMP_ROOT/g11-tmp"
G11_ARCHIVE="$TMP_ROOT/g11-archive"
G11_BIN="$TMP_ROOT/g11-bin"
mkdir -p "$G11_PRIVATE_TMP" "$G11_TMP"
# Canonicalize so the pr_ candidate has a declared-ephemeral E2 row (archivable).
G11_PRIVATE_TMP="$(cd "$G11_PRIVATE_TMP" && pwd -P)"
G11_TMP="$(cd "$G11_TMP" && pwd -P)"
make_find_shim "$G11_BIN" "$G11_PRIVATE_TMP" "$G11_TMP"
make_large_dir "$G11_PRIVATE_TMP/pr_dir_mtime_only"
set_old_mtime "$G11_PRIVATE_TMP/pr_dir_mtime_only"
# Re-touch ONLY the directory entry itself (2h ago, past the root grace): content
# stays old, dir mtime is newer than the content but outside the short grace.
touch -t "$(ago_stamp 120)" "$G11_PRIVATE_TMP/pr_dir_mtime_only"

G11_OUT="$TMP_ROOT/g11.out"
if run_capture "$G11_OUT" env -i HOME="$TMP_ROOT/g11-home" \
  PATH="$G11_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G11_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G11_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G11_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G11_RC=0
else
  G11_RC=$?
fi
G11_OUT_CONTENT=$(cat "$G11_OUT")
assert_rc "GREEN 11: exits 0" 0 "$G11_RC"
assert_not_contains "GREEN 11: dir-mtime-only tree is NOT reported active" \
  "Skipping recently active dir (mtime/ctime within 24h): $G11_PRIVATE_TMP/pr_dir_mtime_only" "$G11_OUT_CONTENT"

assert_contains "GREEN 11: dir-mtime-only tree is actually archived" \
  "Archiving: $G11_PRIVATE_TMP/pr_dir_mtime_only ->" "$G11_OUT_CONTENT"
assert_missing "GREEN 11: dir-mtime-only original path is gone (moved)" "$G11_PRIVATE_TMP/pr_dir_mtime_only"
G11_ARCHIVED_COUNT=$(/usr/bin/find "$G11_ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr_dir_mtime_only 2>/dev/null | wc -l | tr -d ' ')
if [[ "$G11_ARCHIVED_COUNT" -eq 1 ]]; then
  record_pass "GREEN 11: exactly one archived copy exists"
else
  record_fail "GREEN 11: exactly one archived copy exists" "found $G11_ARCHIVED_COUNT under $G11_ARCHIVE"
fi

echo "GREEN 12: genuinely recent CONTENT still protects the tree (other side of 7871)"
G12_PRIVATE_TMP="$TMP_ROOT/g12-private-tmp"
G12_TMP="$TMP_ROOT/g12-tmp"
G12_ARCHIVE="$TMP_ROOT/g12-archive"
G12_BIN="$TMP_ROOT/g12-bin"
mkdir -p "$G12_PRIVATE_TMP" "$G12_TMP"
make_find_shim "$G12_BIN" "$G12_PRIVATE_TMP" "$G12_TMP"
make_large_dir "$G12_PRIVATE_TMP/recent_content"
set_old_mtime "$G12_PRIVATE_TMP/recent_content"
# A real write inside the tree: this is genuine activity and must still skip.
printf 'fresh\n' > "$G12_PRIVATE_TMP/recent_content/written_now.txt"

G12_OUT="$TMP_ROOT/g12.out"
if run_capture "$G12_OUT" env -i HOME="$TMP_ROOT/g12-home" \
  PATH="$G12_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G12_ARCHIVE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$G12_PRIVATE_TMP" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$G12_TMP" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G12_RC=0
else
  G12_RC=$?
fi
G12_OUT_CONTENT=$(cat "$G12_OUT")
assert_rc "GREEN 12: exits 0" 0 "$G12_RC"
assert_contains "GREEN 12: recent content still logs the active skip" \
  "Skipping recently active dir (mtime/ctime within 24h): $G12_PRIVATE_TMP/recent_content" "$G12_OUT_CONTENT"
assert_exists "GREEN 12: recent-content tree untouched" "$G12_PRIVATE_TMP/recent_content/payload.bin"

# Structural activity leaves OLD mtimes but a FRESH ctime on the moved file:
# mv / cp -p / tar -x / rsync -a of old content into a stale dir. Fixtures
# cannot backdate ctime, so these opt in to the real ctime signal
# (DISK_MAGICIAN_TEST_CTIME_SIGNAL=1) and use a freshly moved/copied file.
run_ctime_case() {
  # run_ctime_case <id> <how: mv|cp-p>
  local id="$1" how="$2" pt tm ar bin out rc content
  pt="$TMP_ROOT/$id-private-tmp"; tm="$TMP_ROOT/$id-tmp"; ar="$TMP_ROOT/$id-archive"; bin="$TMP_ROOT/$id-bin"
  mkdir -p "$pt" "$tm"
  pt="$(cd "$pt" && pwd -P)"; tm="$(cd "$tm" && pwd -P)"
  make_find_shim "$bin" "$pt" "$tm"
  make_large_dir "$pt/pr_moved_in"
  set_old_mtime "$pt/pr_moved_in"
  # An old-mtime file created elsewhere, then structurally moved in AFTER the
  # tree was backdated: mtime stays old (mv/cp -p preserve it), ctime is fresh.
  mkdir -p "$TMP_ROOT/$id-src"
  printf 'old content\n' > "$TMP_ROOT/$id-src/moved.txt"
  touch -t 202001010000 "$TMP_ROOT/$id-src/moved.txt"
  if [[ "$how" == mv ]]; then
    mv "$TMP_ROOT/$id-src/moved.txt" "$pt/pr_moved_in/moved.txt"
  else
    cp -p "$TMP_ROOT/$id-src/moved.txt" "$pt/pr_moved_in/moved.txt"
  fi
  # The dir's own mtime is fresh from the insert; backdate it (keeps the tree
  # looking stale by mtime everywhere, including the top-level entry).
  touch -t 202001010000 "$pt/pr_moved_in"
  out="$TMP_ROOT/$id.out"
  if run_capture "$out" env -i HOME="$TMP_ROOT/$id-home" \
    PATH="$bin:/usr/bin:/bin" \
    LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
    DISK_MAGICIAN_TEST_CTIME_SIGNAL=1 \
    DISK_MAGICIAN_ARCHIVE_ROOT="$ar" \
    DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$pt" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tm" \
    bash "$SOURCE_SCRIPT" --clean --large; then rc=0; else rc=$?; fi
  content=$(cat "$out")
  assert_rc "$id: exits 0" 0 "$rc"
  assert_contains "$id: old-mtime file ($how) into stale dir reads ACTIVE via ctime" \
    "Skipping recently active dir (mtime/ctime within 24h): $pt/pr_moved_in" "$content"
  assert_exists "$id: moved-in tree untouched" "$pt/pr_moved_in/moved.txt"
}

echo "GREEN 13: mv of old-mtime content into a stale dir is ACTIVE (ctime signal)"
run_ctime_case "g13" mv
echo "GREEN 14: cp -p of old-mtime content into a stale dir is ACTIVE (ctime signal)"
run_ctime_case "g14" cp-p

# Root grace: the candidate ROOT's own mtime counts only within a short window
# (default 30m), so a just-deleted/renamed child protects the tree but a quiet
# dir mtime does not (bead 7871). Content is always old here.
run_root_grace_case() {
  # run_root_grace_case <id> <root_minutes_ago> <active|archived>
  local id="$1" ago="$2" expect="$3" pt tm ar bin out rc content
  pt="$TMP_ROOT/$id-private-tmp"; tm="$TMP_ROOT/$id-tmp"; ar="$TMP_ROOT/$id-archive"; bin="$TMP_ROOT/$id-bin"
  mkdir -p "$pt" "$tm"
  pt="$(cd "$pt" && pwd -P)"; tm="$(cd "$tm" && pwd -P)"
  make_find_shim "$bin" "$pt" "$tm"
  make_large_dir "$pt/pr_root_grace"
  set_old_mtime "$pt/pr_root_grace"
  touch -t "$(ago_stamp "$ago")" "$pt/pr_root_grace"
  out="$TMP_ROOT/$id.out"
  if run_capture "$out" env -i HOME="$TMP_ROOT/$id-home" \
    PATH="$bin:/usr/bin:/bin" \
    LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
    DISK_MAGICIAN_ARCHIVE_ROOT="$ar" \
    DISK_MAGICIAN_TEST_CONTEXT=1 \
    DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$pt" \
    DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tm" \
    bash "$SOURCE_SCRIPT" --clean --large; then rc=0; else rc=$?; fi
  content=$(cat "$out")
  assert_rc "$id: exits 0" 0 "$rc"
  if [[ "$expect" == active ]]; then
    assert_contains "$id: root mtime ${ago}m old with stale content is ACTIVE" \
      "Skipping recently active dir (mtime/ctime within 24h): $pt/pr_root_grace" "$content"
    assert_exists "$id: tree untouched" "$pt/pr_root_grace/payload.bin"
  else
    assert_not_contains "$id: root mtime ${ago}m old is NOT active" \
      "Skipping recently active dir (mtime/ctime within 24h): $pt/pr_root_grace" "$content"
    assert_contains "$id: archived" "Archiving: $pt/pr_root_grace ->" "$content"
    assert_missing "$id: original path gone" "$pt/pr_root_grace"
  fi
}

echo "GREEN 15: root mtime 10m old, stale content -> ACTIVE (just-deleted child grace)"
run_root_grace_case "g15" 10 active
echo "GREEN 16: root mtime 2h old, stale content -> archivable"
run_root_grace_case "g16" 120 archived

# Clamp table for DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES (production helper,
# extracted from the script, no test seam). Leading-zero values must be read as
# decimal (08/09 are invalid octal), junk falls back to 30, floor 5, ceiling =
# the normal window, and over-long digit strings use the window.
GRACE_FN_FILE="$TMP_ROOT/grace_fn.sh"
/usr/bin/awk '/^tmp_root_grace_minutes\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SOURCE_SCRIPT" > "$GRACE_FN_FILE"
echo "GREEN 17: DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES clamp table"
if [[ ! -s "$GRACE_FN_FILE" ]]; then
  record_fail "GREEN 17: tmp_root_grace_minutes helper exists" "not found in $SOURCE_SCRIPT"
else
  check_grace() {
    # check_grace <label> <expected> <window_mins> [env-assign-or-UNSET]
    local label="$1" want="$2" win="$3" val="${4-__UNSET__}" got
    if [[ "$val" == __UNSET__ ]]; then
      got=$(env -u DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES bash -c 'set -eu; source "$1"; tmp_root_grace_minutes "$2"' _ "$GRACE_FN_FILE" "$win" 2>&1)
    else
      got=$(DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES="$val" bash -c 'set -eu; source "$1"; tmp_root_grace_minutes "$2"' _ "$GRACE_FN_FILE" "$win" 2>&1)
    fi
    if [[ "$got" == "$want" ]]; then record_pass "GREEN 17: grace '$label' -> $want"; else record_fail "GREEN 17: grace '$label' -> $want" "got '$got'"; fi
  }
  check_grace unset 30 1440
  check_grace 30 30 1440 30
  check_grace 08 8 1440 08
  check_grace 09 9 1440 09
  check_grace 010 10 1440 010
  check_grace 0600 600 1440 0600
  check_grace 0 5 1440 0
  check_grace 03 5 1440 03
  check_grace 5 5 1440 5
  check_grace 4 5 1440 4
  check_grace 1440 1440 1440 1440
  check_grace 99999999999999999999 1440 1440 99999999999999999999
  check_grace abc 30 1440 abc
  check_grace empty 30 1440 ""
  check_grace -5 30 1440 -5
  check_grace ' 7 ' 30 1440 ' 7 '
  check_grace window-smaller-than-grace 20 20 30
fi

# Production path (NO test context): a root whose mtime is old but whose ctime
# is fresh (touch -t re-stamps ctime) and that has no entries under it can only
# be ACTIVE through the root -cmin clause. The same tree under the test seam is
# mtime-only, so it reads stale.
echo "GREEN 18: production-path root ctime clause marks a fresh-ctime root ACTIVE"
HRA_FN_FILE="$TMP_ROOT/hra_fn.sh"
/usr/bin/awk '/^tmp_root_grace_minutes\(\) \{/{f=1} f{print} f&&/^\}/{f=0} /^has_recent_activity\(\) \{/{g=1} g{print} g&&/^\}/{g=0}' "$SOURCE_SCRIPT" > "$HRA_FN_FILE"
G18_ROOT="$TMP_ROOT/g18-root"
mkdir -p "$G18_ROOT"
touch -t 202001010000 "$G18_ROOT"
g18_probe() {
  # g18_probe <env-assign...>: prints active|stale
  env -i PATH=/usr/bin:/bin "$@" bash -c '
    set -u
    log() { :; }; resolve_timeout_bin() { echo ""; }; warn_unbounded_probes_once() { :; }
    PROBE_TIMEOUT_SEC=10
    source "$1"
    if has_recent_activity "$2" 24; then echo active; else echo stale; fi' _ "$HRA_FN_FILE" "$G18_ROOT"
}
G18_PROD=$(g18_probe X=1)
G18_SEAM=$(g18_probe DISK_MAGICIAN_TEST_CONTEXT=1)
if [[ "$G18_PROD" == active ]]; then record_pass "GREEN 18: production probe: old-mtime/fresh-ctime root is ACTIVE"; else record_fail "GREEN 18: production probe: old-mtime/fresh-ctime root is ACTIVE" "got '$G18_PROD'"; fi
if [[ "$G18_SEAM" == stale ]]; then record_pass "GREEN 18: test-seam control is mtime-only (stale)"; else record_fail "GREEN 18: test-seam control is mtime-only (stale)" "got '$G18_SEAM'"; fi

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

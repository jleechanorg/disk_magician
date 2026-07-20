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

TMP_ROOT=$(mktemp -d -t cleanup_tmp_large_protections.XXXXXX)
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

set_old_mtime() {
  # Backdate every entry under $1 (and $1 itself) well outside the default
  # 24h active-use window.
  local dir="$1"
  /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
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
  bash "$SOURCE_SCRIPT" --clean --large; then
  G1_RC=0
else
  G1_RC=$?
fi
G1_OUT_CONTENT=$(cat "$G1_OUT")
assert_rc "GREEN 1: exits 0" 0 "$G1_RC"
assert_contains "GREEN 1: logs recently-active skip" \
  "Skipping recently active dir (mtime within 24h): $G1_PRIVATE_TMP/fresh_scratch_dir" "$G1_OUT_CONTENT"
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
  bash "$SOURCE_SCRIPT" --clean --large; then
  G3D_RC=0
else
  G3D_RC=$?
fi
G3D_OUT_CONTENT=$(cat "$G3D_OUT")
assert_rc "GREEN 3d: exits 0" 0 "$G3D_RC"
assert_contains "GREEN 3d: logs env-selected active window" \
  "mtime within 876000h" "$G3D_OUT_CONTENT"
assert_exists "GREEN 3d: env-selected active window preserves candidate" \
  "$G3D_PRIVATE_TMP/env_active_window"

echo "GREEN 4: old + unmarked large dir is archived (moved, not rm -rf'd)"
G4_PRIVATE_TMP="$TMP_ROOT/g4-private-tmp"
G4_TMP="$TMP_ROOT/g4-tmp"
G4_ARCHIVE="$TMP_ROOT/g4-archive"
G4_BIN="$TMP_ROOT/g4-bin"
mkdir -p "$G4_PRIVATE_TMP" "$G4_TMP"
make_find_shim "$G4_BIN" "$G4_PRIVATE_TMP" "$G4_TMP"
make_du_probe "$G4_BIN"
make_large_dir "$G4_PRIVATE_TMP/stale_scratch_dir"
set_old_mtime "$G4_PRIVATE_TMP/stale_scratch_dir"
G4_DU_LOG="$TMP_ROOT/g4-du.log"
: > "$G4_DU_LOG"

G4_OUT="$TMP_ROOT/g4.out"
if run_capture "$G4_OUT" env -i HOME="$TMP_ROOT/g4-home" \
  PATH="$G4_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DU_LOG="$G4_DU_LOG" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G4_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G4_RC=0
else
  G4_RC=$?
fi
G4_OUT_CONTENT=$(cat "$G4_OUT")
assert_rc "GREEN 4: exits 0" 0 "$G4_RC"
assert_contains "GREEN 4: logs archiving (not 'Removing:')" \
  "Archiving: $G4_PRIVATE_TMP/stale_scratch_dir ->" "$G4_OUT_CONTENT"
assert_missing "GREEN 4: original path is gone (moved)" "$G4_PRIVATE_TMP/stale_scratch_dir"
G4_ARCHIVED_COUNT=$(/usr/bin/find "$G4_ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name stale_scratch_dir 2>/dev/null | wc -l | tr -d ' ')
if [[ "$G4_ARCHIVED_COUNT" -eq 1 ]]; then
  record_pass "GREEN 4: exactly one archived copy exists under DISK_MAGICIAN_ARCHIVE_ROOT"
else
  record_fail "GREEN 4: exactly one archived copy exists under DISK_MAGICIAN_ARCHIVE_ROOT" \
    "found $G4_ARCHIVED_COUNT under $G4_ARCHIVE"
fi
assert_exists "GREEN 4: archived payload is still readable (data preserved, not lost)" \
  "$G4_ARCHIVE"/*/stale_scratch_dir/payload.bin
G4_TARGET_DU_COUNT=$(grep -cFx "$G4_PRIVATE_TMP/stale_scratch_dir" "$G4_DU_LOG" || true)
assert_rc "GREEN 4: candidate size is measured once" 1 "$G4_TARGET_DU_COUNT"
assert_contains "GREEN 4: archive move is not counted as a removed dir" \
  "Dirs removed: 0" "$G4_OUT_CONTENT"
assert_contains "GREEN 4: same-filesystem archive move reports zero reclaimed bytes" \
  "Total freed: 0 KB" "$G4_OUT_CONTENT"
assert_contains "GREEN 4: quarantine accounting is reported separately" \
  "Dirs archived: 1" "$G4_OUT_CONTENT"

echo "GREEN 5: an aged archive entry is purged (space actually reclaimed on a later run)"
G5_PRIVATE_TMP="$TMP_ROOT/g5-private-tmp"
G5_TMP="$TMP_ROOT/g5-tmp"
G5_ARCHIVE="$TMP_ROOT/g5-archive"
G5_BIN="$TMP_ROOT/g5-bin"
mkdir -p "$G5_PRIVATE_TMP" "$G5_TMP" "$G5_ARCHIVE/20200101T000000Z/already_archived_dir"
touch "$G5_ARCHIVE/20200101T000000Z/already_archived_dir/payload.bin"
set_old_mtime "$G5_ARCHIVE/20200101T000000Z"
make_find_shim "$G5_BIN" "$G5_PRIVATE_TMP" "$G5_TMP"

G5_OUT="$TMP_ROOT/g5.out"
if run_capture "$G5_OUT" env -i HOME="$TMP_ROOT/g5-home" \
  PATH="$G5_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  LARGE_TMP_ARCHIVE_MAX_HOURS=876000 \
  FAIL_FIND_ROOT="$G5_ARCHIVE" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5_ARCHIVE" \
  bash "$SOURCE_SCRIPT" --clean --large; then
  G5_RC=0
else
  G5_RC=$?
fi
G5_OUT_CONTENT=$(cat "$G5_OUT")
assert_rc "GREEN 5: exits 0" 0 "$G5_RC"
assert_contains "GREEN 5: logs purging the aged archive entry" \
  "Purging aged archive" "$G5_OUT_CONTENT"
assert_missing "GREEN 5: aged archive entry actually reclaimed" "$G5_ARCHIVE/20200101T000000Z"
assert_contains "GREEN 5: actual purge is counted as a removed dir" \
  "Dirs removed: 1" "$G5_OUT_CONTENT"

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
  DU_OPEN_ON_PATH="$G5F_STAMP" DU_OPEN_PATH="$G5F_PAYLOAD" \
  DU_HOLDER_PID_FILE="$G5F_PID_FILE" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$G5F_ARCHIVE" \
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

echo "GREEN 7: over-cap archive entry is purged despite an active marker (hard cap, bead jleechan-mtow)"
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
  bash "$SOURCE_SCRIPT" --clean --large; then
  G7_RC=0
else
  G7_RC=$?
fi
G7_OUT_CONTENT=$(cat "$G7_OUT")
assert_rc "GREEN 7: exits 0" 0 "$G7_RC"
assert_contains "GREEN 7: logs over-cap purge with guards bypassed" \
  "Purging over-cap archive" "$G7_OUT_CONTENT"
assert_missing "GREEN 7: over-cap marked entry actually reclaimed" \
  "$G7_ARCHIVE/20200101T000000Z"

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

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

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
# RED section runs the pre-fix script content (git show HEAD, before this
# PR's changes) against a fixture and proves it deletes the protected dir.
# GREEN section runs the current script and proves it does not.
#
# Run: bash tests/test_cleanup_tmp_large_protections.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/cleanup_tmp.sh"

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

# ─────────────────────── RED: prove the pre-fix bug ───────────────────────
echo "RED: pre-fix cleanup_tmp.sh deletes a protected-root-shaped large tmp dir"
RED_SCRIPT="$TMP_ROOT/red-cleanup_tmp.sh"
if git -C "$REPO_ROOT" show HEAD:scripts/cleanup_tmp.sh > "$RED_SCRIPT" 2>/dev/null; then
  chmod +x "$RED_SCRIPT"
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
else
  record_fail "RED: could not load HEAD:scripts/cleanup_tmp.sh" "git show failed — skipped RED proof"
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

echo "GREEN 4: old + unmarked large dir is archived (moved, not rm -rf'd)"
G4_PRIVATE_TMP="$TMP_ROOT/g4-private-tmp"
G4_TMP="$TMP_ROOT/g4-tmp"
G4_ARCHIVE="$TMP_ROOT/g4-archive"
G4_BIN="$TMP_ROOT/g4-bin"
mkdir -p "$G4_PRIVATE_TMP" "$G4_TMP"
make_find_shim "$G4_BIN" "$G4_PRIVATE_TMP" "$G4_TMP"
make_large_dir "$G4_PRIVATE_TMP/stale_scratch_dir"
set_old_mtime "$G4_PRIVATE_TMP/stale_scratch_dir"

G4_OUT="$TMP_ROOT/g4.out"
if run_capture "$G4_OUT" env -i HOME="$TMP_ROOT/g4-home" \
  PATH="$G4_BIN:/usr/bin:/bin" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
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

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

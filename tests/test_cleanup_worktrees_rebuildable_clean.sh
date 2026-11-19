#!/usr/bin/env bash
# Regression coverage for rebuildable untracked entries (e.g. .husky/_/post-checkout)
# across cleanup_worktrees.sh (--dry-run and --clean final_status), C14
# (c14_repo_content_ok / artifact_removal_verdict), and WRH (wrh_removal_verdict).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_SCRIPT="$REPO_ROOT/scripts/cleanup_worktrees.sh"
IGNORED_LIB="$REPO_ROOT/scripts/lib/worktree_ignored.sh"
VERDICT_LIB="$REPO_ROOT/scripts/lib/artifact_verdict.sh"
WRH_SCRIPT="$REPO_ROOT/scripts/worktree_remove_hook.sh"

TMP_ROOT="$(cd "$(mktemp -d -t cleanup_wt_rebuildable_clean.XXXXXX)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1 ($2)"; FAIL=$((FAIL + 1)); }
assert_contains() {
  if grep -qF -- "$2" <<<"$3"; then pass "$1"
  else fail "$1" "missing '$2'"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$3"; then fail "$1" "unexpected '$2'"
  else pass "$1"; fi
}

if ! OLD_TS=$(date -v-4d +%Y%m%d%H%M 2>/dev/null); then
  OLD_TS=$(date -d "4 days ago" +%Y%m%d%H%M)
fi

age_days_ago() {
  local wt="$1" gitdir
  /usr/bin/find "$wt" -name .git -prune -o -exec touch -h -t "$OLD_TS" {} +
  touch -h -t "$OLD_TS" "$wt/.git"
  gitdir="$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)"
  /usr/bin/find "$gitdir" -exec touch -t "$OLD_TS" {} +
}

echo "== 1. worktree_status_classify unit checks =="
mkdir -p "$TMP_ROOT/unit_wt"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$IGNORED_LIB"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "")" && rc=$? || rc=$?
[[ "$rc" -eq 0 && "$out" == clean ]] && pass "empty porcelain is clean" || fail "empty porcelain is clean" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "?? .husky/_/post-checkout")" && rc=$? || rc=$?
[[ "$rc" -eq 0 && "$out" == clean ]] && pass "untracked .husky/_/post-checkout is clean" || fail "untracked .husky/_/post-checkout is clean" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "?? .husky/_/")" && rc=$? || rc=$?
[[ "$rc" -eq 0 && "$out" == clean ]] && pass "untracked .husky/_/ dir is clean" || fail "untracked .husky/_/ dir is clean" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "?? node_modules/pkg/index.js")" && rc=$? || rc=$?
[[ "$rc" -eq 0 && "$out" == clean ]] && pass "untracked node_modules file is clean" || fail "untracked node_modules file is clean" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "?? notes.txt")" && rc=$? || rc=$?
[[ "$rc" -ne 0 && "$out" == untracked ]] && pass "untracked notes.txt rejected as untracked" || fail "untracked notes.txt rejected as untracked" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" '?? "weird dir/node_modules/x"')" && rc=$? || rc=$?
[[ "$rc" -ne 0 && "$out" == untracked ]] && pass "quoted porcelain path rejected" || fail "quoted porcelain path rejected" "rc=$rc out=$out"

out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "?? node_modules/pkg/.env")" && rc=$? || rc=$?
[[ "$rc" -ne 0 && "$out" == untracked ]] && pass "unignored secret inside rebuildable dir rejected" || fail "unignored secret inside rebuildable dir rejected" "rc=$rc out=$out"

mixed_status=$' M README.md\n?? .husky/_/post-checkout'
out="$(worktree_status_classify "$TMP_ROOT/unit_wt" "$mixed_status")" && rc=$? || rc=$?
[[ "$rc" -ne 0 && "$out" == dirty ]] && pass "tracked edit + rebuildable untracked stays dirty" || fail "tracked edit + rebuildable untracked stays dirty" "rc=$rc out=$out"

echo "== 2. setup git repo + merged worktrees =="
export HERMES_SKIP_EXAMPLE_COM_GUARD=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
REPO="$TMP_ROOT/repo"
WT="$REPO/.claude/worktrees"
mkdir -p "$WT" "$TMP_ROOT/home" "$TMP_ROOT/bin"

git init -q --bare -b main "$TMP_ROOT/origin.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "fixture@users.noreply.github.com"
git -C "$REPO" config user.name "Fixture User"
printf 'base\n' > "$REPO/README.md"
mkdir -p "$REPO/.husky"
printf '#!/bin/sh\n' > "$REPO/.husky/pre-commit"
git -C "$REPO" add README.md .husky/pre-commit
git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main

git -C "$REPO" checkout -q -b feature-merged main
printf 'merged change\n' >> "$REPO/README.md"
git -C "$REPO" commit -q -am merged
MERGED_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --ff-only feature-merged
git -C "$REPO" push -q origin main

add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$3"; }

# 1) Merged worktree with untracked .husky/_/post-checkout (must be deleted by --clean)
add_wt husky-clean "$WT/wt-husky" "$MERGED_SHA"
mkdir -p "$WT/wt-husky/.husky/_"
printf '#!/bin/sh\n' > "$WT/wt-husky/.husky/_/post-checkout"

# 2) Clean at start, then size probe adds rebuildable .husky/_/post-checkout (must be deleted by --clean)
add_wt husky-late "$WT/wt-husky-late" "$MERGED_SHA"

# 3) Clean at start, then size probe adds non-rebuildable notes.txt (must preserve as changed-after-size)
add_wt race-notes "$WT/wt-race-notes" "$MERGED_SHA"

# 4) Has .husky/_/post-checkout at start, then size probe edits tracked README.md (must preserve as changed-after-size)
add_wt race-tracked "$WT/wt-race-tracked" "$MERGED_SHA"
mkdir -p "$WT/wt-race-tracked/.husky/_"
printf '#!/bin/sh\n' > "$WT/wt-race-tracked/.husky/_/post-checkout"

# 5) Direct C14 / WRH probe fixtures (never touched by cleanup_worktrees)
add_wt direct-husky "$WT/wt-direct-husky" "$MERGED_SHA"
mkdir -p "$WT/wt-direct-husky/.husky/_"
printf '#!/bin/sh\n' > "$WT/wt-direct-husky/.husky/_/post-checkout"

add_wt direct-notes "$WT/wt-direct-notes" "$MERGED_SHA"
printf 'user notes\n' > "$WT/wt-direct-notes/notes.txt"

for n in husky husky-late race-notes race-tracked direct-husky direct-notes; do
  age_days_ago "$WT/wt-$n"
done

echo "== 3. C14 and WRH direct checks =="
cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
exit 1
SH
# Provide clean lsof/cwdscan stubs so live-cwd and open-file checks succeed deterministically.
cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "+D" ]; then exit 1; fi
done
echo "p1"
echo "n/"
SH
cat > "$TMP_ROOT/bin/cwdscan" <<'SH'
#!/bin/sh
printf '1\t0\t/\0'
SH
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/cwdscan" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"

v_c14_husky="$(env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash -c 'source "$1"; c14_repo_content_ok "$2"' _ "$VERDICT_LIB" "$WT/wt-direct-husky")"
[[ "$v_c14_husky" == ok ]] && pass "c14_repo_content_ok allows .husky/_/post-checkout" || fail "c14_repo_content_ok allows .husky/_/post-checkout" "got=$v_c14_husky"

v_c14_notes="$(env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash -c 'source "$1"; c14_repo_content_ok "$2" || true' _ "$VERDICT_LIB" "$WT/wt-direct-notes")"
[[ "$v_c14_notes" == kept:dirty ]] && pass "c14_repo_content_ok rejects notes.txt" || fail "c14_repo_content_ok rejects notes.txt" "got=$v_c14_notes"

v_wrh_husky="$(env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash -c 'source "$1"; wrh_removal_verdict "$2" hours:48 origin-or-merged-pr' _ "$WRH_SCRIPT" "$WT/wt-direct-husky")"
[[ "$v_wrh_husky" == remove ]] && pass "wrh_removal_verdict allows .husky/_/post-checkout" || fail "wrh_removal_verdict allows .husky/_/post-checkout" "got=$v_wrh_husky"

v_wrh_notes="$(env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash -c 'source "$1"; wrh_removal_verdict "$2" hours:48 origin-or-merged-pr' _ "$WRH_SCRIPT" "$WT/wt-direct-notes")"
[[ "$v_wrh_notes" == kept:dirty ]] && pass "wrh_removal_verdict rejects notes.txt" || fail "wrh_removal_verdict rejects notes.txt" "got=$v_wrh_notes"

# Remove direct fixtures so section 4 focuses cleanly on the cleanup_worktrees --clean targets.
git -C "$REPO" worktree remove --force "$WT/wt-direct-husky"
git -C "$REPO" worktree remove --force "$WT/wt-direct-notes"

echo "== 4. cleanup_worktrees.sh --clean end-to-end =="
REAL_DU="$(command -v du)"
cat > "$TMP_ROOT/bin/du" <<SH
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    */wt-husky-late)
      mkdir -p "\$arg/.husky/_"
      printf '#!/bin/sh\n' > "\$arg/.husky/_/post-checkout"
      touch -h -t "$OLD_TS" "\$arg/.husky" "\$arg/.husky/_" "\$arg/.husky/_/post-checkout"
      ;;
    */wt-race-notes)
      printf 'late user notes\n' > "\$arg/notes.txt"
      ;;
    */wt-race-tracked)
      printf 'late tracked edit\n' >> "\$arg/README.md"
      ;;
  esac
done
exec "$REAL_DU" "\$@"
SH
chmod +x "$TMP_ROOT/bin/du"

CLEAN_OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
  WORKTREE_APPROVED=1 WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash "$CLEANUP_SCRIPT" --clean --repos "$REPO" 2>&1)"

assert_contains "wt-husky deleted by --clean" "DELETE    $WT/wt-husky |" "$CLEAN_OUT"
assert_not_contains "wt-husky not preserved as changed-after-size" "wt-husky | changed-after-size" "$CLEAN_OUT"
[[ ! -e "$WT/wt-husky" ]] && pass "wt-husky removed from disk" || fail "wt-husky removed from disk" "still exists"

assert_contains "wt-husky-late deleted by --clean" "DELETE    $WT/wt-husky-late |" "$CLEAN_OUT"
[[ ! -e "$WT/wt-husky-late" ]] && pass "wt-husky-late removed from disk" || fail "wt-husky-late removed from disk" "still exists"

assert_contains "wt-race-notes preserved as changed-after-size" "wt-race-notes | changed-after-size" "$CLEAN_OUT"
[[ -f "$WT/wt-race-notes/notes.txt" ]] && pass "wt-race-notes/notes.txt remains on disk" || fail "wt-race-notes/notes.txt remains on disk" "missing"

assert_contains "wt-race-tracked preserved as changed-after-size" "wt-race-tracked | changed-after-size" "$CLEAN_OUT"
[[ -f "$WT/wt-race-tracked/README.md" ]] && grep -qF "late tracked edit" "$WT/wt-race-tracked/README.md" && pass "wt-race-tracked edit remains on disk" || fail "wt-race-tracked edit remains on disk" "missing edit"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

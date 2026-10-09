#!/usr/bin/env bash
# test_cleanup_worktrees_merged_fastpath.sh — bead disk_magician-plf: merged,
# clean worktrees may be ELIGIBLE at >= 3 days; everything else keeps 7 days.
#
# Run: bash tests/test_cleanup_worktrees_merged_fastpath.sh
set -euo pipefail
# These cases pin the 7-day non-merged path; the production default is now 3.
export WORKTREE_MIN_AGE_DAYS=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"

TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_fastpath.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    echo "  PASS  $name"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name (missing: $needle)"; FAIL=$(( FAIL + 1 ))
  fi
}

age_days_ago() {
  local wt="$1" days="$2" ts gitdir
  ts=$(date -v-"${days}"d +%Y%m%d%H%M)
  find "$wt" -name .git -prune -o -print0 | xargs -0 touch -h -t "$ts"
  touch -t "$ts" "$wt/.git"
  gitdir=$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)
  find "$gitdir" -print0 | xargs -0 touch -t "$ts"
}

export HERMES_SKIP_EXAMPLE_COM_GUARD=1
REPO="$TMP_ROOT/repo"
WT="$REPO/.claude/worktrees"
mkdir -p "$WT"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "fixture@users.noreply.github.com"
git -C "$REPO" config user.name "Fixture"
printf '.env*\nnode_modules/\n.npmrc\n*.p12\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add .gitignore README.md
git -C "$REPO" commit -q -m base
MERGED_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b unmerged
printf 'ahead\n' >> "$REPO/README.md"
git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main

add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$3"; }
add_wt m4 "$WT/wt-m4" "$MERGED_SHA"
add_wt m4dirty "$WT/wt-m4dirty" "$MERGED_SHA"
printf 'dirty\n' >> "$WT/wt-m4dirty/README.md"
add_wt u4 "$WT/wt-u4" "$AHEAD_SHA"
add_wt m2 "$WT/wt-m2" "$MERGED_SHA"
add_wt m4live "$WT/wt-m4live" "$MERGED_SHA"
add_wt m4secret "$WT/wt-m4secret" "$MERGED_SHA"
printf 'TOKEN=x\n' > "$WT/wt-m4secret/.env.local"
add_wt m4ignored "$WT/wt-m4ignored" "$MERGED_SHA"
mkdir -p "$WT/wt-m4ignored/node_modules/pkg"
printf 'x\n' > "$WT/wt-m4ignored/node_modules/pkg/index.js"
add_wt m4ao "$REPO/.ao/data/worktrees/wt-m4ao" "$MERGED_SHA"
add_wt m6 "$WT/wt-m6" "$MERGED_SHA"
add_wt m4cfg "$TMP_ROOT/aodir/wt-m4cfg" "$MERGED_SHA"
mkdir -p "$TMP_ROOT/home/.hermes"
printf 'projects:\n  p:\n    worktreeDir: %s\n' "$TMP_ROOT/aodir" > "$TMP_ROOT/home/.hermes/agent-orchestrator.yaml"
add_wt u8 "$WT/wt-u8" "$AHEAD_SHA"
# Verifier: untracked files must count as dirty even with showUntrackedFiles=no.
git -C "$REPO" config status.showUntrackedFiles no
add_wt m4untr "$WT/wt-m4untr" "$MERGED_SHA"
printf 'notes\n' > "$WT/wt-m4untr/notes.txt"
add_wt m8untr "$WT/wt-m8untr" "$MERGED_SHA"
printf 'notes\n' > "$WT/wt-m8untr/notes.txt"
add_wt m4untrdir "$WT/wt-m4untrdir" "$MERGED_SHA"
mkdir -p "$WT/wt-m4untrdir/newdir" && printf 'f\n' > "$WT/wt-m4untrdir/newdir/f"
# Hidden tracked edits (assume-unchanged / skip-worktree) are not clean.
add_wt m4au "$WT/wt-m4au" "$MERGED_SHA"
git -C "$WT/wt-m4au" update-index --assume-unchanged README.md
printf 'hidden\n' >> "$WT/wt-m4au/README.md"
add_wt m4sw "$WT/wt-m4sw" "$MERGED_SHA"
git -C "$WT/wt-m4sw" update-index --skip-worktree README.md
printf 'hidden\n' >> "$WT/wt-m4sw/README.md"
# Secret pathspecs: case-insensitive, plus .npmrc and *.p12.
add_wt m4envcase "$WT/wt-m4envcase" "$MERGED_SHA"
printf 'x\n' > "$WT/wt-m4envcase/.ENV"
add_wt m4npmrc "$WT/wt-m4npmrc" "$MERGED_SHA"
printf 'x\n' > "$WT/wt-m4npmrc/.npmrc"
add_wt m4p12 "$WT/wt-m4p12" "$MERGED_SHA"
mkdir -p "$WT/wt-m4p12/certs" && printf 'x\n' > "$WT/wt-m4p12/certs/Client.P12"
# Locked with a reason (`locked <reason>` porcelain line) and ed25519 key.
add_wt m4lockr "$WT/wt-m4lockr" "$MERGED_SHA"
git -C "$REPO" worktree lock --reason "agent busy" "$WT/wt-m4lockr"
add_wt m4ed "$WT/wt-m4ed" "$MERGED_SHA"
mkdir -p "$WT/wt-m4ed/config" && printf 'x\n' > "$WT/wt-m4ed/config/id_ed25519"
printf 'config/id_ed25519\n' >> "$REPO/.git/info/exclude"
# gh-verified squash-merged route (bead ueh) into the 3-day path.
git -C "$REPO" remote add origin https://github.com/fixture/repo.git
add_wt sqmatch "$WT/wt-sqmatch" "$AHEAD_SHA"
add_wt sqdiff "$WT/wt-sqdiff" "$AHEAD_SHA"

for w in wt-m4 wt-m4dirty wt-u4 wt-m4live wt-m4secret wt-m4ignored wt-m4untr wt-m4untrdir \
    wt-m4au wt-m4sw wt-m4envcase wt-m4npmrc wt-m4p12 wt-sqmatch wt-sqdiff wt-m4lockr wt-m4ed; do age_days_ago "$WT/$w" 4; done
age_days_ago "$REPO/.ao/data/worktrees/wt-m4ao" 4
age_days_ago "$WT/wt-m2" 2
age_days_ago "$TMP_ROOT/aodir/wt-m4cfg" 4
age_days_ago "$WT/wt-m6" 6
age_days_ago "$WT/wt-u8" 8
age_days_ago "$WT/wt-m8untr" 8

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
LIVE_REAL="$(cd "$WT/wt-m4live" && pwd -P)"
cat > "$FAKE_BIN/lsof" <<SH
#!/bin/sh
echo "p1"
echo "n/"
echo "n$LIVE_REAL"
SH
# Fake gh: only the sq* branches resolve; everything else fails closed.
cat > "$FAKE_BIN/gh" <<SH
#!/bin/sh
case "\$*" in
  *sqmatch*) echo "$AHEAD_SHA"; exit 0 ;;
  *sqdiff*) echo "differing000000000000000000000000000000000"; exit 0 ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$FAKE_BIN/timeout"
chmod +x "$FAKE_BIN/lsof" "$FAKE_BIN/gh" "$FAKE_BIN/timeout"

run() {
  env -i HOME="$TMP_ROOT/home" PATH="$FAKE_BIN:/usr/bin:/bin" WORKTREE_MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 "$@" \
    bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1
}

echo "Test: default (merged floor 3d)"
OUT="$(run)"
check "header shows 3d merged floor" "Merged clean worktree floor: 3d" "$OUT"
check "4d merged clean -> ELIGIBLE" "ELIGIBLE  $WT/wt-m4 |" "$OUT"
check "4d merged dirty -> PRESERVE young" "wt-m4dirty | young" "$OUT"
check "4d unmerged clean -> PRESERVE young" "wt-u4 | young" "$OUT"
check "2d merged clean -> PRESERVE young" "wt-m2 | young" "$OUT"
check "4d merged clean live cwd -> PRESERVE live-cwd" "wt-m4live | live-cwd" "$OUT"
check "4d merged with ignored .env -> PRESERVE young" "wt-m4secret | young" "$OUT"
check "4d merged with ignored node_modules -> ELIGIBLE" "ELIGIBLE  $WT/wt-m4ignored |" "$OUT"
check "4d merged under AO worktreeDir -> PRESERVE young" "wt-m4ao | young" "$OUT"
check "4d merged under AO config worktreeDir -> PRESERVE young" "wt-m4cfg | young" "$OUT"
check "8d unmerged keeps 7d path reason" "wt-u8 | ahead-of-main" "$OUT"
check "4d untracked file (showUntrackedFiles=no) -> young" "wt-m4untr | young" "$OUT"
check "4d untracked dir (showUntrackedFiles=no) -> young" "wt-m4untrdir | young" "$OUT"
check "8d untracked file (showUntrackedFiles=no) -> untracked" "wt-m8untr | untracked" "$OUT"
check "4d assume-unchanged edit -> young" "wt-m4au | young" "$OUT"
check "4d skip-worktree edit -> young" "wt-m4sw | young" "$OUT"
check "4d ignored .ENV (uppercase) -> young" "wt-m4envcase | young" "$OUT"
check "4d ignored .npmrc -> young" "wt-m4npmrc | young" "$OUT"
check "4d ignored *.P12 -> young" "wt-m4p12 | young" "$OUT"
check "4d merged locked with reason -> PRESERVE locked" "wt-m4lockr | locked" "$OUT"
check "4d ignored id_ed25519 -> young" "wt-m4ed | young" "$OUT"
check "4d gh squash-merged matching head -> ELIGIBLE" "ELIGIBLE  $WT/wt-sqmatch |" "$OUT"
check "4d gh squash-merged differing head -> young" "wt-sqdiff | young" "$OUT"

echo "Test: env 1 clamped to 3"
OUT="$(run DISK_MAGICIAN_MERGED_WORKTREE_MIN_DAYS=1)"
check "env 1 -> header 3d" "Merged clean worktree floor: 3d" "$OUT"
check "env 1 -> 2d merged still young" "wt-m2 | young" "$OUT"

echo "Test: env 10 clamped to 7"
OUT="$(run DISK_MAGICIAN_MERGED_WORKTREE_MIN_DAYS=10)"
check "env 10 -> header 7d" "Merged clean worktree floor: 7d" "$OUT"
check "env 10 -> 6d merged clean young" "wt-m6 | young" "$OUT"

echo "Test: env 5 raises floor"
OUT="$(run DISK_MAGICIAN_MERGED_WORKTREE_MIN_DAYS=5)"
check "env 5 -> 4d merged clean young" "wt-m4 | young" "$OUT"
check "env 5 -> 6d merged clean ELIGIBLE" "ELIGIBLE  $WT/wt-m6 |" "$OUT"

echo "Test: production default floor is 3 days for all worktrees"
OUT="$(run WORKTREE_MIN_AGE_DAYS=3)"
check "default -> header others 3d" "(others: 3d)" "$OUT"
check "default -> 4d unmerged clean is not young" "wt-u4 | ahead-of-main" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

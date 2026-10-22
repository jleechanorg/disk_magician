#!/usr/bin/env bash
# DISK_MAGICIAN_WORKTREE_FLOOR_HOURS (operator decision 2026-10-22): N>=12 lowers the
# non-AO recency floor to N hours; every other gate (clean, pushed/merged, live cwd,
# unmeasurable recency) still decides. Lower or malformed N keeps the day floor.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_hours.XXXXXX)" && pwd -P)
trap 'chmod -R u+rwx "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1)); fi; }
age_hours_ago() {
  local wt="$1" hours="$2" ts gitdir
  if ! ts=$(date -v-"${hours}"H +%Y%m%d%H%M 2>/dev/null); then
    ts=$(date -d "${hours} hours ago" +%Y%m%d%H%M)
  fi
  /usr/bin/find "$wt" -name .git -prune -o -exec touch -h -t "$ts" {} +
  touch -t "$ts" "$wt/.git"
  gitdir=$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)
  /usr/bin/find "$gitdir" -exec touch -t "$ts" {} +
}
export HERMES_SKIP_EXAMPLE_COM_GUARD=1
REPO="$TMP_ROOT/repo"; WT="$REPO/.claude/worktrees"; mkdir -p "$WT"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email f@users.noreply.github.com
git -C "$REPO" config user.name F
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md; git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b ahead; printf 'ahead\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$3"; }
add_wt h13 "$WT/wt-h13" "$AHEAD_SHA";     git -C "$REPO" push -q origin h13
add_wt h11 "$WT/wt-h11" "$AHEAD_SHA";     git -C "$REPO" push -q origin h11
add_wt d2dirty "$WT/wt-d2dirty" "$AHEAD_SHA"; git -C "$REPO" push -q origin d2dirty
add_wt d2unpushed "$WT/wt-d2unpushed" "$AHEAD_SHA"
add_wt unmeas "$WT/wt-unmeas" "$AHEAD_SHA";   git -C "$REPO" push -q origin unmeas
printf 'wip\n' >> "$WT/wt-d2dirty/README.md"
age_hours_ago "$WT/wt-h13" 13
age_hours_ago "$WT/wt-h11" 11
age_hours_ago "$WT/wt-d2dirty" 48
age_hours_ago "$WT/wt-d2unpushed" 48
age_hours_ago "$WT/wt-unmeas" 13
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
printf '#!/bin/sh\nprintf '"'"'p1\\nn/\\n'"'"'\n' > "$TMP_ROOT/bin/lsof"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"
run() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 "$@" bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1; }

OUT="$(run)"
check "no env: 13h-idle clean pushed worktree stays young" "wt-h13 | young" "$OUT"
[[ ! -e "$TMP_ROOT/home/.disk_magician_state/worktree_guard.log" ]] && { echo "  PASS  no env: nothing written to guard log"; PASS=$((PASS+1)); } || { echo "  FAIL  no env: guard log written"; FAIL=$((FAIL+1)); }

# a worktree dir the scan cannot read: recency is unmeasurable, so it stays preserved
chmod 000 "$WT/wt-unmeas"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12)"
chmod 755 "$WT/wt-unmeas"
check "12h floor: 13h-idle clean pushed worktree is ELIGIBLE" "ELIGIBLE  $WT/wt-h13 |" "$OUT"
check "12h floor: ELIGIBLE line names the override" "recency=hours:12" "$OUT"
check "12h floor: 11h-idle worktree stays young" "wt-h11 | young" "$OUT"
check "12h floor: 2-day-old dirty worktree is preserved" "PRESERVE  $WT/wt-d2dirty |" "$OUT"
check "12h floor: 2-day-old unpushed worktree is preserved" "wt-d2unpushed | ahead-of-main" "$OUT"
check "12h floor: unreadable worktree is preserved" "PRESERVE  $WT/wt-unmeas |" "$OUT"
check "12h floor: override recorded in guard log" "recency override active: hours:12" "$(cat "$TMP_ROOT/home/.disk_magician_state/worktree_guard.log")"

OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=6)"
check "floor 6 falls back to the day floor" "wt-h13 | young" "$OUT"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=abc)"
check "malformed floor falls back to the day floor" "wt-h13 | young" "$OUT"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=012)"
check "zero-padded floor falls back to the day floor" "wt-h13 | young" "$OUT"
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

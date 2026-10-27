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
add_wt locked13 "$WT/wt-locked13" "$AHEAD_SHA"; git -C "$REPO" push -q origin locked13
git -C "$REPO" worktree lock "$WT/wt-locked13"
printf 'wip\n' >> "$WT/wt-d2dirty/README.md"
age_hours_ago "$WT/wt-h13" 13
age_hours_ago "$WT/wt-h11" 11
age_hours_ago "$WT/wt-d2dirty" 48
age_hours_ago "$WT/wt-d2unpushed" 48
age_hours_ago "$WT/wt-unmeas" 13
age_hours_ago "$WT/wt-locked13" 13
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
# cwd snapshot reports one process at /; the C14/quarantine "+D <tree>" open-file probes find nothing
cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
case "$*" in *+D*) exit 1 ;; esac
printf 'p1\nn/\n'
SH
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"
run() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 "$@" bash "$CLEANUP_SCRIPT" ${MODE:---dry-run} --repos "$REPO" 2>&1; }

OUT="$(run)"
check "no env: 13h-idle clean pushed worktree stays young" "wt-h13 | young" "$OUT"
[[ ! -e "$TMP_ROOT/home/.disk_magician_state/worktree_guard.log" ]] && { echo "  PASS  no env: nothing written to guard log"; PASS=$((PASS+1)); } || { echo "  FAIL  no env: guard log written"; FAIL=$((FAIL+1)); }

# a worktree dir the scan cannot read: recency is unmeasurable, so it stays preserved
# (chmod cannot deny root, so that one check is skipped when run as root)
[[ "$(id -u)" -eq 0 ]] || chmod 000 "$WT/wt-unmeas"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12)"
chmod 755 "$WT/wt-unmeas"
check "12h floor: 13h-idle clean pushed worktree is ELIGIBLE" "ELIGIBLE  $WT/wt-h13 |" "$OUT"
check "12h floor: ELIGIBLE line names the override" "recency=hours:12" "$OUT"
check "12h floor: 11h-idle worktree stays young" "wt-h11 | young" "$OUT"
check "12h floor: 2-day-old dirty worktree is preserved" "PRESERVE  $WT/wt-d2dirty |" "$OUT"
check "12h floor: 2-day-old unpushed worktree is preserved" "wt-d2unpushed | ahead-of-main" "$OUT"
[[ "$(id -u)" -eq 0 ]] || check "12h floor: unreadable worktree is preserved" "PRESERVE  $WT/wt-unmeas |" "$OUT"
check "12h floor: locked 13h-idle worktree is preserved" "wt-locked13 | locked" "$OUT"
check "12h floor: override recorded in guard log" "recency override active: hours:12" "$(cat "$TMP_ROOT/home/.disk_magician_state/worktree_guard.log")"

OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=6)"
check "floor 6 falls back to the day floor" "wt-h13 | young" "$OUT"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=abc)"
check "malformed floor falls back to the day floor" "wt-h13 | young" "$OUT"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=012)"
check "zero-padded floor falls back to the day floor" "wt-h13 | young" "$OUT"

# Real removal: the 13h-idle worktree goes, and its deletion-log line names the override.
DLOG="$TMP_ROOT/deletions.log"
# h13 also carries its own owner-null lease: only the C14 T3 owner-null relax (clean + pushed + non-AO
# + idle >= the caller floor) may free it.
mkdir -p "$TMP_ROOT/state/worktree_leases"
LEASE_HASH=$(printf '%s' "$WT/wt-h13" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16)
printf '{"path":"%s","owner":null}\n' "$WT/wt-h13" > "$TMP_ROOT/state/worktree_leases/$LEASE_HASH.json"
MODE=--clean run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 WORKTREE_APPROVED=1 DISK_MAGICIAN_DELETION_LOG="$DLOG" DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state" >"$TMP_ROOT/clean.out" || true
[[ ! -e "$WT/wt-h13" ]] && { echo "  PASS  --clean removed the 13h-idle owner-null-lease worktree"; PASS=$((PASS+1)); } || { echo "  FAIL  --clean left wt-h13"; grep -iE "wrh|kept|quarantine|error" "$TMP_ROOT/clean.out" | head -15; FAIL=$((FAIL+1)); }
check "deletion log names the override" "recency=hours:12" "$(cat "$DLOG" 2>/dev/null)"
[[ -d "$WT/wt-h11" && -d "$WT/wt-d2dirty" && -d "$WT/wt-d2unpushed" && -d "$WT/wt-locked13" ]] && { echo "  PASS  --clean kept 11h, dirty, unpushed and locked worktrees"; PASS=$((PASS+1)); } || { echo "  FAIL  --clean removed a protected worktree"; FAIL=$((FAIL+1)); }
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

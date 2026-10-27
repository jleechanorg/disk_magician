#!/usr/bin/env bash
# Exact-target 12h discard mode; all removals occur in disposable fixture repos.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(cd "$(mktemp -d /tmp/manual-worktree-cleanup.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HOME_FIX="$TMP/home"
REPO="$HOME_FIX/projects/repo"
WTROOT="$HOME_FIX/.worktrees/fixture"
BIN="$TMP/bin"
mkdir -p "$HOME_FIX" "$WTROOT" "$BIN" "$REPO"
git -C "$TMP" init -q --bare -b main origin.git
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@users.noreply.github.com
git -C "$REPO" config user.name fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
HERMES_SKIP_EXAMPLE_COM_GUARD=1 git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP/origin.git"
git -C "$REPO" push -q origin main

add_wt() {
  local name="$1" path="$WTROOT/$2"
  mkdir -p "$(dirname "$path")"
  git -C "$REPO" worktree add -q "$path" -b "$name" origin/main
  printf '%s\n' "$path"
}
OLD="$(add_wt old-discard old-discard)"
YOUNG="$(add_wt young young)"
LOCKED="$(add_wt locked locked)"
LIVE="$(add_wt live live)"
PROTECTED="$(add_wt protected protected)"
AO="$(add_wt ao ao/data/worktrees/ao)"
# Detached local commit plus tracked/untracked work exercises recovery and loss.
git -C "$OLD" checkout -q --detach
printf 'local commit\n' >> "$OLD/README.md"
git -C "$OLD" add README.md
HERMES_SKIP_EXAMPLE_COM_GUARD=1 git -C "$OLD" -c user.email=fixture@users.noreply.github.com -c user.name=fixture commit -q -m local-only
printf 'dirty tracked change\n' >> "$OLD/README.md"
printf 'untracked local data\n' > "$OLD/.env.local"
git -C "$REPO" worktree lock "$LOCKED" --reason 'fixture lock'

age_hours_ago() {
  local path="$1" hours="$2" ts gitdir
  ts="$(date -v-"$hours"H +%Y%m%d%H%M 2>/dev/null || date -d "$hours hours ago" +%Y%m%d%H%M)"
  find "$path" -name .git -prune -o -type f -exec touch -t "$ts" {} +
  gitdir="$(sed -n 's/^gitdir: *//p' "$path/.git" | head -1)"
  touch -t "$ts" "$path/.git"
  find "$gitdir" -exec touch -t "$ts" {} +
}
for path in "$OLD" "$YOUNG" "$LOCKED" "$LIVE" "$PROTECTED" "$AO"; do age_hours_ago "$path" 13; done
# Youngest actual content is under the 12h cutoff.
touch "$YOUNG/README.md"
printf '%s\n' "$OLD" > "$TMP/targets.txt"
printf '%s\n' "$YOUNG" > "$TMP/young.txt"
printf '%s\n' "$LIVE" > "$TMP/live.txt"
printf '%s\n' "$PROTECTED" > "$TMP/protected.txt"
printf '%s\n' "$LOCKED" > "$TMP/locked.txt"
printf '%s\n' "$AO" > "$TMP/ao.txt"
cat > "$BIN/lsof" <<'SH2'
#!/bin/sh
if [ "${LSOF_FAIL:-0}" = 1 ]; then exit 1; fi
if [ -n "${LSOF_COUNT_FILE:-}" ]; then
  count=0
  [ ! -f "$LSOF_COUNT_FILE" ] || count="$(cat "$LSOF_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$LSOF_COUNT_FILE"
  if [ "${LOCK_ON_CALL:-}" = "$count" ]; then
    git -C "$FIXTURE_REPO" worktree lock "$LOCK_TARGET" --reason 'execute-time race'
  fi
fi
printf 'p1\nn/\n'
if [ -n "${LIVE_CWD:-}" ]; then printf 'p2\nn%s\n' "$LIVE_CWD"; fi
SH2
cat > "$BIN/timeout" <<'SH2'
#!/bin/sh
shift 2
exec "$@"
SH2
chmod +x "$BIN/lsof" "$BIN/timeout"

run() {
  local include_args=()
  [[ "${INCLUDE_LIVE:-0}" != 1 ]] || include_args+=(--include-live)
  env HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_WORKTREE_FLOOR_HOURS="${FLOOR_HOURS:-12}" LIVE_CWD="${LIVE_CWD:-}" \
    FIXTURE_REPO="$REPO" LOCK_TARGET="${LOCK_TARGET:-$OLD}" LSOF_COUNT_FILE="${LSOF_COUNT_FILE:-}" LOCK_ON_CALL="${LOCK_ON_CALL:-}" \
    DISK_MAGICIAN_STATE_DIR="$TMP/state" DISK_MAGICIAN_DELETION_LOG="$TMP/deletions.log" \
    "$ROOT/disk_magician.sh" cleanup-worktrees "$@" --repos "$REPO" --discard-local-state --targets-file "${TARGETS_FILE:-$TMP/targets.txt}" "${include_args[@]}"
}
PASS=0
FAIL=0
check() { local name="$1"; shift; if "$@"; then echo "PASS $name"; PASS=$((PASS+1)); else echo "FAIL $name"; FAIL=$((FAIL+1)); fi; }

# Exact CLI dispatch, preview, and explicit loss disclosure.
PREVIEW="$(run --dry-run 2>&1)"
grep -q 'MANUAL DISCARD MODE: exact targets only' <<<"$PREVIEW"
grep -q "ELIGIBLE  $OLD .*discard-local-state=true" <<<"$PREVIEW"
check 'dry-run identifies dirty old target without removal' test -d "$OLD" -a -e "$OLD/.env.local"
YOUNG_OUT="$(TARGETS_FILE="$TMP/young.txt" run --dry-run 2>&1)"
check 'fresh target is preserved' grep -q "PRESERVE  $YOUNG | young-or-unmeasurable" <<<"$YOUNG_OUT"
LOCKED_OUT="$(TARGETS_FILE="$TMP/locked.txt" run --dry-run 2>&1)"
check 'locked target is preserved' grep -q "PRESERVE  $LOCKED | locked" <<<"$LOCKED_OUT"
AO_OUT="$(TARGETS_FILE="$TMP/ao.txt" run --dry-run 2>&1)"
check 'AO target is preserved' grep -q "PRESERVE  $AO | ao-owned" <<<"$AO_OUT"

# Missing approval must never remove the selected directory.
UNAPPROVED="$(WORKTREE_APPROVED=0 run --clean 2>&1)"
grep -q 'set WORKTREE_APPROVED=1' <<<"$UNAPPROVED"
check 'clean mode requires approval' test -d "$OLD"

# Manual mode rejects invalid floors, malformed allowlists, and preserves legacy defaults.
LOW_FLOOR="$(FLOOR_HOURS=11 run --dry-run 2>&1 || true)"
check 'manual mode rejects a sub-12h floor' grep -q 'requires a logged.*=12' <<<"$LOW_FLOOR"
printf '%s\n' "$TMP" > "$TMP/bad-targets.txt"
BAD_TARGETS="$(TARGETS_FILE="$TMP/bad-targets.txt" run --dry-run 2>&1 || true)"
check 'manual mode rejects targets outside home scope' grep -q 'outside the canonical home worktree scope' <<<"$BAD_TARGETS"
printf '%s\n' "$REPO" > "$TMP/main-targets.txt"
MAIN_TARGET="$(TARGETS_FILE="$TMP/main-targets.txt" run --dry-run 2>&1 || true)"
check 'manual mode refuses the main checkout' grep -q 'not a recognized linked worktree' <<<"$MAIN_TARGET"
printf '%s\n' 'relative/worktree' > "$TMP/relative-targets.txt"
RELATIVE_TARGET="$(TARGETS_FILE="$TMP/relative-targets.txt" run --dry-run 2>&1 || true)"
check 'manual mode rejects relative target entries' grep -q 'invalid target entry' <<<"$RELATIVE_TARGET"
ln -s "$OLD" "$WTROOT/old-symlink"
printf '%s\n' "$WTROOT/old-symlink" > "$TMP/symlink-targets.txt"
SYMLINK_TARGET="$(TARGETS_FILE="$TMP/symlink-targets.txt" run --dry-run 2>&1 || true)"
check 'manual mode rejects symlink targets' grep -q 'non-symlink directory' <<<"$SYMLINK_TARGET"
DEFAULT_OUT="$(env HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_STATE_DIR="$TMP/state" "$ROOT/disk_magician.sh" cleanup-worktrees --dry-run --repos "$REPO" 2>&1)"
check 'ordinary cleanup keeps local dirty work protected' grep -q "PRESERVE  $OLD |" <<<"$DEFAULT_OUT"

# Revalidate cwd and lock state after the preview, immediately before removal.
LIVE_RACE="$(LIVE_CWD="$OLD" WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'execute-time live cwd race preserves target' grep -q "PRESERVE  $OLD | live-cwd" <<<"$LIVE_RACE"
LOCK_RACE="$(LSOF_COUNT_FILE="$TMP/lsof.count" LOCK_ON_CALL=3 WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'execute-time lock race preserves target' grep -q "PRESERVE  $OLD | locked" <<<"$LOCK_RACE"
git -C "$REPO" worktree unlock "$OLD"

# A live cwd and unknown cwd scan remain hard holds even in discard mode.
LIVE_OUT="$(env LIVE_CWD="$LIVE" HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 DISK_MAGICIAN_STATE_DIR="$TMP/state" DISK_MAGICIAN_DELETION_LOG="$TMP/deletions.log" "$ROOT/disk_magician.sh" cleanup-worktrees --dry-run --repos "$REPO" --discard-local-state --targets-file "$TMP/live.txt" 2>&1)"
check 'live cwd is retained' grep -q "PRESERVE  $LIVE | live-cwd" <<<"$LIVE_OUT"
UNKNOWN_OUT="$(env LSOF_FAIL=1 HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 DISK_MAGICIAN_STATE_DIR="$TMP/state" "$ROOT/disk_magician.sh" cleanup-worktrees --dry-run --repos "$REPO" --discard-local-state --targets-file "$TMP/targets.txt" 2>&1 || true)"
check 'unavailable cwd scan fails closed' grep -q 'PRESERVE.*cwd-unknown' <<<"$UNKNOWN_OUT"

# Machine-local safety protection is retained.
cat > "$TMP/safety.json" <<EOF
{"never_delete":[{"path":"$PROTECTED","reason":"fixture protection"}]}
EOF
SAFE_OUT="$(env HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 DISK_MAGICIAN_STATE_DIR="$TMP/state" DISK_MAGICIAN_SAFETY_FILE="$TMP/safety.json" "$ROOT/disk_magician.sh" cleanup-worktrees --dry-run --repos "$REPO" --discard-local-state --targets-file "$TMP/protected.txt" 2>&1)"
check 'machine safety rule remains active' grep -q "PRESERVE  $PROTECTED | machine-safety:" <<<"$SAFE_OUT"
SAFE_INCLUDE_OUT="$(env HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 DISK_MAGICIAN_STATE_DIR="$TMP/state" DISK_MAGICIAN_SAFETY_FILE="$TMP/safety.json" "$ROOT/disk_magician.sh" cleanup-worktrees --dry-run --repos "$REPO" --discard-local-state --include-live --targets-file "$TMP/protected.txt" 2>&1)"
check 'include-live cannot bypass machine safety rules' grep -q "PRESERVE  $PROTECTED | machine-safety:" <<<"$SAFE_INCLUDE_OUT"

# Execute only the one old target. Detached commit remains addressable by recovery ref.
CLEAN="$(WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'manual clean reports before df used and available KB' grep -q '^MANUAL DF BEFORE path=.* used_kb=[0-9][0-9]* available_kb=[0-9][0-9]*$' <<<"$CLEAN"
check 'manual clean reports after df used and available KB' grep -q '^MANUAL DF AFTER path=.* used_kb=[0-9][0-9]* available_kb=[0-9][0-9]*$' <<<"$CLEAN"
check 'approved cleanup removes exact old target' test ! -e "$OLD"
check 'untracked and tracked local changes were discarded' test ! -e "$OLD/.env.local"
RECOVERY_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/disk-magician/recovery/manual-12h | head -1)"
check 'detached local commit gets recovery ref' test -n "$RECOVERY_REF"
if [[ -n "$RECOVERY_REF" ]]; then check 'recovery ref preserves local commit' git -C "$REPO" cat-file -e "$RECOVERY_REF^{commit}"; fi
check 'deletion log records discard and 12h policy' grep -q 'manual-discard recency=hours:12' "$TMP/deletions.log"
check 'fresh worktree remains' test -d "$YOUNG"
check 'locked and AO worktrees remain' test -d "$LOCKED" -a -d "$AO"

# The stronger opt-in applies only to the exact selected target and clears only
# the live/AO/lock holds; all identity, recency, and machine safety checks stay on.
LIVE_CLEAN="$(INCLUDE_LIVE=1 TARGETS_FILE="$TMP/live.txt" LIVE_CWD="$LIVE" WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'include-live removes an old live target' test ! -e "$LIVE"
check 'include-live receipt records the selected policy' grep -q 'manual-discard recency=hours:12' "$TMP/deletions.log"
AO_CLEAN="$(INCLUDE_LIVE=1 TARGETS_FILE="$TMP/ao.txt" WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'include-live removes an old AO-owned target' test ! -e "$AO"
LOCKED_CLEAN="$(INCLUDE_LIVE=1 TARGETS_FILE="$TMP/locked.txt" WORKTREE_APPROVED=1 run --clean 2>&1)"
check 'include-live removes an old locked target' test ! -e "$LOCKED"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

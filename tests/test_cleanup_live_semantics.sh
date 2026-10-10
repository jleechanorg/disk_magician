#!/usr/bin/env bash
# Pins the APFS / Docker / Antigravity cleanup scripts to the live user-scope
# semantics (Time Machine snapshot deletion, builder prune + TRIM, brain/
# worktree/.backup pruning) with dm's dry-run-by-default / --clean contract.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t cleanup_live_sem.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; FAIL=1; }
has() { grep -qF -- "$2" <<<"$3" && ok "$1" || bad "$1 (missing: $2)"; }
hasnt() { grep -qF -- "$2" <<<"$3" && bad "$1 (found: $2)" || ok "$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/calls"; : > "$CALLS"
OLD="com.apple.TimeMachine.2020-01-01-000000.local"
NEW="com.apple.TimeMachine.$(date '+%Y-%m-%d-%H%M%S').local"
cat > "$BIN/tmutil" <<EOS
#!/usr/bin/env bash
case "\$1" in
  listlocalsnapshots) printf '%s\n%s\n' "$OLD" "$NEW" ;;
  listlocalsnapshotdates) echo "Snapshot dates for all disks:" ;;
  deletelocalsnapshots) echo "tmutil \$*" >> "$CALLS" ;;
esac
EOS
cat > "$BIN/diskutil" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
cat > "$BIN/docker" <<EOS
#!/usr/bin/env bash
case "\$1" in
  info|system) exit 0 ;;
  *) echo "docker \$*" >> "$CALLS" ;;
esac
EOS
chmod +x "$BIN"/*
# lsof is not installed on some Linux runners; return a complete harmless cwd
# snapshot so fail-closed live-process checks can exercise stale fixtures.
cat > "$BIN/lsof" <<'EOS'
#!/usr/bin/env bash
printf "p1\nn/\n"
EOS
chmod +x "$BIN/lsof"
export PATH="$BIN:/usr/bin:/bin"

echo "APFS: dry-run default does not delete"
out="$(HOME="$TMP/home" bash "$REPO_ROOT/scripts/cleanup_apfs_snapshots.sh" 2>&1)"
has "dry-run queues old TM snapshot" "[dry-run] would delete snapshot: 2020-01-01-000000" "$out"
[[ ! -s "$CALLS" ]] && ok "no tmutil delete in dry-run" || bad "tmutil delete ran in dry-run"
echo "APFS: --clean deletes only the old Time Machine snapshot"
HOME="$TMP/home" bash "$REPO_ROOT/scripts/cleanup_apfs_snapshots.sh" --clean >/dev/null 2>&1
[[ "$(cat "$CALLS")" == "tmutil deletelocalsnapshots 2020-01-01-000000" ]] && ok "deleted old TM only" || bad "unexpected calls: $(cat "$CALLS")"

: > "$CALLS"
echo "Docker: dry-run default prints builder prune + TRIM, runs neither"
out="$(HOME="$TMP/home" bash "$REPO_ROOT/scripts/cleanup_docker.sh" 2>&1)"
has "builder prune planned" "docker builder prune -af --keep-storage 5g" "$out"
has "TRIM planned" "docker/desktop-reclaim-space" "$out"
hasnt "no system prune" "system prune" "$out"
[[ ! -s "$CALLS" ]] && ok "no docker mutation in dry-run" || bad "docker mutated in dry-run"
echo "Docker: --clean runs builder prune, image prune, TRIM"
HOME="$TMP/home" bash "$REPO_ROOT/scripts/cleanup_docker.sh" --clean >/dev/null 2>&1
calls="$(cat "$CALLS")"
has "builder prune ran" "docker builder prune -af --keep-storage 5g" "$calls"
has "image prune ran" "docker image prune -af" "$calls"
has "TRIM ran" "docker/desktop-reclaim-space" "$calls"

echo "Antigravity: IDE brain, eligible Git worktree, non-Git orphan, .backup semantics"
H="$TMP/ag"; AG="$H/.gemini/antigravity"
mkdir -p "$AG/brain/old" "$AG/brain/old_with_recent_log" "$AG/brain/new" \
         "$AG/worktrees/proj/idle" "$AG/worktrees/proj/live" \
         "$AG/worktrees/proj/non_git" "$AG/brain.backup" "$AG/conversations/keep"
echo x > "$AG/worktrees/proj/live/f"; echo x > "$AG/worktrees/proj/non_git/f"; echo x > "$AG/conversations/keep/f"
echo x > "$AG/brain/old/old_file"
echo x > "$AG/brain/old_with_recent_log/task.log"
# A real clean Git checkout on main is eligible when old; unlike a plain
# non-Git orphan, it satisfies the production cleanup contract.
git -C "$AG/worktrees/proj/idle" init -q -b main
git -C "$AG/worktrees/proj/idle" config user.name "Cleanup Fixture"
git -C "$AG/worktrees/proj/idle" config user.email "cleanup-fixture@example.invalid"
echo tracked > "$AG/worktrees/proj/idle/tracked.txt"
git -C "$AG/worktrees/proj/idle" add tracked.txt
git -C "$AG/worktrees/proj/idle" commit -qm "fixture main commit"

touch -t 202001010000 "$AG/brain/old" "$AG/brain/old/old_file" \
  "$AG/worktrees/proj/idle" "$AG/worktrees/proj/idle/tracked.txt" \
  "$AG/worktrees/proj/live" "$AG/worktrees/proj/live/f" \
  "$AG/worktrees/proj/non_git" "$AG/worktrees/proj/non_git/f" "$AG/brain.backup"
touch -t 202001010000 "$AG/brain/old_with_recent_log"
# task.log in old_with_recent_log is left with current mtime (descendant activity)

out="$(HOME="$H" bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" 2>&1)"
has "dry-run reports old IDE brain" "would delete old" "$out"
has "dry-run identifies a clean eligible Git worktree" "ELIGIBLE" "$out"
[[ -d "$AG/brain/old" ]] && ok "dry-run keeps old brain" || bad "dry-run deleted old brain"

# Clean without WORKTREE_APPROVED prunes old brain, but preserves worktree and old brain with recent descendant
HOME="$H" bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean >/dev/null 2>&1
[[ ! -e "$AG/brain/old" ]] && ok "old IDE brain pruned" || bad "old IDE brain kept"
[[ -d "$AG/brain/old_with_recent_log" ]] && ok "old brain with recent descendant preserved" || bad "old brain with recent descendant deleted"
[[ -d "$AG/worktrees/proj/idle" ]] && ok "worktree preserved without WORKTREE_APPROVED" || bad "worktree deleted without WORKTREE_APPROVED"
[[ -d "$AG/worktrees/proj/non_git" ]] && ok "non-Git orphan preserved without WORKTREE_APPROVED" || bad "non-Git orphan deleted without WORKTREE_APPROVED"
[[ ! -e "$AG/brain.backup" ]] && ok ".backup leftover pruned" || bad ".backup kept"

# Clean with WORKTREE_APPROVED=1 removes eligible clean Git worktree only
HOME="$H" WORKTREE_APPROVED=1 bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean >/dev/null 2>&1
[[ ! -e "$AG/worktrees/proj/idle" ]] && ok "eligible Git worktree pruned with WORKTREE_APPROVED" || bad "eligible Git worktree kept with WORKTREE_APPROVED"
[[ -d "$AG/worktrees/proj/non_git" ]] && ok "non-Git orphan preserved with WORKTREE_APPROVED" || bad "non-Git orphan deleted with WORKTREE_APPROVED"
[[ -d "$AG/brain/new" && -d "$AG/worktrees/proj/live" && -d "$AG/conversations/keep" ]] && ok "recent state + conversations kept" || bad "protected state deleted"

# Verify symlinked candidates/parents are rejected and physical targets outside root are protected
EXTERNAL_TARGET="$TMP/external_dir"; mkdir -p "$EXTERNAL_TARGET"
echo "important external data" > "$EXTERNAL_TARGET/important.txt"
touch -t 202001010000 "$EXTERNAL_TARGET" "$EXTERNAL_TARGET/important.txt"
ln -s "$EXTERNAL_TARGET" "$AG/worktrees/proj/symlink_wt"

EXTERNAL_BRAIN="$TMP/external_brain"; mkdir -p "$EXTERNAL_BRAIN"
echo "important brain data" > "$EXTERNAL_BRAIN/data.txt"
touch -t 202001010000 "$EXTERNAL_BRAIN" "$EXTERNAL_BRAIN/data.txt"
ln -s "$EXTERNAL_BRAIN" "$AG/brain/symlink_brain"

HOME="$H" WORKTREE_APPROVED=1 bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean >/dev/null 2>&1
[[ -d "$EXTERNAL_TARGET" && -f "$EXTERNAL_TARGET/important.txt" ]] && ok "symlinked worktree external target protected" || bad "symlinked worktree external target deleted"
[[ -d "$EXTERNAL_BRAIN" && -f "$EXTERNAL_BRAIN/data.txt" ]] && ok "symlinked brain external target protected" || bad "symlinked brain external target deleted"

exit $FAIL

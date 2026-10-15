#!/usr/bin/env bash
# Pins the APFS / Docker / Antigravity cleanup scripts to the live user-scope
# semantics (Time Machine snapshot deletion, builder prune + TRIM, brain/
# worktree/.backup pruning) with dm's dry-run-by-default / --clean contract.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON3_DIR="$(dirname "$(command -v python3)")"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
TMP="$(mktemp -d /tmp/cleanup_live_sem.XXXXXX)" || exit 1
[[ "$TMP" == /tmp/cleanup_live_sem.* && -d "$TMP" && ! -L "$TMP" ]] || exit 1
TMP="$(cd "$TMP" && pwd -P)" || exit 1
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
trap 'rm -rf "$TMP"' EXIT
# lease_path_for builds the pushed fixture's released C14 git_meta baseline.
# shellcheck source=scripts/lib/quarantine.sh
source "$REPO_ROOT/scripts/lib/quarantine.sh"
FAIL=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; FAIL=1; }
has() { grep -qF -- "$2" <<<"$3" && ok "$1" || bad "$1 (missing: $2)"; }
hasnt() { grep -qF -- "$2" <<<"$3" && bad "$1 (found: $2)" || ok "$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/calls"; : > "$CALLS"
OLD="com.apple.TimeMachine.2020-01-01-000000.local"
NEW="com.apple.TimeMachine.$(date '+%Y-%m-%d-%H%M%S').local"
NOW_EPOCH="$(date '+%s')"
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
# cleanup_apfs_snapshots.sh intentionally uses macOS date(1). Keep this
# fixture deterministic on non-macOS development hosts while preserving its
# old-versus-recent snapshot assertions.
cat > "$BIN/date" <<EOS
#!/usr/bin/env bash
if [[ "\${1:-}" == "-j" ]]; then
  if [[ "\${4:-}" == "2020-01-01 00:00:00" ]]; then
    printf '%s\n' 1577836800
  else
    printf '%s\n' "$NOW_EPOCH"
  fi
else
  /bin/date "\$@"
fi
EOS
cat > "$BIN/docker" <<EOS
#!/usr/bin/env bash
case "\$1" in
  info|system) exit 0 ;;
  *) echo "docker \$*" >> "$CALLS" ;;
esac
EOS
chmod +x "$BIN"/*
# C14's live-cwd probe runs `lsof -d cwd -Fn`; its open-file probe runs
# `lsof ... +D <candidate>`. Answer only the former with a harmless cwd
# snapshot. The open-file probe must report no open files (rc 1) or every
# candidate is falsely kept as open-file.
cat > "$BIN/lsof" <<'EOS'
#!/usr/bin/env bash
if [[ " $* " == *" +D "* ]]; then exit 1; fi
printf "p1\nn/\n"
EOS
chmod +x "$BIN/lsof"
export PATH="$BIN:$PYTHON3_DIR:/usr/bin:/bin"

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
         "$AG/worktrees/proj/idle" "$AG/worktrees/proj/unpushed" \
         "$AG/worktrees/proj/live" \
         "$AG/worktrees/proj/non_git" "$AG/brain.backup" "$AG/conversations/keep"
echo x > "$AG/worktrees/proj/live/f"; echo x > "$AG/worktrees/proj/non_git/f"; echo x > "$AG/conversations/keep/f"
echo x > "$AG/brain/old/old_file"
echo x > "$AG/brain/old_with_recent_log/task.log"
# A genuinely pushed standalone checkout is eligible: a bare origin lives
# outside the worktree root and main is pushed to it, plus the released C14
# git_meta baseline lease an ordinary (non-ephemeral) candidate needs. Fixture
# git runs under HOME="$H" so host global hooks/LFS filters cannot fail the
# push. A second clean checkout with NO remote is the unpushed negative.
ORIGIN="$TMP/origin.git"
HOME="$H" git init -q --bare -b main "$ORIGIN"
for name in idle unpushed; do
  d="$AG/worktrees/proj/$name"
  HOME="$H" git -C "$d" init -q -b main
  HOME="$H" git -C "$d" config user.name "Cleanup Fixture"
  HOME="$H" git -C "$d" config user.email "cleanup-fixture@example.invalid"
  echo tracked > "$d/tracked.txt"
  HOME="$H" git -C "$d" add tracked.txt
  HOME="$H" git -C "$d" commit -qm "fixture main commit"
done
HOME="$H" git -C "$AG/worktrees/proj/idle" remote add origin "$ORIGIN"
HOME="$H" git -C "$AG/worktrees/proj/idle" push -q origin main
idle_lease="$(lease_path_for "$AG/worktrees/proj/idle")"
mkdir -p "${idle_lease%/*}"
printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":%s}\n' \
  "$AG/worktrees/proj/idle" \
  "$(python3 "$REPO_ROOT/scripts/c14_probe.py" gitmeta "$(HOME="$H" git -C "$AG/worktrees/proj/idle" rev-parse --absolute-git-dir)")" \
  > "$idle_lease"

# Age the whole candidate including git admin. C14's inventory newest-mtime
# gate covers .git, so touching only working files leaves a fresh index that
# reads as recent-activity.
find "$AG/worktrees/proj/idle" "$AG/worktrees/proj/unpushed" "$AG/worktrees/proj/non_git" \
  -exec touch -h -t 202001010000 {} + 2>/dev/null
touch -t 202001010000 "$AG/brain/old" "$AG/brain/old/old_file" \
  "$AG/worktrees/proj/live" "$AG/worktrees/proj/live/f" \
  "$AG/worktrees/proj/non_git" "$AG/worktrees/proj/non_git/f" "$AG/brain.backup"
touch -t 202001010000 "$AG/brain/old_with_recent_log"
# task.log in old_with_recent_log is left with current mtime (descendant activity)

# Probes must avoid index refresh even when the caller allows optional locks.
export GIT_OPTIONAL_LOCKS=1

out="$(HOME="$H" bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" 2>&1)"
has "dry-run reports old IDE brain" "would delete old" "$out"
has "dry-run identifies a clean eligible Git worktree" "ELIGIBLE" "$out"
[[ -d "$AG/brain/old" ]] && ok "dry-run keeps old brain" || bad "dry-run deleted old brain"

# Clean without WORKTREE_APPROVED prunes old brain, but preserves worktrees and
# old brain with recent descendant
HOME="$H" bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean >/dev/null 2>&1
[[ ! -e "$AG/brain/old" ]] && ok "old IDE brain pruned" || bad "old IDE brain kept"
[[ -d "$AG/brain/old_with_recent_log" ]] && ok "old brain with recent descendant preserved" || bad "old brain with recent descendant deleted"
[[ -d "$AG/worktrees/proj/idle" ]] && ok "worktree preserved without WORKTREE_APPROVED" || bad "worktree deleted without WORKTREE_APPROVED"
[[ -d "$AG/worktrees/proj/non_git" ]] && ok "non-Git orphan preserved without WORKTREE_APPROVED" || bad "non-Git orphan deleted without WORKTREE_APPROVED"
[[ ! -e "$AG/brain.backup" ]] && ok ".backup leftover pruned" || bad ".backup kept"

# Clean with WORKTREE_APPROVED=1 removes the pushed clean Git worktree, keeps
# the unpushed one and the unknown non-Git orphan (bytes + reason)
clean_out="$(HOME="$H" WORKTREE_APPROVED=1 bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean 2>&1)"
[[ ! -e "$AG/worktrees/proj/idle" ]] && ok "pushed clean Git worktree pruned with WORKTREE_APPROVED" || bad "pushed clean Git worktree kept with WORKTREE_APPROVED"
[[ -d "$AG/worktrees/proj/unpushed" ]] && ok "unpushed clean Git worktree preserved" || bad "unpushed clean Git worktree deleted"
has "unpushed worktree keeps the not-pushed C14 reason" "not-pushed" "$clean_out"
[[ -d "$AG/worktrees/proj/non_git" ]] && ok "non-Git orphan preserved with WORKTREE_APPROVED" || bad "non-Git orphan deleted with WORKTREE_APPROVED"
[[ "$(cat "$AG/worktrees/proj/non_git/f" 2>/dev/null)" == "x" ]] && ok "non-Git orphan bytes preserved" || bad "non-Git orphan bytes lost"
has "non-Git orphan keeps the not-git reason" "not-git" "$clean_out"
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

#!/usr/bin/env bash
# test_cleanup_mirror_clones.sh — the mirror-clone sweeper seam
# (bead disk_magician-mirror-clone-sweeper-g1xz).
#
# Contract:
#   - `diskm cleanup-mirror-clones` is the only entry point (dispatcher + packaged CLI).
#   - A standalone clone (own .git DIRECTORY) under a configured root is removed
#     only when it is clean, holds no hidden state/secret-like file/stash, is not
#     referenced by a worktree registration, and every local ref is advertised by
#     origin RIGHT NOW (live ls-remote).
#   - Everything else is preserved with a printed reason, and the run ends with a
#     reason histogram.
#   - Dry run is the default; --clean requires WORKTREE_APPROVED=1 and logs every
#     removal to the shared deletion log.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_mirror_clones.sh"
ORCHESTRATOR="$REPO_ROOT/disk_magician.sh"

WORK="$(cd "$(mktemp -d -t test_cleanup_mirror_clones.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

export HOME="$WORK/home"
export DISK_MAGICIAN_SAFETY_FILE="$HOME/.config/disk-magician/safety.local.json"
export DISK_MAGICIAN_DELETION_LOG="$WORK/deletions.log"
export DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_mirror_clones
export DISK_MAGICIAN_TEST_SANDBOX="$WORK"
export DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$WORK/registry-repo"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset DISK_MAGICIAN_AO_CONFIG DISK_MAGICIAN_MIRROR_CLONE_ROOTS

mkdir -p "$HOME/mirror" "$HOME/projects" "$HOME/.config/disk-magician"
printf '{}\n' >"$DISK_MAGICIAN_SAFETY_FILE"
# A host-level guarded `rm` shim resolves its guards relative to $HOME, which this
# fixture overrides; expose the system rm so removals behave normally here.
SYSTEM_RM=/bin/rm
[[ -x "$SYSTEM_RM" ]] || SYSTEM_RM=/usr/bin/rm
mkdir -p "$WORK/bin"
ln -sf "$SYSTEM_RM" "$WORK/bin/rm"
export PATH="$WORK/bin:$PATH"

echo "Test 1: dispatcher and packaged CLI expose cleanup-mirror-clones"
rc=0
help_out="$(bash "$ORCHESTRATOR" cleanup-mirror-clones --help 2>&1)" || rc=$?
check "dispatcher: cleanup-mirror-clones --help exits 0" '[[ "$rc" -eq 0 ]]'
check "dispatcher: --help prints usage" 'grep -q "Usage:" <<<"$help_out"'
menu="$(bash "$ORCHESTRATOR" --help 2>&1 || true)"
check "dispatcher: command menu lists cleanup-mirror-clones" 'grep -q "cleanup-mirror-clones" <<<"$menu"'
rc=0
PYTHONPATH="$REPO_ROOT/src" python3 -m disk_magician.cli cleanup-mirror-clones --help >"$WORK/pycli.out" 2>&1 || rc=$?
check "packaged CLI: cleanup-mirror-clones --help exits 0" '[[ "$rc" -eq 0 ]]'

echo "Test 2: fixtures"
REMOTE="$WORK/remote.git"
git init -q --bare -b main "$REMOTE"
SEED="$WORK/seed"
git clone -q "$REMOTE" "$SEED" 2>/dev/null
printf 'one\n' >"$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -qm initial
git -C "$SEED" push -q origin HEAD:main

clone_into() { git clone -q "$REMOTE" "$1" 2>/dev/null; }

CLEAN_MIRROR="$HOME/mirror/clean-mirror"
CLEAN_PROJECTS="$HOME/projects/clean-projects"
DIRTY="$HOME/mirror/dirty-mirror"
UNPUSHED="$HOME/mirror/unpushed-mirror"
DEAD_REMOTE="$HOME/mirror/dead-remote-mirror"
REGISTERED="$HOME/mirror/registered-mirror"
SECRET="$HOME/mirror/secret-mirror"
for d in "$CLEAN_MIRROR" "$CLEAN_PROJECTS" "$DIRTY" "$UNPUSHED" "$DEAD_REMOTE" "$REGISTERED" "$SECRET"; do
  clone_into "$d"
done

printf 'uncommitted\n' >>"$DIRTY/README.md"
printf 'local only\n' >>"$UNPUSHED/README.md"
git -C "$UNPUSHED" commit -qam "local only commit"
git -C "$DEAD_REMOTE" remote set-url origin "$WORK/missing-remote.git"
# Registration pointer with a missing worktree directory (dead registration): the
# clone was re-created at the path the registry still points at.
REG="$DISK_MAGICIAN_MIRROR_REGISTRY_REPOS"
git init -q "$REG"
mkdir -p "$REG/.git/worktrees/zombie"
printf '%s\n' "$REGISTERED/.git" >"$REG/.git/worktrees/zombie/gitdir"
# Local-only ignore rule keeps git status clean while the ignored secret remains.
printf '.env\n' >>"$SECRET/.git/info/exclude"
printf 'API_KEY=secret\n' >"$SECRET/.env"

check "fixture: clean clone is clean" '[[ -z "$(git -C "$CLEAN_MIRROR" status --porcelain)" ]]'
check "fixture: clean clone HEAD equals origin/main" \
  '[[ "$(git -C "$CLEAN_MIRROR" rev-parse HEAD)" == "$(git -C "$SEED" rev-parse origin/main)" ]]'

echo "Test 3: dry run removes nothing and explains every preserve reason"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
dry_out="$(bash "$SCRIPT" --dry-run 2>&1)" || rc=$?
check "dry-run exits 0" '[[ "$rc" -eq 0 ]]'
check "dry-run keeps every clone on disk" \
  '[[ -d "$CLEAN_MIRROR" && -d "$CLEAN_PROJECTS" && -d "$DIRTY" && -d "$UNPUSHED" && -d "$DEAD_REMOTE" && -d "$REGISTERED" && -d "$SECRET" ]]'
check "dry-run writes no deletion-log line" '[[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'
check "dry-run announces the clean mirror clone" 'grep -qF "would remove: $CLEAN_MIRROR" <<<"$dry_out"'
check "dry-run announces the clean projects clone" 'grep -qF "would remove: $CLEAN_PROJECTS" <<<"$dry_out"'
check "dirty clone preserved as dirty" 'grep -qF "KEEP [dirty] $DIRTY" <<<"$dry_out"'
check "unpushed clone preserved as unpushed-head" 'grep -qF "KEEP [unpushed-head] $UNPUSHED" <<<"$dry_out"'
check "broken origin preserved as lsremote-failed" 'grep -qF "KEEP [lsremote-failed] $DEAD_REMOTE" <<<"$dry_out"'
check "registered clone preserved as registered-worktree" 'grep -qF "KEEP [registered-worktree] $REGISTERED" <<<"$dry_out"'
check "secret clone preserved as hidden-state" 'grep -qF "KEEP [hidden-state] $SECRET" <<<"$dry_out"'
check "histogram prints the registered-worktree bucket" 'grep -q "registered-worktree: 1" <<<"$dry_out"'
check "histogram prints the dirty bucket" 'grep -q "dirty: 1" <<<"$dry_out"'

echo "Test 4: linked worktrees below a root are not candidates"
LINKED_WT="$HOME/mirror/linked-wt"
git -C "$SEED" worktree add -q "$LINKED_WT" HEAD
rc=0
linked_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" 2>&1)" || rc=$?
check "linked-worktree run exits 0" '[[ "$rc" -eq 0 ]]'
check "linked worktree is not reported at all" '! grep -qF "$LINKED_WT" <<<"$linked_out"'
check "linked worktree survives the run" '[[ -d "$LINKED_WT" ]]'
git -C "$SEED" worktree remove --force "$LINKED_WT" >/dev/null 2>&1 || true

echo "Test 5: a live cwd preserves an otherwise eligible clone"
rc=0
cwd_out="$(cd "$CLEAN_MIRROR" && bash "$SCRIPT" --dry-run --root "$HOME/mirror" 2>&1)" || rc=$?
check "live-cwd run exits 0" '[[ "$rc" -eq 0 ]]'
check "live cwd preserved with reason" 'grep -qF "KEEP [live-cwd] $CLEAN_MIRROR" <<<"$cwd_out"'
check "live-cwd run removed nothing" '[[ -d "$CLEAN_MIRROR" && -d "$CLEAN_PROJECTS" ]]'

echo "Test 6: --clean without WORKTREE_APPROVED=1 refuses"
rc=0
refuse_out="$(env -u WORKTREE_APPROVED bash "$SCRIPT" --clean 2>&1)" || rc=$?
check "refused clean exits 0" '[[ "$rc" -eq 0 ]]'
check "refused clean names the approval gate" 'grep -q "WORKTREE_APPROVED=1" <<<"$refuse_out"'
check "refused clean removes nothing" '[[ -d "$CLEAN_MIRROR" && -d "$CLEAN_PROJECTS" ]]'

echo "Test 7: --clean removes only the clean+pushed clones and logs them"
rc=0
clean_out="$(WORKTREE_APPROVED=1 bash "$SCRIPT" --clean --root "$HOME/mirror" --root "$HOME/projects" 2>&1)" || rc=$?
check "--clean exits 0" '[[ "$rc" -eq 0 ]]'
check "--clean removed the clean mirror clone" '[[ ! -e "$CLEAN_MIRROR" ]]'
check "--clean removed the clean projects clone" '[[ ! -e "$CLEAN_PROJECTS" ]]'
check "--clean preserved the dirty clone" '[[ -d "$DIRTY" ]]'
check "--clean preserved the unpushed clone" '[[ -d "$UNPUSHED" ]]'
check "--clean preserved the broken-origin clone" '[[ -d "$DEAD_REMOTE" ]]'
check "--clean preserved the registered clone" '[[ -d "$REGISTERED" ]]'
check "--clean preserved the secret clone" '[[ -d "$SECRET" ]]'
check "--clean reports freed space" 'grep -q "Freed:" <<<"$clean_out"'
check "deletion log records the mirror clone" \
  'grep -qF "$CLEAN_MIRROR" "$DISK_MAGICIAN_DELETION_LOG"'
check "deletion log records the projects clone" \
  'grep -qF "$CLEAN_PROJECTS" "$DISK_MAGICIAN_DELETION_LOG"'
check "deletion log carries the origin note" \
  'grep -q "mirror-clone origin=" "$DISK_MAGICIAN_DELETION_LOG"'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

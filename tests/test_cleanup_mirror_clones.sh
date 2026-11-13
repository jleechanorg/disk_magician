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
export COPYFILE_DISABLE=1
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

echo "Test 8: --archive-to archives, and the archive restores what was removed"
# A fixture that proves the archive carries what NTFS cannot: an exec bit and a
# relative symlink.
ARCHIVE_DIR="$WORK/archive"
mkdir -p "$ARCHIVE_DIR"
printf '#!/bin/sh\necho hi\n' >"$SEED/tool.sh"
chmod 755 "$SEED/tool.sh"
ln -sfn README.md "$SEED/readme-link"
git -C "$SEED" add -A
git -C "$SEED" commit -qm "add exec bit and symlink"
git -C "$SEED" push -q origin HEAD:main
ARCH_MIRROR="$HOME/mirror/archive-mirror"
clone_into "$ARCH_MIRROR"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
arch_out="$(WORKTREE_APPROVED=1 bash "$SCRIPT" --clean --root "$HOME/mirror" \
  --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "archive run exits 0" '[[ "$rc" -eq 0 ]]'
check "unchanged source identity passes post-archive revalidation" \
  '! grep -qF "KEEP [post-archive-identity-changed]" <<<"$arch_out"'
check "archive run removed the source clone" '[[ ! -e "$ARCH_MIRROR" ]]'
arch_file="$(find "$ARCHIVE_DIR" -maxdepth 1 -name 'archive-mirror-*.tar.zst' | head -1)"
check "archive file landed on the target volume" '[[ -f "$arch_file" ]]'
check "archive name carries the short sha" \
  '[[ "$(basename "$arch_file")" == "archive-mirror-$(git -C "$SEED" rev-parse --short=12 HEAD).tar.zst" ]]'
check "deletion log records the archive path" \
  'grep -qF "mirror-clone-archived archive=$arch_file" "$DISK_MAGICIAN_DELETION_LOG"'
check "archive reports GiB archived" 'grep -q "Archived and verified:" <<<"$arch_out"'
RESTORE="$WORK/restore"
mkdir -p "$RESTORE"
if [[ -n "$arch_file" && -f "$arch_file" ]]; then
  tar --zstd -xf "$arch_file" -C "$RESTORE"
fi
check "restore yields the tracked file content" \
  '[[ "$(cat "$RESTORE/README.md")" == "one" ]]'
check "restore yields the git metadata" '[[ -d "$RESTORE/.git" ]]'
check "restore yields the git object for HEAD" \
  '([[ "$(git -C "$RESTORE" rev-parse HEAD 2>/dev/null)" == "$(git -C "$SEED" rev-parse HEAD)" ]])'
check "restore preserves the exec bit" '[[ -x "$RESTORE/tool.sh" ]]'
check "restore preserves the symlink as a symlink" '[[ -L "$RESTORE/readme-link" ]]'
check "restore preserves the symlink target" \
  '[[ "$(readlink "$RESTORE/readme-link")" == "README.md" ]]'

echo "Test 8b: --archive-to preserves the source when identity probes are invalid"
UNKNOWN_ID_MIRROR="$HOME/mirror/unknown-id-mirror"
clone_into "$UNKNOWN_ID_MIRROR"
BAD_STAT="$WORK/bin/stat"
cat >"$BAD_STAT" <<'BAD_STAT_SCRIPT'
#!/usr/bin/env bash
if { [[ "${1:-}" == -c && "${2:-}" == '%d:%i' ]] || [[ "${1:-}" == -f && "${2:-}" == '%d:%i' ]]; }; then
  printf 'not-a-device-inode\n'
  exit 1
fi
exec /usr/bin/stat "$@"
BAD_STAT_SCRIPT
chmod 755 "$BAD_STAT"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
unknown_id_out="$(WORKTREE_APPROVED=1 PATH="$WORK/bin:$PATH" bash "$SCRIPT" \
  --clean --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "unknown-identity archive run exits 0" '[[ "$rc" -eq 0 ]]'
check "unknown source identity keeps the source clone" '[[ -d "$UNKNOWN_ID_MIRROR" ]]'
check "unknown source identity is reported fail-closed" \
  'grep -qF "KEEP [archive-identity-unavailable] $UNKNOWN_ID_MIRROR" <<<"$unknown_id_out"'
check "unknown source identity publishes no archive" \
  '[[ -z "$(find "$ARCHIVE_DIR" -maxdepth 1 -name "unknown-id-mirror-*.tar.zst" -o -name "*.part-*")" ]]'
check "unknown source identity writes no deletion-log entry" \
  '! grep -qF "$UNKNOWN_ID_MIRROR" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || [[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'
rm -f "$BAD_STAT"

echo "Test 9: a verify failure keeps the source and leaves no archive behind"
FAIL_MIRROR="$HOME/mirror/verifyfail-mirror"
clone_into "$FAIL_MIRROR"
printf 'local work\n' >>"$FAIL_MIRROR/README.md"
# A tar that silently drops a member: the archive is readable and well-formed,
# so only the manifest comparison can catch it. This exercises the real verify
# path instead of bypassing it.
FAKE_TAR="$WORK/bin/fake-tar"
printf '#!/usr/bin/env bash\nexec %s --exclude=README.md "$@"\n' "$(command -v tar)" >"$FAKE_TAR"
chmod 755 "$FAKE_TAR"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
fail_out="$(WORKTREE_APPROVED=1 DISK_MAGICIAN_ARCHIVE_TAR_BIN="$FAKE_TAR" bash "$SCRIPT" \
  --clean --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" \
  --archive-relaxed-content-gates 2>&1)" || rc=$?
check "verify-failure run exits 0" '[[ "$rc" -eq 0 ]]'
check "verify failure keeps the source clone intact" '[[ -d "$FAIL_MIRROR" ]]'
check "verify failure keeps the dirty content" 'grep -qx "local work" <(tail -1 "$FAIL_MIRROR/README.md")'
check "verify failure is reported as archive-failed" \
  'grep -qF "KEEP [archive-failed] $FAIL_MIRROR" <<<"$fail_out"'
check "verify failure leaves no partial archive" \
  '[[ -z "$(find "$ARCHIVE_DIR" -maxdepth 1 -name "verifyfail-mirror-*" -o -name "*.part-*" | head -1)" ]]'
check "verify failure writes no deletion-log entry" \
  '! grep -qF "$FAIL_MIRROR" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || [[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'

echo "Test 10: relaxed content gates are off by default and require --archive-to"
RELAX_MIRROR="$HOME/mirror/relax-mirror"
clone_into "$RELAX_MIRROR"
printf 'uncommitted\n' >>"$RELAX_MIRROR/README.md"
rc=0
strict_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "strict archive dry-run preserves the dirty clone" \
  'grep -qF "KEEP [dirty] $RELAX_MIRROR" <<<"$strict_out"'
rc=0
relaxed_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" \
  --archive-relaxed-content-gates 2>&1)" || rc=$?
check "relaxed dry-run announces the dirty clone for archiving" \
  'grep -qF "would archive: $RELAX_MIRROR" <<<"$relaxed_out"'
rc=0
bad_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" --archive-relaxed-content-gates 2>&1)" || rc=$?
check "relaxed gates without --archive-to is an error" '[[ "$rc" -eq 2 ]]'
check "correctly rejects relaxation without an archive target" \
  'grep -q "requires --archive-to" <<<"$bad_out"'

echo "Test 11: Regression A: same-length archive corruption fails verification and preserves source"
CORRUPT_MIRROR="$HOME/mirror/corrupt-mirror"
clone_into "$CORRUPT_MIRROR"
CORRUPT_TAR="$WORK/bin/corrupt-tar"
cat >"$CORRUPT_TAR" <<'EOF'
#!/usr/bin/env bash
args=("$@")
dir=""
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == "-C" && $((i+1)) -lt ${#args[@]} ]]; then
    dir="${args[i+1]}"
    break
  fi
done
if [[ -n "$dir" && -f "$dir/README.md" ]]; then
  shadow="$dir.shadow.$$"
  cp -a "$dir" "$shadow"
  printf 'two\n' >"$shadow/README.md"
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[i]}" == "-C" ]]; then
      args[i+1]="$shadow"
      break
    fi
  done
  if command -v gtar >/dev/null 2>&1; then
    gtar "${args[@]}"
  else
    tar "${args[@]}"
  fi
  rc=$?
  rm -rf "$shadow"
  exit $rc
fi
if command -v gtar >/dev/null 2>&1; then
  exec gtar "$@"
else
  exec tar "$@"
fi
EOF
chmod 755 "$CORRUPT_TAR"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
corrupt_out="$(WORKTREE_APPROVED=1 DISK_MAGICIAN_ARCHIVE_TAR_BIN="$CORRUPT_TAR" bash "$SCRIPT" \
  --clean --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "same-length corruption run exits 0" '[[ "$rc" -eq 0 ]]'
check "same-length corruption keeps source clone intact" '[[ -d "$CORRUPT_MIRROR" ]]'
check "same-length corruption keeps uncorrupted content" '[[ "$(cat "$CORRUPT_MIRROR/README.md")" == "one" ]]'
check "same-length corruption reports archive-failed" \
  'grep -qF "KEEP [archive-failed] $CORRUPT_MIRROR" <<<"$corrupt_out"'
check "same-length corruption writes no deletion-log entry" \
  '! grep -qF "$CORRUPT_MIRROR" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || [[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'

echo "Test 12: Regression B: concurrent archive collision prevents overwrite and retains source"
COLLIDE_MIRROR="$HOME/mirror/collide-mirror"
clone_into "$COLLIDE_MIRROR"
collide_sha="$(git -C "$COLLIDE_MIRROR" rev-parse --short=12 HEAD)"
collide_target="$ARCHIVE_DIR/collide-mirror-$collide_sha.tar.zst"
COLLIDE_TAR="$WORK/bin/collide-tar"
cat >"$COLLIDE_TAR" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"collide-mirror"* ]]; then
  printf 'PRE-EXISTING-WINNER-ARCHIVE\n' >"$collide_target"
fi
if command -v gtar >/dev/null 2>&1; then
  exec gtar "\$@"
else
  exec tar "\$@"
fi
EOF
chmod 755 "$COLLIDE_TAR"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
collide_out="$(WORKTREE_APPROVED=1 DISK_MAGICIAN_ARCHIVE_TAR_BIN="$COLLIDE_TAR" bash "$SCRIPT" \
  --clean --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "concurrent collision run exits 0" '[[ "$rc" -eq 0 ]]'
check "concurrent collision retains existing archive content" \
  '[[ "$(cat "$collide_target" 2>/dev/null)" == "PRE-EXISTING-WINNER-ARCHIVE" ]]'
check "concurrent collision retains loser source clone" '[[ -d "$COLLIDE_MIRROR" ]]'
check "concurrent collision writes no deletion log for loser" \
  '! grep -qF "$COLLIDE_MIRROR" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || [[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'

echo "Test 13: Regression C: consumer entering during archive prevents deletion and retains source"
ENTER_MIRROR="$HOME/mirror/enter-mirror"
clone_into "$ENTER_MIRROR"
SLEEP_PID_FILE="$WORK/enter_sleeper.pid"
ENTER_TAR="$WORK/bin/enter-tar"
cat >"$ENTER_TAR" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"enter-mirror"* ]]; then
  (
    cd "$ENTER_MIRROR"
    nohup sleep 300 </dev/null >/dev/null 2>&1 &
    echo "\$!" >"$SLEEP_PID_FILE"
  )
  sleep 0.5
fi
if command -v gtar >/dev/null 2>&1; then
  exec gtar "\$@"
else
  exec tar "\$@"
fi
EOF
chmod 755 "$ENTER_TAR"
rm -f "$DISK_MAGICIAN_DELETION_LOG"
rc=0
enter_out="$(WORKTREE_APPROVED=1 DISK_MAGICIAN_ARCHIVE_TAR_BIN="$ENTER_TAR" bash "$SCRIPT" \
  --clean --root "$HOME/mirror" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
if [[ -f "$SLEEP_PID_FILE" ]]; then
  kill "$(cat "$SLEEP_PID_FILE")" 2>/dev/null || true
  rm -f "$SLEEP_PID_FILE"
fi
check "consumer entering during archive run exits 0" '[[ "$rc" -eq 0 ]]'
check "consumer entering during archive keeps source clone intact" '[[ -d "$ENTER_MIRROR" ]]'
check "consumer entering during archive writes no deletion log entry" \
  '! grep -qF "$ENTER_MIRROR" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || [[ ! -s "$DISK_MAGICIAN_DELETION_LOG" ]]'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

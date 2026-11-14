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
if [[ "${DISK_MAGICIAN_TEST_CLEAN_ENV:-0}" != 1 ]]; then
  clean_env=(PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/}" \
    DISK_MAGICIAN_TEST_CLEAN_ENV=1 LC_ALL=C TZ=UTC)
  [[ -z "${TMPDIR:-}" ]] || clean_env+=(TMPDIR="$TMPDIR")
  exec env -i "${clean_env[@]}" bash "$0" "$@"
fi
unset BASH_ENV ENV
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_mirror_clones.sh"
ORCHESTRATOR="$REPO_ROOT/disk_magician.sh"

WORK="$(cd "$(mktemp -d -t test_cleanup_mirror_clones.XXXXXX)" && pwd -P)"
cleanup_test_work() {
  if [[ -n "${ACTIVE_LEASE_PID:-}" ]]; then
    kill "$ACTIVE_LEASE_PID" 2>/dev/null || true
    wait "$ACTIVE_LEASE_PID" 2>/dev/null || true
  fi
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup_test_work EXIT

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
check "dispatcher: --help documents the optional registry reader image" \
  'grep -q -- "--registry-reader-image sha256:" <<<"$help_out"'
menu="$(bash "$ORCHESTRATOR" --help 2>&1 || true)"
check "dispatcher: command menu lists cleanup-mirror-clones" 'grep -q "cleanup-mirror-clones" <<<"$menu"'
rc=0
PYTHONPATH="$REPO_ROOT/src" python3 -m disk_magician.cli cleanup-mirror-clones --help >"$WORK/pycli.out" 2>&1 || rc=$?
check "packaged CLI: cleanup-mirror-clones --help exits 0" '[[ "$rc" -eq 0 ]]'
check "packaged CLI: --help documents the optional registry reader image" \
  'grep -q -- "--registry-reader-image sha256:" "$WORK/pycli.out"'

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

if [[ "$(uname -s)" != Linux ]]; then
  echo "Test 14: registry reader is refused outside Linux"
  READER_IMAGE="sha256:$(printf 'a%.0s' {1..64})"
  rc=0
  platform_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" \
    --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
  check "non-Linux reader request is rejected explicitly" \
    '[[ "$rc" -eq 2 ]] && grep -qF "supported only on Linux" <<<"$platform_out"'
  echo "Results: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

echo "Test 14: registry-reader option is pinned and cannot relax archive gates"
reader_help="$(bash "$SCRIPT" --help 2>&1)"
check "usage documents the optional registry reader image" 'grep -q -- "--registry-reader-image sha256:" <<<"$reader_help"'
rc=0
bad_reader_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" --registry-reader-image latest 2>&1)" || rc=$?
check "reader image must be a sha256 digest" '[[ "$rc" -eq 2 ]]'
check "invalid reader image is explained" 'grep -q "sha256" <<<"$bad_reader_out"'
rc=0
archive_reader_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" \
  --registry-reader-image "sha256:$(printf 'a%.0s' {1..64})" --archive-to "$ARCHIVE_DIR" 2>&1)" || rc=$?
check "reader mode rejects archive options" '[[ "$rc" -eq 2 ]]'
check "reader mode explains archive rejection" 'grep -q "incompatible" <<<"$archive_reader_out"'
rc=0
relaxed_reader_out="$(bash "$SCRIPT" --dry-run --root "$HOME/mirror" \
  --registry-reader-image "sha256:$(printf 'a%.0s' {1..64})" --archive-relaxed-content-gates 2>&1)" || rc=$?
check "reader mode rejects relaxed archive gates" '[[ "$rc" -eq 2 ]]'

echo "Test 15: native registry failure retries only through the read-only Docker reader"
READER_ROOT="$WORK/reader-scratch"
READER_CLONE="$READER_ROOT/registered-mirror"
READER_ADMIN="$READER_ROOT/registry-admin"
READER_BIN="$WORK/reader-bin"
REAL_FIND_BIN="$(command -v find)"
READER_IMAGE="sha256:$(printf 'a%.0s' {1..64})"
DOCKER_ARGS_LOG="$WORK/reader-docker-args.log"
TIMEOUT_ARGS_LOG="$WORK/reader-timeout-args.log"
REAL_TIMEOUT_BIN="$(type -P timeout)"
mkdir -p "$READER_ROOT" "$READER_BIN"
clone_into "$READER_CLONE"
mkdir -p "$READER_ADMIN/.git/worktrees/zombie"
printf '%s\n' "$READER_CLONE/.git" >"$READER_ADMIN/.git/worktrees/zombie/gitdir"
cat >"$READER_BIN/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "${REGISTRY_FAIL_ROOT:-}" && "$*" == *"-path */.git/worktrees"* ]]; then
  echo "fixture native registry permission failure" >&2
  exit 1
fi
if [[ -n "${REGISTRY_FAIL_POINTER:-}" && "${1:-}" == "$REGISTRY_FAIL_POINTER" && "$*" == *"-name gitdir"* ]]; then
  echo "fixture host pointer listing failure" >&2
  exit 1
fi
exec "$REAL_FIND_BIN" "$@"
EOF
cat >"$READER_BIN/diskm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "volume path scratch" ]] || exit 90
printf '%s\n' "${MOCK_ACTIVE_SCRATCH_ROOT:?}"
EOF
cat >"$READER_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TIMEOUT_ARGS_LOG"
args=("$@")
if [[ "${MOCK_TIMEOUT_QUICK:-0}" == 1 && "${args[2]:-}" == 120s ]]; then
  args[2]=1s
fi
exec "$REAL_TIMEOUT_BIN" "${args[@]}"
EOF
cat >"$READER_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$DOCKER_ARGS_LOG"
[[ "${1:-}" == --host && "${2:-}" == unix:///var/run/docker.sock ]] || exit 91
shift 2
case "${1:-}" in
  image)
    [[ "${2:-}" == inspect && "${5:-}" == "$EXPECTED_READER_IMAGE" ]] || exit 92
    [[ "${MOCK_READER_MODE:-success}" != inspect-failure ]] || exit 1
    printf '%s\n' "$EXPECTED_READER_IMAGE"
    exit 0
    ;;
  run)
    args=" $* "
    for required in --rm --pull=never --network=none --read-only --security-opt=no-new-privileges:true \
      --cap-drop=ALL --cap-add=DAC_READ_SEARCH --user=0:0 --memory=128m --memory-swap=128m \
      --pids-limit=32 --cpus=0.5 --mount= --entrypoint=/usr/bin/timeout; do
      [[ "$args" == *"$required"* ]] || { echo "unsafe/missing Docker option: $required" >&2; exit 93; }
    done
    [[ "$args" == *"dst=/registry-root,readonly"* && "$args" == *"--signal=TERM --kill-after=5s 90s /usr/bin/find /registry-root -maxdepth "* &&
       "$args" == *"-type d -path */.git/worktrees -print0"* ]] || exit 94
    [[ "$args" != *--privileged* && "$args" != *--network=host* && "$args" != *--cap-add=SYS_ADMIN* ]] || exit 95
    [[ "$args" == *"$EXPECTED_READER_IMAGE"* ]] || exit 96
    case "${MOCK_READER_MODE:-success}" in
      timeout-missing) echo "fixture /usr/bin/timeout missing" >&2; exit 127 ;;
      client-hang)
        printf '%s\n' "$$" >"${MOCK_READER_PID_FILE:?}"
        exec sleep 30 ;;
      success) [[ -n "${MOCK_READER_OUTPUT:-}" ]] && printf '%s\0' "$MOCK_READER_OUTPUT" ;;
      empty) : ;;
  failure) echo "fixture Docker find failure" >&2; exit 1 ;;
      stderr) echo "fixture Docker stderr" >&2; exit 0 ;;
      malformed) printf '/registry-root/../outside/.git/worktrees\0' ;;
      foreign-prefix) printf '/outside/registered/.git/worktrees\0' ;;
      newline) printf '/registry-root/registered\n-mirror/.git/worktrees\0' ;;
      unterminated) printf '/registry-root/registered-mirror/.git/worktrees' ;;
      *) exit 97 ;;
    esac
    ;;
  *) exit 98 ;;
esac
EOF
chmod 755 "$READER_BIN/find" "$READER_BIN/diskm" "$READER_BIN/timeout" "$READER_BIN/docker"
reader_env=(PATH="$READER_BIN:$PATH" REAL_FIND_BIN="$REAL_FIND_BIN" REAL_TIMEOUT_BIN="$REAL_TIMEOUT_BIN"
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" TIMEOUT_ARGS_LOG="$TIMEOUT_ARGS_LOG"
  EXPECTED_READER_IMAGE="$READER_IMAGE" REGISTRY_FAIL_ROOT="$READER_ROOT"
  MOCK_ACTIVE_SCRATCH_ROOT="$READER_ROOT" DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$REG")
rc=0
reader_out="$(env "${reader_env[@]}" MOCK_READER_MODE=success \
  MOCK_READER_OUTPUT="/registry-root/registry-admin/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$READER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "native registry failure uses the local pinned reader and keeps the registered clone" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registered-worktree] $READER_CLONE" <<<"$reader_out"'
check "successful reader does not leave the root registry incomplete" '! grep -qF "registry-incomplete" <<<"$reader_out"'
check "reader image is inspected locally before run" \
  'grep -q -- "image inspect" "$DOCKER_ARGS_LOG" && grep -qF "$READER_IMAGE" "$DOCKER_ARGS_LOG"'
check "reader uses no network, no-new-privileges, bounded resources and a read-only bind" \
  'grep -q -- "--network=none" "$DOCKER_ARGS_LOG" && grep -q -- "--security-opt=no-new-privileges:true" "$DOCKER_ARGS_LOG" && grep -q -- "--memory=128m" "$DOCKER_ARGS_LOG" && grep -q -- "--pids-limit=32" "$DOCKER_ARGS_LOG" && grep -qF "dst=/registry-root,readonly" "$DOCKER_ARGS_LOG"'
check "reader drops all but DAC_READ_SEARCH and executes only fixed find" \
  'grep -q -- "--cap-drop=ALL" "$DOCKER_ARGS_LOG" && grep -q -- "--cap-add=DAC_READ_SEARCH" "$DOCKER_ARGS_LOG" && grep -q -- "--entrypoint=/usr/bin/timeout" "$DOCKER_ARGS_LOG" && grep -q -- "/usr/bin/timeout.* /usr/bin/find" "$DOCKER_ARGS_LOG" && ! grep -q -- "--privileged" "$DOCKER_ARGS_LOG" && ! grep -q -- "--network=host" "$DOCKER_ARGS_LOG"'

OTHER_ROOT="$WORK/not-registered-scratch"
OTHER_CLONE="$OTHER_ROOT/other-clone"
mkdir -p "$OTHER_ROOT"
clone_into "$OTHER_CLONE"
: >"$DOCKER_ARGS_LOG"
rc=0
other_root_out="$(env "${reader_env[@]}" REGISTRY_FAIL_ROOT="$OTHER_ROOT" \
  MOCK_READER_MODE=success MOCK_READER_OUTPUT="/registry-root/other-clone/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$OTHER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "reader fallback is not used outside the active registered Scratch root" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registry-incomplete] $OTHER_CLONE" <<<"$other_root_out" && [[ ! -s "$DOCKER_ARGS_LOG" ]]'

echo "Test 16: timeout bounds the Docker client and the fixed in-container find"
READER_PID_FILE="$WORK/reader-client.pid"
: >"$DOCKER_ARGS_LOG"
: >"$TIMEOUT_ARGS_LOG"
rc=0
client_timeout_out="$(env "${reader_env[@]}" MOCK_TIMEOUT_QUICK=1 MOCK_READER_MODE=client-hang \
  MOCK_READER_PID_FILE="$READER_PID_FILE" \
  bash "$SCRIPT" --dry-run --root "$READER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
reader_pid="$(cat "$READER_PID_FILE" 2>/dev/null || true)"
check "Docker image and run client calls have finite TERM/KILL timeouts" \
  'grep -q -- "--signal=TERM --kill-after=5s 120s" "$TIMEOUT_ARGS_LOG"'
check "fixed in-container timeout supervises only the fixed find command" \
  'grep -q -- "--entrypoint=/usr/bin/timeout" "$DOCKER_ARGS_LOG" && grep -q -- "--signal=TERM --kill-after=5s 90s /usr/bin/find" "$DOCKER_ARGS_LOG" && grep -q -- "--rm" "$DOCKER_ARGS_LOG"'
check "timed out reader process is reaped" \
  '[[ -n "$reader_pid" ]] && ! kill -0 "$reader_pid" 2>/dev/null'
check "timed out reader keeps candidates behind the incomplete registry gate" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registry-incomplete] $READER_CLONE" <<<"$client_timeout_out"'

echo "Test 17: Docker and malformed reader output fail closed for the whole registry"
for mode in inspect-failure failure stderr timeout-missing malformed foreign-prefix newline unterminated; do
  rc=0
  failed_reader_out="$(env "${reader_env[@]}" MOCK_READER_MODE="$mode" \
    MOCK_READER_OUTPUT="/registry-root/registered-mirror/.git/worktrees" \
    bash "$SCRIPT" --dry-run --root "$READER_ROOT" --max-depth 12 \
    --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
  check "reader $mode output preserves the clone and marks registry incomplete" \
    '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registry-incomplete] $READER_CLONE" <<<"$failed_reader_out"'
  check "reader $mode output also preserves every other root candidate" \
    'grep -qF "KEEP [registry-incomplete] $READER_ADMIN" <<<"$failed_reader_out"'
done

echo "Test 18: a host-side registry pointer listing error remains incomplete"
POINTER_CLONE="$READER_ROOT/pointer-unreadable"
POINTER_ADMIN="$READER_ROOT/pointer-admin"
clone_into "$POINTER_CLONE"
mkdir -p "$POINTER_ADMIN/.git/worktrees/blocked"
printf '%s\n' "$POINTER_CLONE/.git" >"$POINTER_ADMIN/.git/worktrees/blocked/gitdir"
rc=0
pointer_out="$(env "${reader_env[@]}" REGISTRY_FAIL_POINTER="$POINTER_ADMIN/.git/worktrees" \
  MOCK_READER_MODE=success MOCK_READER_OUTPUT="/registry-root/pointer-admin/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$READER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "host-side pointer listing failure preserves all reader candidates" \
  '[[ "$rc" -eq 0 ]] && grep -qF "registry-incomplete: 4" <<<"$pointer_out" && grep -qF "KEEP [registry-incomplete] $POINTER_CLONE" <<<"$pointer_out"'

echo "Test 19: reader mode applies canonical recency, C14 leases and quarantine removal"
C14_ROOT="$WORK/c14-scratch"
OLD_READER_CLONE="$C14_ROOT/old-clean-clone"
UNBASELINED_CLONE="$C14_ROOT/old-unbaselined-clone"
RECENT_READER_CLONE="$C14_ROOT/recent-clone"
UNKNOWN_LEASE_CLONE="$C14_ROOT/unknown-lease-clone"
ACTIVE_LEASE_CLONE="$C14_ROOT/active-lease-clone"
mkdir -p "$C14_ROOT"
c14_reader_env=(PATH="$READER_BIN:$PATH" REAL_FIND_BIN="$REAL_FIND_BIN" REAL_TIMEOUT_BIN="$REAL_TIMEOUT_BIN"
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" TIMEOUT_ARGS_LOG="$TIMEOUT_ARGS_LOG"
  EXPECTED_READER_IMAGE="$READER_IMAGE" REGISTRY_FAIL_ROOT="$C14_ROOT"
  MOCK_ACTIVE_SCRATCH_ROOT="$C14_ROOT" DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$REG")
for d in "$OLD_READER_CLONE" "$UNBASELINED_CLONE" "$RECENT_READER_CLONE" "$UNKNOWN_LEASE_CLONE" "$ACTIVE_LEASE_CLONE"; do
  clone_into "$d"
done
age_clone_content_days() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
root, days = os.path.realpath(sys.argv[1]), int(sys.argv[2])
stamp = time.time() - days * 86400
for parent, dirs, files in os.walk(root):
    if os.path.realpath(parent) == os.path.join(root, ".git"):
        dirs[:] = []
        continue
    dirs[:] = [name for name in dirs if name != ".git"]
    for name in files:
        path = os.path.join(parent, name)
        os.utime(path, (stamp, stamp), follow_symlinks=False)
PY
}
for d in "$OLD_READER_CLONE" "$UNBASELINED_CLONE" "$UNKNOWN_LEASE_CLONE" "$ACTIVE_LEASE_CLONE"; do
  age_clone_content_days "$d" 8
done
age_clone_content_days "$RECENT_READER_CLONE" 8
touch "$RECENT_READER_CLONE/README.md"
python3 - "$RECENT_READER_CLONE" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 10 * 86400, time.time() - 10 * 86400))
PY
age_clone_content_days "$RECENT_READER_CLONE" 3
age_clone_content_days "$RECENT_READER_CLONE" 3

printf '{"min_stale_days":10}\n' >"$DISK_MAGICIAN_SAFETY_FILE"
rc=0
high_floor_out="$(env "${c14_reader_env[@]}" \
  MOCK_READER_MODE=empty bash "$SCRIPT" --dry-run --root "$C14_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "higher local safety floor also protects a clean clone" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [recent-activity] $RECENT_READER_CLONE" <<<"$high_floor_out"'
printf '{}\n' >"$DISK_MAGICIAN_SAFETY_FILE"

source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
c14_baseline() {
  local lease gitdir gitmeta
  lease="$(lease_path_for "$1")"
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir)"
  gitmeta="$(python3 "$REPO_ROOT/scripts/c14_probe.py" gitmeta "$gitdir")"
  mkdir -p "$(dirname "$lease")"
  python3 - "$lease" "$1" "$gitmeta" <<'PY'
import json, os, sys
lease, path, gitmeta = sys.argv[1:]
with open(lease, "w") as f:
    json.dump({"path": os.path.realpath(path), "owner": {"pid": 1},
               "released_at": 1, "git_meta": json.loads(gitmeta)}, f)
PY
}
c14_baseline "$OLD_READER_CLONE"
c14_baseline "$RECENT_READER_CLONE"
default_floor_out="$(env "${c14_reader_env[@]}" MOCK_READER_MODE=empty bash "$SCRIPT" --dry-run --root "$C14_ROOT" --max-depth 12 --registry-reader-image "$READER_IMAGE" 2>&1)"
check "3d-idle clone qualifies at the 48h default" '[[ "$rc" -eq 0 ]] && grep -qF "DRY RUN: would remove: $RECENT_READER_CLONE" <<<"$default_floor_out"'
c14_baseline "$RECENT_READER_CLONE"
rc=0
default_floor_out="$(env "${c14_reader_env[@]}" MOCK_READER_MODE=empty bash "$SCRIPT" --dry-run --root "$C14_ROOT" --max-depth 12 --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "3d-idle clean clone passes the shared 48h default" '[[ "$rc" -eq 0 ]] && grep -qF "DRY RUN: would remove: $RECENT_READER_CLONE" <<<"$default_floor_out"'
old_c14_verdict="$(artifact_removal_verdict "$OLD_READER_CLONE")"
check "old clone with released C14 git baseline receives an exact remove verdict" '[[ "$old_c14_verdict" == remove ]]'
unbaselined_c14_verdict="$(artifact_removal_verdict "$UNBASELINED_CLONE")"
check "unbaselined clone is kept by C14" '[[ "$unbaselined_c14_verdict" == kept:git-unbaselined ]]'

ROOT_POINTER_ROOT="$WORK/root-pointer-scratch"
ROOT_POINTER_CLONE="$ROOT_POINTER_ROOT/old-clean-clone"
ROOT_POINTER_ADMIN="$ROOT_POINTER_ROOT/root-pointer-admin"
mkdir -p "$ROOT_POINTER_ROOT"
clone_into "$ROOT_POINTER_CLONE"
age_clone_content_days "$ROOT_POINTER_CLONE" 8
c14_baseline "$ROOT_POINTER_CLONE"
root_pointer_verdict="$(artifact_removal_verdict "$ROOT_POINTER_CLONE")"
check "root-pointer fixture is otherwise C14 removable" '[[ "$root_pointer_verdict" == remove ]]'
mkdir -p "$ROOT_POINTER_ADMIN/.git/worktrees/invalid"
printf '/\n' >"$ROOT_POINTER_ADMIN/.git/worktrees/invalid/gitdir"
root_pointer_env=(PATH="$READER_BIN:$PATH" REAL_FIND_BIN="$REAL_FIND_BIN" REAL_TIMEOUT_BIN="$REAL_TIMEOUT_BIN"
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" TIMEOUT_ARGS_LOG="$TIMEOUT_ARGS_LOG"
  EXPECTED_READER_IMAGE="$READER_IMAGE" REGISTRY_FAIL_ROOT="$ROOT_POINTER_ROOT"
  MOCK_ACTIVE_SCRATCH_ROOT="$ROOT_POINTER_ROOT" DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$REG")
rc=0
root_pointer_out="$(env "${root_pointer_env[@]}" MOCK_READER_MODE=success \
  MOCK_READER_OUTPUT="/registry-root/root-pointer-admin/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$ROOT_POINTER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "root-only pointer makes registry incomplete and preserves an otherwise-removable clone" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registry-incomplete] $ROOT_POINTER_CLONE" <<<"$root_pointer_out"'

NUL_POINTER_ROOT="$WORK/nul-pointer-scratch"
NUL_POINTER_CLONE="$NUL_POINTER_ROOT/old-clean-clone"
NUL_POINTER_ADMIN="$NUL_POINTER_ROOT/nul-pointer-admin"
mkdir -p "$NUL_POINTER_ROOT"
clone_into "$NUL_POINTER_CLONE"
age_clone_content_days "$NUL_POINTER_CLONE" 8
c14_baseline "$NUL_POINTER_CLONE"
nul_pointer_verdict="$(artifact_removal_verdict "$NUL_POINTER_CLONE")"
check "NUL-pointer fixture is otherwise C14 removable" '[[ "$nul_pointer_verdict" == remove ]]'
mkdir -p "$NUL_POINTER_ADMIN/.git/worktrees/invalid"
python3 - "$NUL_POINTER_ADMIN/.git/worktrees/invalid/gitdir" "$NUL_POINTER_CLONE" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(sys.argv[2].encode() + b"\0suffix/.git\n")
PY
nul_pointer_env=(PATH="$READER_BIN:$PATH" REAL_FIND_BIN="$REAL_FIND_BIN" REAL_TIMEOUT_BIN="$REAL_TIMEOUT_BIN"
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" TIMEOUT_ARGS_LOG="$TIMEOUT_ARGS_LOG"
  EXPECTED_READER_IMAGE="$READER_IMAGE" REGISTRY_FAIL_ROOT="$NUL_POINTER_ROOT"
  MOCK_ACTIVE_SCRATCH_ROOT="$NUL_POINTER_ROOT" DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$REG")
rc=0
nul_pointer_out="$(env "${nul_pointer_env[@]}" MOCK_READER_MODE=success \
  MOCK_READER_OUTPUT="/registry-root/nul-pointer-admin/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$NUL_POINTER_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "embedded NUL pointer makes registry incomplete and preserves the C14-removable clone" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registry-incomplete] $NUL_POINTER_CLONE" <<<"$nul_pointer_out"'

BACKSLASH_ROOT="$WORK/backslash-scratch"
BACKSLASH_NAME='registered\nclone'
BACKSLASH_CLONE="$BACKSLASH_ROOT/$BACKSLASH_NAME"
BACKSLASH_ADMIN="$BACKSLASH_ROOT/backslash-admin"
mkdir -p "$BACKSLASH_ROOT"
clone_into "$BACKSLASH_CLONE"
age_clone_content_days "$BACKSLASH_CLONE" 8
c14_baseline "$BACKSLASH_CLONE"
mkdir -p "$BACKSLASH_ADMIN/.git/worktrees/registered"
printf '%s\n' "$BACKSLASH_CLONE/.git" >"$BACKSLASH_ADMIN/.git/worktrees/registered/gitdir"
backslash_reader_env=(PATH="$READER_BIN:$PATH" REAL_FIND_BIN="$REAL_FIND_BIN" REAL_TIMEOUT_BIN="$REAL_TIMEOUT_BIN"
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" TIMEOUT_ARGS_LOG="$TIMEOUT_ARGS_LOG"
  EXPECTED_READER_IMAGE="$READER_IMAGE" REGISTRY_FAIL_ROOT="$BACKSLASH_ROOT"
  MOCK_ACTIVE_SCRATCH_ROOT="$BACKSLASH_ROOT" DISK_MAGICIAN_MIRROR_REGISTRY_REPOS="$REG")
rc=0
backslash_out="$(env "${backslash_reader_env[@]}" MOCK_READER_MODE=success \
  MOCK_READER_OUTPUT="/registry-root/backslash-admin/.git/worktrees" \
  bash "$SCRIPT" --dry-run --root "$BACKSLASH_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "literal backslash in a registered Unix path is compared without escape decoding" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [registered-worktree] $BACKSLASH_CLONE" <<<"$backslash_out"'

: >"$DOCKER_ARGS_LOG"
rc=0
native_reader_out="$(env "${reader_env[@]}" MOCK_READER_MODE=empty \
  bash "$SCRIPT" --dry-run --root "$C14_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "reader mode keeps native discovery first when it succeeds" \
  '[[ "$rc" -eq 0 ]] && grep -qF "DRY RUN: would remove: $OLD_READER_CLONE" <<<"$native_reader_out" && [[ ! -s "$DOCKER_ARGS_LOG" ]]'
unknown_lease="$(lease_path_for "$UNKNOWN_LEASE_CLONE")"
mkdir -p "$(dirname "$unknown_lease")"
python3 - "$unknown_lease" "$UNKNOWN_LEASE_CLONE" <<'PY'
import json, os, sys
with open(sys.argv[1], "w") as f:
    json.dump({"path": os.path.realpath(sys.argv[2])}, f)
PY
sleep 300 &
ACTIVE_LEASE_PID=$!
active_lease="$(lease_path_for "$ACTIVE_LEASE_CLONE")"
mkdir -p "$(dirname "$active_lease")"
python3 - "$active_lease" "$ACTIVE_LEASE_CLONE" <<'PY'
import json, os, sys
with open(sys.argv[1], "w") as f:
    json.dump({"path": os.path.realpath(sys.argv[2]), "owner": None}, f)
PY
active_start="$(_lease_ps_lstart_epoch "$ACTIVE_LEASE_PID")"
lease_owner_add "$ACTIVE_LEASE_CLONE" "$ACTIVE_LEASE_PID" "$active_start" sleep
rc=0
c14_out="$(env "${c14_reader_env[@]}" \
  MOCK_READER_MODE=empty bash "$SCRIPT" --dry-run --root "$C14_ROOT" --max-depth 12 \
  --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
kill "$ACTIVE_LEASE_PID" 2>/dev/null || true
wait "$ACTIVE_LEASE_PID" 2>/dev/null || true
check "C14 retains an unknown lease" \
  '[[ "$rc" -eq 0 ]] && grep -qF "KEEP [c14:kept:owner-unknown] $UNKNOWN_LEASE_CLONE" <<<"$c14_out"'
check "C14 retains an active lease" \
  'grep -qF "KEEP [c14:kept:live-owner] $ACTIVE_LEASE_CLONE" <<<"$c14_out"'
check "C14 keeps an old clone with no git metadata baseline" \
  'grep -qF "KEEP [c14:kept:git-unbaselined] $UNBASELINED_CLONE" <<<"$c14_out"'
check "old unleased clone is previewed only after a remove verdict" \
  'grep -qF "DRY RUN: would remove: $OLD_READER_CLONE" <<<"$c14_out"'
check "dry-run leaves the old unleased clone in place" '[[ -d "$OLD_READER_CLONE" ]]'

rc=0
approved_c14_out="$(env "${c14_reader_env[@]}" \
  MOCK_READER_MODE=empty WORKTREE_APPROVED=1 bash "$SCRIPT" --clean --root "$C14_ROOT" \
  --max-depth 12 --registry-reader-image "$READER_IMAGE" 2>&1)" || rc=$?
check "approved reader-mode removal uses C14 quarantine and removes only its accepted clone" \
  '[[ "$rc" -eq 0 ]] && [[ ! -e "$OLD_READER_CLONE" ]] && [[ -d "$RECENT_READER_CLONE" && -d "$UNKNOWN_LEASE_CLONE" && -d "$ACTIVE_LEASE_CLONE" && -d "$UNBASELINED_CLONE" ]] && grep -qF "C14 removed:" <<<"$approved_c14_out"'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

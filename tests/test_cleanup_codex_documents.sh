#!/usr/bin/env bash
# test_cleanup_codex_documents.sh — coverage for the ~/Documents/Codex/<date>/<task>
# scratch sweeper (bead disk_magician-nlq5). Everything runs under a temp HOME;
# the real ~/Documents/Codex is never touched.
#
# Run: bash tests/test_cleanup_codex_documents.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/cleanup_codex_documents.sh"
# shellcheck source=tests/lib/sandbox_env.sh
source "$SCRIPT_DIR/lib/sandbox_env.sh"

TMP_ROOT=$(mktemp -d -t cleanup_codex_documents.XXXXXX)
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
SLEEPERS=()
cleanup() {
  local p
  for p in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }
assert_exists()  { if [[ -e "$2" ]]; then record_pass "$1"; else record_fail "$1" "expected to exist: $2"; fi; }
assert_missing() { if [[ ! -e "$2" ]]; then record_pass "$1"; else record_fail "$1" "expected absent: $2"; fi; }
assert_contains() {
  if grep -qF -- "$2" <<<"$3"; then record_pass "$1"; else record_fail "$1" "expected output to contain: $2"; fi
}

# Fixture HOME with a bare origin that holds a committed .gitignore.
export HOME="$TMP_ROOT/home"
export DISK_MAGICIAN_DELETION_LOG="$TMP_ROOT/deletions.log"
export DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT"
export DISK_MAGICIAN_SAFETY_FILE="$TMP_ROOT/safety.json"
echo '{"never_delete": []}' >"$DISK_MAGICIAN_SAFETY_FILE"
CODEX="$HOME/Documents/Codex"
mkdir -p "$CODEX"

ORIGIN="$TMP_ROOT/origin.git"
SEED="$TMP_ROOT/seed"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$SEED"
printf '.env\n' >"$SEED/.gitignore"
printf 'hello\n' >"$SEED/a.txt"
git -C "$SEED" add -A && git -C "$SEED" commit -qm init
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main

D_OLD=2026-09-01
age() { /usr/bin/find "$1" -exec touch -h -t 202609010000 {} +; }
mktask() { mkdir -p "$CODEX/$1/$2"; printf 'x%.0s' {1..1024} >"$CODEX/$1/$2/payload.bin"; }
clone_into() { git clone -q "$ORIGIN" "$CODEX/$1/$2/repo"; }

run_sweeper() {
  local out="$1"; shift
  local rc=0
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    bash "$SWEEPER" "$@" >"$out" 2>&1 || rc=$?
  return "$rc"
}

# --- fixtures -------------------------------------------------------------
mktask $D_OLD t-old-pushed;   clone_into $D_OLD t-old-pushed;   age "$CODEX/$D_OLD/t-old-pushed"
mktask 2026-10-10 t-young;    clone_into 2026-10-10 t-young
mktask $D_OLD t-dirty;        clone_into $D_OLD t-dirty;        echo change >>"$CODEX/$D_OLD/t-dirty/repo/a.txt"; age "$CODEX/$D_OLD/t-dirty"
mktask $D_OLD t-untracked;    clone_into $D_OLD t-untracked;    echo n >"$CODEX/$D_OLD/t-untracked/repo/new.txt"; age "$CODEX/$D_OLD/t-untracked"
mktask $D_OLD t-unpushed;     clone_into $D_OLD t-unpushed
git -C "$CODEX/$D_OLD/t-unpushed/repo" commit -q --allow-empty -m local-only; age "$CODEX/$D_OLD/t-unpushed"
mktask $D_OLD t-secret;       clone_into $D_OLD t-secret;       echo S=1 >"$CODEX/$D_OLD/t-secret/repo/.env"; age "$CODEX/$D_OLD/t-secret"
mktask $D_OLD t-ignored-data; clone_into $D_OLD t-ignored-data
printf 'data/\n' >>"$CODEX/$D_OLD/t-ignored-data/repo/.git/info/exclude"
mkdir "$CODEX/$D_OLD/t-ignored-data/repo/data"; echo d >"$CODEX/$D_OLD/t-ignored-data/repo/data/db.sqlite"; age "$CODEX/$D_OLD/t-ignored-data"
mktask $D_OLD t-rebuildable; clone_into $D_OLD t-rebuildable
printf 'test-results/\n' >>"$CODEX/$D_OLD/t-rebuildable/repo/.git/info/exclude"
mkdir "$CODEX/$D_OLD/t-rebuildable/repo/test-results"; echo generated >"$CODEX/$D_OLD/t-rebuildable/repo/test-results/results.xml"; age "$CODEX/$D_OLD/t-rebuildable"
mktask $D_OLD t-live;         clone_into $D_OLD t-live;         age "$CODEX/$D_OLD/t-live"
( cd "$CODEX/$D_OLD/t-live/repo" && exec sleep 300 ) & SLEEPERS+=("$!")
mktask $D_OLD t-scratch;      mkdir -p "$CODEX/$D_OLD/t-scratch/advice-results"; echo r >"$CODEX/$D_OLD/t-scratch/advice-results/r.md"; age "$CODEX/$D_OLD/t-scratch"
mktask $D_OLD t-protected;    age "$CODEX/$D_OLD/t-protected"
mktask 2026-09-02 t-only;     age "$CODEX/2026-09-02/t-only"   # sole task of its date dir
# linked worktrees whose main repo lives outside the task dir
MAIN="$TMP_ROOT/main-repo"; git clone -q "$ORIGIN" "$MAIN"
mktask $D_OLD t-wt-clean
git -C "$MAIN" worktree add -q -b wt-clean "$CODEX/$D_OLD/t-wt-clean/wt" origin/main
git -C "$MAIN" push -q origin wt-clean; git -C "$CODEX/$D_OLD/t-wt-clean/wt" branch -q -u origin/wt-clean
age "$CODEX/$D_OLD/t-wt-clean"
mktask $D_OLD t-wt-unpushed
git -C "$MAIN" worktree add -q -b wt-unpushed "$CODEX/$D_OLD/t-wt-unpushed/wt" origin/main
git -C "$CODEX/$D_OLD/t-wt-unpushed/wt" commit -q --allow-empty -m wt-local; age "$CODEX/$D_OLD/t-wt-unpushed"
# --- round-2 fixtures (data-loss paths) ---
C="$CODEX/$D_OLD"
mktask $D_OLD t-bare; git clone -q --bare "$ORIGIN" "$C/t-bare/b.git"
git clone -q "$ORIGIN" "$TMP_ROOT/pushbare" && git -C "$TMP_ROOT/pushbare" checkout -q -b uniq && git -C "$TMP_ROOT/pushbare" commit -q --allow-empty -m uniq && git -C "$TMP_ROOT/pushbare" push -q "$C/t-bare/b.git" uniq
age "$C/t-bare"
mktask $D_OLD t-inremote; git clone -q "$ORIGIN" "$C/t-inremote/local"
git clone -q "$C/t-inremote/local" "$C/t-inremote/w"; git -C "$C/t-inremote/w" commit -q --allow-empty -m only-in-task
git -C "$C/t-inremote/w" push -q origin HEAD:refs/heads/feat; age "$C/t-inremote"
mktask $D_OLD t-tag; clone_into $D_OLD t-tag
git -C "$C/t-tag/repo" checkout -q --detach && git -C "$C/t-tag/repo" commit -q --allow-empty -m tagonly && git -C "$C/t-tag/repo" tag keepme && git -C "$C/t-tag/repo" checkout -q main; age "$C/t-tag"
mktask $D_OLD t-detached-ok; clone_into $D_OLD t-detached-ok; git -C "$C/t-detached-ok/repo" checkout -q --detach; age "$C/t-detached-ok"
mktask $D_OLD t-detached-bad; clone_into $D_OLD t-detached-bad
git -C "$C/t-detached-bad/repo" checkout -q --detach && git -C "$C/t-detached-bad/repo" commit -q --allow-empty -m det; age "$C/t-detached-bad"
mktask $D_OLD t-localbranch; clone_into $D_OLD t-localbranch
git -C "$C/t-localbranch/repo" branch side && git -C "$C/t-localbranch/repo" checkout -q side && git -C "$C/t-localbranch/repo" commit -q --allow-empty -m side && git -C "$C/t-localbranch/repo" checkout -q main; age "$C/t-localbranch"
mktask $D_OLD t-stash; clone_into $D_OLD t-stash
echo s >>"$C/t-stash/repo/a.txt"; git -C "$C/t-stash/repo" stash -q; age "$C/t-stash"
ORIGIN2="$TMP_ROOT/origin2.git"; SEED2="$TMP_ROOT/seed2"; git init -q --bare -b main "$ORIGIN2"
git clone -q "$ORIGIN2" "$SEED2" 2>/dev/null; git -C "$SEED2" checkout -q -b main 2>/dev/null || true
git -C "$SEED2" -c protocol.file.allow=always submodule add -q "$ORIGIN" sub 2>/dev/null
git -C "$SEED2" commit -qm sub && git -C "$SEED2" push -q origin main
mktask $D_OLD t-submod; git -c protocol.file.allow=always clone -q --recurse-submodules "$ORIGIN2" "$C/t-submod/repo"
echo u >"$C/t-submod/repo/sub/untracked.txt"; age "$C/t-submod"
mktask $D_OLD t-extwt; clone_into $D_OLD t-extwt; git -C "$C/t-extwt/repo" worktree add -q "$TMP_ROOT/ext-wt" -b extb origin/main; age "$C/t-extwt"
mktask $D_OLD t-locked
git -C "$MAIN" worktree add -q --detach "$C/t-locked/wt" origin/main && git -C "$MAIN" worktree lock "$C/t-locked/wt"; age "$C/t-locked"
mktask $D_OLD t-multiwt
git -C "$MAIN" worktree add -q --detach "$C/t-multiwt/w1" origin/main; git -C "$MAIN" worktree add -q --detach "$C/t-multiwt/w2" origin/main; age "$C/t-multiwt"
mkdir -p "$TMP_ROOT/symtarget"; echo keep >"$TMP_ROOT/symtarget/f"; ln -s "$TMP_ROOT/symtarget" "$C/t-symlink"
mktask $D_OLD t-fileopen; echo o >"$C/t-fileopen/open.log"; age "$C/t-fileopen"
( cd / && exec 3<"$C/t-fileopen/open.log" && exec sleep 300 ) & SLEEPERS+=("$!")
sleep 1
echo "{\"never_delete\": [\"$CODEX/$D_OLD/t-protected\"]}" >"$DISK_MAGICIAN_SAFETY_FILE"

echo "=== cleanup_codex_documents.sh tests ==="

echo "T1: dry-run default deletes nothing"
O1="$TMP_ROOT/o1"; RC=0; run_sweeper "$O1" || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T1: exits 0" || record_fail "T1: exits 0" "rc=$RC"
assert_contains "T1: reports would-remove" "would remove" "$(cat "$O1")"
assert_exists "T1: old pushed clone still present" "$CODEX/$D_OLD/t-old-pushed"
assert_exists "T1: scratch still present" "$CODEX/$D_OLD/t-scratch"

echo "T2: --clean removes/keeps per policy"
O2="$TMP_ROOT/o2"; RC=0; run_sweeper "$O2" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T2: exits 0" || { record_fail "T2: exits 0" "rc=$RC"; cat "$O2"; }
assert_missing "old clean pushed clone removed" "$CODEX/$D_OLD/t-old-pushed"
assert_exists  "young task kept" "$CODEX/2026-10-10/t-young"
assert_exists  "dirty nested repo kept" "$CODEX/$D_OLD/t-dirty"
assert_exists  "untracked file kept" "$CODEX/$D_OLD/t-untracked"
assert_exists  "unpushed commits kept" "$CODEX/$D_OLD/t-unpushed"
assert_exists  "ignored .env kept" "$CODEX/$D_OLD/t-secret"
assert_exists  "ignored user data kept" "$CODEX/$D_OLD/t-ignored-data"
assert_missing "current-base rebuildable test-results removed" "$CODEX/$D_OLD/t-rebuildable"
assert_exists  "live cwd process kept" "$CODEX/$D_OLD/t-live"
assert_missing "non-git old scratch removed" "$CODEX/$D_OLD/t-scratch"
assert_exists  "safety never_delete kept" "$CODEX/$D_OLD/t-protected"
assert_missing "clean pushed linked worktree task removed" "$CODEX/$D_OLD/t-wt-clean"
if git -C "$MAIN" worktree list --porcelain | grep -q "t-wt-clean"; then
  record_fail "main repo no longer lists removed worktree" "$(git -C "$MAIN" worktree list)"
else record_pass "main repo no longer lists removed worktree"; fi
assert_exists  "linked worktree with unpushed commit kept" "$CODEX/$D_OLD/t-wt-unpushed"
assert_exists  "bare repo with unique branch kept" "$C/t-bare"
assert_exists  "work pushed only to in-task remote kept" "$C/t-inremote"
assert_exists  "tag-only commit kept" "$C/t-tag"
assert_missing "detached HEAD on pushed commit removed" "$C/t-detached-ok"
assert_exists  "detached HEAD on unpushed commit kept" "$C/t-detached-bad"
assert_exists  "local-only branch kept" "$C/t-localbranch"
assert_exists  "stash kept" "$C/t-stash"
assert_exists  "dirty submodule kept" "$C/t-submod"
assert_exists  "repo with external worktree kept" "$C/t-extwt"
assert_exists  "locked linked worktree kept" "$C/t-locked"
assert_missing "multi linked-worktree task removed" "$C/t-multiwt"
if git -C "$MAIN" worktree list --porcelain | grep -q "t-multiwt"; then record_fail "multi worktrees all unregistered" "still listed"; else record_pass "multi worktrees all unregistered"; fi
assert_exists  "symlink task kept" "$C/t-symlink"
assert_exists  "symlink target untouched" "$TMP_ROOT/symtarget/f"
assert_exists  "file open by process kept" "$C/t-fileopen"
assert_missing "emptied date dir removed" "$CODEX/2026-09-02"
assert_exists  "date dir with kept tasks stays" "$CODEX/$D_OLD"
assert_contains "deletion log written" "cleanup_codex_documents.sh" "$(cat "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null || true)"

echo "T3: lsof unavailable fails closed"
mktask $D_OLD t-nolsof; age "$CODEX/$D_OLD/t-nolsof"
O3="$TMP_ROOT/o3"; RC=0
DISK_MAGICIAN_LSOF_BIN=/nonexistent/lsof run_sweeper "$O3" --clean || RC=$?
assert_exists "lsof missing -> kept" "$CODEX/$D_OLD/t-nolsof"

echo "T4: diskm dispatch (dry-run)"
O4="$TMP_ROOT/o4"; RC=0
bash "$REPO_ROOT/disk_magician.sh" cleanup-codex-documents >"$O4" 2>&1 || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T4: dispatch exits 0" || record_fail "T4: dispatch exits 0" "rc=$RC"
assert_contains "T4: dry-run banner" "DRY RUN" "$(cat "$O4")"
assert_contains "T4: help lists command" "cleanup-codex-documents" "$(bash "$REPO_ROOT/disk_magician.sh" help 2>&1 || true)"

echo "T5: inherited Git variables are scrubbed and an unreadable worktree path fails closed"
mktask $D_OLD t-poisoned-env; clone_into $D_OLD t-poisoned-env; age "$CODEX/$D_OLD/t-poisoned-env"
mktask $D_OLD t-path-unreadable
git -C "$MAIN" worktree add -q --detach "$CODEX/$D_OLD/t-path-unreadable/wt" origin/main
age "$CODEX/$D_OLD/t-path-unreadable"
POISON="$TMP_ROOT/poison"
git clone -q "$ORIGIN" "$POISON"
echo dirty >>"$POISON/a.txt"
pwd() {
  local physical
  physical="$(builtin pwd -P)"
  case "$physical" in
    */t-path-unreadable/wt) return 1 ;;
    *) printf '%s\n' "$physical" ;;
  esac
}
export -f pwd
O5="$TMP_ROOT/o5"; RC=0
GIT_DIR="$POISON/.git" GIT_WORK_TREE="$POISON" GIT_INDEX_FILE="$POISON/.git/index" \
  run_sweeper "$O5" --clean || RC=$?
unset -f pwd
[[ "$RC" -eq 0 ]] && record_pass "T5: exits 0" || { record_fail "T5: exits 0" "rc=$RC"; cat "$O5"; }
assert_missing "T5: eligible task removed despite poisoned Git environment" "$CODEX/$D_OLD/t-poisoned-env"
assert_contains "T5: caller repository remains untouched" "dirty" "$(tail -n 1 "$POISON/a.txt")"
assert_exists "T5: linked worktree with unreadable physical path is kept" "$CODEX/$D_OLD/t-path-unreadable"
assert_contains "T5: reports unreadable worktree path" "worktree-path-unreadable" "$(cat "$O5")"

echo "T6: failed removal is kept and does not abort the sweep"
mktask $D_OLD t-rm-fail; age "$CODEX/$D_OLD/t-rm-fail"
chmod 500 "$CODEX/$D_OLD/t-rm-fail"
O6="$TMP_ROOT/o6"; RC=0; run_sweeper "$O6" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T6: exits 0" || { record_fail "T6: exits 0" "rc=$RC"; cat "$O6"; }
assert_exists "T6: task remains after rm failure" "$CODEX/$D_OLD/t-rm-fail"
assert_contains "T6: reports fail-closed reason" "KEEP [rm-failed]" "$(cat "$O6")"
chmod 700 "$CODEX/$D_OLD/t-rm-fail"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

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

# C14/quarantine is a dependency owned by other tasks. The caller suite exercises
# its gates and routing against a minimal double (DISK_MAGICIAN_QUARANTINE_LIB);
# the T11-T14 regressions below use the real scripts/lib/quarantine.sh instead.
QUARANTINE_STUB="$TMP_ROOT/quarantine_stub.sh"
cat >"$QUARANTINE_STUB" <<'STUB'
quarantine_remove() {
  local p="${1:-}"; shift || true
  if rm -rf -- "$p" 2>/dev/null && [[ ! -e "$p" ]]; then printf 'removed:stub\n'; else printf 'kept:rm-failed\n'; fi
}
wrh_remove_now() {
  local real="$1"
  [[ "${3:-}" == --quarantine ]] || return 1
  real="$(cd "$real" 2>/dev/null && pwd -P)" || return 1
  local common main
  common="$(git -C "$real" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) ;; *) common="$real/$common" ;; esac
  main="$(dirname "$common")"
  git -C "$main" worktree remove --force "$real" >/dev/null 2>&1 || return 1
  return 0
}
STUB
export DISK_MAGICIAN_QUARANTINE_LIB="$QUARANTINE_STUB"
REAL_QUARANTINE_LIB="$REPO_ROOT/scripts/lib/quarantine.sh"

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
if grep -F "$CODEX/$D_OLD/t-rm-fail" "$DISK_MAGICIAN_DELETION_LOG" 2>/dev/null | grep -q $'\tremoved\t'; then
  record_fail "T6: failed removal is not audited as removed" "found a removed audit entry"
else record_pass "T6: failed removal is not audited as removed"; fi
chmod 700 "$CODEX/$D_OLD/t-rm-fail"

FAKE_LSOF="$TMP_ROOT/fake-lsof"
cat >"$FAKE_LSOF" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "${FAKE_LSOF_COUNT:-}" ]] && read -r count <"$FAKE_LSOF_COUNT"
count=$(( count + 1 ))
[[ -n "${FAKE_LSOF_COUNT:-}" ]] && printf '%s\n' "$count" >"$FAKE_LSOF_COUNT"
if [[ "$count" -eq 2 ]]; then
  case "${FAKE_LSOF_MODE:-closed}" in
    recent) echo changed >>"$FAKE_LSOF_TARGET/payload.bin" ;;
    dirty-old)
      echo local >"$FAKE_LSOF_TARGET/repo/local.txt"
      touch -t 202609010000 "$FAKE_LSOF_TARGET/repo/local.txt"
      ;;
  esac
fi
printf 'p1\nfcwd\nn%s\n' "${FAKE_LSOF_PATH:-/tmp/outside-codex-task}"
EOF
chmod +x "$FAKE_LSOF"

echo "T7: macOS firmlink alias from lsof protects the physical task path"
ALIAS_HOME="$TMP_ROOT/alias-home"; ALIAS_CODEX="$ALIAS_HOME/Documents/Codex"; ALIAS_TASK="$ALIAS_CODEX/$D_OLD/t-alias"
mkdir -p "$ALIAS_TASK"; echo data >"$ALIAS_TASK/payload.bin"; age "$ALIAS_TASK"
export FAKE_LSOF_MODE=alias FAKE_LSOF_PATH="/System/Volumes/Data$ALIAS_TASK" FAKE_LSOF_COUNT="$TMP_ROOT/alias-count" FAKE_LSOF_TARGET="$ALIAS_TASK"
O7="$TMP_ROOT/o7"; RC=0
HOME="$ALIAS_HOME" DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" run_sweeper "$O7" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T7: exits 0" || { record_fail "T7: exits 0" "rc=$RC"; cat "$O7"; }
assert_exists "T7: alias-form live path keeps task" "$ALIAS_TASK"
assert_contains "T7: reports live process" "KEEP [live-process]" "$(cat "$O7")"

echo "T8: recency is rechecked after the final lsof scan"
RECENT_HOME="$TMP_ROOT/recent-home"; RECENT_CODEX="$RECENT_HOME/Documents/Codex"; RECENT_TASK="$RECENT_CODEX/$D_OLD/t-recent-race"
mkdir -p "$RECENT_TASK"; echo data >"$RECENT_TASK/payload.bin"; age "$RECENT_TASK"
export FAKE_LSOF_MODE=recent FAKE_LSOF_PATH=/tmp/outside-codex-task FAKE_LSOF_COUNT="$TMP_ROOT/recent-count" FAKE_LSOF_TARGET="$RECENT_TASK"
O8="$TMP_ROOT/o8"; RC=0
HOME="$RECENT_HOME" DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" run_sweeper "$O8" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T8: exits 0" || { record_fail "T8: exits 0" "rc=$RC"; cat "$O8"; }
assert_exists "T8: task changed during lsof is kept" "$RECENT_TASK"
assert_contains "T8: reports recent recheck" "KEEP [recent-recheck]" "$(cat "$O8")"

echo "T9: Git state is rechecked after the final lsof scan"
DIRTY_HOME="$TMP_ROOT/dirty-home"; DIRTY_CODEX="$DIRTY_HOME/Documents/Codex"; DIRTY_TASK="$DIRTY_CODEX/$D_OLD/t-dirty-race"
mkdir -p "$DIRTY_TASK"; git clone -q "$ORIGIN" "$DIRTY_TASK/repo"; age "$DIRTY_TASK"
export FAKE_LSOF_MODE=dirty-old FAKE_LSOF_PATH=/tmp/outside-codex-task FAKE_LSOF_COUNT="$TMP_ROOT/dirty-count" FAKE_LSOF_TARGET="$DIRTY_TASK"
O9="$TMP_ROOT/o9"; RC=0
HOME="$DIRTY_HOME" DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" run_sweeper "$O9" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T9: exits 0" || { record_fail "T9: exits 0" "rc=$RC"; cat "$O9"; }
assert_exists "T9: task dirtied during lsof is kept" "$DIRTY_TASK"
assert_contains "T9: reports dirty Git recheck" "KEEP [recheck:dirty:" "$(cat "$O9")"

echo "T10: partial linked-worktree removal is audited"
PART_HOME="$TMP_ROOT/partial-home"; PART_CODEX="$PART_HOME/Documents/Codex"; PART_TASK="$PART_CODEX/$D_OLD/t-partial-wt"
mkdir -p "$PART_TASK"
git -C "$MAIN" worktree add -q --detach "$PART_TASK/w1" origin/main
git -C "$MAIN" worktree add -q --detach "$PART_TASK/w2" origin/main
age "$PART_TASK"
REAL_GIT_BIN="$(command -v git)"; FAKE_GIT_BIN="$TMP_ROOT/fake-git-bin"; mkdir -p "$FAKE_GIT_BIN"
cat >"$FAKE_GIT_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove "* ]]; then
  count=0
  [[ -f "$FAKE_GIT_COUNT" ]] && read -r count <"$FAKE_GIT_COUNT"
  count=$(( count + 1 ))
  printf '%s\n' "$count" >"$FAKE_GIT_COUNT"
  [[ "$count" -eq 2 ]] && exit 1
fi
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$FAKE_GIT_BIN/git"
export FAKE_LSOF_MODE=closed FAKE_LSOF_PATH=/tmp/outside-codex-task FAKE_LSOF_COUNT="$TMP_ROOT/partial-lsof-count" FAKE_LSOF_TARGET="$PART_TASK"
export REAL_GIT_BIN FAKE_GIT_COUNT="$TMP_ROOT/git-remove-count"
PART_LOG="$TMP_ROOT/partial-deletions.log"; O10="$TMP_ROOT/o10"; RC=0
HOME="$PART_HOME" PATH="$FAKE_GIT_BIN:$PATH" DISK_MAGICIAN_LSOF_BIN="$FAKE_LSOF" DISK_MAGICIAN_DELETION_LOG="$PART_LOG" run_sweeper "$O10" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T10: exits 0" || { record_fail "T10: exits 0" "rc=$RC"; cat "$O10"; }
assert_exists "T10: task remains after second unregister fails" "$PART_TASK"
assert_contains "T10: reports worktree removal failure" "KEEP [wrh-quarantine-failed:" "$(cat "$O10")"
assert_contains "T10: partial worktree removal is audited" $'\tpartial\t' "$(grep -F "$PART_TASK" "$PART_LOG" 2>/dev/null || true)"
unset FAKE_LSOF_MODE FAKE_LSOF_PATH FAKE_LSOF_COUNT FAKE_LSOF_TARGET REAL_GIT_BIN FAKE_GIT_COUNT

echo "T11: real C14 keeps a provenance-less old task"
PL_HOME="$TMP_ROOT/pl-home"; PL_CODEX="$PL_HOME/Documents/Codex"; PL_TASK="$PL_CODEX/$D_OLD/t-doc"
mkdir -p "$PL_TASK"; printf 'unique\n' >"$PL_TASK/report.md"; age "$PL_TASK"
O11="$TMP_ROOT/o11"; RC=0
HOME="$PL_HOME" DISK_MAGICIAN_QUARANTINE_LIB="$REAL_QUARANTINE_LIB" run_sweeper "$O11" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T11: exits 0" || { record_fail "T11: exits 0" "rc=$RC"; cat "$O11"; }
assert_exists "T11: provenance-less document kept" "$PL_TASK"
assert_contains "T11: reports unproven content" "KEEP [unproven-content]" "$(cat "$O11")"

echo "T12: real C14 keeps a dirty/unpushed nested repo"
DR_HOME="$TMP_ROOT/dr-home"; DR_CODEX="$DR_HOME/Documents/Codex"; DR_TASK="$DR_CODEX/$D_OLD/t-nested"
mkdir -p "$DR_TASK"; git clone -q "$ORIGIN" "$DR_TASK/repo"
git -C "$DR_TASK/repo" commit -q --allow-empty -m local-only
age "$DR_TASK"
O12="$TMP_ROOT/o12"; RC=0
HOME="$DR_HOME" DISK_MAGICIAN_QUARANTINE_LIB="$REAL_QUARANTINE_LIB" run_sweeper "$O12" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T12: exits 0" || { record_fail "T12: exits 0" "rc=$RC"; cat "$O12"; }
assert_exists "T12: unpushed nested repo kept" "$DR_TASK"
assert_contains "T12: reports unpushed head" "KEEP [unpushed-head:" "$(cat "$O12")"

echo "T13: real C14 + quarantine removes an eligible ephemeral fixture"
QC_HOME="$TMP_ROOT/qc-home"; QC_CODEX="$QC_HOME/Documents/Codex"; QC_DATE="$QC_CODEX/$D_OLD"; QC_TASK="$QC_DATE/pr-123"
mkdir -p "$QC_TASK"; printf 'generated\n' >"$QC_TASK/results.json"; age "$QC_TASK"
O13="$TMP_ROOT/o13"; RC=0
HOME="$QC_HOME" DISK_MAGICIAN_QUARANTINE_LIB="$REAL_QUARANTINE_LIB" \
  DISK_MAGICIAN_CODEX_KIND=ephemeral DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$QC_DATE" \
  run_sweeper "$O13" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T13: exits 0" || { record_fail "T13: exits 0" "rc=$RC"; cat "$O13"; }
assert_missing "T13: eligible ephemeral task removed via quarantine" "$QC_TASK"
assert_contains "T13: routed through C14/quarantine" "via C14/quarantine" "$(cat "$O13")"

echo "T14: replacement race after nomination keeps the artifact"
RC_HOME="$TMP_ROOT/rc-home"; RC_CODEX="$RC_HOME/Documents/Codex"; RC_DATE="$RC_CODEX/$D_OLD"; RC_TASK="$RC_DATE/pr-456"
mkdir -p "$RC_TASK"; printf 'generated\n' >"$RC_TASK/results.json"; age "$RC_TASK"
O14="$TMP_ROOT/o14"; RC=0
HOME="$RC_HOME" DISK_MAGICIAN_QUARANTINE_LIB="$REAL_QUARANTINE_LIB" \
  DISK_MAGICIAN_CODEX_KIND=ephemeral DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$RC_DATE" \
  DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_AFTER_NOMINATE="$RC_TASK/raced.txt" \
  run_sweeper "$O14" --clean || RC=$?
[[ "$RC" -eq 0 ]] && record_pass "T14: exits 0" || { record_fail "T14: exits 0" "rc=$RC"; cat "$O14"; }
assert_exists "T14: raced replacement kept" "$RC_TASK"
assert_contains "T14: reports recent activity" "recent-activity" "$(cat "$O14")"
unset DISK_MAGICIAN_QUARANTINE_LIB

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

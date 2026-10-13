#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/worktree_remove_hook.sh"
HELPER="$REPO_ROOT/scripts/worktree_quarantine.py"
TMPROOT="$(mktemp -d /tmp/dm-wrh-test.XXXXXX)"
CANON_TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap '[[ -n "$TMPROOT" && "$TMPROOT" == /tmp/dm-wrh-test.* ]] && rm -rf -- "$TMPROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=jleechan2015@users.noreply.github.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=jleechan2015@users.noreply.github.com
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (expected '$2', got '$1')"; }

mkdir -p "$TMPROOT/main"
git init -q "$TMPROOT/main"
git -C "$TMPROOT/main" config user.name test
git -C "$TMPROOT/main" config user.email test@example.com
printf 'base\n' > "$TMPROOT/main/base"
git -C "$TMPROOT/main" add base
git -C "$TMPROOT/main" commit -qm base
git -C "$TMPROOT/main" worktree add -q -b worktree-a "$TMPROOT/a"
git -C "$TMPROOT/main" worktree add -q -b feature-b "$TMPROOT/b"
ADMIN_A="$(git -C "$TMPROOT/a" rev-parse --absolute-git-dir)"
ADMIN_B="$(git -C "$TMPROOT/b" rev-parse --absolute-git-dir)"
mkdir -p "$ADMIN_B/logs"
printf 'sibling-head-log\n' >> "$ADMIN_B/logs/HEAD"
git -C "$TMPROOT/main" update-ref refs/rewritten/sibling-private HEAD
SIBLING_ADMIN_HASH="$(find "$ADMIN_B" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')"
SIBLING_REWRITTEN="$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')"
SIBLING_HEAD_LOG="$(shasum -a 256 "$ADMIN_B/logs/HEAD" | awk '{print $1}')"

# wrh_receipt <worktree> <out>: build the legitimate C14 receipt shape (checkout
# inventory plus the selected worktree's own admin rows) so WRH binds to the same
# merged format that artifact_removal_verdict --inventory-out produces.
wrh_receipt() {
    local wt="$1" out="$2" checkout="$2.checkout" admin_rows="$2.admin"
    python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$wt" "$checkout" >/dev/null || return 1
    : > "$admin_rows"
    local admin; admin="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
    C14_INVENTORY_OUT="$admin_rows" python3 "$REPO_ROOT/scripts/c14_probe.py" admin "$admin" >/dev/null || return 1
    python3 "$REPO_ROOT/scripts/c14_probe.py" merge-inventory "$checkout" "$admin_rows" "$out" >/dev/null || return 1
    rm -f "$checkout" "$admin_rows"
}

echo '== phase 1 then restore keeps the linked worktree usable =='
wrh_receipt "$TMPROOT/a" "$TMPROOT/a-inventory.json"
result="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/a" "$TMPROOT/a-inventory.json")"
echo "  phase-1 result: $result"
assert_eq "${result%%:*}" quarantined 'phase 1 moved the checkout under quarantine'
qid="${result#quarantined:}"
[[ -e "$TMPROOT/.dm-quarantine/$qid" ]] && ok 'checkout remains in quarantine' || bad 'quarantined checkout missing'
restore="$(python3 "$HELPER" restore "$qid")"
assert_eq "${restore%%:*}" restored 'restore completed'
[[ -d "$TMPROOT/a" ]] && ok 'original worktree path restored' || bad 'original path missing'
git -C "$TMPROOT/a" status --porcelain >/dev/null && ok 'restored worktree is usable' || bad 'restored worktree status failed'

echo '== recreated original path remains a recoverable quarantine =='
git -C "$TMPROOT/main" worktree add -q -b recreated-path "$TMPROOT/recreated-path"
wrh_receipt "$TMPROOT/recreated-path" "$TMPROOT/recreated-path.inventory.json"
result="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/recreated-path" "$TMPROOT/recreated-path.inventory.json")"
qid="${result#quarantined:}"
mkdir "$TMPROOT/recreated-path"
restore="$(python3 "$HELPER" restore "$qid")"
assert_eq "$restore" kept:restore-target-exists 'recreated original path blocks restore'
[[ -e "$TMPROOT/.dm-quarantine/$qid" ]] && ok 'blocked restore stays quarantined' || bad 'blocked restore lost quarantine'
rmdir "$TMPROOT/recreated-path"
restore="$(python3 "$HELPER" restore "$qid")"
assert_eq "${restore%%:*}" restored 'restore succeeds after conflict is removed'
git -C "$TMPROOT/recreated-path" status --porcelain >/dev/null && ok 'restored checkout is usable after conflict' || bad 'restored checkout is unusable'

echo '== crash points reconcile to the original checkout =='
for point in after_lock after_rename after_repair; do
  name="crash-$point"
  git -C "$TMPROOT/main" worktree add -q -b "$name" "$TMPROOT/$name"
  ADMIN_BEFORE="$(git -C "$TMPROOT/$name" rev-parse --absolute-git-dir)"
  GITDIR_BEFORE="$(cat "$ADMIN_BEFORE/gitdir")"
  wrh_receipt "$TMPROOT/$name" "$TMPROOT/$name.inventory.json"
  DISK_MAGICIAN_TEST_WRH_KILL_AT="$point" python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/$name" "$TMPROOT/$name.inventory.json" >/dev/null 2>&1
  crash_rc=$?
  assert_eq "$crash_rc" 137 "$point injected a process crash"
  if [[ "$point" == after_rename ]]; then
    ADMIN_CRASH="$(find "$TMPROOT/main/.git/worktrees" -mindepth 1 -maxdepth 1 -type d -name "$name" -print -quit)"
    PRE_PRUNE_HASH="$(find "$ADMIN_CRASH" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
    git -C "$TMPROOT/main" worktree prune --expire now
    [[ -d "$ADMIN_CRASH" ]] && ok 'prune retained locked quarantined admin directory' || bad 'prune removed quarantined admin directory'
    [[ "$(find "$ADMIN_CRASH" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')" == "$PRE_PRUNE_HASH" ]] && ok 'prune preserved admin bytes' || bad 'prune changed admin bytes'
  fi
  python3 "$HELPER" reconcile >/dev/null
  [[ -d "$TMPROOT/$name" ]] && ok "$point restored original path" || bad "$point lost original path"
  [[ ! -e "$(git -C "$TMPROOT/$name" rev-parse --absolute-git-dir)/locked" ]] && ok "$point removed only its own lock" || bad "$point left a lock"
  [[ "$(cat "$ADMIN_BEFORE/gitdir")" == "$GITDIR_BEFORE" ]] && ok "$point restored gitdir bytes" || bad "$point changed gitdir bytes"
  git -C "$TMPROOT/$name" status --porcelain >/dev/null && ok "$point left worktree usable" || bad "$point worktree unusable"
  listing="$(git -C "$TMPROOT/main" worktree list --porcelain)"
  if grep -qxF "worktree $CANON_TMPROOT/$name" <<<"$listing" && ! grep -qF "$CANON_TMPROOT/.dm-quarantine/" <<<"$listing"; then ok "$point reconcile left a clean worktree registry"; else bad "$point reconcile left a stale worktree registry"; fi
done

echo '== phase 2 crash point 4 preserves siblings and reconciles =='
SIBLING_ADMIN_HASH="$(find "$ADMIN_B" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
SIBLING_HEAD_LOG="$(shasum -a 256 "$ADMIN_B/logs/HEAD" 2>/dev/null | awk '{print $1}')"
SIBLING_REWRITTEN="$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')"
git -C "$TMPROOT/main" worktree add -q -b phase2-checkout-removed "$TMPROOT/phase2-checkout-removed"
ADMIN_CRASH4="$(git -C "$TMPROOT/phase2-checkout-removed" rev-parse --absolute-git-dir)"
wrh_receipt "$TMPROOT/phase2-checkout-removed" "$TMPROOT/phase2-checkout-removed.inventory.json"
result="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/phase2-checkout-removed" "$TMPROOT/phase2-checkout-removed.inventory.json")"
qid="${result#quarantined:}"
DISK_MAGICIAN_TEST_WRH_KILL_AT=after_checkout_removed python3 "$HELPER" phase2 "$qid" >/dev/null 2>&1
assert_eq "$?" 137 'phase 2 crash point 4 injected'
[[ ! -e "$TMPROOT/.dm-quarantine/$qid" ]] && ok 'crash point 4 removed checkout only after quarantine' || bad 'crash point 4 left checkout payload'
[[ -d "$ADMIN_CRASH4" ]] && ok 'crash point 4 keeps admin directory for reconciliation' || bad 'crash point 4 lost admin directory'
[[ -e "$TMPROOT/.dm-quarantine/$qid.json" ]] && ok 'crash point 4 retained sidecar' || bad 'crash point 4 lost sidecar'
[[ "$(find "$ADMIN_B" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')" == "$SIBLING_ADMIN_HASH" ]] && ok 'crash point 4 preserved sibling admin bytes' || bad 'crash point 4 changed sibling admin'
[[ "$(shasum -a 256 "$ADMIN_B/logs/HEAD" 2>/dev/null | awk '{print $1}')" == "$SIBLING_HEAD_LOG" ]] && ok 'crash point 4 preserved sibling reflog' || bad 'crash point 4 changed sibling reflog'
[[ "$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')" == "$SIBLING_REWRITTEN" ]] && ok 'crash point 4 preserved sibling private ref' || bad 'crash point 4 changed sibling private ref'
python3 "$HELPER" reconcile >/dev/null
[[ ! -e "$ADMIN_CRASH4" ]] && ok 'crash point 4 reconciliation removed selected admin' || bad 'crash point 4 left selected admin'
[[ ! -e "$TMPROOT/.dm-quarantine/$qid.json" ]] && ok 'crash point 4 reconciliation dropped sidecar' || bad 'crash point 4 left sidecar'
if git -C "$TMPROOT/main" worktree list --porcelain | grep -qxF "worktree $CANON_TMPROOT/phase2-checkout-removed"; then bad 'crash point 4 worktree remains registered'; else ok 'crash point 4 worktree absent from registry'; fi

echo '== post-verdict admin changes roll back without deleting the changed data =='
git -C "$TMPROOT/main" worktree add -q -b admin-extra "$TMPROOT/admin-extra"
ADMIN_EXTRA="$(git -C "$TMPROOT/admin-extra" rev-parse --absolute-git-dir)"
wrh_receipt "$TMPROOT/admin-extra" "$TMPROOT/admin-extra.inventory.json"
DISK_MAGICIAN_TEST_AFTER_VERDICT='admin=$(git -C "$DM_Q_PATH" rev-parse --absolute-git-dir); printf keep > "$admin/extra-admin-file"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/admin-extra" "$TMPROOT/admin-extra.inventory.json" >/dev/null
[[ -d "$TMPROOT/admin-extra" ]] && ok 'extra-admin mismatch kept the checkout' || bad 'extra-admin mismatch moved the checkout'
[[ -f "$ADMIN_EXTRA/extra-admin-file" ]] && ok 'extra admin file preserved' || bad 'extra admin file lost'
[[ ! -e "$ADMIN_EXTRA/locked" ]] && ok 'owned lock removed during rollback' || bad 'lock remained after rollback'

git -C "$TMPROOT/main" worktree add -q -b index-change "$TMPROOT/index-change"
ADMIN_INDEX="$(git -C "$TMPROOT/index-change" rev-parse --absolute-git-dir)"
wrh_receipt "$TMPROOT/index-change" "$TMPROOT/index-change.inventory.json"
DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR='printf changed > "$DM_Q_PATH/index"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/index-change" "$TMPROOT/index-change.inventory.json" >/dev/null
[[ -d "$TMPROOT/index-change" ]] && ok 'rewritten-index mismatch restored checkout' || bad 'rewritten-index mismatch lost checkout'
[[ $(cat "$ADMIN_INDEX/index") == changed ]] && ok 'rewritten index preserved' || bad 'rewritten index lost'

git -C "$TMPROOT/main" worktree add -q -b gitdir-change "$TMPROOT/gitdir-change"
ADMIN_GITDIR="$(git -C "$TMPROOT/gitdir-change" rev-parse --absolute-git-dir)"
ORIGINAL_GITDIR="$(cat "$ADMIN_GITDIR/gitdir")"
wrh_receipt "$TMPROOT/gitdir-change" "$TMPROOT/gitdir-change.inventory.json"
DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR='printf /foreign/.git > "$DM_Q_PATH/gitdir"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/gitdir-change" "$TMPROOT/gitdir-change.inventory.json" >/dev/null
[[ -d "$TMPROOT/gitdir-change" ]] && ok 'wrong gitdir mismatch restored checkout' || bad 'wrong gitdir mismatch lost checkout'
[[ $(cat "$ADMIN_GITDIR/gitdir") == "$ORIGINAL_GITDIR" ]] && ok 'rollback restored original gitdir bytes' || bad 'rollback left wrong gitdir'

git -C "$TMPROOT/main" worktree add -q -b foreign-lock "$TMPROOT/foreign-lock"
ADMIN_LOCK="$(git -C "$TMPROOT/foreign-lock" rev-parse --absolute-git-dir)"
wrh_receipt "$TMPROOT/foreign-lock" "$TMPROOT/foreign-lock.inventory.json"
DISK_MAGICIAN_TEST_AFTER_VERDICT='admin=$(git -C "$DM_Q_PATH" rev-parse --absolute-git-dir); printf foreign > "$admin/locked"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/foreign-lock" "$TMPROOT/foreign-lock.inventory.json" >/dev/null
[[ -d "$TMPROOT/foreign-lock" ]] && ok 'foreign lock kept checkout in place' || bad 'foreign lock moved checkout'
[[ $(cat "$ADMIN_LOCK/locked") == foreign ]] && ok 'foreign lock reason preserved' || bad 'foreign lock reason changed'

echo '== a mutation between C14 and phase1 is retained, not refreshed =='
git -C "$TMPROOT/main" worktree add -q -b c14-phase1-race "$TMPROOT/c14-phase1-race"
wrh_receipt "$TMPROOT/c14-phase1-race" "$TMPROOT/c14-phase1-race.inventory.json"
ADMIN_RACE="$(git -C "$TMPROOT/c14-phase1-race" rev-parse --absolute-git-dir)"
printf 'appended-after-verdict\n' >> "$ADMIN_RACE/HEAD"
race="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/c14-phase1-race" "$TMPROOT/c14-phase1-race.inventory.json")"
assert_eq "$race" kept:admin-changed 'admin mutation after the C14 receipt fails closed'
[[ -d "$TMPROOT/c14-phase1-race" ]] && ok 'race checkout retained' || bad 'race checkout moved'
[[ "$(tail -1 "$ADMIN_RACE/HEAD")" == "appended-after-verdict" ]] && ok 'race admin mutation retained' || bad 'race admin mutation lost'

echo '== WRH phase1 honors a deadline after the lock =='
git -C "$TMPROOT/main" worktree add -q -b wrh-deadline "$TMPROOT/wrh-deadline"
wrh_receipt "$TMPROOT/wrh-deadline" "$TMPROOT/wrh-deadline.inventory.json"
SLOWBIN="$TMPROOT/slowbin-wrh"; mkdir -p "$SLOWBIN"
printf '#!/bin/bash\nsleep 1.5\nexit 1\n' > "$SLOWBIN/lsof"; chmod +x "$SLOWBIN/lsof"
NOW="$(python3 -c 'import time; print(time.monotonic()+0.3)')"
START="$(python3 -c 'import time; print(time.monotonic())')"
dres="$(PATH="$SLOWBIN:$PATH" python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/wrh-deadline" "$TMPROOT/wrh-deadline.inventory.json" --deadline-at "$NOW")"
END="$(python3 -c 'import time; print(time.monotonic())')"
assert_eq "$dres" kept:deferred:deadline 'WRH phase1 defers during payload rehash'
[[ -d "$TMPROOT/wrh-deadline" ]] && ok 'deferred WRH phase1 restored the checkout' || bad 'deferred WRH phase1 lost the checkout'
if python3 -c "import sys; sys.exit(0 if (float('$END')-float('$START')) < 1.0 else 1)"; then ok 'WRH phase1 deadline bound beats the slow lsof probe'; else bad 'WRH phase1 deadline did not bound the slow lsof probe'; fi

echo '== phase 2 removes only the selected worktree =='
git -C "$TMPROOT/main" update-ref refs/rewritten/sibling-private HEAD
SIBLING_ADMIN="$(git -C "$TMPROOT/b" rev-parse --absolute-git-dir)"
ADMIN_B="$SIBLING_ADMIN"
SIBLING_ADMIN_HASH="$(find "$SIBLING_ADMIN" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
SIBLING_REWRITTEN="$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')"
SIBLING_HEAD_LOG="$(shasum -a 256 "$ADMIN_B/logs/HEAD" 2>/dev/null | awk '{print $1}')"
wrh_receipt "$TMPROOT/a" "$TMPROOT/a-inventory.json"
source "$SCRIPT"
wrh_remove_now "$TMPROOT/a" "$TMPROOT/a" --quarantine "$TMPROOT/a-inventory.json"
[[ ! -e "$TMPROOT/a" ]] && ok 'selected checkout removed' || bad 'selected checkout remains'
[[ ! -e "$ADMIN_A" ]] && ok 'selected admin directory removed' || bad 'selected admin directory remains'
[[ -d "$TMPROOT/b" ]] && ok 'sibling checkout preserved' || bad 'sibling checkout missing'
git -C "$TMPROOT/b" status --porcelain >/dev/null && ok 'sibling worktree remains usable' || bad 'sibling status failed'
if git -C "$TMPROOT/main" worktree list --porcelain | grep -qxF "worktree $TMPROOT/a"; then bad 'removed worktree still registered'; else ok 'removed worktree absent from registry'; fi
[[ "$(find "$SIBLING_ADMIN" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')" == "$SIBLING_ADMIN_HASH" ]] && ok 'sibling admin files stayed byte-identical' || bad 'sibling admin files changed'
[[ "$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')" == "$SIBLING_REWRITTEN" ]] && ok 'sibling rewritten ref stayed byte-identical' || bad 'sibling rewritten ref changed'
[[ "$(shasum -a 256 "$ADMIN_B/logs/HEAD" | awk '{print $1}')" == "$SIBLING_HEAD_LOG" ]] && ok 'sibling HEAD reflog stayed byte-identical' || bad 'sibling HEAD reflog changed'

echo '== interrupted phase 2 resumes only inside quarantine =='
for point in mid_delete; do
  name="phase2-$point"
  git -C "$TMPROOT/main" worktree add -q -b "$name" "$TMPROOT/$name"
  printf 'extra-data\n' > "$TMPROOT/$name/extra"
  wrh_receipt "$TMPROOT/$name" "$TMPROOT/$name.inventory.json"
  result="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/$name" "$TMPROOT/$name.inventory.json")"
  qid="${result#quarantined:}"
  DISK_MAGICIAN_TEST_KILL_AT="$point" python3 "$HELPER" phase2 "$qid" >/dev/null 2>&1
  assert_eq "$?" 137 "$point crash injected during phase 2"
  [[ ! -e "$TMPROOT/$name" ]] && ok "$point never partially deletes checkout outside quarantine" || bad "$point deleted outside quarantine"
  [[ -e "$TMPROOT/.dm-quarantine/$qid" ]] && ok "$point keeps sidecar and quarantine" || bad "$point lost recovery state"
  python3 "$HELPER" reconcile >/dev/null
  [[ ! -e "$TMPROOT/$name" ]] && ok "$point reconcile completed deletion" || bad "$point reconcile restored partial checkout"
  if git -C "$TMPROOT/main" worktree list --porcelain | grep -qxF "worktree $TMPROOT/$name"; then bad "$point reconciled worktree remains registered"; else ok "$point reconciled worktree absent from registry"; fi
done

echo '== every WRH external entrypoint takes the canonical operation lock =='
git -C "$TMPROOT/main" worktree add -q -b wrh-lock "$TMPROOT/wrh-lock"
wrh_receipt "$TMPROOT/wrh-lock" "$TMPROOT/wrh-lock.inventory.json"
LOCK_READY="$TMPROOT/lock-ready"; LOCK_RELEASE="$TMPROOT/lock-release"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); exec("while not os.path.exists(sys.argv[3]): time.sleep(.01)")' "$DISK_MAGICIAN_STATE_DIR/quarantine-index/operations.lock" "$LOCK_READY" "$LOCK_RELEASE" & HOLDER_PID=$!
for _ in $(seq 1 250); do [[ -e "$LOCK_READY" ]] && break; sleep 0.02; done
NOW="$(python3 -c 'import time; print(time.monotonic()+0.2)')"
R1="$(python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/wrh-lock" "$TMPROOT/wrh-lock.inventory.json" --deadline-at "$NOW")"
R2="$(python3 "$HELPER" phase2 ffffffffffffffff --deadline-at "$NOW")"
R3="$(python3 "$HELPER" restore ffffffffffffffff --deadline-at "$NOW")"
R4="$(python3 "$HELPER" reconcile --deadline-at "$NOW")"
touch "$LOCK_RELEASE"; wait "$HOLDER_PID"
assert_eq "$R1" deferred:operation-lock 'phase1 defers on held operation lock'
assert_eq "$R2" deferred:operation-lock 'phase2 defers on held operation lock'
assert_eq "$R3" deferred:operation-lock 'restore defers on held operation lock'
assert_eq "$R4" deferred:operation-lock 'reconcile defers on held operation lock'
[[ -d "$TMPROOT/wrh-lock" ]] && ok 'deferred phase1 left the worktree untouched' || bad 'deferred phase1 moved the worktree'

echo '== WRH index crash reconciles through the canonical index =='
STATE_IDX="$TMPROOT/state-index"
git -C "$TMPROOT/main" worktree add -q -b wrh-index "$TMPROOT/wrh-index"
ADMIN_WRH_INDEX="$(git -C "$TMPROOT/wrh-index" rev-parse --absolute-git-dir)"
GITDIR_WRH_INDEX="$(cat "$ADMIN_WRH_INDEX/gitdir")"
wrh_receipt "$TMPROOT/wrh-index" "$TMPROOT/wrh-index.inventory.json"
DISK_MAGICIAN_STATE_DIR="$STATE_IDX" DISK_MAGICIAN_TEST_WRH_KILL_AT=after_index python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/wrh-index" "$TMPROOT/wrh-index.inventory.json" >/dev/null 2>&1
assert_eq "$?" 137 'WRH after-index crash injected'
WRH_IDX_QID="$(python3 -c 'import os,sys; d=os.path.join(sys.argv[1],"quarantine-index"); print([n[:-5] for n in os.listdir(d) if n.endswith(".json") and len(n)==21][0])' "$STATE_IDX")"
DISK_MAGICIAN_STATE_DIR="$STATE_IDX" python3 "$HELPER" reconcile >/dev/null
[[ -d "$TMPROOT/wrh-index" ]] && ok 'after-index reconcile retained the original checkout' || bad 'after-index reconcile lost the checkout'
[[ ! -e "$STATE_IDX/quarantine-index/$WRH_IDX_QID.json" ]] && ok 'after-index reconcile cleared the preparing index' || bad 'after-index reconcile left the index'
[[ "$(cat "$ADMIN_WRH_INDEX/gitdir")" == "$GITDIR_WRH_INDEX" ]] && ok 'after-index reconcile left gitdir unchanged' || bad 'after-index reconcile changed gitdir'
git -C "$TMPROOT/wrh-index" status --porcelain >/dev/null && ok 'after-index worktree remains usable' || bad 'after-index worktree unusable'

echo '== WRH rollback publishes a terminal marker before dropping recovery state =='
STATE_RB="$TMPROOT/state-rollback"
git -C "$TMPROOT/main" worktree add -q -b wrh-rollback "$TMPROOT/wrh-rollback"
ADMIN_WRH_RB="$(git -C "$TMPROOT/wrh-rollback" rev-parse --absolute-git-dir)"
wrh_receipt "$TMPROOT/wrh-rollback" "$TMPROOT/wrh-rollback.inventory.json"
DISK_MAGICIAN_STATE_DIR="$STATE_RB" DISK_MAGICIAN_TEST_INDEX_DROP_FAIL=1 \
  DISK_MAGICIAN_TEST_AFTER_VERDICT='admin=$(git -C "$DM_Q_PATH" rev-parse --absolute-git-dir); printf keep > "$admin/extra-admin-file"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/wrh-rollback" "$TMPROOT/wrh-rollback.inventory.json" >"$TMPROOT/rb-out"
RB_OUT="$(cat "$TMPROOT/rb-out")"
WRH_RB_QID="$(python3 -c 'import os,sys; d=os.path.join(sys.argv[1],"quarantine-index"); print([n[:-5] for n in os.listdir(d) if n.endswith(".json") and len(n)==21][0])' "$STATE_RB")"
[[ "$RB_OUT" == quarantine_conflict:*:index-cleanup-failed ]] && ok 'rollback reports index cleanup failure' || bad "rollback result was '$RB_OUT'"
[[ -f "$ADMIN_WRH_RB/extra-admin-file" ]] && ok 'rollback preserved changed admin data' || bad 'rollback lost changed admin data'
[[ ! -e "$TMPROOT/.dm-quarantine/$WRH_RB_QID.json" ]] && ok 'terminal rollback dropped the sidecar' || bad 'rollback kept the sidecar'
python3 -c 'import json,sys; assert json.load(open(sys.argv[1])).get("terminal")=="rolled-back"' "$STATE_RB/quarantine-index/$WRH_RB_QID.json" && ok 'rollback index holds the durable terminal marker' || bad 'rollback index lacks terminal marker'
DISK_MAGICIAN_STATE_DIR="$STATE_RB" python3 "$HELPER" reconcile >/dev/null
[[ ! -e "$STATE_RB/quarantine-index/$WRH_RB_QID.json" ]] && ok 'reconcile cleared the terminal rollback index' || bad 'reconcile left the rollback index'
git -C "$TMPROOT/wrh-rollback" status --porcelain >/dev/null && ok 'rolled-back worktree remains usable' || bad 'rolled-back worktree unusable'

echo '== real artifact_removal_verdict --inventory-out drives wrh_remove_now =='
REALROOT="$(cd "$(mktemp -d)" && pwd -P)"; REALHOME="$REALROOT/home"; mkdir -p "$REALHOME"
REAL_ORIGIN="$REALROOT/origin.git"; REAL_SEED="$REALROOT/seed"; REAL_SEL="$REALROOT/selected"; REAL_SIB="$REALROOT/sibling"
git init -q --bare -b main "$REAL_ORIGIN"
git init -q "$REAL_SEED"; git -C "$REAL_SEED" config user.name test; git -C "$REAL_SEED" config user.email t@e
printf 'base\n' > "$REAL_SEED/base"; git -C "$REAL_SEED" add base; git -C "$REAL_SEED" commit -qm base
git -C "$REAL_SEED" remote add origin "$REAL_ORIGIN"; git -C "$REAL_SEED" push -q -u origin main
git -C "$REAL_SEED" worktree add -q -b real-selected "$REAL_SEL"
git -C "$REAL_SEL" push -q -u origin real-selected
git -C "$REAL_SEED" worktree add -q -b real-sibling "$REAL_SIB"
git -C "$REAL_SIB" commit -q --allow-empty -m "sibling unpushed"
SIB_ADMIN="$(git -C "$REAL_SIB" rev-parse --absolute-git-dir)"
SIB_ADMIN_HASH="$(find "$SIB_ADMIN" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')"
SIB_REF_HASH="$(shasum -a 256 "$REAL_SEED/.git/refs/heads/real-sibling" | awk '{print $1}')"
SIB_REFLOG_HASH="$(shasum -a 256 "$REAL_SEED/.git/logs/refs/heads/real-sibling" 2>/dev/null | awk '{print $1}')"
SIB_TIP="$(git -C "$REAL_SEED" rev-parse refs/heads/real-sibling)"
find "$REAL_SEL" -exec touch -h -t 202001010000 {} +
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
REAL_RECEIPT="$REALROOT/receipt.json"
REAL_SEL_REAL="$(cd "$REAL_SEL" && pwd -P)"
REAL_VERDICT="$(HOME="$REALHOME" artifact_removal_verdict "$REAL_SEL_REAL" --inventory-out "$REAL_RECEIPT")"
assert_eq "$REAL_VERDICT" remove 'real C14 verdict approves the pushed selected worktree'
[[ -f "$REAL_RECEIPT" ]] && ok 'verdict published the merged receipt' || bad 'verdict receipt missing'
REAL_ADMIN_ROWS="$(python3 -c 'import json,sys; print(sum(1 for e in json.load(open(sys.argv[1])) if e.get("type")=="admin"))' "$REAL_RECEIPT" 2>/dev/null)"
assert_eq "$REAL_ADMIN_ROWS" 6 'receipt carries the selected worktree admin rows'
REAL_HASH_BEFORE="$(shasum -a 256 "$REAL_RECEIPT" | awk '{print $1}')"
SAVED_STATE="$DISK_MAGICIAN_STATE_DIR"
export DISK_MAGICIAN_STATE_DIR="$REALROOT/state"
REAL_REMOVED="$(wrh_remove_now "$REAL_SEL_REAL" "$REAL_SEL" --quarantine "$REAL_RECEIPT"; echo rc=$?)"
export DISK_MAGICIAN_STATE_DIR="$SAVED_STATE"
assert_eq "${REAL_REMOVED##*rc=}" 0 'wrh_remove_now accepted the unchanged receipt'
[[ ! -e "$REAL_SEL" ]] && ok 'real selected checkout removed through C14/WRH' || bad 'real selected checkout remains'
[[ ! -e "$REAL_SEED/.git/worktrees/real-selected" ]] && ok 'real selected admin removed' || bad 'real selected admin remains'
[[ "$(shasum -a 256 "$REAL_RECEIPT" | awk '{print $1}')" == "$REAL_HASH_BEFORE" ]] && ok 'receipt bytes were not rewritten before phase1' || bad 'receipt was rewritten'
[[ -d "$REAL_SIB" ]] && ok 'real sibling checkout preserved' || bad 'real sibling checkout missing'
git -C "$REAL_SIB" status --porcelain >/dev/null && ok 'real sibling remains usable' || bad 'real sibling unusable'
[[ "$(find "$SIB_ADMIN" -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}')" == "$SIB_ADMIN_HASH" ]] && ok 'sibling admin bytes preserved' || bad 'sibling admin bytes changed'
[[ "$(shasum -a 256 "$REAL_SEED/.git/refs/heads/real-sibling" | awk '{print $1}')" == "$SIB_REF_HASH" ]] && ok 'sibling branch ref preserved' || bad 'sibling branch ref changed'
[[ "$(shasum -a 256 "$REAL_SEED/.git/logs/refs/heads/real-sibling" 2>/dev/null | awk '{print $1}')" == "$SIB_REFLOG_HASH" ]] && ok 'sibling branch reflog preserved' || bad 'sibling branch reflog changed'
git -C "$REAL_SEED" cat-file -e "$SIB_TIP^{commit}" 2>/dev/null && ok 'sibling unpushed commit preserved' || bad 'sibling unpushed commit lost'

# Dirty and unpushed selected candidates must remain kept by the real verdict.
git -C "$REAL_SEED" worktree add -q -b real-dirty "$REALROOT/dirty" origin/main
printf 'x\n' >> "$REALROOT/dirty/base"; find "$REALROOT/dirty" -exec touch -h -t 202001010000 {} +
assert_eq "$(HOME="$REALHOME" artifact_removal_verdict "$(cd "$REALROOT/dirty" && pwd -P)")" kept:dirty 'dirty selected candidate stays kept'
[[ -d "$REALROOT/dirty" ]] && ok 'dirty candidate retained' || bad 'dirty candidate removed'
git -C "$REAL_SEED" worktree add -q -b real-unpushed "$REALROOT/unpushed" origin/main
git -C "$REALROOT/unpushed" commit -q --allow-empty -m unpushed; find "$REALROOT/unpushed" -exec touch -h -t 202001010000 {} +
assert_eq "$(HOME="$REALHOME" artifact_removal_verdict "$(cd "$REALROOT/unpushed" && pwd -P)")" kept:not-pushed 'unpushed selected candidate stays kept'
[[ -d "$REALROOT/unpushed" ]] && ok 'unpushed candidate retained' || bad 'unpushed candidate removed'
rm -rf "$REALROOT"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

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

echo '== phase 1 then restore keeps the linked worktree usable =='
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/a" "$TMPROOT/a-inventory.json" >/dev/null
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
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/recreated-path" "$TMPROOT/recreated-path.inventory.json" >/dev/null
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
  python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/$name" "$TMPROOT/$name.inventory.json" >/dev/null
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
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/phase2-checkout-removed" "$TMPROOT/phase2-checkout-removed.inventory.json" >/dev/null
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
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/admin-extra" "$TMPROOT/admin-extra.inventory.json" >/dev/null
DISK_MAGICIAN_TEST_AFTER_VERDICT='admin=$(git -C "$DM_Q_PATH" rev-parse --absolute-git-dir); printf keep > "$admin/extra-admin-file"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/admin-extra" "$TMPROOT/admin-extra.inventory.json" >/dev/null
[[ -d "$TMPROOT/admin-extra" ]] && ok 'extra-admin mismatch kept the checkout' || bad 'extra-admin mismatch moved the checkout'
[[ -f "$ADMIN_EXTRA/extra-admin-file" ]] && ok 'extra admin file preserved' || bad 'extra admin file lost'
[[ ! -e "$ADMIN_EXTRA/locked" ]] && ok 'owned lock removed during rollback' || bad 'lock remained after rollback'

git -C "$TMPROOT/main" worktree add -q -b index-change "$TMPROOT/index-change"
ADMIN_INDEX="$(git -C "$TMPROOT/index-change" rev-parse --absolute-git-dir)"
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/index-change" "$TMPROOT/index-change.inventory.json" >/dev/null
DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR='printf changed > "$DM_Q_PATH/index"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/index-change" "$TMPROOT/index-change.inventory.json" >/dev/null
[[ -d "$TMPROOT/index-change" ]] && ok 'rewritten-index mismatch restored checkout' || bad 'rewritten-index mismatch lost checkout'
[[ $(cat "$ADMIN_INDEX/index") == changed ]] && ok 'rewritten index preserved' || bad 'rewritten index lost'

git -C "$TMPROOT/main" worktree add -q -b gitdir-change "$TMPROOT/gitdir-change"
ADMIN_GITDIR="$(git -C "$TMPROOT/gitdir-change" rev-parse --absolute-git-dir)"
ORIGINAL_GITDIR="$(cat "$ADMIN_GITDIR/gitdir")"
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/gitdir-change" "$TMPROOT/gitdir-change.inventory.json" >/dev/null
DISK_MAGICIAN_TEST_WRH_AFTER_REPAIR='printf /foreign/.git > "$DM_Q_PATH/gitdir"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/gitdir-change" "$TMPROOT/gitdir-change.inventory.json" >/dev/null
[[ -d "$TMPROOT/gitdir-change" ]] && ok 'wrong gitdir mismatch restored checkout' || bad 'wrong gitdir mismatch lost checkout'
[[ $(cat "$ADMIN_GITDIR/gitdir") == "$ORIGINAL_GITDIR" ]] && ok 'rollback restored original gitdir bytes' || bad 'rollback left wrong gitdir'

git -C "$TMPROOT/main" worktree add -q -b foreign-lock "$TMPROOT/foreign-lock"
ADMIN_LOCK="$(git -C "$TMPROOT/foreign-lock" rev-parse --absolute-git-dir)"
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/foreign-lock" "$TMPROOT/foreign-lock.inventory.json" >/dev/null
DISK_MAGICIAN_TEST_AFTER_VERDICT='admin=$(git -C "$DM_Q_PATH" rev-parse --absolute-git-dir); printf foreign > "$admin/locked"' \
  python3 "$HELPER" phase1 "$TMPROOT/main" "$TMPROOT/foreign-lock" "$TMPROOT/foreign-lock.inventory.json" >/dev/null
[[ -d "$TMPROOT/foreign-lock" ]] && ok 'foreign lock kept checkout in place' || bad 'foreign lock moved checkout'
[[ $(cat "$ADMIN_LOCK/locked") == foreign ]] && ok 'foreign lock reason preserved' || bad 'foreign lock reason changed'

echo '== phase 2 removes only the selected worktree =='
git -C "$TMPROOT/main" update-ref refs/rewritten/sibling-private HEAD
mkdir -p "$ADMIN_A/logs"
printf 'sibling-head-log\n' >> "$ADMIN_A/logs/HEAD"
SIBLING_ADMIN="$(git -C "$TMPROOT/b" rev-parse --absolute-git-dir)"
ADMIN_B="$SIBLING_ADMIN"
SIBLING_ADMIN_HASH="$(find "$SIBLING_ADMIN" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')"
SIBLING_REWRITTEN="$(shasum -a 256 "$TMPROOT/main/.git/refs/rewritten/sibling-private" | awk '{print $1}')"
SIBLING_HEAD_LOG="$(shasum -a 256 "$ADMIN_B/logs/HEAD" 2>/dev/null | awk '{print $1}')"
python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/a" "$TMPROOT/a-inventory.json" >/dev/null
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
  python3 "$REPO_ROOT/scripts/c14_probe.py" inventory "$TMPROOT/$name" "$TMPROOT/$name.inventory.json" >/dev/null
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

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

#!/usr/bin/env bash
# test_rescue_ref.sh — rescue_check / rescue_push against local bare-repo origins.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/rescue_ref.sh"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
export DISK_MAGICIAN_DELETION_LOG="$T/del.log"
export GIT_CONFIG_GLOBAL="$T/gitconfig"; git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main

mk() { # mk <name> -> work repo with committed file + bare origin
    git init -q --bare "$T/$1.git"; git init -q "$T/$1"
    git -C "$T/$1" remote add origin "$T/$1.git"
    echo a >"$T/$1/a.txt"; git -C "$T/$1" add a.txt; git -C "$T/$1" commit -qm init
}
state() { git -C "$1" ls-files -s; git -C "$1" status --porcelain; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

# clean tree
mk clean
ref="$(rescue_push "$T/clean")"; r=$?
[[ $r -eq 0 && "$ref" == refs/diskm-rescue/* ]] && ok "clean tree pushes" || bad "clean tree rc=$r ref=$ref"
[[ "$(git -C "$T/clean.git" rev-parse "$ref")" == "$(git -C "$T/clean" ls-remote origin "$ref" | cut -f1)" ]] && ok "ref verified on origin" || bad "ref not on origin"
grep -q $'\trescue\t' "$T/del.log" && ok "deletion log has rescue line" || bad "no rescue log line"

# dirty tracked + untracked
mk dirty
echo changed >"$T/dirty/a.txt"; echo new >"$T/dirty/u.txt"
before="$(state "$T/dirty")"
ref="$(rescue_push "$T/dirty")"; r=$?
after="$(state "$T/dirty")"
[[ $r -eq 0 ]] && ok "dirty push rc 0" || bad "dirty push rc=$r"
[[ "$before" == "$after" ]] && ok "user's index/status unchanged" || bad "index or status changed"
tree="$(git -C "$T/dirty.git" ls-tree -r --name-only "$ref")"
grep -qx u.txt <<<"$tree" && ok "untracked file captured" || bad "untracked missing"
[[ "$(git -C "$T/dirty.git" show "$ref:a.txt")" == changed ]] && ok "tracked change captured" || bad "tracked change missing"
[[ "$(git -C "$T/dirty.git" rev-parse "$ref^")" == "$(git -C "$T/dirty" rev-parse HEAD)" ]] && ok "parent is HEAD" || bad "parent not HEAD"

# unpushed commits
mk unp; echo 2 >"$T/unp/b.txt"; git -C "$T/unp" add b.txt; git -C "$T/unp" commit -qm two
ref="$(rescue_push "$T/unp")"; git -C "$T/unp.git" show "$ref:b.txt" >/dev/null 2>&1 && ok "unpushed commit rescued" || bad "unpushed commit missing"

# A dirty current branch does not preserve a separate unpublished branch.
mk branch
git -C "$T/branch" push -q origin main
git -C "$T/branch" checkout -q -b local-only
printf 'branch-only\n' >"$T/branch/local.txt"
git -C "$T/branch" add local.txt; git -C "$T/branch" commit -qm local-only
git -C "$T/branch" checkout -q main
printf 'dirty current branch\n' >"$T/branch/a.txt"
[[ "$(rc rescue_check "$T/branch")" -ne 0 ]] && ok "unpublished branch blocks rescue check" || bad "unpublished branch was not checked"
[[ "$(rc rescue_push "$T/branch")" -ne 0 ]] && ok "unpublished branch blocks rescue push" || bad "unpublished branch was lost by rescue"
[[ -z "$(git -C "$T/branch.git" for-each-ref refs/diskm-rescue)" ]] && ok "no rescue ref for unpublished branch" || bad "rescue ref created despite unpublished branch"

# Stashes and reflog-reachable commits are separate history, not HEAD's tree.
mk stash; git -C "$T/stash" push -q origin main
printf 'saved\n' >"$T/stash/a.txt"; git -C "$T/stash" stash push -qm saved
printf 'current\n' >"$T/stash/a.txt"
[[ "$(rc rescue_check "$T/stash")" -ne 0 && "$(rc rescue_push "$T/stash")" -ne 0 ]] && ok "stash blocks rescue" || bad "stash was lost by rescue"
[[ -z "$(git -C "$T/stash.git" for-each-ref refs/diskm-rescue)" ]] && ok "no rescue ref for stash" || bad "rescue ref created despite stash"

# The fresh rescue index starts at HEAD, so it cannot hold a staged blob A
# while the worktree has a different blob B for the same path.
mk staged; git -C "$T/staged" push -q origin main
printf 'staged A\n' >"$T/staged/a.txt"; git -C "$T/staged" add a.txt
printf 'unstaged B\n' >"$T/staged/a.txt"
[[ "$(rc rescue_check "$T/staged")" -ne 0 && "$(rc rescue_push "$T/staged")" -ne 0 ]] && ok "different staged/worktree versions block rescue" || bad "staged version was lost by rescue"

mk hidden; git -C "$T/hidden" push -q origin main
git -C "$T/hidden" update-index --assume-unchanged a.txt
printf 'hidden dirty A\n' >"$T/hidden/a.txt"
[[ "$(rc rescue_check "$T/hidden")" -ne 0 && "$(rc rescue_push "$T/hidden")" -ne 0 ]] && ok "hidden index state blocks rescue" || bad "hidden index state was lost by rescue"

# A deleted local branch can leave its only commit in the reflog.
mk reflog; git -C "$T/reflog" push -q origin main
git -C "$T/reflog" checkout -q -b temp-only
printf 'reflog-only\n' >"$T/reflog/r.txt"; git -C "$T/reflog" add r.txt; git -C "$T/reflog" commit -qm reflog-only
git -C "$T/reflog" checkout -q main; git -C "$T/reflog" branch -D -q temp-only
printf 'dirty\n' >"$T/reflog/a.txt"
[[ "$(rc rescue_check "$T/reflog")" -ne 0 && "$(rc rescue_push "$T/reflog")" -ne 0 ]] && ok "reflog-only commit blocks rescue" || bad "reflog-only commit was lost by rescue"

# An unreachable blob is outside the HEAD-parented rescue tree.
mk dangling; git -C "$T/dangling" push -q origin main
printf 'private object\n' | git -C "$T/dangling" hash-object -w --stdin >/dev/null
printf 'dirty\n' >"$T/dangling/a.txt"
[[ "$(rc rescue_check "$T/dangling")" -ne 0 && "$(rc rescue_push "$T/dangling")" -ne 0 ]] && ok "unreachable object blocks rescue" || bad "unreachable object was lost by rescue"

# unborn
git init -q --bare "$T/unb.git"; git init -q "$T/unb"; git -C "$T/unb" remote add origin "$T/unb.git"; echo x >"$T/unb/x.txt"
ref="$(rescue_push "$T/unb")"; r=$?
[[ $r -eq 0 && -z "$(git -C "$T/unb.git" rev-list --parents -n1 "$ref" | cut -s -d' ' -f2)" ]] && ok "unborn branch: parentless commit" || bad "unborn failed rc=$r"

# secret-like
mk sec; echo k >"$T/sec/server.pem"
[[ "$(rc rescue_check "$T/sec")" -ne 0 ]] && ok "secret blocks check" || bad "secret did not block check"
[[ "$(rc rescue_push "$T/sec")" -ne 0 ]] && ok "secret blocks push" || bad "secret did not block push"
[[ -z "$(git -C "$T/sec.git" for-each-ref refs/diskm-rescue)" ]] && ok "nothing pushed for secret" || bad "ref pushed despite secret"

# non-secret ignored user data is not part of the rescue snapshot
mk ignored; echo 'local.db' >"$T/ignored/.gitignore"; echo state >"$T/ignored/local.db"
[[ "$(rc rescue_check "$T/ignored")" -ne 0 && "$(rc rescue_push "$T/ignored")" -ne 0 ]] && ok "ignored user data blocks rescue" || bad "ignored user data passed rescue"
[[ -z "$(git -C "$T/ignored.git" for-each-ref refs/diskm-rescue)" ]] && ok "nothing pushed for ignored data" || bad "ref pushed despite ignored data"

# an origin that borrows the candidate's object database is not an independent rescue
mk alt
mkdir -p "$T/alt.git/objects/info"
printf '%s\n' "$T/alt/.git/objects" >"$T/alt.git/objects/info/alternates"
git -C "$T/alt.git" update-ref refs/heads/main "$(git -C "$T/alt" rev-parse HEAD)"
[[ "$(rc rescue_check "$T/alt")" -ne 0 && "$(rc rescue_push "$T/alt")" -ne 0 ]] && ok "dependent origin blocks rescue" || bad "dependent origin passed rescue"

# over cap
mk big; head -c 2097152 /dev/zero >"$T/big/blob"
[[ "$(DISK_MAGICIAN_RESCUE_CAP_MB=1 rc rescue_check "$T/big")" -ne 0 ]] && ok "over cap blocks check" || bad "over cap passed"
[[ "$(DISK_MAGICIAN_RESCUE_CAP_MB=1 rc rescue_push "$T/big")" -ne 0 ]] && ok "over cap blocks push" || bad "over cap pushed"
[[ "$(DISK_MAGICIAN_RESCUE_CAP_MB=5 rc rescue_check "$T/big")" -eq 0 ]] && ok "under raised cap passes" || bad "raised cap failed"

# no origin / not git
git init -q "$T/noor"; [[ "$(rc rescue_check "$T/noor")" -ne 0 && "$(rc rescue_push "$T/noor")" -ne 0 ]] && ok "no origin fails closed" || bad "no origin passed"
mkdir "$T/plain"; [[ "$(rc rescue_check "$T/plain")" -ne 0 ]] && ok "non-git fails" || bad "non-git passed"
mk subdir-host; mkdir -p "$T/subdir-host/venv"; printf 'x' >"$T/subdir-host/venv/lib"
[[ "$(rc rescue_check "$T/subdir-host/venv")" -ne 0 ]] && ok "subdirectory of a work tree is not rescuable" || bad "subdirectory passed rescue_check"
mk nest-host; git init -q "$T/nest-host/inner"; printf 'unsaved' >"$T/nest-host/inner/work.txt"
[[ "$(rc rescue_check "$T/nest-host")" -ne 0 && "$(rc rescue_push "$T/nest-host")" -ne 0 ]] \
    && ok "a nested repository blocks rescue (it would snapshot as an empty gitlink)" || bad "nested repo passed rescue"

# broken / read-only origin
mk ro; chmod -R a-w "$T/ro.git"
if [[ $(id -u) -ne 0 ]]; then
    [[ "$(rc rescue_push "$T/ro")" -ne 0 ]] && ok "read-only origin fails closed" || bad "read-only origin passed"
fi
chmod -R u+w "$T/ro.git"
mk gone; git -C "$T/gone" remote set-url origin "$T/does-not-exist.git"
[[ "$(rc rescue_push "$T/gone")" -ne 0 ]] && ok "broken origin fails closed" || bad "broken origin passed"

echo "rescue_ref: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

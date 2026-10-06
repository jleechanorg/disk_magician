#!/usr/bin/env bash
# test_worktree_new.sh — `diskm worktree-new` (spec D2): worktrees are created
# under $HOME/.worktrees/<repo>/<name>. Runs entirely under a temp HOME with
# temp repos; never touches the real ~/.worktrees.
set -uo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_new.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT="$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset STANDARD_WORKTREE_ROOT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Bare origin with one commit, cloned to $TMPROOT/myrepo, plus one local-only
# commit so origin/HEAD and HEAD differ.
git init -q --bare -b main "$TMPROOT/origin.git"
git clone -q "$TMPROOT/origin.git" "$TMPROOT/seed" 2>/dev/null
git -C "$TMPROOT/seed" commit -q --allow-empty -m base
git -C "$TMPROOT/seed" push -q origin HEAD:main
git clone -q "$TMPROOT/origin.git" "$TMPROOT/myrepo"
git -C "$TMPROOT/myrepo" commit -q --allow-empty -m local-only
REPO="$TMPROOT/myrepo"
ORIGIN_SHA="$(git -C "$REPO" rev-parse origin/HEAD)"
LOCAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
WTROOT="$HOME/.worktrees/myrepo"

echo "== case 1: new branch from origin/HEAD, stdout is exactly the path =="
out="$(bash "$SCRIPT" "$REPO" feat/x 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-x" "stdout"
assert_eq "$(git -C "$WTROOT/feat-x" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/x" "branch"
assert_eq "$(git -C "$WTROOT/feat-x" rev-parse HEAD 2>/dev/null)" "$ORIGIN_SHA" "based on origin/HEAD"
if git -C "$WTROOT/feat-x" rev-parse -q --verify 'feat/x@{upstream}' >/dev/null 2>&1; then bad "new branch tracks an upstream"; else ok "new branch has no upstream (--no-track)"; fi

echo "== case 2: --base and --name honored =="
out="$(bash "$SCRIPT" "$REPO" feat/y --base HEAD --name custom 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/custom" "stdout"
assert_eq "$(git -C "$WTROOT/custom" rev-parse HEAD 2>/dev/null)" "$LOCAL_SHA" "based on --base HEAD"

echo "== case 3: existing branch checked out without -b =="
git -C "$REPO" branch existing "$LOCAL_SHA"
out="$(bash "$SCRIPT" "$REPO" existing 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$(git -C "$WTROOT/existing" rev-parse --abbrev-ref HEAD 2>/dev/null)" "existing" "branch"
assert_eq "$(git -C "$WTROOT/existing" rev-parse HEAD 2>/dev/null)" "$LOCAL_SHA" "existing branch tip kept"

echo "== case 4: existing target path -> exit 1, nothing created =="
mkdir -p "$WTROOT/taken"
out="$(bash "$SCRIPT" "$REPO" feat/z --name taken 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "exit code"
assert_eq "$out" "" "stdout empty"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/z; then bad "branch feat/z created"; else ok "no branch created"; fi
assert_eq "$(ls -A "$WTROOT/taken")" "" "taken dir untouched"

echo "== case 5: no origin -> falls back to HEAD =="
git init -q -b main "$TMPROOT/noorigin"
git -C "$TMPROOT/noorigin" commit -q --allow-empty -m only
out="$(bash "$SCRIPT" "$TMPROOT/noorigin" feat/n 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$HOME/.worktrees/noorigin/feat-n" "stdout"
assert_eq "$(git -C "$out" rev-parse HEAD 2>/dev/null)" "$(git -C "$TMPROOT/noorigin" rev-parse HEAD)" "based on HEAD"

echo "== case 6: non-repo path and missing args -> exit 1 =="
mkdir -p "$TMPROOT/plain"
bash "$SCRIPT" "$TMPROOT/plain" feat/q >/dev/null 2>&1; assert_eq "$?" "1" "non-repo"
bash "$SCRIPT" "$REPO" >/dev/null 2>&1; assert_eq "$?" "1" "missing branch"

echo "== case 7: branch only on origin -> tracking branch at the remote tip =="
git -C "$TMPROOT/seed" checkout -q -b pr/feature
git -C "$TMPROOT/seed" commit -q --allow-empty -m pr-commit
git -C "$TMPROOT/seed" push -q origin pr/feature
PR_SHA="$(git -C "$TMPROOT/seed" rev-parse HEAD)"
git -C "$REPO" fetch -q origin   # test setup only; the script itself never fetches
out="$(bash "$SCRIPT" "$REPO" pr/feature 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$(git -C "$WTROOT/pr-feature" rev-parse HEAD 2>/dev/null)" "$PR_SHA" "HEAD is the PR commit"
assert_eq "$(git -C "$WTROOT/pr-feature" rev-parse --abbrev-ref 'pr/feature@{upstream}' 2>/dev/null)" "origin/pr/feature" "tracks origin/pr/feature"

echo "== case 8: --base with an existing branch is rejected; --opt=value forms work =="
git -C "$REPO" branch idle "$LOCAL_SHA"
out="$(bash "$SCRIPT" "$REPO" idle --base HEAD --name ex2 2>/dev/null)"; rc=$?
assert_eq "$rc" "1" "--base + existing branch"
[[ ! -e "$WTROOT/ex2" ]] && ok "nothing created" || bad "created ex2"
out="$(bash "$SCRIPT" "$REPO" feat/eq --base=HEAD --name=eqform 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/eqform" "--name= honored"
assert_eq "$(git -C "$WTROOT/eqform" rev-parse HEAD 2>/dev/null)" "$LOCAL_SHA" "--base= honored"

echo "== case 9: submodule path -> worktree of the submodule, named after it =="
git init -q -b main "$TMPROOT/subsrc"
git -C "$TMPROOT/subsrc" commit -q --allow-empty -m subcommit
SUB_SHA="$(git -C "$TMPROOT/subsrc" rev-parse HEAD)"
git init -q -b main "$TMPROOT/super"
git -C "$TMPROOT/super" -c protocol.file.allow=always submodule -q add "$TMPROOT/subsrc" sm 2>/dev/null
git -C "$TMPROOT/super" commit -q -m supercommit
out="$(bash "$SCRIPT" "$TMPROOT/super/sm" feat/s 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$HOME/.worktrees/sm/feat-s" "named after the submodule"
assert_eq "$(git -C "$out" rev-parse HEAD 2>/dev/null)" "$SUB_SHA" "submodule commit, not superproject"

echo "== case 10: bare repo + linked worktree layout =="
git clone -q --bare "$TMPROOT/origin.git" "$TMPROOT/proj.git"
git -C "$TMPROOT/proj.git" worktree add -q "$TMPROOT/proj-main" main 2>/dev/null
out="$(bash "$SCRIPT" "$TMPROOT/proj-main" feat/b 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$HOME/.worktrees/proj/feat-b" "named after the bare repo"
assert_eq "$(git -C "$out" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/b" "branch"

echo "== case 11: add killed after registering -> worktree and branch kept together; same name then refused =="
REAL_GIT="$(command -v git)"
mkdir -p "$TMPROOT/hangbin"
cat > "$TMPROOT/hangbin/git" <<EOF
#!/usr/bin/env bash
"$REAL_GIT" "\$@"; rc=\$?
[[ " \$* " == *" worktree add "* && ! -e "$TMPROOT/nohang" ]] && sleep 100
exit \$rc
EOF
chmod +x "$TMPROOT/hangbin/git"
out="$(PATH="$TMPROOT/hangbin:$PATH" WTN_ADD_TIMEOUT=1 bash "$SCRIPT" "$REPO" feat/hang 2>/dev/null)"; rc=$?
[[ "$rc" -ne 0 ]] && ok "timeout -> nonzero ($rc)" || bad "timeout returned 0"
assert_eq "$out" "" "stdout empty"
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WTROOT/feat-hang" && ok "registered worktree kept" || bad "registered worktree removed"
git -C "$REPO" show-ref -q --verify refs/heads/feat/hang && ok "its branch kept" || bad "its branch deleted (worktree orphaned)"
touch "$TMPROOT/nohang"
out="$(PATH="$TMPROOT/hangbin:$PATH" bash "$SCRIPT" "$REPO" feat/hang 2>"$TMPROOT/retry.err")"; rc=$?
[[ "$rc" -ne 0 ]] && ok "retry at a registered path refused ($rc)" || bad "retry reused a registered path"
grep -q "target registered" "$TMPROOT/retry.err" && ok "refusal names the registered target" || bad "unclear refusal: $(cat "$TMPROOT/retry.err")"

echo "== case 12: perl fallback timeout kills the whole process group =="
mkdir -p "$TMPROOT/minbin"
for t in bash perl sleep dirname; do ln -s "$(command -v "$t")" "$TMPROOT/minbin/$t"; done
PATH="$TMPROOT/minbin" bash -c 'source "$1"; wtn_timeout 1 bash -c "sleep 100 & echo \$! > \"$2\"; wait"' _ "$SCRIPT" "$TMPROOT/child.pid" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && ok "perl timeout -> nonzero ($rc)" || bad "perl timeout returned 0"
sleep 1
if kill -0 "$(cat "$TMPROOT/child.pid" 2>/dev/null)" 2>/dev/null; then bad "grandchild orphaned"; kill "$(cat "$TMPROOT/child.pid")"; else ok "grandchild killed"; fi

echo "== case 13: concurrent same-branch creates -> one wins, winner intact =="
mkdir -p "$TMPROOT/slowbin"
cat > "$TMPROOT/slowbin/git" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *" worktree add "* ]] && sleep 1
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPROOT/slowbin/git"
race() { # <tag> <branch> <name...>: two concurrent creates, sets WINS
    local i
    for i in 1 2; do
        (PATH="$TMPROOT/slowbin:$PATH" bash "$SCRIPT" "$REPO" "$2" --name "$3" >"$TMPROOT/$1.$i.out" 2>/dev/null
         echo $? >"$TMPROOT/$1.$i.rc") &
    done
    wait
    WINS=0; WINNER=""
    for i in 1 2; do
        if [[ "$(cat "$TMPROOT/$1.$i.rc")" == 0 ]]; then WINS=$((WINS + 1)); WINNER="$(cat "$TMPROOT/$1.$i.out")"; fi
    done
}
race same feat/race race
assert_eq "$WINS" "1" "exactly one same-path create succeeds"
assert_eq "$WINNER" "$WTROOT/race" "winner path"
assert_eq "$(git -C "$WTROOT/race" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/race" "winner worktree checked out on its branch"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/race; then ok "winner branch survives"; else bad "winner branch deleted"; fi
if git -C "$REPO" worktree list --porcelain | grep -qx "worktree $WTROOT/race"; then ok "winner still registered"; else bad "winner unregistered"; fi

echo "== case 14: concurrent same-branch creates at different paths -> winner intact =="
(PATH="$TMPROOT/slowbin:$PATH" bash "$SCRIPT" "$REPO" feat/race2 --name r2a >"$TMPROOT/r2.1.out" 2>/dev/null; echo $? >"$TMPROOT/r2.1.rc") &
(PATH="$TMPROOT/slowbin:$PATH" bash "$SCRIPT" "$REPO" feat/race2 --name r2b >"$TMPROOT/r2.2.out" 2>/dev/null; echo $? >"$TMPROOT/r2.2.rc") &
wait
WINS=0; WINNER=""; LOSER=""
for i in 1 2; do
    if [[ "$(cat "$TMPROOT/r2.$i.rc")" == 0 ]]; then WINS=$((WINS + 1)); WINNER="$(cat "$TMPROOT/r2.$i.out")"; fi
done
[[ "$WINNER" == "$WTROOT/r2a" ]] && LOSER="$WTROOT/r2b" || LOSER="$WTROOT/r2a"
assert_eq "$WINS" "1" "exactly one different-path create succeeds"
assert_eq "$(git -C "$WINNER" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/race2" "winner worktree checked out on its branch"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/race2; then ok "winner branch survives"; else bad "winner branch deleted"; fi
[[ ! -e "$LOSER" ]] && ok "loser path cleaned" || bad "loser path left: $LOSER"

echo "== case 15: failed create leaves other worktrees' admin entries alone (no repo-wide prune) =="
git -C "$REPO" worktree add -q "$TMPROOT/stale-wt" -b stale-br 2>/dev/null
rm -rf "$TMPROOT/stale-wt"
rm -f "$TMPROOT/nohang"
PATH="$TMPROOT/hangbin:$PATH" WTN_ADD_TIMEOUT=1 bash "$SCRIPT" "$REPO" feat/hang2 >/dev/null 2>&1
[[ -d "$REPO/.git/worktrees/stale-wt" ]] && ok "unrelated stale admin entry kept" || bad "unrelated admin entry pruned"
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WTROOT/feat-hang2" && ok "own registered worktree kept" || bad "own registered worktree removed"
git -C "$REPO" show-ref -q --verify refs/heads/feat/hang2 && ok "own branch kept with it" || bad "own branch deleted (worktree orphaned)"

echo "== case 16: CDPATH does not redirect the script's own cd =="
mkdir -p "$TMPROOT/cdp/scripts"
out="$(cd "$REPO_ROOT" && CDPATH="$TMPROOT/cdp" bash scripts/worktree_new.sh "$REPO" feat/cdp 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code with CDPATH set"
assert_eq "$out" "$WTROOT/feat-cdp" "stdout with CDPATH set"

echo "== case 17: branch created by someone else mid-create is never deleted by the loser =="
mkdir -p "$TMPROOT/stealbin"
cat > "$TMPROOT/stealbin/git" <<EOF
#!/usr/bin/env bash
# Simulate a concurrent winner committing refs/heads/feat/steal just before this
# call's own branch creation (inside 'worktree add -b' or 'branch').
if [[ " \$* " == *" feat/steal "* && ( " \$* " == *" worktree add "* || " \$* " == *" branch "* ) && ! -e "$TMPROOT/steal.done" ]]; then
    touch "$TMPROOT/steal.done"
    "$REAL_GIT" -C "$REPO" branch --no-track feat/steal origin/HEAD
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPROOT/stealbin/git"
PATH="$TMPROOT/stealbin:$PATH" bash "$SCRIPT" "$REPO" feat/steal --name steal >/dev/null 2>&1; rc=$?
[[ -e "$TMPROOT/steal.done" ]] && ok "interloper fired" || bad "interloper never fired"
[[ "$rc" -ne 0 ]] && ok "loser fails ($rc)" || bad "loser reported success"
assert_eq "$(git -C "$REPO" rev-parse -q --verify refs/heads/feat/steal 2>/dev/null)" "$ORIGIN_SHA" "other's branch survives"
[[ ! -e "$WTROOT/steal" ]] && ok "loser path cleaned" || bad "loser path left"

echo "== case 18: winner paused after its ref commit, before registration -> one wins, branch intact =="
HOOK="$REPO/.git/hooks/reference-transaction"
mkdir -p "$REPO/.git/hooks"
cat > "$HOOK" <<'EOF'
#!/bin/sh
[ "$1" = committed ] && [ -n "${WTN_PAUSE:-}" ] || { cat >/dev/null; exit 0; }
grep -q ' refs/heads/feat/pause$' || exit 0
touch "$WTN_PAUSE.paused"
i=0; while [ ! -e "$WTN_PAUSE.go" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
EOF
chmod +x "$HOOK"
(WTN_PAUSE="$TMPROOT/p" bash "$SCRIPT" "$REPO" feat/pause --name pa >"$TMPROOT/pa.out" 2>/dev/null; echo $? >"$TMPROOT/pa.rc") &
i=0; while [[ ! -e "$TMPROOT/p.paused" && $i -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
[[ -e "$TMPROOT/p.paused" ]] && ok "first create paused after ref commit" || bad "first create never paused"
bash "$SCRIPT" "$REPO" feat/pause --name pb >"$TMPROOT/pb.out" 2>/dev/null; echo $? >"$TMPROOT/pb.rc"
touch "$TMPROOT/p.go"
wait
rm -f "$HOOK"
WINS=0; WINNER=""
for t in pa pb; do
    if [[ "$(cat "$TMPROOT/$t.rc")" == 0 ]]; then WINS=$((WINS + 1)); WINNER="$(cat "$TMPROOT/$t.out")"; fi
done
assert_eq "$WINS" "1" "exactly one create succeeds"
assert_eq "$(git -C "$WINNER" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/pause" "winner worktree on its branch"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/pause; then ok "winner branch survives"; else bad "winner branch deleted"; fi
n="$(git -C "$REPO" worktree list --porcelain | grep -cx 'branch refs/heads/feat/pause')"
assert_eq "$n" "1" "branch checked out exactly once"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

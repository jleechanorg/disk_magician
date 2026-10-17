#!/usr/bin/env bash
# test_worktree_new.sh — `diskm worktree-new` (spec D2): worktrees are created
# under $HOME/.worktrees/<repo>/<name>. Runs entirely under a temp HOME with
# temp repos; never touches the real ~/.worktrees.
set -uo pipefail
export DISK_MAGICIAN_ADMIT_RETRY_S=0

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_new.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT_RAW="$(mktemp -d /tmp/dm-worktree-new.XXXXXX)" || { echo "FATAL: fixture allocation failed" >&2; exit 1; }
if [[ -z "$TMPROOT_RAW" || "$TMPROOT_RAW" != /tmp/dm-worktree-new.* || ! -d "$TMPROOT_RAW" || -L "$TMPROOT_RAW" ]]; then
    echo "FATAL: refusing non-/tmp fixture root '$TMPROOT_RAW'" >&2
    exit 1
fi
# Canonicalize (/tmp is a symlink to /private/tmp on macOS): lease paths,
# own-claim canonicalization and git all compare canonical bytes.
TMPROOT="$(CDPATH= cd -- "$TMPROOT_RAW" && pwd -P)"
trap 'rm -rf -- "$TMPROOT_RAW"' EXIT
# No ambient Git redirection or injected tool stubs may reach the fixtures.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR GIT_EXEC_PATH GIT_CEILING_DIRECTORIES \
    DISK_MAGICIAN_PS_BIN DISK_MAGICIAN_STAT_BIN DISK_MAGICIAN_LSOF_BIN DISK_MAGICIAN_GIT_BIN \
    DISK_MAGICIAN_C14_LEDGER C14_INVENTORY_OUT C14_INVENTORY_FILE 2>/dev/null || true
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset STANDARD_WORKTREE_ROOT
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$TMPROOT" || exit 1

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
i=0; while [ ! -e "$WTN_PAUSE.go" ] && [ $i -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
EOF
chmod +x "$HOOK"
(WTN_PAUSE="$TMPROOT/p" bash "$SCRIPT" "$REPO" feat/pause --name pa >"$TMPROOT/pa.out" 2>/dev/null; echo $? >"$TMPROOT/pa.rc") &
i=0; while [[ ! -e "$TMPROOT/p.paused" && $i -lt 600 ]]; do sleep 0.1; i=$((i + 1)); done
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

echo "== case L1: lease written at creation (plan Task 4) =="
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
lease_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get(sys.argv[2]))
except Exception:
    print("ERR")
PY
}
out="$(bash "$SCRIPT" "$REPO" feat/lease 2>/dev/null)"; rc=$?
assert_eq "$out" "$WTROOT/feat-lease" "stdout is still exactly the path"
L="$(lease_path_for "$WTROOT/feat-lease")"
[[ -f "$L" ]] && ok "lease file exists" || bad "lease file missing"
assert_eq "$(lease_field "$L" creator)" "worktree-new" "lease creator"
assert_eq "$(lease_field "$L" branch)" "feat/lease" "lease branch"
[[ "$(lease_field "$L" path)" == "$WTROOT/feat-lease" ]] && ok "lease path" || bad "lease path wrong"

echo "== case L2: failing lease write still prints the path, exit 0 =="
mkdir -p "$DISK_MAGICIAN_STATE_DIR/worktree_leases"
chmod 500 "$DISK_MAGICIAN_STATE_DIR/worktree_leases"
out="$(bash "$SCRIPT" "$REPO" feat/leasefail 2>"$TMPROOT/lease_err")"; rc=$?
chmod 700 "$DISK_MAGICIAN_STATE_DIR/worktree_leases"
assert_eq "$rc" "0" "exit code stays 0"
assert_eq "$out" "$WTROOT/feat-leasefail" "stdout is still exactly the path"
grep -q "lease write failed" "$TMPROOT/lease_err" && ok "stderr logs lease write failed" || bad "stderr missing lease write failed"
[[ -d "$WTROOT/feat-leasefail" ]] && ok "worktree itself still created" || bad "worktree not created"

echo "== case A0: unset override -> real measurement, no gate interference =="
out="$(env -u DISK_MAGICIAN_FREE_GB_OVERRIDE bash "$SCRIPT" "$REPO" feat/nogate 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-nogate" "stdout is exactly the path"

# The shared admit gate owns the decision when it is available (plan Task 4).
# These cases pass an explicit estimate so the real disk_budget.py (whose
# producer-estimate adapter is a separate lane) records a real event.
echo "== case A1: free 50 GiB -> creates, no legacy warning ="
out="$(WORKTREE_ADMIT_EST_GB=2 DISK_MAGICIAN_FREE_GB_OVERRIDE=50 bash "$SCRIPT" "$REPO" feat/a1 2>"$TMPROOT/a1.err")"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-a1" "stdout is exactly the path"
grep -q "low disk" "$TMPROOT/a1.err" && bad "warned above the warn threshold: $(cat "$TMPROOT/a1.err")" || ok "no warning"

# D2 is not recorded, so the shared admit decision is observe (rc 0). The old
# legacy floor must NOT override it (Task 4 gap): low df now proceeds through
# the shared gate, and only the missing-admit fallback rejects.
echo "== case A2: free 5 GiB, shared admit observe -> proceeds (no legacy refusal) =="
out="$(WORKTREE_ADMIT_EST_GB=2 DISK_MAGICIAN_FREE_GB_OVERRIDE=5 bash "$SCRIPT" "$REPO" feat/a2 2>"$TMPROOT/a2.err")"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-a2" "stdout is exactly the path"
grep -q "disk low" "$TMPROOT/a2.err" && bad "legacy floor ran despite shared admit: $(cat "$TMPROOT/a2.err")" || ok "shared admit owns the decision"
[[ -d "$WTROOT/feat-a2" ]] && ok "worktree created" || bad "worktree not created"

# Producer lookup: with no explicit override the caller omits --est-gb and
# lets the admit side resolve the calibrated producer estimate; an explicit
# override is always forwarded.
echo "== case A2b: producer lookup vs explicit estimate override =="
cat > "$TMPROOT/admit-args" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISK_MAGICIAN_ADMIT_ARGS_LOG"
exit 0
EOF
chmod +x "$TMPROOT/admit-args"
A2B_LOG="$TMPROOT/admit-args.log"; : > "$A2B_LOG"
out="$(DISK_MAGICIAN_ADMIT_BIN="$TMPROOT/admit-args" DISK_MAGICIAN_ADMIT_ARGS_LOG="$A2B_LOG" DISK_MAGICIAN_FREE_GB_OVERRIDE=50 bash "$SCRIPT" "$REPO" feat/a2b --name a2b 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "producer-only create exit"
assert_eq "$out" "$WTROOT/a2b" "producer-only create path"
grep -q -- "--producer worktree-new:myrepo" "$A2B_LOG" && ok "producer passed" || bad "producer missing: $(cat "$A2B_LOG")"
grep -q -- "--est-gb" "$A2B_LOG" && bad "--est-gb passed without an explicit override: $(cat "$A2B_LOG")" || ok "producer-only lookup when unset"
: > "$A2B_LOG"
out="$(WORKTREE_ADMIT_EST_GB=7 DISK_MAGICIAN_ADMIT_BIN="$TMPROOT/admit-args" DISK_MAGICIAN_ADMIT_ARGS_LOG="$A2B_LOG" DISK_MAGICIAN_FREE_GB_OVERRIDE=50 bash "$SCRIPT" "$REPO" feat/a2c --name a2c 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "explicit-override create exit"
assert_eq "$out" "$WTROOT/a2c" "explicit-override create path"
grep -q -- "--est-gb 7" "$A2B_LOG" && ok "explicit estimate override forwarded" || bad "override lost: $(cat "$A2B_LOG")"

# Missing admit: the legacy thresholds own the decision and reject at low df.
echo "== case A3: admit missing + free 5 GiB -> legacy floor rejects (rc 75) =="
out="$(DISK_MAGICIAN_ADMIT_BIN="$TMPROOT/no-such-admit" DISK_MAGICIAN_FREE_GB_OVERRIDE=5 bash "$SCRIPT" "$REPO" feat/a3 2>"$TMPROOT/a3.err")"; rc=$?
assert_eq "$rc" "75" "exit code 75"
assert_eq "$out" "" "stdout empty"
grep -q "admission_degraded:caller" "$TMPROOT/a3.err" && ok "stderr logs admission_degraded:caller" || bad "stderr: $(cat "$TMPROOT/a3.err")"
grep -q "disk low (5 GiB free): reuse an existing worktree" "$TMPROOT/a3.err" && ok "stderr names the floor and the remedy" || bad "stderr message: $(cat "$TMPROOT/a3.err")"
[[ ! -e "$WTROOT/feat-a3" ]] && ok "no worktree dir created" || bad "worktree created despite refusal"
if git -C "$REPO" show-ref -q --verify refs/heads/feat/a3; then bad "branch created"; else ok "no branch created"; fi
grep -q "disk-admission: refused class=worktrees rc=75" "$TMPROOT/a3.err" && ok "stderr carries the refused line" || bad "refused line missing: $(cat "$TMPROOT/a3.err")"

echo "== case A4: missing admit + WORKTREE_ADMIT_MIN_GB=0 disables the refusal =="
out="$(DISK_MAGICIAN_ADMIT_BIN="$TMPROOT/no-such-admit" DISK_MAGICIAN_FREE_GB_OVERRIDE=5 WORKTREE_ADMIT_MIN_GB=0 bash "$SCRIPT" "$REPO" feat/a4 2>"$TMPROOT/a4.err")"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-a4" "stdout is exactly the path"
[[ -d "$WTROOT/feat-a4" ]] && ok "worktree created" || bad "worktree not created"

echo "== case A5: missing admit + unmeasurable free space fails open =="
out="$(DISK_MAGICIAN_ADMIT_BIN="$TMPROOT/no-such-admit" DISK_MAGICIAN_FREE_GB_OVERRIDE=x bash "$SCRIPT" "$REPO" feat/a5 2>"$TMPROOT/a5.err")"; rc=$?
assert_eq "$rc" "0" "exit code"
assert_eq "$out" "$WTROOT/feat-a5" "stdout is exactly the path"
grep -q "free-space unmeasurable" "$TMPROOT/a5.err" && ok "stderr logs free-space unmeasurable" || bad "stderr missing free-space unmeasurable: $(cat "$TMPROOT/a5.err")"

echo "== case A6: real diskm admit logs one worktrees event with producer and dest =="
EV="$DISK_MAGICIAN_STATE_DIR/admission/events.jsonl"
out="$(WORKTREE_ADMIT_EST_GB=2 DISK_MAGICIAN_FREE_GB_OVERRIDE=50 bash "$SCRIPT" "$REPO" feat/a6 2>"$TMPROOT/a6.err")"; rc=$?
assert_eq "$rc" "0" "exit code (admit is observe-only until D2)"
assert_eq "$out" "$WTROOT/feat-a6" "stdout is exactly the path"
assert_eq "$(python3 -c 'import json,sys; e=[e for e in map(json.loads, open(sys.argv[1])) if e.get("event") == "admit"][-1]; print(e["class"], e["producer"], e["source"], e["dest"])' "$EV" 2>&1)" \
    "worktrees worktree-new:myrepo worktree-new $WTROOT/feat-a6" "event class/producer/source/dest"

# shellcheck source=tests/lib/admit_contract.sh
source "$REPO_ROOT/tests/lib/admit_contract.sh"
run_admit_contract "DISK_MAGICIAN_FREE_GB_OVERRIDE=50 bash '$SCRIPT' '$REPO' feat/contract-{n}"

echo "== case 19: complete C14 permits merged idle worktree reuse =="
REUSE_WT="$WTROOT/reuse-old"
git -C "$REPO" branch reuse/old "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$REUSE_WT" reuse/old
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
reuse_out="$(bash -c '
    source "$1"
    lease_write "$2" "$3" reuse/old reuse-test
    DISK_MAGICIAN_TEST_OWNER_LEASE="$(lease_path_for "$2")"
    lease_owner_state() { [[ "$1" == "$DISK_MAGICIAN_TEST_OWNER_LEASE" && "$(_lease_get "$1" branch)" == reuse/old ]] && echo dead || echo alive; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; wrh_removal_verdict "$1" minutes:120 origin-or-merged-pr; }
    wtn_main "$3" feat/recycled --base origin/main --name recycled
' _ "$SCRIPT" "$REUSE_WT" "$REPO" 2>"$TMPROOT/reuse.err")"; rc=$?
[[ "$rc" == 0 && "$reuse_out" == "$REUSE_WT" ]] || cat "$TMPROOT/reuse.err" >&2
assert_eq "$rc" "0" "reuse exit code"
assert_eq "$reuse_out" "$REUSE_WT" "reuse keeps existing path"
assert_eq "$(git -C "$REUSE_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/recycled" "reuse checks out requested branch"
if git -C "$REPO" show-ref -q --verify refs/heads/reuse/old; then bad "recycled old branch remains"; else ok "old branch removed after successful recycle"; fi

echo "== case 19b: non-ok C14 self-test refuses reuse (double) =="
NEG_WT="$WTROOT/reuse-neg-c14"
git -C "$REPO" branch reuse/neg-c14 "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$NEG_WT" reuse/neg-c14
bash -c 'source "$1"; lease_write "$2" "$3" reuse/neg-c14 reuse-test' _ "$SCRIPT" "$NEG_WT" "$REPO" >/dev/null 2>&1
neg_out="$(bash -c '
    source "$1"
    DISK_MAGICIAN_TEST_OWNER_LEASE="$(lease_path_for "$2")"
    lease_owner_state() { [[ "$1" == "$DISK_MAGICIAN_TEST_OWNER_LEASE" ]] && echo dead || echo alive; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }; echo remove; }
    wtn_main "$3" feat/neg-c14 --base origin/main --name neg-c14
' _ "$SCRIPT" "$NEG_WT" "$REPO" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "non-ok C14 fallback exit"
assert_eq "$neg_out" "$WTROOT/neg-c14" "non-ok C14 self-test refuses reuse"
assert_eq "$(git -C "$NEG_WT" rev-parse --abbrev-ref HEAD)" "reuse/neg-c14" "non-ok C14 candidate preserved"

run_reuse_attempt() {
    local wt="$1" old="$2" wanted="$3" name="$4" cd_into="${5:-}"
    local err="$TMPROOT/reuse-$name.err" out rc
    out="$(bash -c '
        source "$1"
        lease_write "$2" "$3" "$4" reuse-test
        DISK_MAGICIAN_TEST_OWNER_LEASE="$(lease_path_for "$2")"
        DISK_MAGICIAN_TEST_OWNER_BRANCH="$4"
        lease_owner_state() { [[ "$1" == "$DISK_MAGICIAN_TEST_OWNER_LEASE" && "$(_lease_get "$1" branch)" == "$DISK_MAGICIAN_TEST_OWNER_BRANCH" ]] && echo dead || echo alive; }
        worktree_is_recently_active_minutes() { return 1; }
        artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; wrh_removal_verdict "$1" minutes:120 origin-or-merged-pr; }
        [[ -z "$7" ]] || cd "$2"
        wtn_main "$3" "$5" --base origin/main --name "$6"
    ' _ "$SCRIPT" "$wt" "$REPO" "$old" "$wanted" "$name" "$cd_into" 2>"$err")"; rc=$?
    [[ "$rc" == 0 ]] || cat "$err" >&2
    printf '%s\n' "$out"
    return "$rc"
}

echo "== case 31: registered worktrees outside the canonical repository root are not reused =="
OUTSIDE_WT="$TMPROOT/outside-myrepo/reuse-outside"
mkdir -p "$(dirname "$OUTSIDE_WT")"
git -C "$REPO" branch reuse/outside "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$OUTSIDE_WT" reuse/outside
fresh="$(run_reuse_attempt "$OUTSIDE_WT" reuse/outside feat/outside outside)"; rc=$?
assert_eq "$rc" "0" "outside-root fallback exit"
assert_eq "$fresh" "$WTROOT/outside" "outside-root candidate is not recycled"
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" main "main worktree remains on main"
assert_eq "$(git -C "$OUTSIDE_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" reuse/outside "outside-root candidate remains intact"

echo "== case 32: noncanonical lease filename cannot authorize reuse =="
NONCAN_WT="$WTROOT/reuse-noncanonical-lease"
git -C "$REPO" branch reuse/noncanonical-lease "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$NONCAN_WT" reuse/noncanonical-lease
bash -c 'source "$1"; lease_write "$2" "$3" reuse/noncanonical-lease reuse-test' _ "$SCRIPT" "$NONCAN_WT" "$REPO" >/dev/null 2>&1
NONCAN_LEASE="$(bash -c 'source "$1"; lease_path_for "$2"' _ "$SCRIPT" "$NONCAN_WT")"
NONCAN_STATE="$TMPROOT/noncanonical-state"
mkdir -p "$NONCAN_STATE/worktree_leases"
cp "$NONCAN_LEASE" "$NONCAN_STATE/worktree_leases/noncanonical-copy.json"
rm "$NONCAN_LEASE"
fresh="$(bash -c '
    source "$1"
    export DISK_MAGICIAN_STATE_DIR="$4"
    lease_owner_state() { echo dead; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; echo remove; }
    wtn_main "$3" feat/noncanonical --base origin/main --name noncanonical
' _ "$SCRIPT" "$NONCAN_WT" "$REPO" "$NONCAN_STATE" 2>"$TMPROOT/noncanonical.err")"; rc=$?
assert_eq "$rc" "0" "noncanonical-lease fallback exit"
assert_eq "$fresh" "$WTROOT/noncanonical" "noncanonical lease cannot authorize reuse"
assert_eq "$(git -C "$NONCAN_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" reuse/noncanonical-lease "noncanonical candidate remains intact"

echo "== case 29: stale lease cannot authorize replacement checkout reuse =="
STALE_WT="$WTROOT/reuse-stale-incarnation"
git -C "$REPO" branch reuse/stale-incarnation "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$STALE_WT" reuse/stale-incarnation
bash -c 'source "$1"; lease_write "$2" "$3" reuse/stale-incarnation reuse-test' _ "$SCRIPT" "$STALE_WT" "$REPO" >/dev/null 2>&1
STALE_LEASE="$(bash -c 'source "$1"; lease_path_for "$2"' _ "$SCRIPT" "$STALE_WT")"
cp "$STALE_LEASE" "$TMPROOT/stale-lease.json"
git -C "$REPO" worktree remove "$STALE_WT"
git -C "$REPO" worktree add -q "$STALE_WT" reuse/stale-incarnation
cp "$TMPROOT/stale-lease.json" "$STALE_LEASE"
fresh="$(bash -c '
    source "$1"
    DISK_MAGICIAN_TEST_OWNER_LEASE="$(lease_path_for "$2")"
    lease_owner_state() { [[ "$1" == "$DISK_MAGICIAN_TEST_OWNER_LEASE" ]] && echo dead || echo alive; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; wrh_removal_verdict "$1" minutes:120 origin-or-merged-pr; }
    wtn_main "$3" feat/stale-incarnation --base origin/main --name stale-incarnation
' _ "$SCRIPT" "$STALE_WT" "$REPO" 2>"$TMPROOT/stale-incarnation.err")"; rc=$?
assert_eq "$rc" "0" "stale-incarnation fallback exit"
[[ "$fresh" != "$STALE_WT" ]] && ok "stale lease cannot recycle replacement checkout" || bad "stale lease recycled replacement checkout"
assert_eq "$(git -C "$STALE_WT" rev-parse --abbrev-ref HEAD)" "reuse/stale-incarnation" "replacement checkout remains intact"

echo "== case 29b: legacy lease without checkout identity cannot authorize reuse =="
LEGACY_WT="$WTROOT/reuse-legacy-lease"
git -C "$REPO" branch reuse/legacy-lease "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$LEGACY_WT" reuse/legacy-lease
bash -c 'source "$1"; lease_write "$2" "$3" reuse/legacy-lease reuse-test' _ "$SCRIPT" "$LEGACY_WT" "$REPO" >/dev/null 2>&1
LEGACY_LEASE="$(bash -c 'source "$1"; lease_path_for "$2"' _ "$SCRIPT" "$LEGACY_WT")"
python3 - "$LEGACY_LEASE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("checkout_dev",None); d.pop("checkout_ino",None)
json.dump(d,open(p,'w'))
PY
fresh="$(bash -c '
    source "$1"
    DISK_MAGICIAN_TEST_OWNER_LEASE="$(lease_path_for "$2")"
    lease_owner_state() { [[ "$1" == "$DISK_MAGICIAN_TEST_OWNER_LEASE" ]] && echo dead || echo alive; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; wrh_removal_verdict "$1" minutes:120 origin-or-merged-pr; }
    wtn_main "$3" feat/legacy-lease --base origin/main --name legacy-lease
' _ "$SCRIPT" "$LEGACY_WT" "$REPO" 2>"$TMPROOT/legacy-lease.err")"; rc=$?
assert_eq "$rc" "0" "legacy-lease fallback exit"
[[ "$fresh" != "$LEGACY_WT" ]] && ok "legacy lease cannot authorize reuse without checkout identity" || bad "legacy lease authorized reuse"
assert_eq "$(git -C "$LEGACY_WT" rev-parse --abbrev-ref HEAD)" "reuse/legacy-lease" "legacy-lease candidate preserved"

echo "== case 30: lease changed to a live owner at the claim boundary is not claimed =="
LIVE_OWNER_WT="$WTROOT/reuse-live-owner-race"
export LIVE_OWNER_WT
git -C "$REPO" branch reuse/live-owner-race "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$LIVE_OWNER_WT" reuse/live-owner-race
export LIVE_OWNER_MARKER="$TMPROOT/live-owner-marker"
export LIVE_OWNER_CLAIM_LOG="$TMPROOT/live-owner-claim.log"
: > "$LIVE_OWNER_CLAIM_LOG"
# Keep the injected owner alive through the claim boundary.
sleep 300 & LIVE_OWNER_PID=$!
export LIVE_OWNER_PID
# Rewrite the lease to name the live owner. Done by the test, not production.
cat > "$TMPROOT/live-owner-mutate.py" <<'PY'
import json, os, sys
p, pid, epoch, comm, marker = sys.argv[1:]
d = json.load(open(p))
d["owner"] = {"pid": int(pid), "start_epoch": int(epoch), "comm": comm}
tmp = p + ".live-owner-race"
json.dump(d, open(tmp, "w"))
os.replace(tmp, p)
open(marker, "w").write(pid)
PY
export LIVE_OWNER_MUTATOR="$TMPROOT/live-owner-mutate.py"
live_owner_out="$(bash -c '
    source "$1"
    lease_write "$2" "$3" reuse/live-owner-race reuse-test
    lease_owner_state() {
        if [[ "$(_lease_get "$1" path)" == "$LIVE_OWNER_WT" ]]; then echo dead; else echo alive; fi
    }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() { [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }; echo remove; }
    # Capture the real claim, then wrap it so the lease is rewritten to a live
    # owner exactly at the claim boundary, after eligibility was read and hashed.
    # The real claim must detect the hash mismatch and refuse; returning "recently
    # active" instead would short-circuit before this gate and never test it.
    eval "$(declare -f lease_claim_reuse | sed "1s/lease_claim_reuse/_real_lease_claim_reuse/")"
    lease_claim_reuse() {
        local lease
        lease="$(lease_path_for "$LIVE_OWNER_WT")"
        [[ "$1" == "$lease" ]] && kill -0 "$LIVE_OWNER_PID" 2>/dev/null || return 1
        printf "claim-boundary\n" >> "$LIVE_OWNER_CLAIM_LOG"
        python3 "$LIVE_OWNER_MUTATOR" "$lease" "$LIVE_OWNER_PID" "$(_lease_ps_lstart_epoch "$LIVE_OWNER_PID")" "$(_lease_full_comm "$LIVE_OWNER_PID")" "$LIVE_OWNER_MARKER" || return 1
        _real_lease_claim_reuse "$@"
    }
    wtn_main "$2" feat/live-owner-race --base origin/main --name live-owner-race
' _ "$SCRIPT" "$LIVE_OWNER_WT" "$REPO" 2>/dev/null)"; rc=$?
kill "$LIVE_OWNER_PID" 2>/dev/null || true
assert_eq "$rc" "0" "live-owner race fallback exit"
assert_eq "$live_owner_out" "$WTROOT/live-owner-race" "live-owner lease cannot authorize reuse"
assert_eq "$(git -C "$LIVE_OWNER_WT" rev-parse --abbrev-ref HEAD)" "reuse/live-owner-race" "live-owner candidate branch preserved"
[[ -s "$LIVE_OWNER_CLAIM_LOG" ]] && ok "claim boundary reached with a live-owner lease injection" || bad "claim boundary never reached"
[[ -f "$LIVE_OWNER_MARKER" ]] && ok "post-eligibility lease rewrite was applied" || bad "lease was not rewritten before claim"
unset LIVE_OWNER_MARKER LIVE_OWNER_CLAIM_LOG LIVE_OWNER_MUTATOR LIVE_OWNER_PID

echo "== case 21: unpushed old branch falls back to fresh worktree =="
UNPUSHED_WT="$WTROOT/reuse-unpushed"
git -C "$REPO" branch reuse/unpushed "$LOCAL_SHA"
git -C "$REPO" worktree add -q "$UNPUSHED_WT" reuse/unpushed
fresh="$(run_reuse_attempt "$UNPUSHED_WT" reuse/unpushed feat/unpushed unpushed)"; rc=$?
assert_eq "$rc" "0" "unpushed fallback exit"
assert_eq "$fresh" "$WTROOT/unpushed" "unpushed branch uses fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/unpushed)" "$LOCAL_SHA" "unpushed branch tip preserved"
assert_eq "$(git -C "$UNPUSHED_WT" rev-parse --abbrev-ref HEAD)" "reuse/unpushed" "unpushed candidate checkout preserved"

echo "== case 22: untracked and ignored user data block reuse =="
printf '\n.env\ndata/notes.db\n' >> "$REPO/.git/info/exclude"
for payload in untracked ignored_env ignored_db; do
    wt="$WTROOT/reuse-$payload"; old="reuse/$payload"; wanted="feat/$payload"
    git -C "$REPO" branch "$old" "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$wt" "$old"
    case "$payload" in
        untracked) echo keep > "$wt/notes.txt" ;;
        ignored_env) echo keep > "$wt/.env" ;;
        ignored_db) mkdir -p "$wt/data"; echo keep > "$wt/data/notes.db" ;;
    esac
    fresh="$(run_reuse_attempt "$wt" "$old" "$wanted" "$payload")"; rc=$?
    assert_eq "$rc" "0" "$payload fallback exit"
    assert_eq "$fresh" "$WTROOT/$payload" "$payload uses fresh path"
    if [[ "$payload" == untracked ]]; then checkfile="$wt/notes.txt"; elif [[ "$payload" == ignored_env ]]; then checkfile="$wt/.env"; else checkfile="$wt/data/notes.db"; fi
    [[ -f "$checkfile" ]] && ok "$payload preserved" || bad "$payload was lost"
done

echo "== case 23: live current working directory blocks reuse =="
LIVE_WT="$WTROOT/reuse-live"
git -C "$REPO" branch reuse/live "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$LIVE_WT" reuse/live
(cd "$LIVE_WT" && sleep 60) & LIVE_CWD_PID=$!
sleep 0.2
fresh="$(run_reuse_attempt "$LIVE_WT" reuse/live feat/live live)"; rc=$?
kill "$LIVE_CWD_PID" 2>/dev/null || true
wait "$LIVE_CWD_PID" 2>/dev/null || true
assert_eq "$rc" "0" "live cwd fallback exit"
assert_eq "$fresh" "$WTROOT/live" "live cwd uses fresh path"
assert_eq "$(git -C "$LIVE_WT" rev-parse --abbrev-ref HEAD)" "reuse/live" "live cwd candidate branch preserved"

echo "== case 24: concurrent reuse claims yield one recycle and one fresh create =="
RACE_WT="$WTROOT/reuse-race"
git -C "$REPO" branch reuse/race "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$RACE_WT" reuse/race
bash -c 'source "$1"; lease_write "$2" "$3" reuse/race reuse-test' _ "$SCRIPT" "$RACE_WT" "$REPO" >/dev/null 2>&1
run_reuse_attempt "$RACE_WT" reuse/race feat/reuse-race-a reuse-race-a >"$TMPROOT/reuse-race-a.out" 2>/dev/null & P1=$!
run_reuse_attempt "$RACE_WT" reuse/race feat/reuse-race-b reuse-race-b >"$TMPROOT/reuse-race-b.out" 2>/dev/null & P2=$!
wait "$P1"; RC1=$?; wait "$P2"; RC2=$?
R1="$(cat "$TMPROOT/reuse-race-a.out")"; R2="$(cat "$TMPROOT/reuse-race-b.out")"
assert_eq "$RC1" "0" "concurrent recycle caller A succeeds"
assert_eq "$RC2" "0" "concurrent recycle caller B succeeds"
if { [[ "$R1" == "$RACE_WT" && "$R2" == "$WTROOT/reuse-race-b" ]] || [[ "$R2" == "$RACE_WT" && "$R1" == "$WTROOT/reuse-race-a" ]]; }; then ok "one caller recycles while the other creates fresh"; else bad "unexpected concurrent results: A=$R1 B=$R2"; fi

echo "== case 25: conditional ref deletion catches a last-moment commit =="
BOUNDARY_WT="$WTROOT/reuse-boundary"
git -C "$REPO" branch reuse/boundary "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$BOUNDARY_WT" reuse/boundary
bash -c 'source "$1"; lease_write "$2" "$3" reuse/boundary reuse-test' _ "$SCRIPT" "$BOUNDARY_WT" "$REPO" >/dev/null 2>&1
cat > "$TMPROOT/race-ref-hook" <<EOF
#!/usr/bin/env bash
set -e
repo=\$1; branch=\$2
tip=\$("$REAL_GIT" -C "\$repo" rev-parse "refs/heads/\$branch")
new=\$("$REAL_GIT" -C "\$repo" commit-tree "\$tip^{tree}" -p "\$tip" -m interloper)
"$REAL_GIT" -C "\$repo" update-ref "refs/heads/\$branch" "\$new" "\$tip"
EOF
chmod +x "$TMPROOT/race-ref-hook"
export DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF="$TMPROOT/race-ref-hook"
fresh="$(run_reuse_attempt "$BOUNDARY_WT" reuse/boundary feat/boundary boundary)"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF
assert_eq "$rc" "0" "last-moment commit fallback exits zero"
assert_eq "$fresh" "$WTROOT/boundary" "last-moment commit creates fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/boundary)" "$(git -C "$BOUNDARY_WT" rev-parse HEAD)" "new old-branch commit is preserved"
assert_eq "$(git -C "$BOUNDARY_WT" rev-parse --abbrev-ref HEAD)" "reuse/boundary" "candidate switches back to preserved old branch"

echo "== case 33: content added at the branch-delete boundary blocks reuse =="
ACTIVITY_WT="$WTROOT/reuse-activity-boundary"
git -C "$REPO" branch reuse/activity-boundary "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$ACTIVITY_WT" reuse/activity-boundary
cat > "$TMPROOT/add-user-data-hook" <<'EOF'
#!/usr/bin/env bash
echo keep > "$3/late-untracked.txt"
EOF
chmod +x "$TMPROOT/add-user-data-hook"
export DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF="$TMPROOT/add-user-data-hook"
fresh="$(run_reuse_attempt "$ACTIVITY_WT" reuse/activity-boundary feat/activity-boundary activity-boundary)"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF
assert_eq "$rc" "0" "late-activity fallback exit"
assert_eq "$fresh" "$WTROOT/activity-boundary" "late content blocks candidate recycle"
assert_eq "$(git -C "$ACTIVITY_WT" rev-parse --abbrev-ref HEAD)" "reuse/activity-boundary" "late-activity branch preserved"
[[ -f "$ACTIVITY_WT/late-untracked.txt" ]] && ok "late content remains intact" || bad "late content was lost"

echo "== case 34: ignored user content blocks branch switch and remains intact =="
IGNORED_WT="$WTROOT/reuse-ignored-boundary"
git -C "$REPO" branch reuse/ignored-boundary "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$IGNORED_WT" reuse/ignored-boundary
git -C "$REPO" config --add core.excludesFile "$TMPROOT/global-excludes"
echo ignored-target.txt >> "$TMPROOT/global-excludes"
git -C "$REPO" checkout -q -b target/ignored-file "$ORIGIN_SHA"
echo committed > "$REPO/ignored-target.txt"
git -C "$REPO" add -f ignored-target.txt
git -C "$REPO" commit -q -m target-ignored-file
IGNORED_BASE="$(git -C "$REPO" rev-parse target/ignored-file)"
git -C "$REPO" update-ref refs/remotes/origin/main "$IGNORED_BASE"
git -C "$REPO" checkout -q main
cat > "$TMPROOT/add-ignored-user-data-hook" <<'EOF'
#!/usr/bin/env bash
echo keep-user-bytes > "$3/ignored-target.txt"
EOF
chmod +x "$TMPROOT/add-ignored-user-data-hook"
export DISK_MAGICIAN_TEST_BEFORE_BRANCH_SWITCH="$TMPROOT/add-ignored-user-data-hook"
fresh="$(run_reuse_attempt "$IGNORED_WT" reuse/ignored-boundary target/ignored-reuse ignored-reuse)"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_BRANCH_SWITCH
assert_eq "$rc" "0" "ignored-content fallback exits zero"
assert_eq "$fresh" "$WTROOT/ignored-reuse" "ignored-content candidate falls back to fresh path"
assert_eq "$(cat "$IGNORED_WT/ignored-target.txt")" "keep-user-bytes" "ignored user bytes survive failed switch"

echo "== case 35: second checkout at delete boundary keeps the old branch alive =="
BRANCH_BUSY_WT="$WTROOT/reuse-branch-busy"
BRANCH_BUSY_OTHER="$TMPROOT/second-branch-checkout"
git -C "$REPO" branch reuse/branch-busy "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$BRANCH_BUSY_WT" reuse/branch-busy
cat > "$TMPROOT/add-second-checkout" <<EOF
#!/usr/bin/env bash
set -e
"$REAL_GIT" -C "\$1" worktree add -q "$BRANCH_BUSY_OTHER" "\$2"
EOF
chmod +x "$TMPROOT/add-second-checkout"
export DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF="$TMPROOT/add-second-checkout"
fresh="$(run_reuse_attempt "$BRANCH_BUSY_WT" reuse/branch-busy feat/branch-busy branch-busy)"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF
assert_eq "$rc" "0" "occupied-branch fallback exits zero"
assert_eq "$fresh" "$WTROOT/branch-busy" "occupied old branch uses fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/branch-busy)" "$ORIGIN_SHA" "old branch ref survives second checkout"
assert_eq "$(git -C "$BRANCH_BUSY_OTHER" symbolic-ref --short HEAD)" "reuse/branch-busy" "second worktree remains attached to its branch"
assert_eq "$(git -C "$BRANCH_BUSY_OTHER" rev-parse HEAD)" "$ORIGIN_SHA" "second worktree HEAD remains valid"
assert_eq "$(git -C "$BRANCH_BUSY_WT" symbolic-ref -q --short HEAD || true)" "" "candidate stays detached when recovery is unsafe"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$BRANCH_BUSY_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse',{}).get('state','')); break
 except OSError: pass
PY
)" "reuse_incomplete" "occupied candidate is parked for recovery"

echo "== case 36: ignored bytes created after checkout survive rollback =="
ROLLBACK_WT="$WTROOT/reuse-rollback-ignored"
git -C "$REPO" config --add core.excludesFile "$TMPROOT/global-excludes"
echo ignored-target.txt >> "$TMPROOT/global-excludes"
git -C "$REPO" checkout -q -b reuse/rollback-ignored main
echo original-tracked > "$REPO/ignored-target.txt"
git -C "$REPO" add -f ignored-target.txt
git -C "$REPO" commit -q -m old-branch-tracked-file
git -C "$REPO" push -q origin reuse/rollback-ignored
git -C "$REPO" checkout -q main
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse main)"
# The old branch must own the tracked path; the new base must not. Otherwise
# the hook edits a tracked file and the test misses ignored-file rollback.
assert_eq "$(git -C "$REPO" show reuse/rollback-ignored:ignored-target.txt)" "original-tracked" "rollback old branch tracks the collision path"
if git -C "$REPO" cat-file -e origin/main:ignored-target.txt 2>/dev/null; then
    bad "rollback new base unexpectedly tracks the collision path"
else
    ok "rollback new base leaves the collision path untracked"
fi
git -C "$REPO" worktree add -q "$ROLLBACK_WT" reuse/rollback-ignored
cat > "$TMPROOT/add-ignored-after-switch" <<'EOF'
#!/usr/bin/env bash
echo keep-user-bytes > "$3/ignored-target.txt"
EOF
chmod +x "$TMPROOT/add-ignored-after-switch"
export DISK_MAGICIAN_TEST_AFTER_BRANCH_SWITCH="$TMPROOT/add-ignored-after-switch" DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE=1
fallback="$(run_reuse_attempt "$ROLLBACK_WT" reuse/rollback-ignored feat/rollback-ignored rollback-ignored)"; rc=$?
unset DISK_MAGICIAN_TEST_AFTER_BRANCH_SWITCH DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE
[[ "$rc" -ne 0 ]] && ok "unsafe rollback fails closed ($rc)" || bad "unsafe rollback unexpectedly succeeded: $fallback"
assert_eq "$(cat "$ROLLBACK_WT/ignored-target.txt")" "keep-user-bytes" "ignored bytes survive failed rollback"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/rollback-ignored)" "$(git -C "$REPO" ls-remote origin refs/heads/reuse/rollback-ignored | awk 'NR==1{print $1}')" "old branch ref restored at remote tip"

echo "== case 26: failure after conditional delete restores the old branch =="
RESTORE_WT="$WTROOT/reuse-restore"
git -C "$REPO" branch reuse/restore "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$RESTORE_WT" reuse/restore
bash -c 'source "$1"; lease_write "$2" "$3" reuse/restore reuse-test' _ "$SCRIPT" "$RESTORE_WT" "$REPO" >/dev/null 2>&1
export DISK_MAGICIAN_TEST_FAIL_AFTER_REF_DELETE=1
fresh="$(run_reuse_attempt "$RESTORE_WT" reuse/restore feat/restore restore)"; rc=$?
unset DISK_MAGICIAN_TEST_FAIL_AFTER_REF_DELETE
assert_eq "$rc" "0" "post-delete failure fallback exits zero"
assert_eq "$fresh" "$WTROOT/restore" "post-delete failure creates fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/restore)" "$ORIGIN_SHA" "old branch restored at its recorded tip"
assert_eq "$(git -C "$RESTORE_WT" rev-parse --abbrev-ref HEAD)" "reuse/restore" "candidate switches back to old branch"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$RESTORE_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse','')) ; break
 except OSError: pass
PY
)" "" "lease claim restored after recovery"

echo "== case 27: conflicting recreated old ref is preserved and marked incomplete =="
CONFLICT_WT="$WTROOT/reuse-conflict"
git -C "$REPO" branch reuse/conflict "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$CONFLICT_WT" reuse/conflict
bash -c 'source "$1"; lease_write "$2" "$3" reuse/conflict reuse-test' _ "$SCRIPT" "$CONFLICT_WT" "$REPO" >/dev/null 2>&1
cat > "$TMPROOT/conflict-ref-hook" <<EOF
#!/usr/bin/env bash
set -e
repo=\$1; branch=\$2; tip=\$3
new=\$("$REAL_GIT" -C "\$repo" commit-tree "\$tip^{tree}" -p "\$tip" -m competing-ref)
"$REAL_GIT" -C "\$repo" update-ref "refs/heads/\$branch" "\$new" 0000000000000000000000000000000000000000
EOF
chmod +x "$TMPROOT/conflict-ref-hook"
export DISK_MAGICIAN_TEST_RECREATE_OLD_REF_AFTER_DELETE="$TMPROOT/conflict-ref-hook" DISK_MAGICIAN_TEST_FAIL_AFTER_REF_DELETE=1
fresh="$(run_reuse_attempt "$CONFLICT_WT" reuse/conflict feat/conflict conflict)"; rc=$?
unset DISK_MAGICIAN_TEST_RECREATE_OLD_REF_AFTER_DELETE DISK_MAGICIAN_TEST_FAIL_AFTER_REF_DELETE
assert_eq "$rc" "0" "conflicting ref fallback exits zero"
assert_eq "$fresh" "$WTROOT/conflict" "conflicting ref leaves fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/conflict^ )" "$ORIGIN_SHA" "conflicting ref commit is preserved"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$CONFLICT_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse',{}).get('state','')); break
 except OSError: pass
PY
)" "reuse_incomplete" "lease records incomplete recovery"

echo "== case 28: lease rewrite failure restores the old branch and claim =="
LEASEFAIL_WT="$WTROOT/reuse-leasefail"
git -C "$REPO" branch reuse/leasefail "$ORIGIN_SHA"; git -C "$REPO" worktree add -q "$LEASEFAIL_WT" reuse/leasefail
bash -c 'source "$1"; lease_write "$2" "$3" reuse/leasefail reuse-test' _ "$SCRIPT" "$LEASEFAIL_WT" "$REPO" >/dev/null 2>&1
export DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE=1
fresh="$(run_reuse_attempt "$LEASEFAIL_WT" reuse/leasefail feat/reuse-leasefail leasefail)"; rc=$?
unset DISK_MAGICIAN_TEST_FAIL_LEASE_REWRITE
assert_eq "$rc" "0" "lease rewrite failure fallback exits zero"
assert_eq "$fresh" "$WTROOT/leasefail" "lease rewrite failure creates fresh path"
assert_eq "$(git -C "$REPO" rev-parse refs/heads/reuse/leasefail)" "$ORIGIN_SHA" "old branch restored after lease failure"
assert_eq "$(git -C "$LEASEFAIL_WT" rev-parse --abbrev-ref HEAD)" "reuse/leasefail" "candidate restored after lease failure"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$LEASEFAIL_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse','')); break
 except OSError: pass
PY
)" "" "old claim restored after lease failure"

echo "== case 37: replacement checkout after detach is parked, not switched =="
REPLACE_WT="$WTROOT/reuse-replacement"
git -C "$REPO" branch reuse/replacement "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$REPLACE_WT" reuse/replacement
cat > "$TMPROOT/replace-checkout-hook" <<EOF
#!/usr/bin/env bash
set -e
"$REAL_GIT" -C "\$1" worktree remove --force "\$3"
"$REAL_GIT" -C "\$1" worktree add -q -b reuse/replacement-new "\$3" "$ORIGIN_SHA"
EOF
chmod +x "$TMPROOT/replace-checkout-hook"
export DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF="$TMPROOT/replace-checkout-hook"
fresh="$(run_reuse_attempt "$REPLACE_WT" reuse/replacement feat/replacement replacement)"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF
assert_eq "$rc" "0" "replacement fallback exit"
assert_eq "$fresh" "$WTROOT/replacement" "replacement checkout uses fresh path"
assert_eq "$(git -C "$REPLACE_WT" rev-parse --abbrev-ref HEAD)" "reuse/replacement-new" "replacement checkout keeps its own branch"
assert_eq "$(git -C "$REPLACE_WT" rev-parse HEAD)" "$ORIGIN_SHA" "replacement checkout content unchanged"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$REPLACE_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse',{}).get('state','')); break
 except OSError: pass
PY
)" "reuse_incomplete" "replacement lease parked incomplete"

echo "== case 38: failed claim restore at pre-detach C14 parks the lease =="
RESTOREFAIL_WT="$WTROOT/reuse-restorefail"
git -C "$REPO" branch reuse/restorefail "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$RESTOREFAIL_WT" reuse/restorefail
bash -c 'source "$1"; lease_write "$2" "$3" reuse/restorefail reuse-test' _ "$SCRIPT" "$RESTOREFAIL_WT" "$REPO" >/dev/null 2>&1
RESTOREFAIL_MARK="$TMPROOT/restorefail-verdict"
fresh="$(bash -c '
    source "$1"
    RESTORE_MARK="$3"
    RESTORE_TARGET="$2"
    lease_owner_state() { [[ "$(_lease_get "$1" path)" == "$RESTORE_TARGET" ]] && echo dead || echo alive; }
    worktree_is_recently_active_minutes() { return 1; }
    artifact_removal_verdict() {
        [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }
        if [[ -e "$RESTORE_MARK" ]]; then echo keep; else touch "$RESTORE_MARK"; echo remove; fi
    }
    lease_restore_reuse_claim() { return 1; }
    wtn_main "$4" feat/restorefail --base origin/main --name restorefail
' _ "$SCRIPT" "$RESTOREFAIL_WT" "$RESTOREFAIL_MARK" "$REPO" 2>"$TMPROOT/restorefail.err")"; rc=$?
assert_eq "$rc" "0" "failed-restore fallback exit"
assert_eq "$fresh" "$WTROOT/restorefail" "failed-restore creates fresh path"
assert_eq "$(git -C "$RESTOREFAIL_WT" rev-parse --abbrev-ref HEAD)" "reuse/restorefail" "failed-restore candidate untouched"
assert_eq "$(python3 - "$DISK_MAGICIAN_STATE_DIR" "$RESTOREFAIL_WT" <<'PY'
import glob,json,os,sys
for p in glob.glob(os.path.join(sys.argv[1],'worktree_leases','*.json')):
 try:
  d=json.load(open(p))
  if d.get('path')==sys.argv[2]: print(d.get('reuse',{}).get('state','')); break
 except OSError: pass
PY
)" "reuse_incomplete" "failed-restore lease parked incomplete"

echo "== case 20: incomplete C14 content verdict fails closed to a fresh worktree =="
export C14INC_WT="$WTROOT/reuse-c14-inc"
git -C "$REPO" branch reuse/c14-inc "$ORIGIN_SHA"
git -C "$REPO" worktree add -q "$C14INC_WT" reuse/c14-inc
bash -c 'source "$1"; lease_write "$2" "$3" reuse/c14-inc reuse-test' _ "$SCRIPT" "$C14INC_WT" "$REPO" >/dev/null 2>&1
export C14INC_VERDICT_LOG="$TMPROOT/c14-inc-verdict.log"; : > "$C14INC_VERDICT_LOG"
c14inc_out="$(bash -c '
    source "$1"
    lease_owner_state() {
        if [[ "$(_lease_get "$1" path)" == "$C14INC_WT" ]]; then echo dead; else echo alive; fi
    }
    worktree_is_recently_active_minutes() { return 1; }
    # Self-test passes; the candidate-content verdict is incomplete. This reaches
    # the second C14 gate (the one 19b never exercises), so reuse must refuse.
    artifact_removal_verdict() {
        [[ "${1:-}" == --self-test ]] && { echo ok; return 0; }
        printf "%s %s\n" "${2:-}" "${3:-}" >> "$C14INC_VERDICT_LOG"
        echo incomplete
    }
    wtn_main "$2" feat/c14-inc --base origin/main --name c14-inc
' _ "$SCRIPT" "$REPO" 2>"$TMPROOT/c14-inc.err")"; rc=$?
assert_eq "$rc" "0" "incomplete C14 content fallback exit"
assert_eq "$c14inc_out" "$WTROOT/c14-inc" "incomplete C14 content verdict uses fresh path"
assert_eq "$(git -C "$C14INC_WT" rev-parse --abbrev-ref HEAD)" "reuse/c14-inc" "incomplete C14 content verdict leaves candidate untouched"
grep -q -- "--own-reuse-claim" "$C14INC_VERDICT_LOG" && ok "content C14 gate reached (--own-reuse-claim)" || bad "content C14 gate not reached: $(cat "$C14INC_VERDICT_LOG")"
unset C14INC_VERDICT_LOG C14INC_WT

echo "== case 39: zero-LFS repo sets lfs.locksverify=false so push succeeds; LFS repos keep default =="
git init -q --bare -b main "$TMPROOT/nolfs-origin.git"
git clone -q "$TMPROOT/nolfs-origin.git" "$TMPROOT/nolfs" 2>/dev/null
git -C "$TMPROOT/nolfs" commit -q --allow-empty -m base
git -C "$TMPROOT/nolfs" push -q origin HEAD:main
mkdir -p "$TMPROOT/nolfs/.git/hooks"
cat > "$TMPROOT/nolfs/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
if [[ "$(git config --bool --get lfs.locksverify 2>/dev/null)" != "false" ]]; then
    echo "Authentication required: You must have push access to verify locks" >&2
    exit 1
fi
EOF
chmod +x "$TMPROOT/nolfs/.git/hooks/pre-push"
nolfs_wt="$(bash "$SCRIPT" "$TMPROOT/nolfs" feat/nolfs-push 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "zero-LFS worktree-new exit"
assert_eq "$(git -C "$nolfs_wt" config --bool --get lfs.locksverify 2>/dev/null)" "false" "zero-LFS worktree sets lfs.locksverify=false"
git -C "$nolfs_wt" commit -q --allow-empty -m "worktree change"
git -C "$nolfs_wt" push -q origin HEAD:refs/heads/feat/nolfs-push 2>"$TMPROOT/nolfs-push.err"; rc=$?
assert_eq "$rc" "0" "git push from zero-LFS worktree succeeds without GIT_LFS_SKIP_PUSH"

git init -q -b main "$TMPROOT/withlfs"
echo "*.bin filter=lfs diff=lfs merge=lfs -text" > "$TMPROOT/withlfs/.gitattributes"
git -C "$TMPROOT/withlfs" add .gitattributes
git -C "$TMPROOT/withlfs" commit -q -m "track lfs"
withlfs_wt="$(bash "$SCRIPT" "$TMPROOT/withlfs" feat/withlfs 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "LFS-attributes worktree-new exit"
assert_eq "$(git -C "$withlfs_wt" config --get lfs.locksverify 2>/dev/null || true)" "" "LFS-attributes repo does not force lfs.locksverify=false"

git init -q -b main "$TMPROOT/withlfsobj"
git -C "$TMPROOT/withlfsobj" commit -q --allow-empty -m base
mkdir -p "$TMPROOT/withlfsobj/.git/lfs/objects/aa/bb"
echo "lfs-blob" > "$TMPROOT/withlfsobj/.git/lfs/objects/aa/bb/0123456789"
withlfsobj_wt="$(bash "$SCRIPT" "$TMPROOT/withlfsobj" feat/withlfsobj 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "LFS-objects worktree-new exit"
assert_eq "$(git -C "$withlfsobj_wt" config --get lfs.locksverify 2>/dev/null || true)" "" "LFS-objects repo does not force lfs.locksverify=false"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

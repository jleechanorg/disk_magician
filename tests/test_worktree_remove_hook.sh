#!/usr/bin/env bash
# test_worktree_remove_hook.sh — `diskm worktree-remove-hook` (spec D3b): Claude
# WorktreeRemove hook only removes clean, fully-pushed worktrees under the
# standard root, never with --force. Temp HOME and temp repos only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_remove_hook.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { [[ -n "$TMPROOT" && "$TMPROOT" == /*/tmp.* ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset STANDARD_WORKTREE_ROOT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
LOG="$HOME/.disk_magician_state/worktree_guard.log"

git init -q --bare -b main "$TMPROOT/origin.git"
git clone -q "$TMPROOT/origin.git" "$TMPROOT/myrepo" 2>/dev/null
REPO="$TMPROOT/myrepo"
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" push -q origin HEAD:main
WTROOT="$HOME/.worktrees/myrepo"

# add_wt <name> <branch> [dir] — linked worktree on <branch> from origin/main.
add_wt() {
    git -C "$REPO" worktree add -q -b "$2" "${3:-$WTROOT/$1}" origin/main 2>/dev/null
}
run_hook() { printf '%s' "$1" | bash "$SCRIPT" >/dev/null 2>&1; }
json() { python3 -c 'import json,sys; print(json.dumps({"worktree_path": sys.argv[1]}))' "$1"; }
branch_exists() { git -C "$REPO" show-ref -q --verify "refs/heads/$1"; }
log_lines() { [[ -f "$LOG" ]] && wc -l <"$LOG" | tr -d ' ' || echo 0; }

echo "== case 1: clean + pushed worktree-* branch → removed, branch deleted =="
add_wt a worktree-a
run_hook "$(json "$WTROOT/a")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ ! -e "$WTROOT/a" ]] && ok "worktree dir removed" || bad "worktree dir still present"
git -C "$REPO" worktree list --porcelain | grep -q "$WTROOT/a" && bad "still registered" || ok "unregistered"
branch_exists worktree-a && bad "branch worktree-a kept" || ok "branch worktree-a deleted"

echo "== case 2: dirty (tracked modification) → left, log line =="
add_wt b worktree-b
echo x >"$WTROOT/b/f"; git -C "$WTROOT/b" add f; git -C "$WTROOT/b" commit -q -m f
git -C "$WTROOT/b" push -q origin HEAD:refs/heads/b 2>/dev/null
echo y >"$WTROOT/b/f"
before="$(log_lines)"
run_hook "$(json "$WTROOT/b")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/b/f" ]] && ok "dirty worktree kept" || bad "dirty worktree removed"
branch_exists worktree-b && ok "branch kept" || bad "branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"

echo "== case 3: dirty (untracked file only) → left, log line =="
add_wt c worktree-c
echo z >"$WTROOT/c/untracked"
before="$(log_lines)"
run_hook "$(json "$WTROOT/c")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/c/untracked" ]] && ok "untracked worktree kept" || bad "untracked worktree removed"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"

echo "== case 4: clean but unpushed commit → left =="
add_wt d worktree-d
git -C "$WTROOT/d" commit -q --allow-empty -m unpushed
before="$(log_lines)"
run_hook "$(json "$WTROOT/d")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$WTROOT/d" ]] && ok "unpushed worktree kept" || bad "unpushed worktree removed"
branch_exists worktree-d && ok "branch kept" || bad "branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"

echo "== case 5: clean + pushed but outside the standard root → left =="
add_wt e worktree-e "$TMPROOT/outside/e"
before="$(log_lines)"
run_hook "$(json "$TMPROOT/outside/e")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$TMPROOT/outside/e" ]] && ok "outside worktree kept" || bad "outside worktree removed"
branch_exists worktree-e && ok "branch kept" || bad "branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"

echo "== case 6: malformed stdin → exit 0, nothing removed =="
add_wt f worktree-f
for payload in 'not json' '{}' '{"worktree_path": 7}' '[]' ''; do
    run_hook "$payload"; rc=$?
    assert_eq "$rc" "0" "exit code for '$payload'"
done
[[ -d "$WTROOT/f" ]] && ok "worktree f untouched" || bad "worktree f removed"
branch_exists worktree-f && ok "branch f kept" || bad "branch f deleted"

echo "== case 7: plain dir under root, not a registered worktree → left =="
mkdir -p "$WTROOT/plain"; : >"$WTROOT/plain/keep"
run_hook "$(json "$WTROOT/plain")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/plain/keep" ]] && ok "plain dir kept" || bad "plain dir removed"

echo "== case 8: main checkout itself under root → left =="
git clone -q "$TMPROOT/origin.git" "$HOME/.worktrees/mainclone" 2>/dev/null
run_hook "$(json "$HOME/.worktrees/mainclone")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$HOME/.worktrees/mainclone/.git" ]] && ok "main checkout kept" || bad "main checkout removed"

echo "== case 9: clean + pushed, non worktree-* branch → removed, branch kept =="
add_wt g feat/g
run_hook "$(json "$WTROOT/g")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ ! -e "$WTROOT/g" ]] && ok "worktree removed" || bad "worktree kept"
branch_exists feat/g && ok "non worktree-* branch kept" || bad "feat/g deleted"

echo "== case 10: worktree-* branch also checked out elsewhere → branch kept =="
add_wt h worktree-h
git -C "$REPO" worktree add -q -f "$WTROOT/h2" worktree-h 2>/dev/null
run_hook "$(json "$WTROOT/h")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ ! -e "$WTROOT/h" ]] && ok "worktree h removed" || bad "worktree h kept"
branch_exists worktree-h && ok "branch kept while checked out in h2" || bad "branch deleted"

echo "== case 11: only change is a gitignored .env → left, branch kept, log names ignored =="
add_wt i worktree-i
echo .env >"$WTROOT/i/.gitignore"; git -C "$WTROOT/i" add .gitignore; git -C "$WTROOT/i" commit -q -m ignore
git -C "$WTROOT/i" push -q origin HEAD:refs/heads/i 2>/dev/null
echo 'SECRET_VALUE_XYZ=1' >"$WTROOT/i/.env"
before="$(log_lines)"
run_hook "$(json "$WTROOT/i")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/i/.env" ]] && ok "ignored-file worktree kept" || bad "ignored-file worktree removed"
branch_exists worktree-i && ok "branch kept" || bad "branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"
tail -n 1 "$LOG" | grep -q "ignored" && ok "log names ignored files" || bad "log does not mention ignored files"
grep -q -e SECRET_VALUE_XYZ -e '\.env' "$LOG" && bad "log leaks ignored file name/contents" || ok "log has no ignored file name/contents"

echo "== case 12: locked but otherwise removable → left, exit 0 (no --force) =="
add_wt j worktree-j
git -C "$REPO" worktree lock "$WTROOT/j"
before="$(log_lines)"
run_hook "$(json "$WTROOT/j")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$WTROOT/j" ]] && ok "locked worktree kept" || bad "locked worktree removed"
branch_exists worktree-j && ok "branch kept" || bad "branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"

echo "== case 13: malformed stdin appends a log line =="
before="$(log_lines)"
run_hook 'not json'; rc=$?
assert_eq "$rc" "0" "exit code"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"
tail -n 1 "$LOG" | grep -q "malformed stdin" && ok "log says malformed stdin" || bad "log missing malformed stdin"

echo "== case 14: rebuildable ignored files (node_modules, .mypy_cache) → removed, branch deleted =="
printf 'node_modules/\n.mypy_cache/\n' >>"$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" commit -q -m "ignore rebuildable dirs"
git -C "$REPO" push -q origin HEAD:main
add_wt k worktree-k
mkdir -p "$WTROOT/k/node_modules/pkg"
echo "console.log(1)" >"$WTROOT/k/node_modules/pkg/index.js"
mkdir -p "$WTROOT/k/.mypy_cache/3.13"
echo "cache" >"$WTROOT/k/.mypy_cache/3.13/cache.json"
before="$(log_lines)"
run_hook "$(json "$WTROOT/k")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ ! -e "$WTROOT/k" ]] && ok "rebuildable-ignored worktree removed" || bad "rebuildable-ignored worktree kept"
git -C "$REPO" worktree list --porcelain | grep -q "$WTROOT/k" && bad "still registered" || ok "unregistered"
branch_exists worktree-k && bad "branch worktree-k kept" || ok "branch worktree-k deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"
grep -q "removed $WTROOT/k" "$LOG" && ok "log says removed" || bad "log does not mention removed"
grep -q "deleted branch worktree-k" "$LOG" && ok "log says branch deleted" || bad "log does not mention branch deleted"

echo "== case 15: non-rebuildable ignored data (data/db.sqlite, scratch/notes.txt) → preserved =="
add_wt l worktree-l
printf 'data/\nscratch/\n' >"$WTROOT/l/.gitignore"
git -C "$WTROOT/l" add .gitignore
git -C "$WTROOT/l" commit -q -m ignore
git -C "$WTROOT/l" push -q origin HEAD:refs/heads/l 2>/dev/null
mkdir -p "$WTROOT/l/data" "$WTROOT/l/scratch"
echo "sqlite format 3" >"$WTROOT/l/data/db.sqlite"
echo "important notes" >"$WTROOT/l/scratch/notes.txt"
before="$(log_lines)"
run_hook "$(json "$WTROOT/l")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/l/data/db.sqlite" ]] && ok "non-rebuildable data preserved" || bad "non-rebuildable data deleted"
[[ -f "$WTROOT/l/scratch/notes.txt" ]] && ok "non-rebuildable scratch preserved" || bad "non-rebuildable scratch deleted"
branch_exists worktree-l && ok "branch worktree-l kept" || bad "branch worktree-l deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "log line appended" || bad "no log line"
tail -n 1 "$LOG" | grep -q "ignored" && ok "log names ignored data" || bad "log does not mention ignored data"


echo "== case 16: ignored directory with file-like cache suffix → preserved =="
add_wt m worktree-m
printf 'data.pyc/\n' >"$WTROOT/m/.gitignore"
git -C "$WTROOT/m" add .gitignore
git -C "$WTROOT/m" commit -q -m ignore
git -C "$WTROOT/m" push -q origin HEAD:refs/heads/m 2>/dev/null
mkdir -p "$WTROOT/m/data.pyc"; echo y >"$WTROOT/m/data.pyc/keep.db"
run_hook "$(json "$WTROOT/m")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/m/data.pyc/keep.db" ]] && ok "data.pyc directory preserved" || bad "data.pyc directory removed"
echo "PASS=$PASS FAIL=$FAIL"
echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

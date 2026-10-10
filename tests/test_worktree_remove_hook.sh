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
MOCK_BIN="$TMPROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/lsof" <<'MOCK'
#!/usr/bin/env bash
[[ "${FAKE_LSOF_FAIL:-0}" == 1 ]] && exit 1
if [[ "${FAKE_LSOF_MODE:-}" == caller ]]; then
  printf 'p%s\nn%s\n' "$WRH_LIFECYCLE_CALLER_PID" "$FAKE_LSOF_CWD"
elif [[ "${FAKE_LSOF_MODE:-}" == dispatcher ]]; then
  command_sub=$PPID
  helper=$(ps -o ppid= -p "$command_sub" | tr -d '[:space:]')
  hook=$(ps -o ppid= -p "$helper" | tr -d '[:space:]')
  shell=$(ps -o ppid= -p "$hook" | tr -d '[:space:]')
  cli=$(ps -o ppid= -p "$shell" | tr -d '[:space:]')
  printf 'p%s\nn/\n' "$command_sub"
  printf 'p%s\nn/\n' "$helper"
  for pid in "$hook" "$shell"; do printf 'p%s\nn%s\n' "$pid" "$FAKE_LSOF_CWD"; done
else
  cat "${FAKE_LSOF_FIXTURE:?}"
fi
MOCK
chmod +x "$MOCK_BIN/lsof"
export PATH="$MOCK_BIN:$PATH"
FAKE_LSOF_FIXTURE="$TMPROOT/lsof.out"
printf 'p999999\nn/\n' >"$FAKE_LSOF_FIXTURE"
export FAKE_LSOF_FIXTURE

git init -q --bare -b main "$TMPROOT/origin.git"
git clone -q "$TMPROOT/origin.git" "$TMPROOT/myrepo" 2>/dev/null
REPO="$TMPROOT/myrepo"
printf "base\n" >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m base
git -C "$REPO" push -q origin HEAD:main
WTROOT="$HOME/.worktrees/myrepo"

# add_wt <name> <branch> [dir] — linked worktree on <branch> from origin/main.
add_wt() {
    git -C "$REPO" worktree add -q -b "$2" "${3:-$WTROOT/$1}" origin/main 2>/dev/null
    python3 - "${3:-$WTROOT/$1}" <<'AGEWT'
import os, sys, time
root = sys.argv[1]
old = time.time() - 8 * 86400
for base, dirs, files in os.walk(root):
    for name in files:
        path = os.path.join(base, name)
        try: os.utime(path, (old, old))
        except OSError: pass
AGEWT
}
age_wt() { python3 - "$1" <<'AGEWT2'
import os, sys, time
old = time.time() - 8 * 86400
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(base, name)
        try: os.utime(path, (old, old))
        except OSError: pass
AGEWT2
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
age_wt "$WTROOT/i"
git -C "$WTROOT/i" push -q origin HEAD:refs/heads/i 2>/dev/null
echo 'SECRET_VALUE_XYZ=1' >"$WTROOT/i/.env"
age_wt "$WTROOT/i"
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
age_wt "$WTROOT/k"
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
age_wt "$WTROOT/l"
git -C "$WTROOT/l" push -q origin HEAD:refs/heads/l 2>/dev/null
mkdir -p "$WTROOT/l/data" "$WTROOT/l/scratch"
echo "sqlite format 3" >"$WTROOT/l/data/db.sqlite"
echo "important notes" >"$WTROOT/l/scratch/notes.txt"
age_wt "$WTROOT/l"
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
age_wt "$WTROOT/m"
git -C "$WTROOT/m" push -q origin HEAD:refs/heads/m 2>/dev/null
mkdir -p "$WTROOT/m/data.pyc"; echo y >"$WTROOT/m/data.pyc/keep.db"
run_hook "$(json "$WTROOT/m")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/m/data.pyc/keep.db" ]] && ok "data.pyc directory preserved" || bad "data.pyc directory removed"
echo "== case 17: ignored .testmondata database directory -> preserved =="
add_wt n worktree-n
printf '.testmondata/\n' >"$WTROOT/n/.gitignore"
git -C "$WTROOT/n" add .gitignore
git -C "$WTROOT/n" commit -q -m ignore
age_wt "$WTROOT/n"
git -C "$WTROOT/n" push -q origin HEAD:refs/heads/n 2>/dev/null
mkdir -p "$WTROOT/n/.testmondata"; echo db >"$WTROOT/n/.testmondata/notes.db"
run_hook "$(json "$WTROOT/n")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/n/.testmondata/notes.db" ]] && ok ".testmondata directory preserved" || bad ".testmondata directory removed"

echo "== case 18: ignored *.egg-info directory -> preserved =="
add_wt o worktree-o
printf '*.egg-info\n' >"$WTROOT/o/.gitignore"
git -C "$WTROOT/o" add .gitignore
git -C "$WTROOT/o" commit -q -m ignore
age_wt "$WTROOT/o"
git -C "$WTROOT/o" push -q origin HEAD:refs/heads/o 2>/dev/null
mkdir -p "$WTROOT/o/package.egg-info"; echo user >"$WTROOT/o/package.egg-info/notes.db"
run_hook "$(json "$WTROOT/o")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -f "$WTROOT/o/package.egg-info/notes.db" ]] && ok "egg-info directory preserved" || bad "egg-info directory removed"
echo "== case 19: other process cwd in clean pushed worktree - preserved =="
add_wt u worktree-u
printf 'p999999\nn%s/subdir\n' "$WTROOT/u" >"$FAKE_LSOF_FIXTURE"
before="$(log_lines)"
run_hook "$(json "$WTROOT/u")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$WTROOT/u" ]] && ok "active-cwd worktree kept" || bad "active-cwd worktree removed"
branch_exists worktree-u && ok "active-cwd branch kept" || bad "active-cwd branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "active-cwd log line appended" || bad "active-cwd no log line"
tail -n 1 "$LOG" | grep -q "live-cwd" && ok "active-cwd reason logged" || bad "active-cwd reason missing"
printf 'p999999\nn/\n' >"$FAKE_LSOF_FIXTURE"

echo "== case 20: AO-configured worktreeDir - preserved =="
mkdir -p "$HOME/.worktrees/ao-proj"
cat >"$HOME/agent-orchestrator.yaml" <<YAML
worktreeDir: "$HOME/.worktrees"
projects:
  ao-project:
    path: /tmp/ao-project
    worktreeDir: "$HOME/.worktrees/ao-proj"
YAML
export DISK_MAGICIAN_AO_CONFIG="$HOME/agent-orchestrator.yaml"
add_wt ao worktree-ao "$HOME/.worktrees/ao-proj/ao"
before="$(log_lines)"
run_hook "$(json "$HOME/.worktrees/ao-proj/ao")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$HOME/.worktrees/ao-proj/ao" ]] && ok "AO-owned worktree kept" || bad "AO-owned worktree removed"
branch_exists worktree-ao && ok "AO-owned branch kept" || bad "AO-owned branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "AO-owned log line appended" || bad "AO-owned no log line"
tail -n 1 "$LOG" | grep -q "ao-owned" && ok "AO-owned reason logged" || bad "AO-owned reason missing"

echo "== case 21: lsof failure makes cwd unknown - preserves candidate =="
add_wt p worktree-p
export FAKE_LSOF_FAIL=1
before="$(log_lines)"
run_hook "$(json "$WTROOT/p")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$WTROOT/p" ]] && ok "unknown-cwd worktree kept" || bad "unknown-cwd worktree removed"
branch_exists worktree-p && ok "unknown-cwd branch kept" || bad "unknown-cwd branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "unknown-cwd log line appended" || bad "unknown-cwd no log line"
tail -n 1 "$LOG" | grep -q "cwd-unknown" && ok "unknown-cwd reason logged" || bad "unknown-cwd reason missing"
unset FAKE_LSOF_FAIL

echo "== case 22: explicit missing AO config makes ownership unknown - preserves candidate =="
add_wt q worktree-q
export DISK_MAGICIAN_AO_CONFIG="$HOME/missing-agent-orchestrator.yaml"
before="$(log_lines)"
run_hook "$(json "$WTROOT/q")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ -d "$WTROOT/q" ]] && ok "unknown-AO worktree kept" || bad "unknown-AO worktree removed"
branch_exists worktree-q && ok "unknown-AO branch kept" || bad "unknown-AO branch deleted"
[[ "$(log_lines)" -gt "$before" ]] && ok "unknown-AO log line appended" || bad "unknown-AO no log line"
tail -n 1 "$LOG" | grep -q "ao-config-unreadable" && ok "unknown-AO reason logged" || bad "unknown-AO reason missing"
unset DISK_MAGICIAN_AO_CONFIG
printf 'p999999\nn/\n' >"$FAKE_LSOF_FIXTURE"


echo "== case 23: lifecycle caller cwd in target is exempted =="
add_wt r worktree-r
export FAKE_LSOF_MODE=caller FAKE_LSOF_CWD="$WTROOT/r/subdir"
run_hook "$(json "$WTROOT/r")"; rc=$?
assert_eq "$rc" "0" "exit code"
[[ ! -e "$WTROOT/r" ]] && ok "caller-cwd worktree removed" || bad "caller-cwd worktree kept"
branch_exists worktree-r && bad "caller-cwd branch kept" || ok "caller-cwd branch deleted"
unset FAKE_LSOF_MODE FAKE_LSOF_CWD
echo "== case 24: AO tilde worktreeDir is expanded and preserved =="
mkdir -p "$HOME/.worktrees/ao-tilde"
cat >"$HOME/agent-orchestrator.yaml" <<YAML
projects:
  p:
    path: /tmp/p
    worktreeDir: ~/.worktrees/ao-tilde
YAML
export DISK_MAGICIAN_AO_CONFIG="$HOME/agent-orchestrator.yaml"
add_wt ao-tilde worktree-ao-tilde "$HOME/.worktrees/ao-tilde/session"
run_hook "$(json "$HOME/.worktrees/ao-tilde/session")"; rc=$?
[[ -d "$HOME/.worktrees/ao-tilde/session" ]] && ok "tilde AO worktree kept" || bad "tilde AO worktree removed"
tail -n 1 "$LOG" | grep -q "ao-owned" && ok "tilde AO reason logged" || bad "tilde AO reason missing"
unset DISK_MAGICIAN_AO_CONFIG

echo "== case 25: trailing-slash repo path basename fallback is preserved =="
mkdir -p "$HOME/.worktrees/repo-base"
cat >"$HOME/agent-orchestrator.yaml" <<YAML
worktreeDir: ~/.worktrees
projects:
  alias:
    path: /tmp/repo-base/
YAML
export DISK_MAGICIAN_AO_CONFIG="$HOME/agent-orchestrator.yaml"
add_wt ao-base worktree-ao-base "$HOME/.worktrees/repo-base/session"
run_hook "$(json "$HOME/.worktrees/repo-base/session")"; rc=$?
[[ -d "$HOME/.worktrees/repo-base/session" ]] && ok "basename fallback AO worktree kept" || bad "basename fallback AO worktree removed"
tail -n 1 "$LOG" | grep -q "ao-owned" && ok "basename fallback AO reason logged" || bad "basename fallback AO reason missing"
unset DISK_MAGICIAN_AO_CONFIG

echo "== case 26: real Python -> shell -> hook caller chain is exempted =="
add_wt t worktree-t
export FAKE_LSOF_MODE=dispatcher FAKE_LSOF_CWD="$WTROOT/t/subdir"
python3 - "$REPO_ROOT/src/disk_magician/cli.py" "$WTROOT/t" <<'DISPATCHERPY'
import json, os, subprocess, sys
cli, target = sys.argv[1:]
result = subprocess.run([sys.executable, cli, "worktree-remove-hook"], input=json.dumps({"worktree_path": target}), text=True, cwd=target, env=os.environ.copy(), capture_output=True)
sys.exit(result.returncode)
DISPATCHERPY
[[ ! -e "$WTROOT/t" ]] && ok "dispatcher caller chain worktree removed" || bad "dispatcher caller chain worktree kept"
unset FAKE_LSOF_MODE FAKE_LSOF_CWD

echo "== case 27: malformed lsof PID without path stays unknown =="
add_wt v worktree-v
printf 'p999999\nn/\np888888\n' >"$FAKE_LSOF_FIXTURE"
run_hook "$(json "$WTROOT/v")"; rc=$?
[[ -d "$WTROOT/v" ]] && ok "missing-path record worktree kept" || bad "missing-path record worktree removed"
tail -n 1 "$LOG" | grep -q "cwd-unknown" && ok "missing-path record unknown reason logged" || bad "missing-path record unknown reason missing"

echo "== case 28: nonabsolute lsof cwd stays unknown =="
add_wt x worktree-x
printf 'p999999\nnrelative\np888888\nn/\n' >"$FAKE_LSOF_FIXTURE"
run_hook "$(json "$WTROOT/x")"; rc=$?
[[ -d "$WTROOT/x" ]] && ok "relative-path record worktree kept" || bad "relative-path record worktree removed"
tail -n 1 "$LOG" | grep -q "cwd-unknown" && ok "relative-path record unknown reason logged" || bad "relative-path record unknown reason missing"

printf 'p999999\nn/\n' >"$FAKE_LSOF_FIXTURE"
echo "== case 31: default AO root owns direct children, not nested repo worktrees =="
cat >"$HOME/default-ao.yaml" <<YAML
worktreeDir: "$HOME/.worktrees"
YAML
export DISK_MAGICIAN_AO_CONFIG="$HOME/default-ao.yaml"
add_wt default-direct worktree-default-direct "$HOME/.worktrees/session-direct"
run_hook "$(json "$HOME/.worktrees/session-direct")"; rc=$?
[[ -d "$HOME/.worktrees/session-direct" ]] && ok "direct child of default AO root kept" || bad "direct child of default AO root removed"
tail -n 1 "$LOG" | grep -q "ao-owned" && ok "direct-child AO reason logged" || bad "direct-child AO reason missing"
mkdir -p "$HOME/.worktrees/deep/repo"
add_wt default-deep worktree-default-deep "$HOME/.worktrees/deep/repo/session"
run_hook "$(json "$HOME/.worktrees/deep/repo/session")"; rc=$?
[[ ! -e "$HOME/.worktrees/deep/repo/session" ]] && ok "nested repo worktree remains eligible" || bad "nested repo worktree incorrectly protected"
echo "== case 32: AO path with trailing space is preserved exactly =="
mkdir -p "$HOME/.worktrees/space-root "
cat >"$HOME/space-ao.yaml" <<YAML
worktreeDir: "$HOME/.worktrees/space-root "
YAML
export DISK_MAGICIAN_AO_CONFIG="$HOME/space-ao.yaml"
add_wt space worktree-space "$HOME/.worktrees/space-root /session"
run_hook "$(json "$HOME/.worktrees/space-root /session")"; rc=$?
[[ -d "$HOME/.worktrees/space-root /session" ]] && ok "trailing-space AO worktree kept" || bad "trailing-space AO worktree removed"
tail -n 1 "$LOG" | grep -Eq "ao-owned|ao-config-unreadable" && ok "trailing-space AO result fails closed" || bad "trailing-space AO result not logged"
result="$(TEST_AO_ROOT="$HOME/.worktrees/space-root " bash -c '''source "$1"; ao_worktree_dirs() { printf "P %s\n" "$TEST_AO_ROOT"; }; wrh_ao_skip_reason "$2"''' _ "$SCRIPT" "$HOME/.worktrees/space-root /session")"
[[ "$result" == "ao-owned" ]] && ok "consumer preserves exact trailing-space record" || bad "consumer altered trailing-space record"
unset DISK_MAGICIAN_AO_CONFIG

printf 'p999999\nn/\n' >"$FAKE_LSOF_FIXTURE"
echo "== case 29: recently touched worktree is protected by 7-day floor =="
add_wt recent worktree-recent
touch "$WTROOT/recent/README.md"
run_hook "$(json "$WTROOT/recent")"; rc=$?
[[ -d "$WTROOT/recent" ]] && ok "recent worktree kept" || bad "recent worktree removed"
tail -n 1 "$LOG" | grep -q "recent-activity" && ok "recent reason logged" || bad "recent reason missing"

echo "== case 30: unmeasurable recency fails closed =="
add_wt unknown worktree-unknown
cat >"$MOCK_BIN/find" <<'FINDFAIL'
#!/usr/bin/env bash
exit 1
FINDFAIL
chmod +x "$MOCK_BIN/find"
run_hook "$(json "$WTROOT/unknown")"; rc=$?
[[ -d "$WTROOT/unknown" ]] && ok "unmeasurable worktree kept" || bad "unmeasurable worktree removed"
rm -f "$MOCK_BIN/find"

echo "== case 33: implicit AO data worktree roots stay protected without config =="
unset DISK_MAGICIAN_AO_CONFIG
for suffix in ao .ao; do
    target="$HOME/.worktrees/$suffix/data/worktrees/repo/session"
    mkdir -p "$(dirname "$target")"
    add_wt "implicit-$suffix" "worktree-implicit-$suffix" "$target"
    run_hook "$(json "$target")"; rc=$?
    [[ -d "$target" ]] && ok "implicit $suffix AO worktree kept" || bad "implicit $suffix AO worktree removed"
    tail -n 1 "$LOG" | grep -q "ao-owned" && ok "implicit $suffix AO reason logged" || bad "implicit $suffix AO reason missing"
done

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

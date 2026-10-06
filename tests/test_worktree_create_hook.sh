#!/usr/bin/env bash
# test_worktree_create_hook.sh — Claude `WorktreeCreate` hook (spec D3, P1):
# stdin {name,cwd}; last non-empty stdout line is the absolute path; git output
# on stderr; never fetches. Temp HOME + temp repos only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_create_hook.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
unset STANDARD_WORKTREE_ROOT DISK_MAGICIAN_WORKTREE_HOOK
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Fake git on PATH: logs every invocation and fails loudly on fetch.
REAL_GIT="$(command -v git)"
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMPROOT/git_calls.log"
for a in "\$@"; do [[ "\$a" == fetch ]] && { echo FETCH >> "$TMPROOT/fetch.marker"; exit 99; }; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMPROOT/bin/git"
export PATH="$TMPROOT/bin:$PATH"

git init -q --bare -b main "$TMPROOT/origin.git"
git clone -q "$TMPROOT/origin.git" "$TMPROOT/seed" 2>/dev/null
git -C "$TMPROOT/seed" commit -q --allow-empty -m base
git -C "$TMPROOT/seed" push -q origin HEAD:main
git clone -q "$TMPROOT/origin.git" "$TMPROOT/myrepo"
REPO="$TMPROOT/myrepo"
mkdir -p "$REPO/sub"
git -C "$REPO" commit -q --allow-empty -m local-only
ORIGIN_SHA="$(git -C "$REPO" rev-parse origin/HEAD)"
WTROOT="$HOME/.worktrees/myrepo"

run_hook() { # <json> -> sets OUT, ERR, RC
    OUT="$(printf '%s' "$1" | bash "$SCRIPT" 2>"$TMPROOT/stderr")"; RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
}
last_line() { printf '%s\n' "$1" | awk 'NF{l=$0} END{print l}'; }

echo "== case 1: creates under ~/.worktrees/<repo>/<name> from origin/HEAD =="
run_hook "{\"session_id\":\"s\",\"name\":\"bold-oak\",\"cwd\":\"$REPO/sub\"}"
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$WTROOT/bold-oak" "last stdout line"
assert_eq "$OUT" "$WTROOT/bold-oak" "stdout carries only the path"
assert_eq "$(git -C "$WTROOT/bold-oak" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-bold-oak" "branch"
assert_eq "$(git -C "$WTROOT/bold-oak" rev-parse HEAD 2>/dev/null)" "$ORIGIN_SHA" "based on origin/HEAD"
if [[ "$ERR" == *"Preparing worktree"* || "$ERR" == *"HEAD is now at"* ]]; then ok "git output on stderr"; else bad "git output not on stderr: '$ERR'"; fi

echo "== case 2: cwd inside a linked worktree maps to the main repo; branch collision -> -2 =="
git -C "$REPO" branch worktree-calm-elm
run_hook "{\"name\":\"calm-elm\",\"cwd\":\"$WTROOT/bold-oak\"}"
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$WTROOT/calm-elm" "path under main repo name"
assert_eq "$(git -C "$WTROOT/calm-elm" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-calm-elm-2" "suffixed branch"

echo "== case 3: -2 also taken -> -3 =="
git -C "$REPO" branch worktree-red-fox
git -C "$REPO" branch worktree-red-fox-2
run_hook "{\"name\":\"red-fox\",\"cwd\":\"$REPO\"}"
assert_eq "$(git -C "$WTROOT/red-fox" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-red-fox-3" "suffixed branch"

echo "== case 4: rejects bad input =="
mkdir -p "$TMPROOT/plain"
run_hook "{\"name\":\"x1\",\"cwd\":\"$TMPROOT/plain\"}"; assert_eq "$RC" "1" "non-repo cwd"
run_hook "{\"name\":\"a/b\",\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "name with /"
run_hook "{\"name\":\"..\",\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "name .."
run_hook "not json"; assert_eq "$RC" "1" "malformed stdin"
[[ ! -e "$HOME/.worktrees/a" ]] && ok "nothing created for bad name" || bad "created path for bad name"

echo "== case 5: DISK_MAGICIAN_WORKTREE_HOOK=off -> <repo>/.claude/worktrees/<name> =="
OUT="$(printf '%s' "{\"name\":\"off-one\",\"cwd\":\"$REPO/sub\"}" | DISK_MAGICIAN_WORKTREE_HOOK=off bash "$SCRIPT" 2>/dev/null)"; RC=$?
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$REPO/.claude/worktrees/off-one" "fallback path"
[[ -d "$REPO/.claude/worktrees/off-one" ]] && ok "fallback worktree exists" || bad "fallback worktree missing"

echo "== case 6: never fetches =="
[[ -s "$TMPROOT/git_calls.log" ]] && ok "fake git was used" || bad "fake git never invoked"
[[ ! -e "$TMPROOT/fetch.marker" ]] && ok "no git fetch" || bad "git fetch was invoked"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

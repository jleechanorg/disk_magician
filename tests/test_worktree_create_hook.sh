#!/usr/bin/env bash
# test_worktree_create_hook.sh — Claude `WorktreeCreate` hook (spec D3, P1):
# stdin {name,cwd}; last non-empty stdout line is the absolute path; git output
# on stderr; never fetches. Temp HOME + temp repos only.
set -uo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_create_hook.sh"

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

echo "== case 3b: branch only on origin also counts as a collision =="
git -C "$REPO" update-ref refs/remotes/origin/worktree-gray-owl "$ORIGIN_SHA"
run_hook "{\"name\":\"gray-owl\",\"cwd\":\"$REPO\"}"
assert_eq "$(git -C "$WTROOT/gray-owl" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-gray-owl-2" "suffixed branch"

echo "== case 4: rejects bad input =="
mkdir -p "$TMPROOT/plain"
run_hook "{\"name\":\"x1\",\"cwd\":\"$TMPROOT/plain\"}"; assert_eq "$RC" "1" "non-repo cwd"
run_hook "{\"name\":\"a/b\",\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "name with /"
run_hook "{\"name\":\"..\",\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "name .."
run_hook "not json"; assert_eq "$RC" "1" "malformed stdin"
run_hook "{\"name\":null,\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "null name"
run_hook "{\"name\":\"a..b\",\"cwd\":\"$REPO\"}"; assert_eq "$RC" "1" "name not a valid ref"
[[ ! -e "$WTROOT/a" && ! -e "$WTROOT/None" && ! -e "$WTROOT/a..b" ]] && ok "nothing created for bad names" || bad "created path for bad name"
if git -C "$REPO" show-ref -q --verify refs/heads/worktree-None; then bad "branch for null name"; else ok "no branch for null name"; fi

echo "== case 5: DISK_MAGICIAN_WORKTREE_HOOK=off -> <repo>/.claude/worktrees/<name> =="
OUT="$(printf '%s' "{\"name\":\"off-one\",\"cwd\":\"$REPO/sub\"}" | DISK_MAGICIAN_WORKTREE_HOOK=off bash "$SCRIPT" 2>/dev/null)"; RC=$?
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$REPO/.claude/worktrees/off-one" "fallback path"
[[ -d "$REPO/.claude/worktrees/off-one" ]] && ok "fallback worktree exists" || bad "fallback worktree missing"

echo "== case 5b: existing target path -> -N suffixed path, original untouched =="
mkdir -p "$WTROOT/busy-bee" "$WTROOT/busy-bee-2"
run_hook "{\"name\":\"busy-bee\",\"cwd\":\"$REPO\"}"
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$WTROOT/busy-bee-3" "suffixed path"
assert_eq "$(git -C "$WTROOT/busy-bee-3" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-busy-bee" "branch"
assert_eq "$(ls -A "$WTROOT/busy-bee")" "" "existing dir untouched"

echo "== case 5c: dangling symlink at the target path -> -N suffixed path =="
ln -s "$TMPROOT/nowhere" "$WTROOT/dangle"
run_hook "{\"name\":\"dangle\",\"cwd\":\"$REPO\"}"
assert_eq "$RC" "0" "exit code"
assert_eq "$(last_line "$OUT")" "$WTROOT/dangle-2" "suffixed path"
[[ -L "$WTROOT/dangle" ]] && ok "symlink untouched" || bad "symlink removed"

echo "== case 5d: branch taken by a concurrent creator mid-create -> re-picks -N branch =="
mkdir -p "$TMPROOT/stealbin"
cat > "$TMPROOT/stealbin/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" worktree-stolen "* && ( " \$* " == *" worktree add "* || " \$* " == *" branch "* ) && ! -e "$TMPROOT/steal.done" ]]; then
    touch "$TMPROOT/steal.done"
    "$REAL_GIT" -C "$REPO" branch --no-track worktree-stolen origin/HEAD
fi
exec "$TMPROOT/bin/git" "\$@"
EOF
chmod +x "$TMPROOT/stealbin/git"
OUT="$(printf '%s' "{\"name\":\"stolen\",\"cwd\":\"$REPO\"}" | PATH="$TMPROOT/stealbin:$PATH" bash "$SCRIPT" 2>/dev/null)"; RC=$?
[[ -e "$TMPROOT/steal.done" ]] && ok "interloper fired" || bad "interloper never fired"
assert_eq "$RC" "0" "exit code"
P="$(last_line "$OUT")"
assert_eq "$(git -C "$P" rev-parse --abbrev-ref HEAD 2>/dev/null)" "worktree-stolen-2" "re-picked branch"
if git -C "$REPO" show-ref -q --verify refs/heads/worktree-stolen; then ok "other's branch survives"; else bad "other's branch deleted"; fi

echo "== case 5e: 6 concurrent same-name hook calls all succeed, distinct paths + branches =="
for i in 1 2 3 4 5 6; do
    ( printf '%s' "{\"name\":\"hk\",\"cwd\":\"$REPO\"}" | bash "$SCRIPT" >"$TMPROOT/hk.$i.out" 2>"$TMPROOT/hk.$i.err"; echo $? >"$TMPROOT/hk.$i.rc" ) &
done
wait
HK_RCS="" HK_PATHS="" HK_BRANCHES=""
for i in 1 2 3 4 5 6; do
    HK_RCS="$HK_RCS$(cat "$TMPROOT/hk.$i.rc")"
    P="$(last_line "$(cat "$TMPROOT/hk.$i.out")")"
    HK_PATHS="$HK_PATHS$P"$'\n'
    HK_BRANCHES="$HK_BRANCHES$(git -C "$P" rev-parse --abbrev-ref HEAD 2>/dev/null)"$'\n'
    if [[ -n "$P" ]] && git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $P"; then
        ok "call $i path registered ($P)"
    else
        bad "call $i path not a registered worktree: '$P' — $(tr "\n" "|" <"$TMPROOT/hk.$i.err")"
    fi
done
assert_eq "$HK_RCS" "000000" "all 6 exit codes"
assert_eq "$(printf '%s' "$HK_PATHS" | grep -c .)" "6" "6 non-empty paths"
assert_eq "$(printf '%s' "$HK_PATHS" | sort -u | grep -c .)" "6" "6 distinct paths"
assert_eq "$(printf '%s' "$HK_BRANCHES" | grep -E '^worktree-hk(-[0-9]+)?$' | sort -u | grep -c .)" "6" "6 distinct worktree-hk* branches"

echo "== case 5f: 12 concurrent same-name calls, 3 rounds: all succeed =="
for round in 1 2 3; do
    nm="cc$round"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        ( printf '%s' "{\"name\":\"$nm\",\"cwd\":\"$REPO\"}" | bash "$SCRIPT" >"$TMPROOT/$nm.$i.out" 2>"$TMPROOT/$nm.$i.err"; echo $? >"$TMPROOT/$nm.$i.rc" ) &
    done
    wait
    RCS=""; PATHS=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        RCS="$RCS$(cat "$TMPROOT/$nm.$i.rc")"
        PATHS="$PATHS$(last_line "$(cat "$TMPROOT/$nm.$i.out")")"$'\n'
    done
    assert_eq "$RCS" "000000000000" "round $round: all 12 exit 0"
    assert_eq "$(printf '%s' "$PATHS" | sort -u | grep -c .)" "12" "round $round: 12 distinct paths"
done

echo "== case 5g: foreign locked+missing worktree at the target survives =="
git -C "$REPO" branch foreignlocked >/dev/null 2>&1
FL="$WTROOT/fl"
git -C "$REPO" worktree add "$FL" foreignlocked >/dev/null 2>&1
git -C "$REPO" worktree lock "$FL" >/dev/null 2>&1
mv "$FL" "$TMPROOT/fl-unmounted"
OUT="$(printf '%s' "{\"name\":\"fl\",\"cwd\":\"$REPO\"}" | bash "$SCRIPT" 2>"$TMPROOT/fl.err")"; RC=$?
assert_eq "$RC" "0" "hook succeeds"
assert_eq "$(last_line "$OUT")" "$WTROOT/fl-2" "picks fl-2"
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $FL" && ok "foreign registration kept" || bad "foreign registration removed"
git -C "$REPO" worktree list --porcelain | grep -A4 -xF "worktree $FL" | grep -q '^locked' && ok "foreign lock kept" || bad "foreign lock removed"
git -C "$REPO" show-ref -q --verify refs/heads/foreignlocked && ok "foreign branch kept" || bad "foreign branch deleted"

echo "== case 6: never fetches =="
[[ -s "$TMPROOT/git_calls.log" ]] && ok "fake git was used" || bad "fake git never invoked"
[[ ! -e "$TMPROOT/fetch.marker" ]] && ok "no git fetch" || bad "git fetch was invoked"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

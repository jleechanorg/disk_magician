#!/usr/bin/env bash
# test_artifact_verdict.sh — C14 (spec §7.2) repository discovery and
# per-repository content checks in scripts/lib/artifact_verdict.sh, function
# level. Temp dirs and temp repos only; nothing is removed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/artifact_verdict.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
    chmod -R u+rwx "$TMPROOT" 2>/dev/null
    [[ -n "$TMPROOT" && "$TMPROOT" == /*/tmp.* ]] && rm -rf "$TMPROOT"
}
trap cleanup EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

if [[ ! -f "$LIB" ]]; then
    bad "scripts/lib/artifact_verdict.sh exists"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$LIB"

# mkrepo <dir>: clean repo with one commit, .gitignore covering the fixtures.
mkrepo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    printf 'tracked\n' >"$1/tracked.txt"
    printf '.env\ndata/\nnode_modules/\n' >"$1/.gitignore"
    git -C "$1" add -A && git -C "$1" commit -qm init
}
content() { c14_repo_content_ok "$1"; }

echo "== control =="
mkrepo "$TMPROOT/clean"
assert_eq "$(content "$TMPROOT/clean")" ok "clean repo"
mkdir -p "$TMPROOT/clean/node_modules/pkg" && printf 'x' >"$TMPROOT/clean/node_modules/pkg/i.js"
assert_eq "$(content "$TMPROOT/clean")" ok "clean repo with rebuildable node_modules"
assert_eq "$(c14_repos_ok "$TMPROOT/clean")" ok "c14_repos_ok on clean repo"

echo "== tracked changes, every repo type =="
mkrepo "$TMPROOT/unstaged" && printf 'edit\n' >>"$TMPROOT/unstaged/tracked.txt"
assert_eq "$(content "$TMPROOT/unstaged")" kept:dirty "unstaged tracked edit"
mkrepo "$TMPROOT/staged" && printf 'edit\n' >>"$TMPROOT/staged/tracked.txt" && git -C "$TMPROOT/staged" add tracked.txt
assert_eq "$(content "$TMPROOT/staged")" kept:dirty "staged tracked edit"
mkdir -p "$TMPROOT/plain/sub"
mkrepo "$TMPROOT/plain/sub/nested" && printf 'edit\n' >>"$TMPROOT/plain/sub/nested/tracked.txt"
assert_eq "$(c14_repos_ok "$TMPROOT/plain")" kept:dirty "nested dirty repo under a non-git root"
mkrepo "$TMPROOT/assume" && git -C "$TMPROOT/assume" update-index --assume-unchanged tracked.txt
assert_eq "$(content "$TMPROOT/assume")" kept:dirty "assume-unchanged entry"
mkrepo "$TMPROOT/skip" && git -C "$TMPROOT/skip" update-index --skip-worktree tracked.txt
assert_eq "$(content "$TMPROOT/skip")" kept:dirty "skip-worktree entry"

echo "== untracked and ignored content =="
mkrepo "$TMPROOT/untracked" && printf 'n\n' >"$TMPROOT/untracked/notes.txt"
assert_eq "$(content "$TMPROOT/untracked")" kept:dirty "untracked file"
mkrepo "$TMPROOT/dotenv" && printf 'TOKEN=x\n' >"$TMPROOT/dotenv/.env"
assert_eq "$(content "$TMPROOT/dotenv")" kept:secret-like "ignored .env"
mkrepo "$TMPROOT/db" && mkdir -p "$TMPROOT/db/data" && printf 'db' >"$TMPROOT/db/data/notes.db"
assert_eq "$(content "$TMPROOT/db")" kept:ignored-data "ignored data/notes.db"
mkrepo "$TMPROOT/nmenv" && mkdir -p "$TMPROOT/nmenv/node_modules/pkg" && printf 'TOKEN=x\n' >"$TMPROOT/nmenv/node_modules/pkg/.env"
assert_eq "$(content "$TMPROOT/nmenv")" kept:secret-like ".env inside ignored node_modules"

echo "== discovery (round 9) =="
mkrepo "$TMPROOT/outer"
mkdir -p "$TMPROOT/outer/node_modules"
mkrepo "$TMPROOT/outer/node_modules/inner"
git init -q --bare "$TMPROOT/outer/node_modules/backup.git"
found="$(c14_discover_repos "$TMPROOT/outer" | tr '\0' '\n')"
[[ $'\n'"$found"$'\n' == *$'\n'"$TMPROOT/outer/node_modules/inner"$'\n'* ]] \
    && ok "nested .git dir under an ignored dir found" || bad "nested .git dir not found: $found"
[[ $'\n'"$found"$'\n' == *$'\n'"$TMPROOT/outer/node_modules/backup.git"$'\n'* ]] \
    && ok "bare repo inside another repo's tree found" || bad "bare repo not found: $found"
[[ $'\n'"$found"$'\n' == *$'\n'"$TMPROOT/outer"$'\n'* ]] \
    && ok "candidate root repo found" || bad "root repo not found: $found"
# has_hidden_state cannot tell a nested repo under an ignored dir from a
# secret, so the outer repo is kept (fail closed), never `ok`.
v="$(c14_repos_ok "$TMPROOT/outer")"
[[ "$v" == kept:* ]] && ok "outer repo holding nested repos is kept ($v)" || bad "outer repo holding nested repos: $v"
mkdir -p "$TMPROOT/plain2/node_modules"
mkrepo "$TMPROOT/plain2/node_modules/inner"
git init -q --bare "$TMPROOT/plain2/node_modules/backup.git"
assert_eq "$(c14_repos_ok "$TMPROOT/plain2")" ok "clean nested and bare repos under a non-git root"
printf 'edit\n' >>"$TMPROOT/plain2/node_modules/inner/tracked.txt"
assert_eq "$(c14_repos_ok "$TMPROOT/plain2" --outer-certificate "$TMPROOT/none.json")" kept:dirty \
    "dirty repo nested under allowlisted node_modules is checked"
mkrepo "$TMPROOT/wtsrc" && git -C "$TMPROOT/wtsrc" worktree add -q "$TMPROOT/wtroot/linked" -b lw
found="$(c14_discover_repos "$TMPROOT/wtroot" | tr '\0' '\n')"
assert_eq "$found" "$TMPROOT/wtroot/linked" ".git file (linked worktree) found"

echo "== newline in a directory name =="
mkdir -p "$TMPROOT/cwd"
mkrepo "$TMPROOT/cwd/bar/r"
mkrepo "$TMPROOT/nl/d/foo"$'\n'"bar/r" && printf 'edit\n' >>"$TMPROOT/nl/d/foo"$'\n'"bar/r/tracked.txt"
assert_eq "$(cd "$TMPROOT/cwd" && c14_repos_ok "$TMPROOT/nl/d")" kept:dirty \
    "dirty repo under a newline-named dir is checked, not a cwd decoy"
found="$(cd "$TMPROOT/cwd" && c14_discover_repos "$TMPROOT/nl/d" | tr '\0' '\t')"
assert_eq "$found" "$TMPROOT/nl/d/foo"$'\n'"bar/r"$'\t' "newline-named repo path stays absolute and whole"
found="$(cd "$TMPROOT" && c14_discover_repos wtroot | tr '\0' '\n')"
assert_eq "$found" "$TMPROOT/wtroot/linked" "relative root yields absolute paths"

echo "== incomplete walk =="
mkdir -p "$TMPROOT/locked/closed"
chmod 000 "$TMPROOT/locked/closed"
assert_eq "$(c14_repos_ok "$TMPROOT/locked")" kept:check-failed "unreadable directory"
chmod 700 "$TMPROOT/locked/closed"
assert_eq "$(c14_repos_ok "$TMPROOT/missing")" kept:check-failed "missing root"

echo "== verdict stub stays blocked =="
assert_eq "$(artifact_removal_verdict "$TMPROOT/clean")" kept:check-failed "verdict keeps every path"
st="$(artifact_removal_verdict --self-test)"
[[ "$st" != ok ]] && ok "self-test is not ok ($st)" || bad "self-test reported ok"
assert_eq "$st" incomplete "self-test reports incomplete"
assert_eq "$(bash "$LIB" --self-test)" incomplete "executed self-test reports incomplete"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

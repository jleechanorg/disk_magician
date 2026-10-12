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
assert_eq "$(c14_repos_ok "$TMPROOT/clean")" kept:not-pushed "c14_repos_ok on clean repo with no remote"

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
assert_eq "$(content "$TMPROOT/plain2/node_modules/inner")" ok "clean nested repo under a non-git root"
assert_eq "$(content "$TMPROOT/plain2/node_modules/backup.git")" ok "bare repo under a non-git root"
v="$(c14_repos_ok "$TMPROOT/plain2")"
[[ "$v" == kept:* ]] && ok "unpushed, unbaselined nested repos are kept ($v)" || bad "nested repos with no remote: $v"
printf 'edit\n' >>"$TMPROOT/plain2/node_modules/inner/tracked.txt"
assert_eq "$(c14_repos_ok "$TMPROOT/plain2" --outer-certificate "$TMPROOT/none.json")" kept:dirty \
    "dirty repo nested under allowlisted node_modules is checked"
mkrepo "$TMPROOT/wtsrc" && git -C "$TMPROOT/wtsrc" worktree add -q "$TMPROOT/wtroot/linked" -b lw
found="$(c14_discover_repos "$TMPROOT/wtroot" | tr '\0' '\n')"
assert_eq "$found" "$TMPROOT/wtroot/linked" ".git file (linked worktree) found"

echo "== git must resolve the discovered repository =="
# W tracks sub/t; sub/.git holds an unpushed commit but lost its HEAD, so a
# bare `git -C W/sub` walks up and checks clean W instead.
mkrepo "$TMPROOT/headless" && mkdir -p "$TMPROOT/headless/sub" && printf 't\n' >"$TMPROOT/headless/sub/t"
git -C "$TMPROOT/headless" add sub/t && git -C "$TMPROOT/headless" commit -qm sub
git -C "$TMPROOT/headless/sub" init -q -b main && git -C "$TMPROOT/headless/sub" commit -q --allow-empty -m unpushed
rm "$TMPROOT/headless/sub/.git/HEAD"
assert_eq "$(c14_repos_ok "$TMPROOT/headless")" kept:check-failed "HEAD-less nested repo is not checked as its ancestor"
mkrepo "$TMPROOT/emptygit" && mkdir -p "$TMPROOT/emptygit/sub/.git" && printf 't\n' >"$TMPROOT/emptygit/sub/t"
git -C "$TMPROOT/emptygit" add sub/t && git -C "$TMPROOT/emptygit" commit -qm sub
assert_eq "$(content "$TMPROOT/emptygit/sub")" kept:check-failed "empty .git dir resolves elsewhere"
mkrepo "$TMPROOT/envdirty" && printf 'edit\n' >>"$TMPROOT/envdirty/tracked.txt"
assert_eq "$(export GIT_DIR="$TMPROOT/clean/.git" GIT_WORK_TREE="$TMPROOT/clean"; content "$TMPROOT/envdirty")" \
    kept:dirty "exported GIT_DIR/GIT_WORK_TREE do not redirect the check"
assert_eq "$(export GIT_DIR="$TMPROOT/clean/.git"; c14_repos_ok "$TMPROOT/plain")" kept:dirty \
    "exported GIT_DIR does not hide a nested dirty repo"

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

echo "== remote proof (independent repositories) =="
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
PROBE="$REPO_ROOT/scripts/c14_probe.py"
# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
# baseline <repo>: record the producer's git_meta in the repo's lease.
baseline() {
    local f gd
    f="$(lease_path_for "$1")" && gd="$(git -C "$1" rev-parse --absolute-git-dir)"
    mkdir -p "${f%/*}" && printf '{"git_meta": %s}\n' "$(python3 "$PROBE" gitmeta "$gd")" >"$f"
}
# mkpushed <name>: bare remote + clone with main pushed and a git_meta baseline.
mkpushed() {
    git init -q --bare -b main "$TMPROOT/remotes/$1.git"
    mkrepo "$TMPROOT/seed-$1" && git -C "$TMPROOT/seed-$1" push -q "$TMPROOT/remotes/$1.git" main
    git clone -q "$TMPROOT/remotes/$1.git" "$TMPROOT/$1" && baseline "$TMPROOT/$1"
}
pushed() { c14_repos_ok "$TMPROOT/$1"; }
unpushed_commit() { git -C "$TMPROOT/$1" commit -q --allow-empty -m "unpushed $2"; }
expire() { git -C "$TMPROOT/$1" reflog expire --expire=now --all; }

mkpushed ctl
assert_eq "$(pushed ctl)" ok "pushed clean clone with baseline"
assert_eq "$(c14_repo_pushed_ok "$TMPROOT/ctl")" ok "c14_repo_pushed_ok on pushed clean clone"
mkpushed headx && unpushed_commit headx X
assert_eq "$(pushed headx)" kept:not-pushed "HEAD not on remote"
mkpushed reflog && unpushed_commit reflog X && git -C "$TMPROOT/reflog" reset -q --hard origin/main
assert_eq "$(pushed reflog)" kept:not-pushed "reflog-only commit"
mkpushed rewritten && unpushed_commit rewritten X
git -C "$TMPROOT/rewritten" update-ref refs/rewritten/secret HEAD && git -C "$TMPROOT/rewritten" reset -q --hard origin/main
expire rewritten
assert_eq "$(pushed rewritten)" kept:not-pushed "refs/rewritten-only commit"
mkpushed tag && unpushed_commit tag X && git -C "$TMPROOT/tag" tag t1 && git -C "$TMPROOT/tag" reset -q --hard origin/main
expire tag
assert_eq "$(pushed tag)" kept:not-pushed "unpushed local tag"
mkpushed stash && printf 'x\n' >>"$TMPROOT/stash/tracked.txt" && git -C "$TMPROOT/stash" stash -q
assert_eq "$(pushed stash)" kept:not-pushed "stash only"
mkpushed screate && printf 'X\n' >>"$TMPROOT/screate/tracked.txt" && git -C "$TMPROOT/screate" stash create >/dev/null
git -C "$TMPROOT/screate" restore tracked.txt
assert_eq "$(pushed screate)" kept:unreachable-object "git stash create"
mkpushed blob && printf 'unique bytes\n' >"$TMPROOT/blob/new.txt" && git -C "$TMPROOT/blob" add new.txt
git -C "$TMPROOT/blob" reset -q && rm "$TMPROOT/blob/new.txt"
assert_eq "$(pushed blob)" kept:unreachable-object "staged-then-reset blob (round 9)"

echo "== stale remote-tracking refs =="
# feat_on_remote <name>: commit X pushed to remote feat, local feat deleted, reflogs expired.
feat_on_remote() {
    mkpushed "$1" && git -C "$TMPROOT/$1" checkout -q -b "$2" && unpushed_commit "$1" X
    git -C "$TMPROOT/$1" push -q origin "$2" && git -C "$TMPROOT/$1" checkout -q main
    git -C "$TMPROOT/$1" branch -q -D "$2" && expire "$1"
}
feat_on_remote staledel feat && git -C "$TMPROOT/remotes/staledel.git" branch -q -D feat
assert_eq "$(pushed staledel)" kept:not-pushed "stale origin/feat after remote delete"
feat_on_remote staleforce feat && git -C "$TMPROOT/remotes/staleforce.git" update-ref refs/heads/feat main
assert_eq "$(pushed staleforce)" kept:not-pushed "stale origin/feat after remote force-push"
feat_on_remote narrow old-feature
git -C "$TMPROOT/narrow" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "$TMPROOT/remotes/narrow.git" branch -q -D old-feature
assert_eq "$(pushed narrow)" kept:not-pushed "narrowed refspec, stale origin/old-feature"

echo "== advertisement changed after nomination (no cache) =="
mkpushed advdel && git -C "$TMPROOT/advdel" checkout -q -b feat && unpushed_commit advdel X
git -C "$TMPROOT/advdel" push -q origin feat && baseline "$TMPROOT/advdel"
assert_eq "$(pushed advdel)" ok "X advertised at nomination"
git -C "$TMPROOT/remotes/advdel.git" branch -q -D feat
assert_eq "$(pushed advdel)" kept:not-pushed "remote branch deleted before removal"
mkpushed advforce && git -C "$TMPROOT/advforce" checkout -q -b feat && unpushed_commit advforce X
git -C "$TMPROOT/advforce" push -q origin feat && baseline "$TMPROOT/advforce"
assert_eq "$(pushed advforce)" ok "X advertised at nomination (force-push variant)"
git -C "$TMPROOT/remotes/advforce.git" update-ref refs/heads/feat main
assert_eq "$(pushed advforce)" kept:not-pushed "remote branch force-pushed before removal"

echo "== ls-remote failure =="
mkpushed lsmiss && git -C "$TMPROOT/lsmiss" remote set-url origin "$TMPROOT/remotes/nonexistent.git"
assert_eq "$(pushed lsmiss </dev/null)" kept:remote-unverified "missing remote path"
mkdir -p "$TMPROOT/stub"
cat >"$TMPROOT/stub/git" <<STUB
#!/bin/bash
[[ "\$1" == ls-remote ]] && exec sleep 45.1729
exec $(command -v git) "\$@"
STUB
chmod +x "$TMPROOT/stub/git"
mkpushed lsslow
t0=$SECONDS
v="$(PATH="$TMPROOT/stub:$PATH" pushed lsslow </dev/null)"
el=$((SECONDS - t0))
assert_eq "$v" kept:remote-unverified "ls-remote stub sleeping past 30 s"
[[ $el -ge 29 && $el -lt 40 ]] && ok "ls-remote bounded at 30 s (${el}s)" || bad "ls-remote bound: ${el}s"
pgrep -f "sleep 45.1729" >/dev/null && bad "stub sleep left running" || ok "stub process group killed"

echo "== remote that is removed with the candidate =="
# seturl <name> <url>: point origin at <url> and re-baseline (the config is git_meta).
seturl() { git -C "$TMPROOT/$1" remote set-url origin "$2" && baseline "$TMPROOT/$1"; }
mkpushed selfabs && seturl selfabs "$TMPROOT/selfabs"
assert_eq "$(pushed selfabs)" kept:remote-unverified "remote is the repository itself"
assert_eq "$(c14_repo_pushed_ok "$TMPROOT/selfabs")" kept:remote-unverified "self remote, no root given"
mkpushed selffile && seturl selffile "file://$TMPROOT/selffile/."
assert_eq "$(pushed selffile)" kept:remote-unverified "file:// remote is the repository itself"
mkpushed selflink && ln -s "$TMPROOT/selflink" "$TMPROOT/selflink-alias" && seturl selflink "$TMPROOT/selflink-alias"
assert_eq "$(pushed selflink)" kept:remote-unverified "symlink to the repository itself"
mkpushed relurl && seturl relurl "../remotes/relurl.git"
assert_eq "$(pushed relurl)" kept:remote-unverified "relative local remote path"
mkdir -p "$TMPROOT/sib" && git clone -q --bare "$TMPROOT/remotes/ctl.git" "$TMPROOT/sib/up.git"
git clone -q "$TMPROOT/sib/up.git" "$TMPROOT/sib/down" && baseline "$TMPROOT/sib/down"
assert_eq "$(c14_repo_pushed_ok "$TMPROOT/sib/down" "$TMPROOT/sib")" kept:remote-unverified \
    "remote is a sibling inside the deletion root"
assert_eq "$(c14_repo_pushed_ok "$TMPROOT/sib/down")" ok "same sibling remote, root is the repository"

echo "== .git metadata baseline =="
mkpushed hooks && printf 'private\n' >"$TMPROOT/hooks/.git/hooks/private-output"
assert_eq "$(pushed hooks)" kept:git-metadata ".git/hooks/private-output"
mkpushed nobase && rm -f "$(lease_path_for "$TMPROOT/nobase")"
assert_eq "$(pushed nobase)" kept:git-unbaselined "no git_meta baseline"

echo "== bare repository =="
git init -q --bare -b main "$TMPROOT/pr-123/backup.git"
mkrepo "$TMPROOT/seed-bare" && git -C "$TMPROOT/seed-bare" push -q "$TMPROOT/pr-123/backup.git" main
assert_eq "$(c14_repos_ok "$TMPROOT/pr-123")" kept:not-pushed "bare pr-123/backup.git with an unpushed commit"

echo "== linked worktree scope =="
# mkwt <name>: clean, quiet linked worktree of pushed clone `wtbase` on branch <name>, pushed.
mkpushed wtbase
mkwt() {
    git -C "$TMPROOT/wtbase" worktree add -q "$TMPROOT/wts/$1" -b "$1" origin/main 2>/dev/null
    git -C "$TMPROOT/wts/$1" push -q -u origin "$1" 2>/dev/null
    find "$TMPROOT/wts/$1" -type f -exec touch -t 202001010000 {} +
}
admin() { git -C "$TMPROOT/wts/$1" rev-parse --absolute-git-dir; }
wt() { c14_repos_ok "$TMPROOT/wts/$1"; }

mkwt cand && mkwt sib && git -C "$TMPROOT/wts/sib" commit -q --allow-empty -m "sibling unpushed"
sibx="$(git -C "$TMPROOT/wts/sib" rev-parse HEAD)"
assert_eq "$(wt cand)" ok "sibling's unpushed commit does not veto a clean pushed candidate"
git -C "$TMPROOT/wtbase" cat-file -e "$sibx^{commit}" && ok "sibling's commit survives" || bad "sibling's commit lost"
mkwt wstash && printf 'X\n' >>"$TMPROOT/wts/wstash/tracked.txt" && git -C "$TMPROOT/wts/wstash" stash create >/dev/null
git -C "$TMPROOT/wts/wstash" restore tracked.txt && touch -t 202001010000 "$TMPROOT/wts/wstash/tracked.txt"
assert_eq "$(wt wstash)" ok "git stash create in a linked worktree is not vetoed"
mkwt headlog && git -C "$TMPROOT/wts/headlog" commit -q --allow-empty -m X
git -C "$TMPROOT/wts/headlog" reset -q --hard origin/headlog && touch -t 202001010000 "$TMPROOT/wts/headlog/tracked.txt"
git -C "$TMPROOT/wts/headlog" reflog expire --expire=now refs/heads/headlog && rm "$(admin headlog)/ORIG_HEAD"
assert_eq "$(wt headlog)" kept:not-pushed "commit dropped by reset --hard, only in the HEAD reflog"
mkwt brlog && git -C "$TMPROOT/wts/brlog" commit -q --allow-empty -m X
git -C "$TMPROOT/wts/brlog" reset -q --hard origin/brlog && touch -t 202001010000 "$TMPROOT/wts/brlog/tracked.txt"
git -C "$TMPROOT/wts/brlog" reflog expire --expire=now HEAD && rm "$(admin brlog)/ORIG_HEAD"
assert_eq "$(wt brlog)" kept:not-pushed "unpushed commit only in the branch reflog"
mkwt priv && printf 'p\n' >"$(admin priv)/private-output.txt"
assert_eq "$(wt priv)" kept:admin-unknown "admin dir holding private-output.txt"
mkwt slog && git -C "$TMPROOT/wts/slog" commit -q --allow-empty -m X && ad="$(admin slog)"
git -C "$TMPROOT/wts/slog" reset -q --hard origin/slog && touch -t 202001010000 "$TMPROOT/wts/slog/tracked.txt"
git -C "$TMPROOT/wts/slog" reflog expire --expire=now refs/heads/slog && rm -f "$ad/ORIG_HEAD" "$ad/COMMIT_EDITMSG"
mv "$ad/logs" "$TMPROOT/slog-logs" && ln -s "$TMPROOT/slog-logs" "$ad/logs"
assert_eq "$(wt slog)" kept:admin-unknown "admin logs/ replaced by a symlink (git still follows it)"
mkwt sref && unp="$(git -C "$TMPROOT/wts/sref" commit-tree -p HEAD -m unpushed 'HEAD^{tree}')" && mkdir -p "$(admin sref)/refs/worktree"
printf '%s\n' "$unp" >"$TMPROOT/sref-k" && ln -s "$TMPROOT/sref-k" "$(admin sref)/refs/worktree/k"
[[ "$(git -C "$TMPROOT/wts/sref" rev-parse refs/worktree/k)" == "$unp" ]] && assert_eq "$(wt sref)" kept:admin-unknown "refs/worktree/k symlink to an unpushed commit" || bad "sref setup"
mkwt wref && git -C "$TMPROOT/wts/wref" update-ref refs/worktree/k HEAD
assert_eq "$(wt wref)" ok "git-written refs/worktree/k at a pushed commit"
mkwt nref && mkdir -p "$(admin nref)/refs" && printf 'secret notes' >"$(admin nref)/refs/private-output.txt"
assert_eq "$(wt nref)" kept:admin-unknown "non-ref file nested under refs/"
mkwt nlog && printf 'secret notes\n' >"$(admin nlog)/logs/notes.txt"
assert_eq "$(wt nlog)" kept:admin-unknown "non-reflog file nested under logs/"
mkwt dindex && ad="$(admin dindex)" && mv "$ad/index" "$TMPROOT/dindex-index" && mkdir "$ad/index"
assert_eq "$(python3 "$PROBE" admin "$ad")" kept:admin-unknown "allowlisted name index/ created as a directory (probe)"
mkwt lgitdir && ad="$(admin lgitdir)" && mv "$ad/gitdir" "$TMPROOT/lgitdir-gitdir" && ln -s "$TMPROOT/lgitdir-gitdir" "$ad/gitdir"
assert_eq "$(wt lgitdir)" kept:admin-unknown "allowlisted gitdir as a symlink"
mkwt cfgwt && printf '[core]\n\tsparseCheckout = true\n' >"$(admin cfgwt)/config.worktree"
assert_eq "$(wt cfgwt)" kept:admin-unknown "changed config.worktree"
mkwt cfgempty && : >"$(admin cfgempty)/config.worktree"
assert_eq "$(wt cfgempty)" ok "empty config.worktree"
mkwt emsg && git -C "$TMPROOT/wts/emsg" commit -q --allow-empty -m "pushed message" && git -C "$TMPROOT/wts/emsg" push -q 2>/dev/null
assert_eq "$(wt emsg)" ok "COMMIT_EDITMSG matching a pushed commit (-m)"
printf '#!/bin/sh\nprintf "edited message\\n" | cat - "$1" >"$1.n" && mv "$1.n" "$1"\n' >"$TMPROOT/ed.sh" && chmod +x "$TMPROOT/ed.sh"
GIT_EDITOR="$TMPROOT/ed.sh" git -C "$TMPROOT/wts/emsg" commit -q --allow-empty && git -C "$TMPROOT/wts/emsg" push -q 2>/dev/null
[[ "$(git -C "$TMPROOT/wts/emsg" log -1 --format=%s)" == "edited message" ]] && grep -q '^#' "$(admin emsg)/COMMIT_EDITMSG" && assert_eq "$(wt emsg)" ok "COMMIT_EDITMSG with editor comments, pushed" || bad "editor commit"
mkwt eabort && GIT_EDITOR=true git -C "$TMPROOT/wts/eabort" commit -q --allow-empty 2>/dev/null
assert_eq "$(wt eabort)" ok "COMMIT_EDITMSG of an aborted commit, comments only"
printf 'long typed message rejected by a hook\n' >"$(admin emsg)/COMMIT_EDITMSG"
assert_eq "$(wt emsg)" kept:admin-unknown "COMMIT_EDITMSG holding text of no checked commit"
mkwt lockd && git -C "$TMPROOT/wtbase" worktree lock "$TMPROOT/wts/lockd"
assert_eq "$(wt lockd)" kept:locked "worktree already locked"
mkwt fresh && touch "$TMPROOT/wts/fresh/tracked.txt"
assert_eq "$(wt fresh)" kept:recent-activity "wrh_removal_verdict quiet period applies"
v="$(C14_INVENTORY_OUT="$TMPROOT/inv.jsonl" wt cand)"
python3 -c 'import json,sys; s={json.loads(l)["path"] for l in open(sys.argv[1])}; sys.exit(not {"HEAD","gitdir","commondir"} <= s)' \
    "$TMPROOT/inv.jsonl" 2>/dev/null && ok "admin entries emitted for the inventory" || bad "admin inventory missing ($v)"

echo "== declared-ephemeral rows E2-E7 (--kind ephemeral) =="
PT="$TMPROOT/ptmp" && mkdir -p "$PT" "$TMPROOT/utmp"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$PT"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
NOW="$(date +%s)"
# age <path> <minutes>: every entry under <path> last modified <minutes> ago.
age() { find "$1" -exec touch -h -t "$(date -r $((NOW - $2 * 60)) +%Y%m%d%H%M.%S)" {} +; }
eph() { artifact_removal_verdict "$1" --kind ephemeral; }
mkdir -p "$PT/clones" && git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/clones/repo" && baseline "$PT/clones/repo"
git -C "$TMPROOT/wtbase" worktree add -q "$PT/wtp" -b wtp origin/main 2>/dev/null && git -C "$PT/wtp" push -q -u origin wtp 2>/dev/null
printf 'p' >"$PT/agent_prompt_1.txt"
mkdir -p "$PT/cli_validation_gemini_1" "$PT/pr-123/run" "$HOME/.aside/u/a/sessions/s1" "$HOME/.gemini/antigravity/brain/b1" \
    "$HOME/.gemini/antigravity-cli/brain/b2" "$HOME/.gemini/antigravity/implicit.backup" "$HOME/.llm-inspector/captures" "$HOME/.claude/supervisor"
printf 'r' >"$PT/pr-123/run/results.json"
for f in "$PT/cli_validation_gemini_1/o" "$HOME/.aside/u/a/sessions/s1/state" "$HOME/.gemini/antigravity/brain/b1/t.log" \
    "$HOME/.gemini/antigravity-cli/brain/b2/t.log" "$HOME/.gemini/antigravity/implicit.backup/i" "$HOME/.llm-inspector/captures/capture-1.json" \
    "$HOME/.llm-inspector/captures/x.summary.json" "$HOME/.claude/supervisor/cmux-codex-launchd.20260101T000000.log"; do printf 'x' >"$f"; done
while read -r row ret p; do
    age "$p" $((ret + 60)) && assert_eq "$(eph "$p")" remove "$row 1 h past ${ret} min: ${p#"$TMPROOT"/}"
    age "$p" $((ret - 60)) && assert_eq "$(eph "$p")" kept:recent-activity "$row 1 h short of ${ret} min"
done <<EOF
E2 240 $PT/agent_prompt_1.txt
E2 60 $PT/cli_validation_gemini_1
E2 240 $PT/clones/repo
E2 60 $PT/wtp
E3 2880 $PT/pr-123
E4 10080 $HOME/.aside/u/a/sessions/s1
E5 30240 $HOME/.gemini/antigravity/brain/b1
E5 30240 $HOME/.gemini/antigravity-cli/brain/b2
E5 43200 $HOME/.gemini/antigravity/implicit.backup
E6 4320 $HOME/.llm-inspector/captures/capture-1.json
E6 4320 $HOME/.llm-inspector/captures/x.summary.json
E7 10080 $HOME/.claude/supervisor/cmux-codex-launchd.20260101T000000.log
EOF
age "$PT/pr-123" 180
assert_eq "$(DISK_MAGICIAN_PR_SCRATCH_MIN_AGE_HOURS=1 eph "$PT/pr-123")" kept:recent-activity "sweeper configured below E3 retention"
mkdir -p "$TMPROOT/stub" && printf '#!/bin/sh\nexit 1\n' >"$TMPROOT/stub/stat" && chmod +x "$TMPROOT/stub/stat"
age "$PT/pr-123" 43200
assert_eq "$(PATH="$TMPROOT/stub:$PATH" eph "$PT/pr-123")" kept:mtime-unmeasurable "stat stub fails"
mkdir -p "$PT/pr-sec" "$PT/pr-key" && printf 'T=1' >"$PT/pr-sec/.env" && printf 'k' >"$PT/pr-key/id_ed25519"
age "$PT/pr-sec" 43200 && age "$PT/pr-key" 43200
assert_eq "$(eph "$PT/pr-sec")" kept:secret-like ".env in an E3 dir at 30 d"
assert_eq "$(eph "$PT/pr-key")" kept:secret-like "id_ed25519 in an E3 dir at 30 d"
mkdir -p "$PT/pr-git" && mkrepo "$PT/pr-git/repo" && age "$PT/pr-git" 43200
assert_eq "$(eph "$PT/pr-git")" kept:not-pushed "git repo with an unpushed commit in an E3 dir at 30 d"
mkdir -p "$HOME/work/run-9" && printf 'r' >"$HOME/work/run-9/report.md" && age "$HOME/work/run-9" 43200
assert_eq "$(eph "$HOME/work/run-9")" kept:unproven-content "unique report.md under ~/work/run-9/"

echo "== every-kind checks =="
mkdir -p "$PT/pr-open" "$PT/pr-cwd" "$PT/pr-young" "$PT/pr-live" "$PT/pr-unk" "$PT/pr-rel" "$HOME/.codex/sessions/s"
for d in pr-open pr-cwd pr-young pr-live pr-unk pr-rel; do printf 'x' >"$PT/$d/f"; age "$PT/$d" 43200; done
printf 'x' >"$HOME/.codex/sessions/s/f" && age "$HOME/.codex/sessions/s" 43200
age "$PT/agent_prompt_1.txt" 43200
(exec 7<"$PT/pr-open/f" 8<"$PT/agent_prompt_1.txt"; cd /; sleep 60) & opid=$!
(cd "$PT/pr-cwd" && exec sleep 60) & cpid=$!
sleep 1
assert_eq "$(eph "$PT/pr-open")" kept:open-file "non-git dir with an open file"
assert_eq "$(eph "$PT/agent_prompt_1.txt")" kept:open-file "open E2 agent_prompt file"
assert_eq "$(eph "$PT/pr-cwd")" kept:live-cwd "a process with cwd inside"
kill "$opid" "$cpid" 2>/dev/null; wait "$opid" "$cpid" 2>/dev/null
age "$PT/pr-young" 10
assert_eq "$(artifact_removal_verdict "$PT/pr-young")" kept:recent-activity "content 10 min old"
assert_eq "$(eph "$HOME/.codex/sessions/s")" kept:protected "never-delete path (safety_check.sh)"
# lease <dir> <released_at>: lease owned by this shell (pid + start epoch).
lease() {
    local f; f="$(lease_path_for "$1")" && mkdir -p "${f%/*}"
    printf '{"owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24,"released_at":%s}\n' \
        $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW" "$2" >"$f"
}
lease "$PT/pr-live" null && assert_eq "$(eph "$PT/pr-live")" kept:live-owner "idle live lease owner"
lease "$PT/pr-unk" null && printf '#!/bin/sh\necho boom >&2; exit 2\n' >"$TMPROOT/stub/ps" && chmod +x "$TMPROOT/stub/ps"
assert_eq "$(DISK_MAGICIAN_PS_BIN="$TMPROOT/stub/ps" eph "$PT/pr-unk")" kept:owner-unknown "owner unknown (ps stub fails)"
lease "$PT/pr-rel" '"2026-10-01T00:00:00Z"' && assert_eq "$(eph "$PT/pr-rel")" remove "released lease with a live pid"

echo "== verdict stays blocked =="
v="$(artifact_removal_verdict "$TMPROOT/clean")" && [[ "$v" == kept:* ]] && ok "non-ephemeral path kept ($v)" || bad "non-ephemeral path: $v"
st="$(artifact_removal_verdict --self-test)"
[[ "$st" != ok ]] && ok "self-test is not ok ($st)" || bad "self-test reported ok"
assert_eq "$st" incomplete "self-test reports incomplete"
assert_eq "$(bash "$LIB" --self-test)" incomplete "executed self-test reports incomplete"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

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

TMPROOT="$(mktemp -d /tmp/dm-c14-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-c14-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
    case "$TMPROOT" in
        /tmp/dm-c14-test.*|/private/tmp/dm-c14-test.*) ;;
        *) return ;;
    esac
    [[ -d "$TMPROOT" ]] || return
    chmod -R u+rwx "$TMPROOT" 2>/dev/null
    rm -rf "$TMPROOT"
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
mkdir -p "$TMPROOT/symlink-repo/nested"
mkrepo "$TMPROOT/symlink-repo/nested"
mv "$TMPROOT/symlink-repo/nested/.git" "$TMPROOT/symlink-repo/gitmeta"
ln -s ../gitmeta "$TMPROOT/symlink-repo/nested/.git"
printf 'edit\n' >>"$TMPROOT/symlink-repo/nested/tracked.txt"
assert_eq "$(content "$TMPROOT/symlink-repo/nested")" kept:dirty "Git recognizes a nested repo with an internal .git symlink"
symlink_inventory="$TMPROOT/symlink-repo-inventory.json"
assert_eq "$(python3 "$_AV_DIR/../c14_probe.py" inventory "$TMPROOT/symlink-repo" "$symlink_inventory")" ok "inventory of nested repo with internal .git symlink"
symlink_repos="$(C14_ROOT="$TMPROOT/symlink-repo" python3 "$_AV_DIR/../c14_probe.py" repos "$symlink_inventory" | tr '\0' '\n')"
assert_eq "$symlink_repos" "$TMPROOT/symlink-repo/nested" "inventory classifies linked metadata only as the worktree"
assert_eq "$(c14_repos_ok "$TMPROOT/symlink-repo" "$symlink_inventory")" kept:dirty "inventory finds nested repo with internal .git symlink"
mkdir -p "$TMPROOT/external-gitdir/nested"
mkrepo "$TMPROOT/external-gitdir-source"
cp "$TMPROOT/external-gitdir-source/tracked.txt" "$TMPROOT/external-gitdir/nested/tracked.txt"
ln -s "$TMPROOT/external-gitdir-source/.git" "$TMPROOT/external-gitdir/nested/.git"
printf 'dirty\n' >>"$TMPROOT/external-gitdir/nested/tracked.txt"
external_gitdir_inventory="$TMPROOT/external-gitdir-inventory.json"
assert_eq "$(python3 "$_AV_DIR/../c14_probe.py" inventory "$TMPROOT/external-gitdir" "$external_gitdir_inventory")" ok "inventory of nested repo with external .git symlink"
assert_eq "$(C14_ROOT="$TMPROOT/external-gitdir" python3 "$_AV_DIR/../c14_probe.py" repos "$external_gitdir_inventory")" kept:gitdir-invalid "inventory fails closed on an external .git symlink"
assert_eq "$(c14_repos_ok "$TMPROOT/external-gitdir" "$external_gitdir_inventory")" kept:gitdir-invalid "C14 rejects dirty repo with external .git symlink"
assert_eq "$(c14_repos_ok "$TMPROOT/external-gitdir")" kept:gitdir-invalid "legacy repo discovery rejects external .git symlink"
mkdir -p "$TMPROOT/broken-gitdir/nested"
ln -s "$TMPROOT/no-such-gitdir" "$TMPROOT/broken-gitdir/nested/.git"
broken_gitdir_inventory="$TMPROOT/broken-gitdir-inventory.json"
assert_eq "$(python3 "$_AV_DIR/../c14_probe.py" inventory "$TMPROOT/broken-gitdir" "$broken_gitdir_inventory")" ok "inventory of nested repo with broken .git symlink"
assert_eq "$(C14_ROOT="$TMPROOT/broken-gitdir" python3 "$_AV_DIR/../c14_probe.py" repos "$broken_gitdir_inventory")" kept:gitdir-invalid "inventory fails closed on a broken .git symlink"
assert_eq "$(c14_repos_ok "$TMPROOT/broken-gitdir")" kept:gitdir-invalid "legacy repo discovery rejects broken .git symlink"
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
assert_eq "$(c14_repos_ok "$TMPROOT/plain2")" kept:dirty \
    "dirty repo nested under allowlisted node_modules is checked"
mkrepo "$TMPROOT/wtsrc" && git -C "$TMPROOT/wtsrc" worktree add -q "$TMPROOT/wtroot/linked" -b lw
found="$(c14_discover_repos "$TMPROOT/wtroot" | tr '\0' '\n')"
assert_eq "$found" "$TMPROOT/wtroot/linked" ".git file (linked worktree) found"
# A submodule's metadata (super/.git/modules/<sm>) is owned by the
# superproject, but the submodule worktree is its own repository. The
# inventory path must use the same .git/ exclusion as legacy discovery or
# every submodule-bearing clone is kept.
mkrepo "$TMPROOT/subsrc"
mkrepo "$TMPROOT/super"
git -C "$TMPROOT/super" -c protocol.file.allow=always submodule add -q "$TMPROOT/subsrc" sm 2>/dev/null
git -C "$TMPROOT/super" commit -qm add-sm
[[ -d "$TMPROOT/super/.git/modules/sm" ]] && ok "submodule metadata present" || bad "submodule metadata missing"
sub_inv="$TMPROOT/submodule-inventory.json"
assert_eq "$(python3 "$_AV_DIR/../c14_probe.py" inventory "$TMPROOT/super" "$sub_inv")" ok "inventory of a submodule superproject"
sub_repos="$(C14_ROOT="$TMPROOT/super" python3 "$_AV_DIR/../c14_probe.py" repos "$sub_inv" | tr '\0' '\n' | sort)"
legacy_repos="$(c14_discover_repos "$TMPROOT/super" | tr '\0' '\n' | sort)"
[[ $'\n'"$sub_repos"$'\n' == *$'\n'"$TMPROOT/super"$'\n'* ]] && ok "superproject repo found" || bad "superproject not found: $sub_repos"
[[ $'\n'"$sub_repos"$'\n' == *$'\n'"$TMPROOT/super/sm"$'\n'* ]] && ok "submodule worktree repo found" || bad "submodule worktree not found: $sub_repos"
[[ $'\n'"$sub_repos"$'\n' != *$'\n'"$TMPROOT/super/.git/modules/sm"$'\n'* ]] && ok "submodule metadata under .git/ is not a repository" || bad "submodule metadata misclassified: $sub_repos"
assert_eq "$sub_repos" "$legacy_repos" "inventory and legacy discovery agree on a submodule superproject"
# The exclusion is metadata-scoped: a real nested independent repository in
# candidate content is still discovered.
mkrepo "$TMPROOT/super/vendor/inner"
assert_eq "$(content "$TMPROOT/super/vendor/inner")" ok "clean nested repo under a submodule superproject"

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
PT="$TMPROOT/ptmp" && mkdir -p "$PT"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$PT"
# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
# Advice-owned copies are remote-less by construction; the exact-sha receipt
# permits only its hash-listed review-document overlay and binds .git metadata.
git init -q --bare -b main "$TMPROOT/advice-source.git"
mkrepo "$TMPROOT/advice-source-seed"
mkdir -p "$TMPROOT/advice-source-seed/nested"
printf 'nested content\n' >"$TMPROOT/advice-source-seed/nested/tracked.txt"
git -C "$TMPROOT/advice-source-seed" add nested/tracked.txt && git -C "$TMPROOT/advice-source-seed" commit -qm nested
git -C "$TMPROOT/advice-source-seed" push -q "$TMPROOT/advice-source.git" main
git init -q "$TMPROOT/advice-copy"
advice_sha="$(git -C "$TMPROOT/advice-source-seed" rev-parse HEAD)"
git -C "$TMPROOT/advice-copy" fetch -q --no-tags "$TMPROOT/advice-source.git" "$advice_sha"
git -C "$TMPROOT/advice-copy" checkout -q --detach "$advice_sha"
mkdir -p "$TMPROOT/advice-copy/.advice-review-documents"
printf 'review document\n' >"$TMPROOT/advice-copy/.advice-review-documents/0.md"
advice_receipt="$TMPROOT/advice-receipt.json"
python3 - "$PROBE" "$TMPROOT/advice-copy" "$TMPROOT/advice-source-seed" "$advice_receipt" <<'PY'
import hashlib, json, os, subprocess, sys
probe, clone, source, out = sys.argv[1:]
meta = json.loads(subprocess.run([sys.executable, probe, "gitmeta", os.path.join(clone, ".git")],
                                 check=True, capture_output=True, text=True).stdout)
path = os.path.join(clone, ".advice-review-documents", "0.md")
overlay = [{"path": ".advice-review-documents/0.md",
            "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()}]
json.dump({"source_repo": source, "sha": subprocess.run(["git", "-C", clone, "rev-parse", "HEAD"],
         check=True, capture_output=True, text=True).stdout.strip(), "clone_kind": "independent_exact_sha_fetch",
         "overlay_manifest": overlay, "git_meta": meta, "receipt_path": out,
         "pid": os.getpid(), "start_epoch": 1, "created_epoch": 1}, open(out, "w"))
PY
assert_eq "$(c14_repo_content_ok "$TMPROOT/advice-copy" --overlay-manifest "$advice_receipt")" ok \
    "receipt-listed review overlay is accepted"
assert_eq "$(c14_repos_ok "$TMPROOT/advice-copy" --outer-certificate "$advice_receipt")" ok \
    "outer certificate exempts only the remote-less outer copy"
assert_eq "$(GIT_DIR="$TMPROOT/clean/.git" GIT_WORK_TREE="$TMPROOT/clean" c14_repos_ok "$TMPROOT/advice-copy" --outer-certificate "$advice_receipt")" ok \
    "outer certificate ignores caller Git environment"
git -C "$TMPROOT/advice-copy/nested" init -q
git -C "$TMPROOT/advice-copy/nested" config user.email nested@example.invalid
git -C "$TMPROOT/advice-copy/nested" config user.name nested
git -C "$TMPROOT/advice-copy/nested" add tracked.txt
git -C "$TMPROOT/advice-copy/nested" commit -qm nested
assert_eq "$(c14_repos_ok "$TMPROOT/advice-copy" --outer-certificate "$advice_receipt")" kept:not-pushed \
    "outer certificate does not skip a nested independent repository"
cp "$advice_receipt" "$TMPROOT/advice-bad-meta.json"
python3 - "$TMPROOT/advice-bad-meta.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["receipt_path"]=p; d["git_meta"]["config"]= "0"*64; json.dump(d,open(p,"w"))
PY
assert_eq "$(c14_repo_content_ok "$TMPROOT/advice-copy" --overlay-manifest "$TMPROOT/advice-bad-meta.json")" kept:git-metadata \
    "receipt rejects changed .git metadata baseline"
printf 'tampered review document\n' >"$TMPROOT/advice-copy/.advice-review-documents/0.md"
assert_eq "$(c14_repos_ok "$TMPROOT/advice-copy" --outer-certificate "$advice_receipt")" kept:dirty \
    "receipt rejects overlay bytes changed after certification"
printf 'unlisted\n' >"$TMPROOT/advice-copy/extra.txt"
assert_eq "$(c14_repo_content_ok "$TMPROOT/advice-copy" --overlay-manifest "$advice_receipt")" kept:dirty \
    "receipt does not exempt unrelated untracked files"

# baseline <repo>: record the producer's git_meta in the repo's lease.
baseline() {
    local f gd
    f="$(lease_path_for "$1")" && gd="$(git -C "$1" rev-parse --absolute-git-dir)"
    mkdir -p "${f%/*}" && printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":%s}\n' "$1" "$(python3 "$PROBE" gitmeta "$gd")" >"$f"
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
mkdir -p "$TMPROOT/no-remote" && mkrepo "$TMPROOT/no-remote" && baseline "$TMPROOT/no-remote"
err="$TMPROOT/no-remote.stderr"
v="$(c14_repo_pushed_ok "$TMPROOT/no-remote" 2>"$err")"
[[ "$v" == kept:* ]] && ok "no-remote repository returns a kept verdict under nounset ($v)" || bad "no-remote repository returned an empty/non-kept verdict under nounset: '$v'"
[[ ! -s "$err" ]] && ok "no-remote repository has no nounset diagnostic" || bad "no-remote repository emitted a nounset diagnostic: $(cat "$err")"
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
index_candidate="$PT/pr-index-inventory-check"
git clone -q "$TMPROOT/remotes/ctl.git" "$index_candidate" && baseline "$index_candidate"
age "$index_candidate" 50000
index_before="$(shasum -a 256 "$index_candidate/.git/index" | awk '{print $1}')"
index_inventory="$TMPROOT/index-inventory.json"
assert_eq "$(GIT_OPTIONAL_LOCKS=1 artifact_removal_verdict "$index_candidate" --kind ephemeral --inventory-out "$index_inventory")" remove "full C14 verification can remove an old, clean pushed clone"
python3 - "$index_candidate/.git/index" "$index_inventory" <<'PY' && ok "read-side Git verification preserves the indexed bytes" || bad "C14 inventory's index hash changed during verification"
import hashlib, json, sys
index_path, inventory_path = sys.argv[1:]
entries = {row["path"]: row for row in json.load(open(inventory_path, encoding="utf-8"))}
actual = hashlib.sha256(open(index_path, "rb").read()).hexdigest()
assert entries[".git/index"]["sha256"] == actual
PY
assert_eq "$(shasum -a 256 "$index_candidate/.git/index" | awk '{print $1}')" "$index_before" "index bytes are unchanged across the verifier"
mkdir -p "$PT/clones" && git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/clones/repo" && baseline "$PT/clones/repo"
# A finished run releases its lease; a baseline-only lease (owner absent) would be kept.
python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d.update(owner={"pid":1}, released_at="2026-10-01T00:00:00Z"); json.dump(d,open(f,"w"))' "$(lease_path_for "$PT/clones/repo")"
git -C "$TMPROOT/wtbase" worktree add -q "$PT/wtp" -b wtp origin/main 2>/dev/null && git -C "$PT/wtp" push -q -u origin wtp 2>/dev/null
printf 'p' >"$PT/agent_prompt_1.txt"
mkdir -p "$PT/cli_validation_gemini_1" "$PT/pr-123/run" "$HOME/.aside/u/a/sessions/s1" "$HOME/.gemini/antigravity/brain/b1" \
    "$HOME/.gemini/antigravity-cli/brain/b2" "$HOME/.gemini/antigravity/implicit.backup" "$HOME/.llm-inspector/captures" "$HOME/.claude/supervisor"
printf 'r' >"$PT/pr-123/run/results.json"
for f in "$PT/cli_validation_gemini_1/o" "$HOME/.aside/u/a/sessions/s1/state" "$HOME/.gemini/antigravity/brain/b1/t.log" \
    "$HOME/.gemini/antigravity-cli/brain/b2/t.log" "$HOME/.gemini/antigravity/implicit.backup/i" "$HOME/.llm-inspector/captures/capture-1.json" \
    "$HOME/.llm-inspector/captures/x.summary.json" "$HOME/.claude/supervisor/cmux-codex-launchd.20260101T000000.log"; do printf 'x' >"$f"; done
while read -r row ret p; do
    age "$p" $((ret + 60)) && assert_eq "$(eph "$p")" remove "$row 1 h past ${ret} min: ${p#"$TMPROOT"/}" \
        || bad "$row age-old fixture setup (${p#"$TMPROOT"/})"
    age "$p" $((ret - 60)) && assert_eq "$(eph "$p")" kept:recent-activity "$row 1 h short of ${ret} min" \
        || bad "$row age-fresh fixture setup (${p#"$TMPROOT"/})"
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
# An exact-worktree-root receipt binds only that candidate's own admin rows.
# The admin channel is per-call: a caller-owned C14_INVENTORY_OUT is neither
# appended to nor removed, a stale row planted there cannot bind, and a second
# verdict in the same shell starts from an empty channel. The venv receipt
# above already proves a child directory binds no parent admin rows at all.
caller_channel="$TMPROOT/caller-admin.jsonl"
printf '{"admin":"%s/other-admin","path":"HEAD","mode":"100644","dev":1,"ino":1,"size":0,"sha256":"sentinel"}\n' "$TMPROOT" >"$caller_channel"
caller_before="$(shasum -a 256 "$caller_channel" | awk '{print $1}')"
export C14_INVENTORY_OUT="$caller_channel"
av_tmp="$TMPROOT/av-tmp" && mkdir -p "$av_tmp" && export TMPDIR="$av_tmp"
age "$PT/wtp" 120
wt_gd="$(git -C "$PT/wtp" rev-parse --absolute-git-dir)"
wt_inv_one="$TMPROOT/wt-root-inventory-one.json"
assert_eq "$(artifact_removal_verdict "$PT/wtp" --kind ephemeral --inventory-out "$wt_inv_one")" remove "exact worktree root is eligible and writes its receipt"
wt_inv_two="$TMPROOT/wt-root-inventory-two.json"
assert_eq "$(artifact_removal_verdict "$PT/wtp" --kind ephemeral --inventory-out "$wt_inv_two")" remove "a second consecutive worktree-root verdict is eligible"
assert_eq "$(shasum -a 256 "$caller_channel" | awk '{print $1}')" "$caller_before" "caller-owned C14_INVENTORY_OUT is never written or removed"
[[ -z "$(find "$av_tmp" -mindepth 1 -print -quit 2>/dev/null)" ]] && ok "each verdict removes its owned admin channel and temp dir" || bad "verdict temp files leaked: $(find "$av_tmp" -print)"
python3 - "$wt_gd" "$TMPROOT/other-admin" "$wt_inv_one" "$wt_inv_two" <<'PY' && ok "worktree-root receipts bind only the candidate's own admin rows" || bad "worktree-root receipt admin binding"
import hashlib, json, os, sys
gd, stale, *paths = sys.argv[1:]
root_st = os.lstat(gd)
for p in paths:
    rows = json.load(open(p, encoding="utf-8"))
    admins = [r for r in rows if r.get("type") == "admin"]
    assert admins, p
    assert all(r.get("admin") == gd for r in admins), (p, {r.get("admin") for r in admins})
    assert all(r.get("admin") != stale for r in rows), p
    # The original admin receipt carries the root identity and every allowed
    # refs/** / logs/** directory, plus file hashes. type=admin is the merge
    # envelope; entry_type keeps the underlying filesystem kind. Each row's
    # dev/ino and file hash must bind to that exact path.
    by_path = {r["path"]: r for r in admins}
    root = by_path.get(".")
    assert root is not None and root.get("entry_type") == "dir", (p, sorted(by_path))
    assert (root.get("dev"), root.get("ino")) == (root_st.st_dev, root_st.st_ino), (p, root, root_st)
    dirs = [r for r in admins if r.get("path") != "." and r.get("entry_type") == "dir"]
    assert dirs and all(type(r.get("dev")) is int and type(r.get("ino")) is int for r in dirs), (p, dirs)
    assert "logs" in {r["path"] for r in dirs}, (p, [r["path"] for r in dirs])
    files = [r for r in admins if r.get("entry_type") == "file"]
    assert files and all(len(r.get("sha256", "")) == 64 for r in files), (p, files)
    for r in admins:
        st = os.lstat(gd if r["path"] == "." else os.path.join(gd, r["path"]))
        assert (r["dev"], r["ino"]) == (st.st_dev, st.st_ino), (p, r, st)
        if r["entry_type"] == "file":
            digest = hashlib.sha256(open(os.path.join(gd, r["path"]), "rb").read()).hexdigest()
            assert r["sha256"] == digest, (p, r, digest)
PY
unset C14_INVENTORY_OUT
unset TMPDIR
# Never-touch tmp roots (cleanup_tmp.sh PROTECTED_TMP_ROOTS) and legacy system basenames keep an idle released E2 clone.
for d in worldarchitect.ai/br custom-root/br system-x com.apple.y; do
    git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/$d" && baseline "$PT/$d"
    python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d.update(owner={"pid":1}, released_at="2026-10-01T00:00:00Z"); json.dump(d,open(f,"w"))' "$(lease_path_for "$PT/$d")"
    age "$PT/${d%%/*}" 400
done
assert_eq "$(eph "$PT/worldarchitect.ai/br")" kept:protected "default protected tmp root"
assert_eq "$(DISK_MAGICIAN_PROTECTED_TMP_ROOTS='x custom-root' eph "$PT/custom-root/br")" kept:protected "env protected tmp root"
assert_eq "$(eph "$PT/custom-root/br")" remove "unlisted root at 400 min"
assert_eq "$(eph "$PT/system-x")" kept:unproven-content "system-* basename has no row"
assert_eq "$(eph "$PT/com.apple.y")" kept:unproven-content "com.apple.* basename has no row"
age "$PT/pr-123" 180
assert_eq "$(DISK_MAGICIAN_PR_SCRATCH_MIN_AGE_HOURS=1 eph "$PT/pr-123")" kept:recent-activity "sweeper configured below E3 retention"
age "$PT/pr-123" 43200
printf '{}' >"$TMPROOT/invalid-inventory.json"
assert_eq "$(python3 "$PROBE" newest-mtime "$TMPROOT/invalid-inventory.json")" kept:check-failed "malformed inventory cannot supply an mtime"
mkdir -p "$PT/pr-sec" "$PT/pr-key" && printf 'T=1' >"$PT/pr-sec/.env" && printf 'k' >"$PT/pr-key/id_ed25519"
age "$PT/pr-sec" 43200 && age "$PT/pr-key" 43200
assert_eq "$(eph "$PT/pr-sec")" kept:secret-like ".env in an E3 dir at 30 d"
assert_eq "$(eph "$PT/pr-key")" kept:secret-like "id_ed25519 in an E3 dir at 30 d"
mkdir -p "$PT/pr-review-only.pem" && printf 'synthetic sentinel\n' >"$PT/pr-review-only.pem/payload"
age "$PT/pr-review-only.pem" 43200
assert_eq "$(eph "$PT/pr-review-only.pem")" kept:secret-like "secret-like root name in an E3 directory"
printf 'synthetic sentinel\n' >"$PT/review-only.pem"
root_file_inventory="$TMPROOT/root-secret-file-inventory.json"
assert_eq "$(python3 "$PROBE" inventory "$PT/review-only.pem" "$root_file_inventory")" ok "inventory of a regular-file candidate"
assert_eq "$(python3 "$PROBE" secrets "$root_file_inventory")" yes "secret-like regular-file root name is recognized"
mkdir -p "$PT/pr-git" && mkrepo "$PT/pr-git/repo" && age "$PT/pr-git" 43200
assert_eq "$(eph "$PT/pr-git")" kept:not-pushed "git repo with an unpushed commit in an E3 dir at 30 d"
mkdir -p "$HOME/work/run-9" && printf 'r' >"$HOME/work/run-9/report.md" && age "$HOME/work/run-9" 43200
assert_eq "$(eph "$HOME/work/run-9")" kept:unproven-content "unique report.md under ~/work/run-9/"
# '.'/'..' basenames must not resolve to the parent and inherit a row's retention (§7.2 globs).
mkdir -p "$HOME/.gemini/antigravity/conversations" "$HOME/.aside/u/a/profile" && printf 'c' >"$HOME/.gemini/antigravity/conversations/important.pb"
printf 'c' >"$HOME/.aside/u/a/profile/Cookies" && age "$HOME/.gemini" 43200 && age "$HOME/.aside" 43200
for p in "$HOME/.gemini/antigravity/brain/.." "$HOME/.gemini/antigravity/brain/." "$HOME/.aside/u/a/sessions/.." "/"; do
    assert_eq "$(eph "$p")" kept:check-failed "dot basename: ${p#"$HOME"/}"
done

echo "== every-kind checks =="
mkdir -p "$TMPROOT/no-lsof" && printf x >"$TMPROOT/no-lsof/f"
assert_eq "$(DISK_MAGICIAN_LSOF_BIN="$TMPROOT/missing-lsof" python3 "$PROBE" open-file "$TMPROOT/no-lsof")" kept:check-failed "missing lsof fails closed"
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
    printf '{"path":"%s","owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24,"released_at":%s}\n' \
        "$1" $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW" "$2" >"$f"
}
lease "$PT/pr-live" null && assert_eq "$(eph "$PT/pr-live")" kept:live-owner "idle live lease owner" \
    || bad "pr-live lease fixture setup"
lease "$PT/pr-unk" null && printf '#!/bin/sh\necho boom >&2; exit 2\n' >"$TMPROOT/stub/ps" && chmod +x "$TMPROOT/stub/ps"
assert_eq "$(DISK_MAGICIAN_PS_BIN="$TMPROOT/stub/ps" eph "$PT/pr-unk")" kept:owner-unknown "owner unknown (ps stub fails)"
mkdir -p "$PT/pr-none" && age "$PT/pr-none" 43200 && f="$(lease_path_for "$PT/pr-none")" && mkdir -p "${f%/*}" && printf '{"path":"%s","owner":null}\n' "$PT/pr-none" >"$f"
assert_eq "$(eph "$PT/pr-none")" kept:owner-unknown "owner:null lease (no resolvable owner) is kept"
lease "$PT/pr-rel" '"2026-10-01T00:00:00Z"' && assert_eq "$(eph "$PT/pr-rel")" remove "released lease with a live pid" \
    || bad "pr-rel lease fixture setup"
# A lease that cannot be stat'ed is not absent: EACCES on the lease dir or a parent keeps.
ld="$(lease_dir)" && chmod 000 "$ld"
assert_eq "$(eph "$PT/pr-live")" kept:owner-unknown "unreadable lease dir keeps a live-owner dir"
chmod 700 "$ld" && chmod 000 "${ld%/*}"
assert_eq "$(eph "$PT/pr-live")" kept:owner-unknown "unsearchable lease-dir parent keeps a live-owner dir"
chmod 700 "${ld%/*}"
# own <path> <released_at>: set this shell as owner of <path>'s lease, keeping its git_meta.
own() {
    local f; f="$(lease_path_for "$1")" && mkdir -p "${f%/*}"
    python3 -c 'import json,os,sys; f=sys.argv[1]; d=json.load(open(f)) if os.path.exists(f) else {}
d.update(path=sys.argv[7], owner={"pid":int(sys.argv[2]),"start_epoch":int(sys.argv[3]),"comm":sys.argv[4]}, created_epoch=int(sys.argv[5]), ttl_hours=24, released_at=json.loads(sys.argv[6])); json.dump(d,open(f,"w"))' \
        "$f" $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW" "$2" "$1"
}
mkdir -p "$PT/pr-nest" "$PT/pr-1" && for d in pr-nest pr-1; do git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/$d/repo" && baseline "$PT/$d/repo"; done
own "$PT/pr-nest/repo" null && own "$PT/pr-1/repo" '"2026-10-01T00:00:00Z"' && own "$PT/pr-1" null && age "$PT/pr-nest" 43200 && age "$PT/pr-1" 43200
assert_eq "$(eph "$PT/pr-nest/repo")" kept:live-owner "live owner on the candidate repository"
assert_eq "$(eph "$PT/pr-nest")" kept:live-owner "live-owner lease on a repository nested in the candidate"
assert_eq "$(eph "$PT/pr-1/repo")" kept:live-owner "live-owner lease on a dir enclosing the candidate"
own "$PT/pr-1" '"2026-10-01T00:00:00Z"' && assert_eq "$(eph "$PT/pr-1/repo")" remove "enclosing and own leases released" \
    || bad "pr-1 own lease fixture setup"
# B1: scratch-new --kind evidence leases a plain, non-git run dir. A live lease on
# that nested plain dir must keep the outer candidate even with no open file/cwd.
mkdir -p "$PT/claude-commands/evidence/run-1" && printf 'report-body\n' >"$PT/claude-commands/evidence/run-1/report.md"
lease "$PT/claude-commands/evidence/run-1" null && age "$PT/claude-commands" 3000
assert_eq "$(eph "$PT/claude-commands")" kept:live-owner "live lease on a plain dir nested in the candidate"
[[ "$(cat "$PT/claude-commands/evidence/run-1/report.md")" == report-body ]] \
    && ok "nested plain-dir lease left the candidate bytes intact" || bad "candidate bytes changed"
own "$PT/claude-commands/evidence/run-1" '"2026-10-01T00:00:00Z"'
assert_eq "$(eph "$PT/claude-commands")" remove "released child lease no longer saves the outer candidate"
# A dead child lease (owner gone) is not protection either: strict removal.
lease "$PT/claude-commands/evidence/run-1" null
mkdir -p "$TMPROOT/stub" && printf '#!/bin/sh\nexit 1\n' >"$TMPROOT/stub/ps-dead" && chmod +x "$TMPROOT/stub/ps-dead"
assert_eq "$(DISK_MAGICIAN_PS_BIN="$TMPROOT/stub/ps-dead" eph "$PT/claude-commands")" remove "dead child lease no longer saves the outer candidate"
own "$PT/claude-commands/evidence/run-1" '"2026-10-01T00:00:00Z"'
# A malformed lease record makes the descendant scan unmeasurable: keep, never remove.
printf '{not json' >"$(lease_dir)/zz-malformed.json"
assert_eq "$(eph "$PT/claude-commands")" kept:check-failed "malformed lease record keeps an otherwise-removable candidate"
rm -f "$(lease_dir)/zz-malformed.json"
assert_eq "$(eph "$PT/claude-commands")" remove "malformed record removed: candidate removable again"

echo "== non-git provenance (T11-5) =="
GCS="$TMPROOT/gcs" && mkdir -p "$GCS"
# Stub for `gcloud storage objects describe`: fixture JSON per object, else 404 (rc 1); logs each call.
printf '#!/bin/sh\nf="%s/$(printf %%s "$1" | tr "/:" "__").json"\necho "$1" >>"%s/calls"\n[ -f "$f" ] || { echo 404 >&2; exit 1; }\ncat "$f"\n' "$GCS" "$GCS" >"$TMPROOT/stub/describe"
chmod +x "$TMPROOT/stub/describe" && export DISK_MAGICIAN_STAT_BIN="$TMPROOT/stub/describe"
# publish <dir> [<url>] [<verified_at|->]: released lease marking every file under <dir> published
# (upload_manifest: path, sha256, md5, crc32c, size, object, generation 1) plus matching remote objects.
publish() {
    python3 - "$1" "$(lease_path_for "$1")" "${2:-gs://wa-test-evidence/agent-evidence/${1##*/}/}" "${3:-2026-10-01T00:00:00Z}" "$GCS" <<'PY'
import base64, hashlib, json, os, sys
d, lease, url, ver, gcs = sys.argv[1:]
m = []
for dp, _, fns in os.walk(d):
    for n in sorted(fns):
        p = os.path.join(dp, n); b = open(p, "rb").read(); rel = os.path.relpath(p, d)
        m.append(dict(path=rel, sha256=hashlib.sha256(b).hexdigest(), md5=base64.b64encode(hashlib.md5(b).digest()).decode(),
                      crc32c="AAAAAA==", size=len(b), object=url + rel, generation="1"))
        json.dump({"generation": "1", "md5_hash": m[-1]["md5"]}, open(os.path.join(gcs, (url + rel).replace("/", "_").replace(":", "_") + ".json"), "w"))
os.makedirs(os.path.dirname(lease), exist_ok=True)
json.dump({"path": d, "owner": {"pid": 1}, "released_at": "2026-10-01T00:00:00Z", "kind": "evidence", "published": True,
           "published_at": "2026-10-01T00:00:00Z", "published_url": url, "verified_at": None if ver == "-" else ver,
           "upload_manifest": m}, open(lease, "w"))
PY
}
# lease_edit <dir> <python statement on d>: rewrite <dir>'s lease JSON.
lease_edit() { python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); exec(sys.argv[2]); json.dump(d,open(f,"w"))' "$(lease_path_for "$1")" "$2"; }
gobj() { printf '%s/%s.json' "$GCS" "$(printf %s "gs://wa-test-evidence/agent-evidence/$1" | tr '/:' '__')"; }
av() { artifact_removal_verdict "$@"; }
mkdir -p "$PT/advice-x" "$PT/deploy" && printf 'n' >"$PT/advice-x/notes.txt" && printf 'TOKEN=abc' >"$PT/deploy/deploy_backup.txt"
age "$PT/advice-x" 90 && age "$PT/deploy" 43200
assert_eq "$(av "$PT/advice-x")" kept:unproven-content "unique notes.txt under \$TMPDIR/advice-x/"
assert_eq "$(av "$PT/deploy")" kept:unproven-content "custom-named deploy_backup.txt"
git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/evrepo" && mkdir -p "$PT/evrepo/evidence" && printf '{}' >"$PT/evrepo/evidence/results.json" && age "$PT/evrepo" 43200
assert_eq "$(av "$PT/evrepo/evidence")" kept:unproven-content "unpublished evidence/results.json"
mkdir -p "$PT/inv" && printf 'r' >"$PT/inv/report.md" && age "$PT/inv" 43200 && f="$(lease_path_for "$PT/inv")"
printf '{"path":"%s","owner":{"pid":1},"released_at":"2026-10-01T00:00:00Z","kind":"scratch","source":"git:%s@%s","manifest":[{"path":"report.md","sha256":"%s"}]}\n' \
    "$PT/inv" "$TMPROOT/remotes/wtbase.git" "$(git -C "$PT/evrepo" rev-parse HEAD)" "$(shasum -a 256 "$PT/inv/report.md" | cut -c1-64)" >"$f"
assert_eq "$(av "$PT/inv")" kept:unproven-content "manifest is not a copy (inventory only, never published)"
for d in ev-ok ev-unver ev-added ev-byte ev-subset ev-nomf ev-del ev-regen ev-exp ev-miss; do
    mkdir -p "$PT/$d/sub" && printf 'report' >"$PT/$d/report.md" && printf 'mp4data' >"$PT/$d/sub/recording.mp4" && printf 'j' >"$PT/$d/results.json"
    publish "$PT/$d" "" "$([[ $d == ev-unver ]] && echo - || echo 2026-10-01T00:00:00Z)" && age "$PT/$d" 120
done
: >"$GCS/calls"
assert_eq "$(av "$PT/ev-ok")" remove "published evidence with verified_at, every file matching"
assert_eq "$(wc -l <"$GCS/calls" | tr -d ' ')" 3 "one objects describe per object"
assert_eq "$(av "$PT/ev-unver")" kept:unproven-content "unverified publication (no verified_at)"
printf 'mine' >"$PT/ev-added/private_notes.txt" && age "$PT/ev-added" 120
assert_eq "$(av "$PT/ev-added")" kept:unproven-content "publish, then add private_notes.txt"
printf 'mp4dato' >"$PT/ev-byte/sub/recording.mp4" && age "$PT/ev-byte" 120
assert_eq "$(av "$PT/ev-byte")" kept:unproven-content "publish, then change one byte of recording.mp4"
lease_edit "$PT/ev-subset" 'd["upload_manifest"]=d["upload_manifest"][:2]'
assert_eq "$(av "$PT/ev-subset")" kept:unproven-content "manifest lists a subset"
lease_edit "$PT/ev-nomf" 'd["upload_manifest"]=None'
assert_eq "$(av "$PT/ev-nomf")" kept:unproven-content "URL with no manifest"
rm -f "$(gobj ev-del/report.md)" "$(gobj ev-del/results.json)" "$(gobj ev-del/sub/recording.mp4)"
assert_eq "$(av "$PT/ev-del")" kept:unproven-content "objects deleted after publication"
printf '{"generation":"2","md5_hash":"x"}' >"$(gobj ev-regen/report.md)"
assert_eq "$(av "$PT/ev-regen")" kept:unproven-content "object replaced by a new generation"
printf '{"generation":"1","md5_hash":"bm90IHRoZSBzYW1l"}' >"$(gobj ev-exp/results.json)"
assert_eq "$(av "$PT/ev-exp")" kept:unproven-content "object hash differs from the manifest"
rm -f "$(gobj ev-exp/results.json)"
assert_eq "$(av "$PT/ev-exp")" kept:unproven-content "object past its 30-day lifecycle (stat stub 404)"
rm -f "$(gobj ev-miss/sub/recording.mp4)"
assert_eq "$(av "$PT/ev-miss")" kept:unproven-content "one of three objects missing"
lease_edit "$PT/ev-ok" 'd["verified_at"]=""'
assert_eq "$(av "$PT/ev-ok")" kept:unproven-content "empty verified_at"
mkdir -p "$PT/ev-link" && printf 'r' >"$PT/ev-link/report.md" && publish "$PT/ev-link" && ln -s /etc "$PT/ev-link/l" && age "$PT/ev-link" 120
assert_eq "$(av "$PT/ev-link")" kept:unproven-content "unlisted symlink in a published dir"
mkdir -p "$PT/nm" && git clone -q "$TMPROOT/remotes/wtbase.git" "$PT/nm/repo" && baseline "$PT/nm/repo"
lease_edit "$PT/nm/repo" 'd.update(owner={"pid":1}, released_at="2026-10-01T00:00:00Z")'
mkdir -p "$PT/nm/repo/node_modules/pkg" && printf 'x' >"$PT/nm/repo/node_modules/pkg/i.js" && age "$PT/nm" 120
assert_eq "$(av "$PT/nm/repo")" remove "allowlisted node_modules in a pushed clean clone (no kind)"
printf 'n' >"$PT/nm/notes.txt" && age "$PT/nm" 120
assert_eq "$(av "$PT/nm")" kept:unproven-content "the same clone beside a unique non-git file"
echo "-- rebuildable (--kind rebuildable) and os_clone --"
mkdir -p "$HOME/.cache/uv/archive-v0/x" "$HOME/.cache/other/x" "$HOME/Library/Developer/Xcode/DerivedData/App-1" \
    "$HOME/Library/Caches/ms-playwright/chromium-1248" "$HOME/Library/Caches/CocoaPods/Pods" \
    "$HOME/Library/Caches/@granolaelectron-updater/pending" "$HOME/Library/Caches/claude-cli-nodejs/cache-a" \
    "$HOME/Library/Caches/go-build/00" "$HOME/.cache/ezgha-recovery-target-20261004/sub" \
    "$HOME/.local/share/cursor-agent/versions/2026.02-stale"
for d in .cache/uv/archive-v0/x .cache/other/x Library/Developer/Xcode/DerivedData/App-1 \
    Library/Caches/ms-playwright/chromium-1248 Library/Caches/CocoaPods/Pods \
    Library/Caches/@granolaelectron-updater/pending Library/Caches/claude-cli-nodejs/cache-a \
    Library/Caches/go-build/00 .cache/ezgha-recovery-target-20261004/sub \
    .local/share/cursor-agent/versions/2026.02-stale; do printf 'b' >"$HOME/$d/f"; done
age "$HOME/.cache" 43200 && age "$HOME/Library" 43200 && age "$HOME/.local" 43200
assert_eq "$(av "$HOME/.cache/uv/archive-v0/x" --kind rebuildable)" remove "rebuildable ~/.cache/uv/archive-v0/x"
assert_eq "$(av "$HOME/Library/Developer/Xcode/DerivedData/App-1" --kind rebuildable)" remove "rebuildable Xcode DerivedData entry"
assert_eq "$(av "$HOME/Library/Caches/ms-playwright/chromium-1248" --kind rebuildable)" remove "rebuildable ms-playwright entry"
assert_eq "$(av "$HOME/Library/Caches/CocoaPods/Pods" --kind rebuildable)" remove "rebuildable CocoaPods entry"
assert_eq "$(av "$HOME/Library/Caches/@granolaelectron-updater/pending" --kind rebuildable)" remove "rebuildable @granolaelectron-updater entry"
assert_eq "$(av "$HOME/Library/Caches/claude-cli-nodejs/cache-a" --kind rebuildable)" remove "rebuildable claude-cli-nodejs entry"
assert_eq "$(av "$HOME/Library/Caches/go-build/00" --kind rebuildable)" remove "rebuildable go-build entry"
assert_eq "$(av "$HOME/.cache/ezgha-recovery-target-20261004/sub" --kind rebuildable)" remove "rebuildable ezgha-recovery-target subpath"
assert_eq "$(av "$HOME/.cache/ezgha-recovery-target-20261004" --kind rebuildable)" remove "rebuildable ezgha-recovery-target dir itself"
assert_eq "$(av "$HOME/.cache/uv" --kind rebuildable)" kept:unproven-content "the cache root itself is not an entry"
assert_eq "$(av "$HOME/Library/Caches/ms-playwright" --kind rebuildable)" kept:unproven-content "ms-playwright cache root itself is not an entry"
assert_eq "$(av "$HOME/.local/share/cursor-agent/versions/2026.02-stale" --kind rebuildable)" kept:unproven-content "installed cursor-agent versions stay outside rebuildable cache allowlist"
assert_eq "$(av "$HOME/.cache/other/x" --kind rebuildable)" kept:unproven-content "a path outside the cache-root table"
assert_eq "$(av "$HOME/.cache/uv/archive-v0/x")" kept:unproven-content "cache entry without --kind rebuildable"
# venvw <wt>: linked worktree of wtbase with venv/ ignored on a pushed branch.
venvw() {
    git -C "$TMPROOT/wtbase" worktree add -q "$1" -b "${1##*/}" origin/main 2>/dev/null
    printf 'venv/\n' >>"$1/.gitignore" && git -C "$1" commit -qam ignore-venv && git -C "$1" push -q -u origin "${1##*/}" 2>/dev/null
    mkdir -p "$1/venv/bin" && printf 'py' >"$1/venv/bin/python"
}
venvw "$HOME/wt-dormant" && mkdir -p "$HOME/plain/notvenv" && printf 'py' >"$HOME/plain/notvenv/x"
age "$HOME/wt-dormant" 43200 && age "$HOME/plain" 43200
assert_eq "$(av "$HOME/wt-dormant/venv" --kind rebuildable)" remove "a dormant worktree's ignored venv/"
subtree_inventory="$TMPROOT/dormant-venv-inventory.json"
assert_eq "$(artifact_removal_verdict "$HOME/wt-dormant/venv" --kind rebuildable --inventory-out "$subtree_inventory")" remove "a linked worktree venv receives a subtree-only receipt"
python3 - "$subtree_inventory" <<'PY' && ok "subtree receipt excludes unrelated parent worktree admin rows" || bad "subtree receipt contains parent worktree admin rows"
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
assert rows and all(row.get("type") != "admin" for row in rows)
PY
assert_eq "$(av "$HOME/plain/notvenv" --kind rebuildable)" kept:unproven-content "a non-venv dir"
# B1: the enclosing linked worktree's canonical 7-day floor protects its venv/.
# Root, .git and venv/ are 30 days old, but the tracked content was touched 2h ago.
venvw "$HOME/wt-young" && age "$HOME/wt-young" 43200 && age "$HOME/wt-young/tracked.txt" 120
assert_eq "$(av "$HOME/wt-young/venv" --kind rebuildable)" kept:recent-activity \
    "ignored venv/ in a worktree with 2h-old tracked content"
[[ "$(cat "$HOME/wt-young/venv/bin/python")" == py ]] \
    && ok "young venv path bytes intact after the verdict" || bad "young venv path bytes changed"
# An 8-day-quiet worktree is past the strict 7-day floor and stays eligible.
venvw "$HOME/wt-eligible" && age "$HOME/wt-eligible" 11520
assert_eq "$(av "$HOME/wt-eligible/venv" --kind rebuildable)" remove \
    "ignored venv/ in a worktree quiet for 8 days"
# Canonical unmeasurable recency fails closed (reports active), so the venv stays.
worktree_is_recently_active() { return 0; }
assert_eq "$(av "$HOME/wt-eligible/venv" --kind rebuildable)" kept:recent-activity \
    "ignored venv/ when canonical worktree recency cannot be measured"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$REPO_ROOT/scripts/lib/worktree_recency.sh"
mkdir -p "$HOME/projects/app/venv" && git -C "$HOME/projects/app" init -q -b main && printf 'n' >"$HOME/projects/app/venv/notes.txt"
git -C "$HOME/projects/app" add -A && git -C "$HOME/projects/app" commit -qm notes && printf 'edit' >>"$HOME/projects/app/venv/notes.txt"
mkdir -p "$HOME/Documents/venv" "$HOME/Documents/venv.bak.old" && printf 't' >"$HOME/Documents/venv/thesis.txt" && printf 't' >"$HOME/Documents/venv.bak.old/t.txt"
venvw "$HOME/wt-dirty" && printf 'x\n' >>"$HOME/wt-dirty/tracked.txt"
venvw "$HOME/wt-tracked" && git -C "$HOME/wt-tracked" add -f venv && git -C "$HOME/wt-tracked" commit -qm tracked-venv && git -C "$HOME/wt-tracked" push -q 2>/dev/null
git clone -q "$TMPROOT/remotes/wtbase.git" "$HOME/base" && printf 'venv/\n' >>"$HOME/base/.git/info/exclude" && mkdir -p "$HOME/base/venv" && printf 'py' >"$HOME/base/venv/python"
for d in "$HOME/projects" "$HOME/Documents" "$HOME/wt-dirty" "$HOME/wt-tracked" "$HOME/base"; do age "$d" 43200; done
assert_eq "$(av "$HOME/projects/app/venv" --kind rebuildable)" kept:unproven-content "tracked, unpushed and dirty venv/ in a base repo"
assert_eq "$(av "$HOME/Documents/venv" --kind rebuildable)" kept:unproven-content "venv/ outside any repository"
assert_eq "$(av "$HOME/Documents/venv.bak.old" --kind rebuildable)" kept:unproven-content "venv.bak.old outside any repository"
assert_eq "$(av "$HOME/wt-dirty/venv" --kind rebuildable)" kept:unproven-content "ignored venv/ in a dirty worktree"
assert_eq "$(av "$HOME/wt-tracked/venv" --kind rebuildable)" kept:unproven-content "tracked venv/ in a clean pushed worktree"
assert_eq "$(av "$HOME/base/venv" --kind rebuildable)" kept:unproven-content "ignored venv/ in a base repo, not a linked worktree"
mkdir -p "$PT/X/com.google.Chrome.code_sign_clone/code_sign_clone.c1" && printf 'bin' >"$PT/X/com.google.Chrome.code_sign_clone/code_sign_clone.c1/app" && age "$PT/X" 43200
assert_eq "$(av "$PT/X/com.google.Chrome.code_sign_clone/code_sign_clone.c1" --kind os_clone)" kept:check-failed "os_clone without a frozen-identity proof"
x_thesis="$HOME/Documents/thesis"
mkdir -p "$x_thesis" && printf 'unique' >"$x_thesis/chapter.txt" && age "$x_thesis" 43200
assert_eq "$(av "$x_thesis" --kind os_clone)" kept:check-failed "os_clone flag cannot authorize arbitrary ~/Documents/thesis"
x_clone="$PT/X/com.google.Chrome.code_sign_clone/code_sign_clone.c1"
x_id="$(stat -f '%d:%i:%u' "$PT/X" 2>/dev/null || stat -c '%d:%i:%u' "$PT/X")"
x_parent_id="$(stat -f '%d:%i:%u' "${x_clone%/*}" 2>/dev/null || stat -c '%d:%i:%u' "${x_clone%/*}")"
x_candidate_id="$(stat -f '%d:%i:%u' "$x_clone" 2>/dev/null || stat -c '%d:%i:%u' "$x_clone")"
assert_eq "$(DISK_MAGICIAN_CODE_SIGN_X_DIR="$PT/X" av "$x_clone" --kind os_clone --frozen-identity "$x_candidate_id" --frozen-parent-identity "$x_parent_id" --frozen-root-identity "$x_id")" remove "os_clone with matching frozen candidate, parent and X-root identities"
assert_eq "$(DISK_MAGICIAN_CODE_SIGN_X_DIR="$PT/X" av "$x_clone" --kind os_clone --frozen-identity "$x_parent_id" --frozen-parent-identity "$x_parent_id" --frozen-root-identity "$x_id")" kept:check-failed "os_clone identity mismatch is kept"
assert_eq "$(DISK_MAGICIAN_CODE_SIGN_X_DIR="$PT/X" av "$x_thesis" --kind os_clone --frozen-identity "$x_candidate_id" --frozen-parent-identity "$x_parent_id" --frozen-root-identity "$x_id")" kept:check-failed "os_clone proof outside the frozen X scan root is kept"
assert_eq "$(av "$x_clone")" kept:unproven-content "the same clone without --kind os_clone"
age "$PT/X" 10
assert_eq "$(DISK_MAGICIAN_CODE_SIGN_X_DIR="$PT/X" av "$x_clone" --kind os_clone --frozen-identity "$x_candidate_id" --frozen-parent-identity "$x_parent_id" --frozen-root-identity "$x_id")" kept:recent-activity "os_clone still runs every-kind checks"
assert_eq "$(av "$PT/advice-x" --kind bogus)" kept:unproven-content "unknown kind"
typo_candidate="$PT/agent_prompt_bad_deadline.txt"
printf 'eligible only when every option parses' >"$typo_candidate"
age "$typo_candidate" 50000
assert_eq "$(av "$typo_candidate" --kind ephemeral --deadlin-at bogus)" kept:check-failed "unknown option cannot authorize removal"

echo "== archive origin receipt (E1) =="
ARCHIVE_ROOT="$TMPROOT/archive-root"
export DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE_ROOT"
archive_fixture() {
    local source="$1" entry="$2" archived_at="$3" retention
    retention="$(c14_ephemeral_retention "$source")" || retention=0
    mkdir -p "${entry%/*}" && python3 "$PROBE" archive-receipt "$source" "$entry.c14-origin.json" "$archived_at" "$retention" >/dev/null && mv "$source" "$entry"
}
archive_source="$PT/pr-archive-123"
archive_entry="$ARCHIVE_ROOT/20261010T000000Z/pr-archive-123"
mkdir -p "$archive_source" && printf 'archived pr payload' >"$archive_source/payload"
age "$archive_source" 43200
archive_fixture "$archive_source" "$archive_entry" "$((NOW - 49 * 3600))"
age "$archive_entry" 43200
assert_eq "$(av "$archive_entry" --kind ephemeral)" remove "archived E3 origin past its 48 h row retention"

# A bare repository at the candidate root is discovered from inventory too.
root_bare="$PT/pr-root-bare"
git init --bare -q "$root_bare"
printf 'unreachable root object' | git --git-dir="$root_bare" hash-object -w --stdin >/dev/null
age "$root_bare" 50000
assert_eq "$(av "$root_bare" --kind ephemeral)" kept:git-unbaselined "candidate-root bare repository is checked and fails closed"

unknown_source="$TMPROOT/unregistered-origin"
unknown_entry="$ARCHIVE_ROOT/20261010T010000Z/large-unknown"
mkdir -p "$unknown_source" && truncate -s 209715200 "$unknown_source/large.bin"
archive_fixture "$unknown_source" "$unknown_entry" "$((NOW - 25 * 3600))"
age "$unknown_entry" 43200
assert_eq "$(av "$unknown_entry" --kind ephemeral)" kept:archive-identity "200 MiB archive with unknown origin stays kept"

arbitrary_source="$PT/unregistered-origin-48h"
arbitrary_entry="$ARCHIVE_ROOT/20261010T011000Z/unregistered-origin-48h"
mkdir -p "$arbitrary_source" && printf 'must not trust arbitrary retention' >"$arbitrary_source/payload"
mkdir -p "${arbitrary_entry%/*}"
python3 "$PROBE" archive-receipt "$arbitrary_source" "$arbitrary_entry.c14-origin.json" "$((NOW - 49 * 3600))" 2880 >/dev/null
mv "$arbitrary_source" "$arbitrary_entry"
age "$arbitrary_entry" 50000
assert_eq "$(av "$arbitrary_entry" --kind ephemeral)" kept:archive-identity "E1 rejects allowed retention without a matching E2/E3 origin row"

later_row_source="$PT/e4-origin-fixture"
later_row_entry="$ARCHIVE_ROOT/20261010T012000Z/e4-origin-fixture"
mkdir -p "$later_row_source" "${later_row_entry%/*}" && printf 'E4 is not an E1 origin row' >"$later_row_source/payload"
python3 "$PROBE" archive-receipt "$later_row_source" "$later_row_entry.c14-origin.json" "$((NOW - 49 * 3600))" 10080 >/dev/null
python3 - "$later_row_entry.c14-origin.json" "$HOME/.aside/u/a/sessions/s1" <<'PY'
import json, sys
path, original = sys.argv[1:]
row = json.load(open(path, encoding="utf-8"))
row["original_path"] = original
with open(path, "w", encoding="utf-8") as f:
    json.dump(row, f, separators=(",", ":"))
    f.write("\n")
PY
mv "$later_row_source" "$later_row_entry"
age "$later_row_entry" 50000
assert_eq "$(av "$later_row_entry" --kind ephemeral)" kept:archive-identity "E1 rejects a valid E4 row outside its E2/E3 origin scope"

legacy_entry="$ARCHIVE_ROOT/20261010T020000Z/pre-receipt"
mkdir -p "$legacy_entry" && printf 'legacy archive' >"$legacy_entry/payload" && age "$legacy_entry" 43200
assert_eq "$(av "$legacy_entry" --kind ephemeral)" kept:unproven-content "pre-receipt archive falls through to ordinary provenance"

replaced_source="$PT/pr-replaced-123"
replaced_entry="$ARCHIVE_ROOT/20261010T030000Z/pr-replaced-123"
mkdir -p "$replaced_source" && printf 'original inode' >"$replaced_source/payload"
archive_fixture "$replaced_source" "$replaced_entry" "$((NOW - 49 * 3600))"
mv "$replaced_entry" "$replaced_entry.original" && mkdir -p "$replaced_entry" && printf 'replacement inode' >"$replaced_entry/new"
age "$replaced_entry" 43200
assert_eq "$(av "$replaced_entry" --kind ephemeral)" kept:archive-identity "replaced E1 entry does not inherit its old receipt"

short_source="$PT/cli_validation_gemini_archive"
short_entry="$ARCHIVE_ROOT/20261010T040000Z/cli_validation_gemini_archive"
mkdir -p "$short_source" && printf 'short-row archive' >"$short_source/payload"
age "$short_source" 50000
archive_fixture "$short_source" "$short_entry" "$((NOW - 5 * 3600))"
age "$short_entry" 50000
assert_eq "$(av "$short_entry" --kind ephemeral)" kept:recent-activity "E1 archive retains its 24 h minimum over a short E2 row"

reused_source="$PT/unclassified-origin"
reused_entry="$ARCHIVE_ROOT/20261010T050000Z/unclassified-origin"
mkdir -p "$reused_source" && printf 'unique original' >"$reused_source/payload"
age "$reused_source" 50000
archive_fixture "$reused_source" "$reused_entry" "$((NOW - 5 * 3600))"
mkdir -p "$reused_source" && git -C "$reused_source" init -q
age "$reused_entry" 50000
assert_eq "$(av "$reused_entry" --kind ephemeral)" kept:archive-identity "recreated original path cannot confer E1 eligibility"

receipt_failure_source="$PT/receipt-failure-source"
receipt_failure_entry="$ARCHIVE_ROOT/20261010T060000Z/receipt-failure-source"
mkdir -p "$receipt_failure_source" "${receipt_failure_entry%/*}" && printf 'preserve me' >"$receipt_failure_source/payload"
touch "$TMPROOT/not-a-directory"
if python3 "$PROBE" archive-receipt "$receipt_failure_source" "$TMPROOT/not-a-directory/receipt.json" "$NOW" >"$TMPROOT/receipt-failure.out" 2>&1; then
    mv "$receipt_failure_source" "$receipt_failure_entry"
    bad "receipt creation failure blocks archive move"
else
    ok "receipt creation failure is nonzero"
fi
[[ -d "$receipt_failure_source" ]] && ok "receipt creation failure preserves original" || bad "receipt creation failure moved original"

missing_identity="$ARCHIVE_ROOT/20261010T040000Z/missing-identity"
mkdir -p "$missing_identity" && printf 'missing ids' >"$missing_identity/payload"
printf '{"original_path":"%s/pr-123","archived_at":%s}\n' "$PT" "$((NOW - 49 * 3600))" >"$missing_identity.c14-origin.json"
age "$missing_identity" 43200
assert_eq "$(av "$missing_identity" --kind ephemeral)" kept:archive-identity "E1 receipt missing dev and inode is kept"

missing_size="$ARCHIVE_ROOT/20261010T070000Z/missing-size"
mkdir -p "$missing_size" && printf 'size is binding' >"$missing_size/payload"
python3 - "$missing_size" "$PT/pr-123" "$((NOW - 49 * 3600))" <<'PY'
import json, os, sys
path, original, archived_at = sys.argv[1], sys.argv[2], int(sys.argv[3])
st = os.lstat(path)
json.dump({"original_path": original, "dev": st.st_dev, "ino": st.st_ino, "archived_at": archived_at},
          open(path + ".c14-origin.json", "w"))
PY
age "$missing_size" 50000
assert_eq "$(av "$missing_size" --kind ephemeral)" kept:archive-identity "E1 receipt missing size is kept"

unset DISK_MAGICIAN_STAT_BIN
# B1/F1: the lease-record scan must fail closed on unusable records and bind each
# record to the canonical lease filename for its recorded path.
mkdir -p "$PT/pr-lease-scan/child" && printf 'KEEP\n' >"$PT/pr-lease-scan/child/data.bin"
age "$PT/pr-lease-scan" 43200
CL="$(lease_path_for "$PT/pr-lease-scan/child")" && mkdir -p "${CL%/*}"
# leasefrag: live-owner fragment so an unchecked record would otherwise be ignored.
leasefrag() { printf '"owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24,"released_at":null' \
    $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW"; }
printf '#!/bin/sh\nexit 1\n' >"$TMPROOT/stub/ps-dead" && chmod +x "$TMPROOT/stub/ps-dead"
lease "$PT/pr-lease-scan/child" null
assert_eq "$(eph "$PT/pr-lease-scan")" kept:live-owner "canonical live child lease keeps candidate (control)"
printf '{%s}\n' "$(leasefrag)" >"$CL"
assert_eq "$(eph "$PT/pr-lease-scan")" kept:check-failed "child lease missing path key keeps candidate"
printf '{"path":"",%s}\n' "$(leasefrag)" >"$CL"
assert_eq "$(eph "$PT/pr-lease-scan")" kept:check-failed "child lease empty path keeps candidate"
printf '{"path":123,%s}\n' "$(leasefrag)" >"$CL"
assert_eq "$(eph "$PT/pr-lease-scan")" kept:check-failed "child lease non-string path keeps candidate"
printf '[1,2]\n' >"$CL"
assert_eq "$(eph "$PT/pr-lease-scan")" kept:check-failed "valid JSON non-object record keeps candidate"
rm -f "$CL"
printf '{"path":"%s","owner":{"pid":%d}}\n' "$PT/pr-lease-scan/child" $$ >"$(lease_dir)/c14-lease-misnamed.json"
assert_eq "$(eph "$PT/pr-lease-scan")" kept:check-failed "record under non-canonical filename keeps candidate"
rm -f "$(lease_dir)/c14-lease-misnamed.json"
[[ "$(cat "$PT/pr-lease-scan/child/data.bin")" == KEEP ]] \
    && ok "unusable-record probes left candidate bytes intact" || bad "candidate bytes changed"
lease "$PT/pr-lease-scan/child" null && own "$PT/pr-lease-scan/child" '"2026-10-01T00:00:00Z"'
assert_eq "$(eph "$PT/pr-lease-scan")" remove "canonical released child lease leaves candidate eligible (control)"
lease "$PT/pr-lease-scan/child" null
assert_eq "$(DISK_MAGICIAN_PS_BIN="$TMPROOT/stub/ps-dead" eph "$PT/pr-lease-scan")" remove "canonical dead child lease leaves candidate eligible (control)"
own "$PT/pr-lease-scan/child" '"2026-10-01T00:00:00Z"'
mkdir -p "$TMPROOT/vanish-hook"
cat >"$TMPROOT/vanish-hook/sitecustomize.py" <<'PY'
import os
_orig_listdir = os.listdir
def _racelistdir(p="."):
    res = _orig_listdir(p)
    v = os.environ.get("DISK_MAGICIAN_VANISH_LEASE")
    if v and os.path.basename(v) in res and os.path.realpath(p) == os.path.realpath(os.path.dirname(v)):
        try:
            os.unlink(v)
        except OSError:
            pass
    return res
os.listdir = _racelistdir
PY
vanished_lease="$(lease_dir)/0000000000000000.json"
printf '{"path":"%s/vanished","owner":{"pid":1},"released_at":"2026-10-01T00:00:00Z"}\n' "$PT" >"$vanished_lease"
assert_eq "$(PYTHONPATH="$TMPROOT/vanish-hook${PYTHONPATH:+:$PYTHONPATH}" DISK_MAGICIAN_VANISH_LEASE="$vanished_lease" eph "$PT/pr-lease-scan")" remove "vanished lease file during _av_lease_record_paths does not cause kept:check-failed"
rm -f "$vanished_lease"

echo "== fd-bound inventory, deadline and nomination race =="
inv_case="$TMPROOT/inventory-case"
mkdir -p "$inv_case/sub" && printf 'inventory bytes' >"$inv_case/sub/file.bin" && ln -s sub/file.bin "$inv_case/link"
inv_file="$TMPROOT/inventory.json"
assert_eq "$(python3 "$PROBE" inventory "$inv_case" "$inv_file")" ok "inventory completes"
python3 - "$inv_file" <<'PY' && ok "inventory records relative paths, identity, hash and symlink target" || bad "inventory fields"
import hashlib, json, sys
entries = {e["path"]: e for e in json.load(open(sys.argv[1]))}
f = entries["sub/file.bin"]
assert f["type"] == "file" and f["dev"] and f["ino"] and f["size"] == 15
assert f["sha256"] == hashlib.sha256(b"inventory bytes").hexdigest()
assert entries["link"]["type"] == "symlink" and entries["link"]["target"] == "sub/file.bin"
assert entries["."]["type"] == "dir"
PY
verdict_inv="$TMPROOT/verdict-inventory.json"
mkdir -p "$PT/pr-inventory" && printf 'rebuildable' >"$PT/pr-inventory/cache.bin" && age "$PT/pr-inventory" 43200
assert_eq "$(av "$PT/pr-inventory" --kind ephemeral --inventory-out "$verdict_inv")" remove "verified verdict writes its inventory"
python3 - "$verdict_inv" <<'PY' && ok "verdict inventory includes the verified candidate" || bad "verdict inventory missing candidate"
import json, sys
entries = {e["path"]: e for e in json.load(open(sys.argv[1]))}
assert entries["cache.bin"]["type"] == "file" and entries["cache.bin"]["size"] == 11
PY
mkdir -p "$PT/pr-inventory-kept" && printf 'unknown' >"$PT/pr-inventory-kept/data" && age "$PT/pr-inventory-kept" 43200
kept_inv="$TMPROOT/kept-inventory.json"
assert_eq "$(av "$PT/pr-inventory-kept" --kind bogus --inventory-out "$kept_inv")" kept:unproven-content "unproven path stays kept"
[[ ! -e "$kept_inv" ]] && ok "inventory-out is written only on remove" || bad "inventory-out escaped a kept verdict"

deadline_root="$TMPROOT/deadline-root"
deadline_repo="$deadline_root/nested"
deadline_remote="$TMPROOT/remotes/deadline.git"
deadline_remote2="$TMPROOT/remotes/deadline-second.git"
mkdir -p "$deadline_root"
git init -q --bare -b main "$deadline_remote" && mkrepo "$TMPROOT/seed-deadline" && git -C "$TMPROOT/seed-deadline" push -q "$deadline_remote" main
git clone -q "$deadline_remote" "$deadline_repo" && git -C "$deadline_repo" remote add second "$deadline_remote2"
git init -q --bare -b main "$deadline_remote2"
baseline "$deadline_repo"
deadline_repo_lease="$(lease_path_for "$deadline_repo")"
python3 - "$deadline_repo_lease" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d.update(owner={"pid":1}, released_at="2026-10-01T00:00:00Z"); json.dump(d,open(p,"w"))
PY
truncate -s 2147483648 "$deadline_root/manifested.bin"
deadline_lease="$(lease_path_for "$deadline_root")" && mkdir -p "${deadline_lease%/*}"
printf '{"path":"%s","owner":{"pid":1},"released_at":"2026-10-01T00:00:00Z","published_url":"gs://wa-test-evidence/agent-evidence/deadline","verified_at":"2026-10-01T00:00:00Z","upload_manifest":[{"path":"manifested.bin","size":2147483648,"sha256":"placeholder","object":"gs://wa-test-evidence/agent-evidence/deadline/manifested.bin","generation":"1","md5":"placeholder","crc32c":"placeholder"}]}' "$deadline_root" >"$deadline_lease"
age "$deadline_root" 43200
mkdir -p "$TMPROOT/slow-git"
real_git="$(command -v git)"
cat >"$TMPROOT/slow-git/git" <<STUB
#!/bin/bash
[[ "\$1" == ls-remote ]] && { sleep 25; exec "$real_git" "\$@"; }
exec "$real_git" "\$@"
STUB
cat >"$TMPROOT/slow-git/lsof" <<'STUB'
#!/bin/sh
case " $* " in *" -d cwd "*) printf 'p%s\nfcwd\nn/\n' "$$"; exit 0 ;; esac
exit 1
STUB
chmod +x "$TMPROOT/slow-git/git" "$TMPROOT/slow-git/lsof"
deadline_at="$(python3 -c 'import time; print(time.monotonic()+30)')"
deadline_inventory="$TMPROOT/deferred-inventory.json"
verdict="$(PATH="$TMPROOT/slow-git:$PATH" DISK_MAGICIAN_LSOF_BIN="$TMPROOT/slow-git/lsof" av "$deadline_root" --deadline-at "$deadline_at" --inventory-out "$deadline_inventory")"
[[ "$verdict" == deferred:* ]] && ok "deadline defers the nested-repo / 2 GiB provenance case ($verdict)" || bad "deadline verdict: $verdict"
[[ -f "$deadline_root/manifested.bin" && -d "$deadline_repo" && ! -e "$deadline_inventory" ]] && ok "deferred verdict leaves candidate and output inventory untouched" || bad "deferred path changed candidate or emitted output"
# Rebuildable deadline: the caller's --deadline-at must reach the enclosing
# worktree's shared push (ls-remote) probe; a slow remote defers, never removes.
venvw "$HOME/wt-rbdl" && age "$HOME/wt-rbdl" 11520
rb_short="$(python3 -c 'import time; print(time.monotonic()+5)')"
assert_eq "$(PATH="$TMPROOT/slow-git:$PATH" av "$HOME/wt-rbdl/venv" --kind rebuildable --deadline-at "$rb_short")" deferred:lsremote \
    "rebuildable venv honors the caller deadline on a slow remote"
# Far-deadline positive: the same eligible venv still removes when time allows.
rb_far="$(python3 -c 'import time; print(time.monotonic()+120)')"
assert_eq "$(av "$HOME/wt-rbdl/venv" --kind rebuildable --deadline-at "$rb_far")" remove \
    "far-deadline rebuildable venv still removes"

mkdir -p "$PT/pr-race" && printf 'old bytes' >"$PT/pr-race/old.txt" && age "$PT/pr-race" 43200
race_file="$PT/pr-race/untracked-after-nomination.txt"
assert_eq "$(DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$PT" DISK_MAGICIAN_TEST_AFTER_NOMINATE="$race_file" eph "$PT/pr-race")" kept:recent-activity "post-nomination file is inventoried and kept"
[[ -f "$race_file" ]] && ok "nomination race fixture writes only inside the sandbox" || bad "race hook missed its fixture"

echo "== repository with an external registered linked worktree =="
# A backing repo whose linked worktree lives OUTSIDE the candidate must keep the
# candidate: removing it would destroy the common Git admin storage the worktree
# needs, even when the worktree's visible branch is pushed. The baseline is
# recorded after the worktree exists, so git_meta alone cannot catch this.
ext_candidate="$PT/extwt/repo"
git clone -q "$TMPROOT/remotes/wtbase.git" "$ext_candidate"
ext_wt="$TMPROOT/ext-elsewhere/wt"
git -C "$ext_candidate" worktree add -q "$ext_wt" -b extwt origin/main 2>/dev/null
git -C "$ext_wt" push -q -u origin extwt 2>/dev/null
printf 'EXTERNAL WORK\n' >>"$ext_wt/tracked.txt"
baseline "$ext_candidate"
# The external worktree's live lease is outside the candidate scope, so it cannot
# be what keeps the candidate.
lease "$ext_wt" null
# Age the whole outer candidate (recursively covers the nested backing repo).
age "$PT/extwt" 43200
# An external `git status` may refresh the worktree index; re-age the outer
# candidate afterwards so index refresh cannot mask the topology flaw.
git -C "$ext_wt" status --porcelain >/dev/null 2>&1
age "$PT/extwt" 43200
assert_eq "$(eph "$ext_candidate")" kept:external-worktree "backing repo with an external registered worktree keeps"
assert_eq "$(eph "$PT/extwt")" kept:external-worktree "outer candidate containing the external worktree admin keeps"
[[ "$(tail -n1 "$ext_wt/tracked.txt")" == "EXTERNAL WORK" ]] \
    && ok "external worktree bytes intact after the verdict" || bad "external worktree bytes changed"
[[ -d "$ext_candidate/.git/worktrees/wt" ]] && ok "external worktree admin intact after the verdict" || bad "external worktree admin missing"
own "$ext_wt" '"2026-10-01T00:00:00Z"'
# Control: the same pushed, baselined, old candidate with no external worktree removes.
ext_ctl="$PT/extctl/repo"
git clone -q "$TMPROOT/remotes/wtbase.git" "$ext_ctl" && baseline "$ext_ctl"
age "$ext_ctl" 43200
assert_eq "$(eph "$ext_ctl")" remove "no-external control still removes"
# Control: a normal linked-worktree candidate is not vetoed by its sibling
# worktrees, whose shared admin storage lives outside that candidate.
assert_eq "$(wt cand)" ok "normal linked-worktree candidate still removes with siblings present"

# Topology deadline: a delayed worktree-list command must defer, not remove.
mkdir -p "$TMPROOT/slow-wt"
cat >"$TMPROOT/slow-wt/git" <<STUB
#!/bin/bash
[[ "\$1" == --git-dir && "\$3" == worktree ]] && sleep 25
exec "$real_git" "\$@"
STUB
chmod +x "$TMPROOT/slow-wt/git"
wt_deadline="$(python3 -c 'import time; print(time.monotonic()+5)')"
assert_eq "$(PATH="$TMPROOT/slow-wt:$PATH" c14_repo_pushed_ok "$ext_ctl" "$ext_ctl" "$wt_deadline")" deferred:worktree-topology \
    "short deadline defers the worktree topology probe"
# Empty and malformed worktree records fail closed instead of passing as ok.
mkdir -p "$TMPROOT/bad-wt/empty" "$TMPROOT/bad-wt/junk"
printf '#!/bin/bash\n[[ "$1" == --git-dir && "$3" == worktree ]] && exit 0\nexec "%s" "$@"\n' "$real_git" >"$TMPROOT/bad-wt/empty/git"
printf '#!/bin/bash\n[[ "$1" == --git-dir && "$3" == worktree ]] && { printf "garbage\\0"; exit 0; }\nexec "%s" "$@"\n' "$real_git" >"$TMPROOT/bad-wt/junk/git"
chmod +x "$TMPROOT/bad-wt/empty/git" "$TMPROOT/bad-wt/junk/git"
assert_eq "$(PATH="$TMPROOT/bad-wt/empty:$PATH" c14_repo_pushed_ok "$ext_ctl" "$ext_ctl")" kept:check-failed "empty worktree topology fails closed"
assert_eq "$(PATH="$TMPROOT/bad-wt/junk:$PATH" c14_repo_pushed_ok "$ext_ctl" "$ext_ctl")" kept:check-failed "malformed worktree topology fails closed"
# A complete Git worktree -z record ends with two NUL bytes; reject truncation.
mkdir -p "$TMPROOT/bad-wt/trunc-nonul" "$TMPROOT/bad-wt/trunc-sep"
printf '#!/bin/bash\n[[ "$1" == --git-dir && "$3" == worktree ]] && { printf "worktree /tmp/c14-owned\\0HEAD deadbeef"; exit 0; }\nexec "%s" "$@"\n' "$real_git" >"$TMPROOT/bad-wt/trunc-nonul/git"
printf '#!/bin/bash\n[[ "$1" == --git-dir && "$3" == worktree ]] && { printf "worktree /tmp/c14-owned\\0HEAD deadbeef\\0"; exit 0; }\nexec "%s" "$@"\n' "$real_git" >"$TMPROOT/bad-wt/trunc-sep/git"
chmod +x "$TMPROOT/bad-wt/trunc-nonul/git" "$TMPROOT/bad-wt/trunc-sep/git"
assert_eq "$(PATH="$TMPROOT/bad-wt/trunc-nonul:$PATH" c14_repo_pushed_ok "$ext_ctl" "$ext_ctl")" kept:check-failed "worktree topology missing final NUL fails closed"
assert_eq "$(PATH="$TMPROOT/bad-wt/trunc-sep:$PATH" c14_repo_pushed_ok "$ext_ctl" "$ext_ctl")" kept:check-failed "worktree topology missing record separator fails closed"

echo "== verdict stays blocked =="
v="$(artifact_removal_verdict "$TMPROOT/clean")" && [[ "$v" == kept:* ]] && ok "non-ephemeral path kept ($v)" || bad "non-ephemeral path: $v"
st="$(artifact_removal_verdict --self-test)"
assert_eq "$st" ok "self-test runs a real kept/remove pair (no stub green)"
assert_eq "$(bash "$LIB" --self-test)" ok "executed self-test reports ok"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

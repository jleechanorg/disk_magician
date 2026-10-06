#!/usr/bin/env bash
# test_worktree_hygiene_preserve_wip.sh — worktree_hygiene.sh --preserve-wip.
#
# Every case runs against throwaway repos under a temp HOME; no real worktree,
# remote, or GitHub call is ever touched (origin URLs point at nonexistent
# local paths; `gh` is a fake on PATH where a PR state is needed).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/worktree_hygiene.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_true() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
assert_contains() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — missing '$2'"; echo "$1" | sed 's/^/      | /'; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$1"; then bad "$3 — unexpected '$2'"; echo "$1" | sed 's/^/      | /'; else ok "$3"; fi
}

TMPROOT="$(mktemp -d)"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
BG_PIDS=()
cleanup() {
    local p
    for p in "${BG_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    [[ -n "$TMPROOT" && -d "$TMPROOT" && "$TMPROOT" != "/" ]] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
unset WORKTREE_APPROVED CLAUDE_WORKTREE_REPOS WORKTREE_MIN_AGE_DAYS
TODAY="$(date +%Y%m%d)"

# backdate_tree <dir> <days> — set every non-.git entry's mtime N days back.
backdate_tree() {
    python3 - "$1" "$2" <<'PY'
import os, sys, time
root, days = sys.argv[1], int(sys.argv[2])
t = time.time() - days * 86400
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".git"]
    for f in files:
        if f == ".git":
            continue
        os.utime(os.path.join(d, f), (t, t), follow_symlinks=False)
PY
}

g() { git -c user.name=tester -c user.email=tester@example.com "$@"; }

# mk_repo <name> -> echoes repo path. main branch, one commit, bogus origin.
mk_repo() {
    local r="$TMPROOT/repos/$1"
    mkdir -p "$r"
    g -C "$r" init -q -b main
    g -C "$r" config user.name repo-user
    g -C "$r" config user.email repo-user@example.com
    printf 'node_modules/\n.env\n' >"$r/.gitignore"
    echo base >"$r/tracked.txt"
    g -C "$r" add -A
    g -C "$r" commit -q -m init
    g -C "$r" remote add origin "$TMPROOT/no-such-remote.git"
    echo "$r"
}

# mk_wt <repo> <name> [branch|--detach] -> echoes worktree path.
mk_wt() {
    local repo="$1" name="$2" mode="${3:-}" wt="$TMPROOT/wts/$2"
    mkdir -p "$TMPROOT/wts"
    if [[ "$mode" == "--detach" ]]; then
        g -C "$repo" worktree add -q --detach "$wt" main
    else
        g -C "$repo" worktree add -q -b "${mode:-feat/$name}" "$wt" main
    fi
    echo "$wt"
}

run_hygiene() {
    # shellcheck disable=SC2068
    bash "$SCRIPT" --repos "$1" --skip-gh "${@:2}" 2>&1
}

wt_registered() { git -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; }

MANIFEST="$DISK_MAGICIAN_STATE_DIR/worktree_hygiene_wip_manifest.txt"

# ---------------------------------------------------------------------------
echo "case 1: dirty tracked change -> preserved on wip branch, worktree removed"
R1="$(mk_repo r1)"
W1="$(mk_wt "$R1" dirty1)"
echo "my precious edit" >>"$W1/tracked.txt"
backdate_tree "$W1" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R1" --skip-push --execute --preserve-wip)"
B1="wip/worktree-hygiene/$TODAY/dirty1"
assert_contains "$OUT" "PRESERVED-WIP" "ledger PRESERVED-WIP line"
assert_contains "$OUT" "$W1 -> $B1" "ledger names path -> branch"
assert_true "[[ ! -d '$W1' ]]" "worktree dir removed"
assert_true "! wt_registered '$R1' '$W1'" "worktree unregistered"
assert_true "git -C '$R1' show '$B1:tracked.txt' | grep -q 'my precious edit'" "wip branch contains the edit"
assert_true "git -C '$R1' log -1 --format=%s '$B1' | grep -qF 'wip: preserved by worktree-hygiene before removal ($W1)'" "commit message"
assert_true "[[ \"\$(git -C '$R1' log -1 --format=%an '$B1')\" == repo-user ]]" "author from git config"
assert_true "grep -qF '$B1' '$MANIFEST' && grep -qF '$W1' '$MANIFEST'" "manifest records path+branch"
assert_true "git -C '$R1' rev-parse --verify -q 'feat/dirty1' >/dev/null && [[ \"\$(git -C '$R1' rev-parse feat/dirty1)\" == \"\$(git -C '$R1' rev-parse main)\" ]]" "original branch not advanced"

# ---------------------------------------------------------------------------
echo "case 2: untracked file preserved"
R2="$(mk_repo r2)"
W2="$(mk_wt "$R2" untracked2)"
echo "new notes" >"$W2/notes.md"
backdate_tree "$W2" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R2" --skip-push --execute --preserve-wip)"
B2="wip/worktree-hygiene/$TODAY/untracked2"
assert_contains "$OUT" "$W2 -> $B2" "untracked preserved"
assert_true "git -C '$R2' show '$B2:notes.md' | grep -q 'new notes'" "branch contains untracked file"
assert_true "[[ ! -d '$W2' ]]" "untracked worktree removed"

# ---------------------------------------------------------------------------
echo "case 3: detached-unpushed preserved (commit kept on wip branch)"
R3="$(mk_repo r3)"
W3="$(mk_wt "$R3" detached3 --detach)"
echo "detached work" >"$W3/d.txt"
g -C "$W3" add d.txt
g -C "$W3" commit -q -m "detached commit"
SHA3="$(git -C "$W3" rev-parse HEAD)"
backdate_tree "$W3" 30
# No --skip-push: push to the nonexistent origin fails -> rejected-nonff.
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R3" --execute --preserve-wip)"
B3="wip/worktree-hygiene/$TODAY/detached3"
assert_contains "$OUT" "$W3 -> $B3" "detached-unpushed preserved"
assert_true "[[ \"\$(git -C '$R3' rev-parse '$B3')\" == '$SHA3' ]]" "wip branch points at detached commit (no empty commit)"
assert_true "[[ ! -d '$W3' ]]" "detached worktree removed"

# ---------------------------------------------------------------------------
echo "case 4: ignored node_modules dropped, worktree removed"
R4="$(mk_repo r4)"
W4="$(mk_wt "$R4" nm4)"
echo "edit" >>"$W4/tracked.txt"
mkdir -p "$W4/node_modules/pkg"
echo "x" >"$W4/node_modules/pkg/index.js"
backdate_tree "$W4" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R4" --skip-push --execute --preserve-wip)"
B4="wip/worktree-hygiene/$TODAY/nm4"
assert_contains "$OUT" "$W4 -> $B4" "node_modules worktree preserved"
assert_true "! git -C '$R4' ls-tree -r --name-only '$B4' | grep -q node_modules" "node_modules not committed"
assert_true "[[ ! -d '$W4' ]]" "node_modules worktree removed"

# ---------------------------------------------------------------------------
echo "case 5: ignored .env -> skipped, kept"
R5="$(mk_repo r5)"
W5="$(mk_wt "$R5" env5)"
echo "edit" >>"$W5/tracked.txt"
echo "SECRET=1" >"$W5/.env"
backdate_tree "$W5" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R5" --skip-push --execute --preserve-wip)"
assert_not_contains "$OUT" "PRESERVED-WIP" "no preservation with ignored .env"
assert_contains "$OUT" "ignored-secret" "skip reason names ignored secret"
assert_true "[[ -f '$W5/.env' ]] && wt_registered '$R5' '$W5'" ".env worktree kept"
assert_true "! git -C '$R5' for-each-ref refs/heads/wip | grep -q ." "no wip branch created"

# ---------------------------------------------------------------------------
echo "case 6: large-diff and open-pr untouched"
R6="$(mk_repo r6)"
W6="$(mk_wt "$R6" large6)"
for i in $(seq 1 51); do echo "f$i" >"$W6/f$i.txt"; done
g -C "$W6" add -A
g -C "$W6" commit -q -m many
for i in $(seq 1 51); do echo "changed" >>"$W6/f$i.txt"; done
W6b="$(mk_wt "$R6" openpr6)"
echo "c" >"$W6b/c.txt"
g -C "$W6b" add c.txt
g -C "$W6b" commit -q -m c
g -C "$R6" remote set-url origin "https://github.com/example/fake.git"
backdate_tree "$W6" 30
backdate_tree "$W6b" 30
FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"number":1,"state":"OPEN","title":"t","headRefOid":"abc"}]'
EOF
chmod +x "$FAKEBIN/gh"
OUT="$(WORKTREE_APPROVED=1 PATH="$FAKEBIN:$PATH" bash "$SCRIPT" --repos "$R6" --skip-push --execute --preserve-wip 2>&1)"
assert_contains "$OUT" "large-diff" "large-diff classified"
assert_contains "$OUT" "open-pr" "open-pr classified"
assert_not_contains "$OUT" "PRESERVED-WIP" "neither preserved"
assert_true "[[ -d '$W6' && -d '$W6b' ]]" "both worktrees kept"

# ---------------------------------------------------------------------------
echo "case 7: young (<7d) dirty worktree untouched"
R7="$(mk_repo r7)"
W7="$(mk_wt "$R7" young7)"
echo "fresh" >>"$W7/tracked.txt"
backdate_tree "$W7" 3
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R7" --skip-push --execute --preserve-wip --min-age 1)"
assert_contains "$OUT" "young" "young preserved"
assert_not_contains "$OUT" "PRESERVED-WIP" "young not wip-preserved"
assert_true "[[ -d '$W7' ]]" "young worktree kept"

# ---------------------------------------------------------------------------
echo "case 8: live process cwd inside worktree -> untouched"
R8="$(mk_repo r8)"
W8="$(mk_wt "$R8" live8)"
echo "edit" >>"$W8/tracked.txt"
mkdir -p "$W8/sub"
backdate_tree "$W8" 30
(cd "$W8/sub" && exec sleep 300) &
BG_PIDS+=("$!")
sleep 0.5
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R8" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "live-cwd" "skip reason live-cwd"
assert_not_contains "$OUT" "PRESERVED-WIP" "live worktree not preserved"
assert_true "[[ -d '$W8' ]] && git -C '$W8' status --porcelain | grep -q tracked.txt" "live worktree untouched (still dirty)"

# ---------------------------------------------------------------------------
echo "case 9: dry-run changes nothing"
R9="$(mk_repo r9)"
W9="$(mk_wt "$R9" dry9)"
echo "edit" >>"$W9/tracked.txt"
backdate_tree "$W9" 30
BEFORE="$(git -C "$R9" for-each-ref; git -C "$W9" status --porcelain)"
MAN_BEFORE="$(cat "$MANIFEST" 2>/dev/null || true)"
OUT="$(run_hygiene "$R9" --skip-push --preserve-wip)"
AFTER="$(git -C "$R9" for-each-ref; git -C "$W9" status --porcelain)"
assert_contains "$OUT" "WOULD-PRESERVE-WIP" "dry-run reports WOULD-PRESERVE-WIP"
assert_not_contains "$OUT" "PRESERVED-WIP $W9" "dry-run did not preserve"
assert_true "[[ \"\$BEFORE\" == \"\$AFTER\" && -d '$W9' ]]" "refs/status unchanged"
assert_true "[[ \"\$MAN_BEFORE\" == \"\$(cat '$MANIFEST' 2>/dev/null || true)\" ]]" "manifest unchanged"

# ---------------------------------------------------------------------------
echo "case 10: --execute without WORKTREE_APPROVED=1 refuses"
OUT="$(run_hygiene "$R9" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "Refusing" "refuses without approval"
assert_true "[[ -d '$W9' ]] && ! git -C '$R9' for-each-ref refs/heads/wip | grep -q ." "nothing changed"

# ---------------------------------------------------------------------------
echo "case 11: existing branch name collision gets -2"
R11="$(mk_repo r11)"
W11="$(mk_wt "$R11" collide11)"
g -C "$R11" branch "wip/worktree-hygiene/$TODAY/collide11" main
echo "edit" >>"$W11/tracked.txt"
backdate_tree "$W11" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R11" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "$W11 -> wip/worktree-hygiene/$TODAY/collide11-2" "collision suffix -2"
assert_true "git -C '$R11' show 'wip/worktree-hygiene/$TODAY/collide11-2:tracked.txt' | grep -q edit" "-2 branch has the edit"

# ---------------------------------------------------------------------------
echo "case 12: without --preserve-wip, dirty worktrees stay NEEDS-REVIEW"
R12="$(mk_repo r12)"
W12="$(mk_wt "$R12" plain12)"
echo "edit" >>"$W12/tracked.txt"
backdate_tree "$W12" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R12" --skip-push --execute)"
assert_not_contains "$OUT" "PRESERVE-WIP" "no wip handling when flag absent"
assert_true "[[ -d '$W12' ]]" "dirty worktree kept without flag"

# ---------------------------------------------------------------------------
echo "case 13: locked worktree and in-progress merge state skipped"
R13="$(mk_repo r13)"
W13="$(mk_wt "$R13" locked13)"
echo "edit" >>"$W13/tracked.txt"
g -C "$R13" worktree lock "$W13"
W13b="$(mk_wt "$R13" merging13)"
echo "edit" >>"$W13b/tracked.txt"
GD13b="$(git -C "$W13b" rev-parse --git-dir)"
git -C "$W13b" rev-parse HEAD >"$GD13b/MERGE_HEAD"
backdate_tree "$W13" 30
backdate_tree "$W13b" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R13" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "locked" "locked skip reason"
assert_contains "$OUT" "in-progress-op" "in-progress skip reason"
assert_not_contains "$OUT" "PRESERVED-WIP" "neither preserved"
assert_true "[[ -d '$W13' && -d '$W13b' ]]" "both kept"

# ---------------------------------------------------------------------------
echo "case 14: nested git repo (ignored or untracked) -> skipped, kept intact"
R14="$(mk_repo r14)"
printf 'node_modules/\n.env\nvendor/\n' >"$R14/.gitignore"
g -C "$R14" commit -q -am "ignore vendor"
W14="$(mk_wt "$R14" nestign14)"
echo "edit" >>"$W14/tracked.txt"
mkdir -p "$W14/vendor/lib"
g -C "$W14/vendor/lib" init -q
echo "SECRET=1" >"$W14/vendor/lib/.env"
echo "code" >"$W14/vendor/lib/x.c"
g -C "$W14/vendor/lib" add x.c
g -C "$W14/vendor/lib" commit -q -m nested
W14b="$(mk_wt "$R14" nestuntr14)"
echo "edit" >>"$W14b/tracked.txt"
mkdir -p "$W14b/third/clone"
g -C "$W14b/third/clone" init -q
echo "local only" >"$W14b/third/clone/y.txt"
g -C "$W14b/third/clone" add y.txt
g -C "$W14b/third/clone" commit -q -m local
backdate_tree "$W14" 30
backdate_tree "$W14b" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R14" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "nested-repo" "skip reason nested-repo"
assert_not_contains "$OUT" "PRESERVED-WIP" "nested-repo worktrees not preserved"
assert_true "[[ -f '$W14/vendor/lib/.env' ]] && wt_registered '$R14' '$W14'" "ignored nested repo + .env kept"
assert_true "[[ -f '$W14b/third/clone/y.txt' ]] && wt_registered '$R14' '$W14b'" "untracked nested clone kept"
assert_true "! git -C '$R14' for-each-ref refs/heads/wip | grep -q ." "no wip branch created"

# ---------------------------------------------------------------------------
echo "case 15: large-diff masked by an untracked file -> still skipped"
R15="$(mk_repo r15)"
W15="$(mk_wt "$R15" bigc15)"
for i in $(seq 1 60); do echo "f$i" >"$W15/f$i.txt"; done
g -C "$W15" add -A
g -C "$W15" commit -q -m many
for i in $(seq 1 60); do echo "changed" >>"$W15/f$i.txt"; done
echo "u" >"$W15/untracked.txt"
backdate_tree "$W15" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R15" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "large-diff" "masked large-diff detected"
assert_not_contains "$OUT" "PRESERVED-WIP" "masked large-diff not preserved"
assert_true "[[ -d '$W15' && -f '$W15/untracked.txt' ]]" "large-diff worktree kept"

# ---------------------------------------------------------------------------
echo "case 16: no-merge-base masked by an untracked file -> still skipped"
R16="$(mk_repo r16)"
ORPHAN="$(g -C "$R16" commit-tree -m orphan "$(g -C "$R16" mktree </dev/null)")"
mkdir -p "$TMPROOT/wts"
W16="$TMPROOT/wts/orphan16"
g -C "$R16" worktree add -q --detach "$W16" "$ORPHAN"
echo "u" >"$W16/untracked.txt"
backdate_tree "$W16" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R16" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "no-merge-base" "masked no-merge-base detected"
assert_not_contains "$OUT" "PRESERVED-WIP" "no-merge-base not preserved"
assert_true "[[ -d '$W16' ]]" "no-merge-base worktree kept"

# ---------------------------------------------------------------------------
echo "case 17: dirty worktree with an open PR -> skipped (gh consulted)"
R17="$(mk_repo r17)"
W17="$(mk_wt "$R17" dirtypr17)"
echo "edit" >>"$W17/tracked.txt"
g -C "$R17" remote set-url origin "https://github.com/example/fake.git"
backdate_tree "$W17" 30
OUT="$(WORKTREE_APPROVED=1 PATH="$FAKEBIN:$PATH" bash "$SCRIPT" --repos "$R17" --skip-push --execute --preserve-wip 2>&1)"
assert_contains "$OUT" "open-pr" "open PR detected on dirty worktree"
assert_not_contains "$OUT" "PRESERVED-WIP" "open-PR worktree not preserved"
assert_true "[[ -d '$W17' ]] && git -C '$W17' status --porcelain | grep -q tracked.txt" "open-PR worktree untouched"

# ---------------------------------------------------------------------------
echo "case 18: preservation failure restores the original HEAD"
R18="$(mk_repo r18)"
W18="$(mk_wt "$R18" fail18)"
echo "new content never seen by git" >"$W18/fresh.txt"
echo "edit" >>"$W18/tracked.txt"
backdate_tree "$W18" 30
find "$R18/.git/objects" -type d -exec chmod a-w {} +
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R18" --skip-push --execute --preserve-wip)"
find "$R18/.git/objects" -type d -exec chmod u+w {} +
assert_contains "$OUT" "WIP-FAILED" "failure logged"
assert_true "[[ \"\$(git -C '$W18' symbolic-ref -q HEAD)\" == refs/heads/feat/fail18 ]]" "HEAD restored to original branch"
assert_true "git -C '$W18' status --porcelain | grep -q '^?? fresh.txt' && git -C '$W18' status --porcelain | grep -q '^ M tracked.txt'" "index restored (unstaged), content intact"
assert_true "wt_registered '$R18' '$W18'" "failed worktree kept"

# ---------------------------------------------------------------------------
echo "case 19: skip-worktree / assume-unchanged local edits -> skipped (git add cannot see them)"
R19="$(mk_repo r19)"
echo s >"$R19/skip.txt"; echo a >"$R19/au.txt"
g -C "$R19" add -A; g -C "$R19" commit -q -m flags
W19="$(mk_wt "$R19" flags19)"
g -C "$W19" update-index --skip-worktree skip.txt
echo PRECIOUS-SKIP >"$W19/skip.txt"
g -C "$W19" update-index --assume-unchanged au.txt
echo PRECIOUS-AU >"$W19/au.txt"
echo "edit" >>"$W19/tracked.txt"
backdate_tree "$W19" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R19" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "index-flagged" "index-flagged blocker reported"
assert_not_contains "$OUT" "PRESERVED-WIP" "flagged worktree not preserved"
assert_true "[[ \"\$(cat '$W19/skip.txt')\" == PRECIOUS-SKIP && \"\$(cat '$W19/au.txt')\" == PRECIOUS-AU ]]" "flagged local edits intact"

# ---------------------------------------------------------------------------
echo "case 20: ignored .envrc / secrets.json -> skipped"
R20="$(mk_repo r20)"
printf 'node_modules/\n.env\n.envrc\nsecrets.json\n' >"$R20/.gitignore"
g -C "$R20" add -A; g -C "$R20" commit -q -m ign
W20="$(mk_wt "$R20" envrc20)"
echo "export TOKEN=x" >"$W20/.envrc"
echo "edit" >>"$W20/tracked.txt"
backdate_tree "$W20" 30
OUT="$(WORKTREE_APPROVED=1 run_hygiene "$R20" --skip-push --execute --preserve-wip)"
assert_contains "$OUT" "ignored-secret" "ignored .envrc blocks"
assert_true "[[ -f '$W20/.envrc' ]]" ".envrc intact"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

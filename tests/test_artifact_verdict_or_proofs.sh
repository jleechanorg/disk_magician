#!/usr/bin/env bash
# 2026-11-12 operator decision: artifact_removal_verdict is "no veto AND at least one
# proof", not "every gate passes". Secret-like and ignored content are vetoes;
# dirty/unpushed repositories require a verified rescue instead of age proof.
# live cwd, open file, symlink and the
# .diskm-ballast / dot-prefixed top-level names still veto whatever else holds.
# Portable (Python sets mtimes); fixtures live in a mktemp dir only. Run with TMPDIR outside a
# registered Scratch volume (the fixture HOME has no volume registration, so paths on it read
# kept:volume-identity), e.g. TMPDIR=/private/tmp on macOS.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/artifact_verdict.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-c14-or-proofs.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; chmod -R u+rwx "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

export HOME="$T/home"
export PATH="/usr/bin:/bin:$PATH"  # the fixture HOME hides the rm/git guard shims
export DISK_MAGICIAN_STATE_DIR="$T/state"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR" "$T/s"
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$LIB"
# Rescue is part of the observable C14 decision: dirty/unpushed source qualifies
# only after a real independent snapshot is pushed and verified.
declare -F rescue_check >/dev/null || { echo "FAIL: artifact_verdict.sh did not source rescue_ref.sh"; exit 1; }

PROOF_OUT="$T/proof.out"
export DISK_MAGICIAN_C14_PROOF_OUT="$PROOF_OUT"
# av <path> [args]: verdict word; proofs land in $PROOF_OUT.
av() { : >"$PROOF_OUT"; artifact_removal_verdict "$@" --kind ephemeral; }
proofs() { tr -d '\n' <"$PROOF_OUT"; }
age() {
    python3 -I - "$1" "$2" <<'PY'
import os, sys, time
root, minutes = sys.argv[1], int(sys.argv[2])
when = time.time() - minutes * 60
paths = [root]
for dirpath, dirnames, filenames in os.walk(root):
    paths += [os.path.join(dirpath, n) for n in dirnames + filenames]
for p in sorted(paths, key=len, reverse=True):
    os.utime(p, (when, when), follow_symlinks=False)
PY
}
mkdir_file() { mkdir -p "$1" && printf 'payload' >"$1/${2:-f}"; }
# clone_fixture <name>: a clone of a local bare origin, pushed and clean.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
printf 'x\n' >"$T/seed/a"; git -C "$T/seed" add a; git -C "$T/seed" commit -qm init; git -C "$T/seed" push -q origin main
clone_fixture() { git clone -q --no-local "$T/origin.git" "$T/s/$1" 2>/dev/null; }

echo "== no proof: kept:no-proof, not an old gate reason =="
mkdir_file "$T/s/recent"; age "$T/s/recent" 30
assert_eq "$(av "$T/s/recent")" kept:recent-activity "written 30 min ago: 1 h idle veto"
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/recent" av "$T/s/recent")" kept:recent-activity "1 h idle veto holds even when operator-named"
mkdir_file "$T/s/young"; age "$T/s/young" 90
assert_eq "$(av "$T/s/young")" kept:recent-activity "young plain dir"
mkdir_file "$T/s/name-unknown"; age "$T/s/name-unknown" 200
assert_eq "$(av "$T/s/name-unknown")" kept:recent-activity "below the shared 48h floor"

echo "== proof 1: age =="
mkdir_file "$T/s/old"; age "$T/s/old" 2881
assert_eq "$(av "$T/s/old")" remove "old dir"
assert_eq "$(proofs)" age "age label printed"
mkdir_file "$T/s/secret-old"; printf 'k' >"$T/s/secret-old/.env"; printf 'k' >"$T/s/secret-old/id_rsa"; age "$T/s/secret-old" 2000
assert_eq "$(av "$T/s/secret-old")" kept:secret-like "secret-like remains protected even when old"
mkdir_file "$T/s/secret-young"; printf 'k' >"$T/s/secret-young/.env"; age "$T/s/secret-young" 90
assert_eq "$(av "$T/s/secret-young")" kept:secret-like "secret-like is protected regardless of age"
mkdir_file "$T/s/floor"; age "$T/s/floor" 100
assert_eq "$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=10 av "$T/s/floor")" kept:recent-activity "explicit env floor clamps to 120m for this run"
age "$T/s/floor" 130
assert_eq "$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=10 av "$T/s/floor")" remove "130 min passes the clamped 120 min floor"
(
    _av_newest_mtime() { return 1; }
    mkdir_file "$T/s/unmeasurable"; age "$T/s/unmeasurable" 5000
    assert_eq "$(av "$T/s/unmeasurable")" kept:mtime-unmeasurable "unmeasurable age fails closed"
    [[ "$FAIL" -eq 0 ]]
) || FAIL=$((FAIL + 1))

echo "== proof 2: on-origin / dirty and unpushed git =="
clone_fixture clean-young; age "$T/s/clean-young" 90
assert_eq "$(av "$T/s/clean-young")" kept:recent-activity "on-origin proof does not bypass the 48h content floor"
assert_eq "$(proofs)" "" "recent content does not collect an on-origin removal proof"
clone_fixture dirty-young; printf 'wip' >"$T/s/dirty-young/new"; age "$T/s/dirty-young" 90
assert_eq "$(av "$T/s/dirty-young")" kept:recent-activity "recent dirty work is preserved after rescue is unnecessary"
assert_eq "$(proofs)" "" "no remote rescue is pushed for young content"
clone_fixture dirty-old; printf 'wip' >"$T/s/dirty-old/new"; age "$T/s/dirty-old" 2881
assert_eq "$(av "$T/s/dirty-old")" remove "old dirty clone removed only after rescue push"
assert_eq "$(proofs)" rescued "old dirty clone rescue label printed"
clone_fixture dirty-old-no-remote; printf 'wip' >"$T/s/dirty-old-no-remote/new"; age "$T/s/dirty-old-no-remote" 2881
git -C "$T/s/dirty-old-no-remote" remote set-url origin "$T/missing-origin.git"
assert_eq "$(av "$T/s/dirty-old-no-remote")" kept:dirty "age cannot bypass a failed independent rescue"
clone_fixture unpushed-young; git -C "$T/s/unpushed-young" commit -q --allow-empty -m local; age "$T/s/unpushed-young" 90
assert_eq "$(av "$T/s/unpushed-young")" kept:recent-activity "a recent unpublished commit stays in its worktree"
assert_eq "$(proofs)" "" "recent unpublished commit requires no removal rescue"

clone_fixture git-index-fresh; age "$T/s/git-index-fresh" 2881; git -C "$T/s/git-index-fresh" status --porcelain >/dev/null
assert_eq "$(av "$T/s/git-index-fresh")" remove "fresh .git/index metadata does not make 49h-old content recent"

echo "== rebuildable venv child in locally changed worktree =="
venv_verdict() (
  wrh_live_cwd_reason() { WRH_LIVE_CWD_REASON=""; return 0; }
  _av_open_file() { printf "no\n"; return 0; }
  artifact_removal_verdict "$1" --kind rebuildable
)

git -C "$T/seed" worktree add -q -b venv-parent-wip "$T/s/venv-parent-wip" main
mkdir -p "$T/s/venv-parent-wip/venv/bin"
printf 'rebuildable\n' >"$T/s/venv-parent-wip/venv/bin/python"
# Keep a local unpushed commit and a separate dirty source edit beside the untracked venv.
printf 'local-only commit\n' >>"$T/s/venv-parent-wip/a"
git -C "$T/s/venv-parent-wip" -c user.name=t -c user.email=t@example.invalid commit -qam local-unpushed
printf 'dirty-source\n' >>"$T/s/venv-parent-wip/a"
age "$T/s/venv-parent-wip" 2881
source_commit_before="$(git -C "$T/s/venv-parent-wip" rev-parse HEAD)"
source_status_before="$(git -C "$T/s/venv-parent-wip" status --porcelain)"
assert_eq "$(venv_verdict "$T/s/venv-parent-wip/venv")" remove "49h idle untracked rebuildable venv can be stripped despite local parent work"
assert_eq "$(git -C "$T/s/venv-parent-wip" rev-parse HEAD)" "$source_commit_before" "unpublished parent commit remains"
assert_eq "$(git -C "$T/s/venv-parent-wip" status --porcelain)" "$source_status_before" "dirty parent status remains"
git -C "$T/s/venv-parent-wip" show HEAD:a | grep -q local-only && ok "local unpushed parent content remains intact" || bad "local parent commit disappeared"
grep -q dirty-source "$T/s/venv-parent-wip/a" && ok "dirty parent worktree content remains intact" || bad "dirty parent edit disappeared"
printf 'recent\n' >"$T/s/venv-parent-wip/venv/bin/python"
age "$T/s/venv-parent-wip/venv" 120
git -C "$T/s/venv-parent-wip" status --porcelain >"$T/parent-dirty.before-recent"
assert_eq "$(venv_verdict "$T/s/venv-parent-wip/venv")" kept:recent-activity "2h recent venv content remains protected"
git -C "$T/s/venv-parent-wip" status --porcelain >"$T/parent-dirty.after-recent"
assert_eq "$(cat "$T/parent-dirty.after-recent")" "$(cat "$T/parent-dirty.before-recent")" "young venv verdict leaves parent unchanged"

echo "== proof 3: rescued (only when nothing else proves, push must succeed) =="
PUSHED="$T/pushed.log"
(
    rescue_check() { return 0; }
    rescue_push() { printf '%s\n' "$1" >>"$PUSHED"; return "${RESCUE_RC:-0}"; }
    clone_fixture rescue-ok; printf 'wip' >"$T/s/rescue-ok/new"; age "$T/s/rescue-ok" 2881
    assert_eq "$(av "$T/s/rescue-ok")" remove "dirty young clone, rescue_check ok, rescue_push rc 0"
    assert_eq "$(proofs)" rescued "rescued label printed"
    [[ "$(cat "$PUSHED")" == "$(cd "$T/s/rescue-ok" && pwd -P)" ]] && ok "rescue_push called on the tree" || bad "rescue_push not called"
    : >"$PUSHED"
    clone_fixture rescue-preview; printf 'wip' >"$T/s/rescue-preview/new"; age "$T/s/rescue-preview" 2881
    assert_eq "$(av "$T/s/rescue-preview" --no-rescue-push)" kept:rescue-required "read-only preview does not claim a rescue"
    [[ ! -s "$PUSHED" ]] && ok "preview never pushes" || bad "preview pushed"
    if git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/diskm-rescue | grep -q rescue-preview; then
        bad "read-only preview created a rescue ref"
    else
        ok "read-only preview creates no rescue ref"
    fi
    clone_fixture rescue-fail; printf 'wip' >"$T/s/rescue-fail/new"; age "$T/s/rescue-fail" 2881
    assert_eq "$(RESCUE_RC=1 av "$T/s/rescue-fail")" kept:dirty "rescue_push rc 1 keeps the tree"
    clone_fixture rescue-skip; age "$T/s/rescue-skip" 2881
    : >"$PUSHED"
    av "$T/s/rescue-skip" >/dev/null
    [[ ! -s "$PUSHED" ]] && ok "no push when on-origin already proves it" || bad "pushed despite another proof"
    [[ "$FAIL" -eq 0 ]]
) || FAIL=$((FAIL + 1))

(
    export DISK_MAGICIAN_DELETION_LOG="$T/deletions.log"
    clone_fixture rescue-real; printf 'wip' >"$T/s/rescue-real/new"; age "$T/s/rescue-real" 2881
    assert_eq "$(av "$T/s/rescue-real")" remove "real rescue_ref: dirty young clone rescued"
    assert_eq "$(proofs)" rescued "real rescue_ref proof recorded"
    ref="$(git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/diskm-rescue | grep 'rescue-real-')"
    [[ -n "$ref" ]] && ok "rescue ref exists on origin before removal" || bad "rescue ref missing"
    snap="$(git -C "$T/origin.git" rev-parse "$ref" 2>/dev/null)"
    assert_eq "$(git -C "$T/origin.git" show "$snap:new" 2>/dev/null)" wip "rescue ref holds the untracked work"
    clone_fixture rescue-secret; printf 'wip' >"$T/s/rescue-secret/new"; printf 'k' >"$T/s/rescue-secret/.env"; age "$T/s/rescue-secret" 90
    assert_eq "$(av "$T/s/rescue-secret")" kept:secret-like "secret-like source remains protected"
    [[ "$FAIL" -eq 0 ]]
) || FAIL=$((FAIL + 1))

echo "== proofs 4 and 6: rebuildable name, operator-named =="
mkdir_file "$T/s/proj/build"; age "$T/s/proj/build" 2881
assert_eq "$(av "$T/s/proj/build")" remove "build dir idle past the shared 48 h content floor"
assert_eq "$(proofs)" "age,rebuildable" "age and rebuildable labels printed after48h"
mkdir_file "$T/s/proj3/build"; age "$T/s/proj3/build" 30
assert_eq "$(av "$T/s/proj3/build")" kept:recent-activity "build dir written minutes ago: 1 h idle veto"
mkdir_file "$T/s/proj2/build"; git init -q "$T/s/proj2/build"; age "$T/s/proj2/build" 2881
assert_eq "$(av "$T/s/proj2/build")" kept:dirty "a build-named repo with untracked content is kept"
mkdir_file "$T/s/named"; age "$T/s/named" 2881
target_list="$(printf '%s\n' "$T/s/other" "$T/s/named")"
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$target_list" av "$T/s/named")" remove "operator-target proof still requires48h content inactivity"
assert_eq "$(proofs)" "age,operator-named" "age and operator target proofs are recorded after48h"

echo "== vetoes keep even when every proof holds =="
mkdir_file "$T/s/cwd"; age "$T/s/cwd" 2000
( cd "$T/s/cwd" && exec sleep 60 ) & CWD_PID=$!
sleep 0.3
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/cwd" av "$T/s/cwd")" kept:live-cwd "live process cwd (old + operator-named)"
kill "$CWD_PID" 2>/dev/null
mkdir_file "$T/s/openfile"; age "$T/s/openfile" 2000
exec 7<"$T/s/openfile/f"
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/openfile" av "$T/s/openfile")" kept:open-file "open file inside (old + operator-named)"
exec 7<&-
mkdir_file "$T/s/target-dir"; age "$T/s/target-dir" 2000; ln -s "$T/s/target-dir" "$T/s/link"
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/link" av "$T/s/link")" kept:check-failed "symlink is never followed"
printf x >"$T/s/.diskm-ballast"; age "$T/s/.diskm-ballast" 5000
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/.diskm-ballast" av "$T/s/.diskm-ballast")" kept:protected ".diskm-ballast (old + operator-named)"
echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

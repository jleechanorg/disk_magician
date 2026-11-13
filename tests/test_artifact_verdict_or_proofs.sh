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
# The real rescue_ref.sh is sourced by the verdict. Keep the proof 1/2/4/6 cases isolated
# from it (they assert "dirty alone is no proof"); proof 3 uses stubs and one real case below.
declare -F rescue_check >/dev/null || { echo "FAIL: artifact_verdict.sh did not source rescue_ref.sh"; exit 1; }
eval "_real_$(declare -f rescue_check)"
eval "_real_$(declare -f rescue_push)"
unset -f rescue_check rescue_push

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
clone_fixture() { git clone -q "$T/origin.git" "$T/s/$1" 2>/dev/null; }

echo "== no proof: kept:no-proof, not an old gate reason =="
mkdir_file "$T/s/recent"; age "$T/s/recent" 30
assert_eq "$(av "$T/s/recent")" kept:recent-activity "written 30 min ago: 1 h idle veto"
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/recent" av "$T/s/recent")" kept:recent-activity "1 h idle veto holds even when operator-named"
mkdir_file "$T/s/young"; age "$T/s/young" 90
assert_eq "$(av "$T/s/young")" kept:no-proof "young plain dir"
mkdir_file "$T/s/name-unknown"; age "$T/s/name-unknown" 200
assert_eq "$(av "$T/s/name-unknown")" kept:no-proof "200 min old is below the 1440 min class default"

echo "== proof 1: age =="
mkdir_file "$T/s/old"; age "$T/s/old" 2000
assert_eq "$(av "$T/s/old")" remove "old dir"
assert_eq "$(proofs)" age "age label printed"
mkdir_file "$T/s/secret-old"; printf 'k' >"$T/s/secret-old/.env"; printf 'k' >"$T/s/secret-old/id_rsa"; age "$T/s/secret-old" 2000
assert_eq "$(av "$T/s/secret-old")" remove "secret-like + old is eligible by age"
mkdir_file "$T/s/secret-young"; printf 'k' >"$T/s/secret-young/.env"; age "$T/s/secret-young" 90
assert_eq "$(av "$T/s/secret-young")" kept:no-proof "secret-like + young has no proof"
mkdir_file "$T/s/floor"; age "$T/s/floor" 100
assert_eq "$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=10 av "$T/s/floor")" kept:no-proof "env floor below 120 clamps up to 120"
age "$T/s/floor" 130
assert_eq "$(DISK_MAGICIAN_AGE_FLOOR_MINUTES=10 av "$T/s/floor")" remove "130 min passes the clamped 120 min floor"
(
    _av_newest_mtime() { return 1; }
    mkdir_file "$T/s/unmeasurable"; age "$T/s/unmeasurable" 5000
    assert_eq "$(av "$T/s/unmeasurable")" kept:mtime-unmeasurable "unmeasurable age fails closed"
) || true

echo "== proof 2: on-origin / dirty and unpushed git =="
clone_fixture clean-young; age "$T/s/clean-young" 90
assert_eq "$(av "$T/s/clean-young")" remove "clean pushed clone, young"
assert_eq "$(proofs)" on-origin "on-origin label printed"
clone_fixture dirty-young; printf 'wip' >"$T/s/dirty-young/new"; age "$T/s/dirty-young" 90
assert_eq "$(av "$T/s/dirty-young")" kept:no-proof "dirty clone, young"
clone_fixture dirty-old; printf 'wip' >"$T/s/dirty-old/new"; age "$T/s/dirty-old" 2000
assert_eq "$(av "$T/s/dirty-old")" remove "dirty clone, old: preserved by independent rescue"
clone_fixture unpushed-young; git -C "$T/s/unpushed-young" commit -q --allow-empty -m local; age "$T/s/unpushed-young" 90
assert_eq "$(av "$T/s/unpushed-young")" kept:no-proof "unpushed clone, young"

echo "== proof 3: rescued (only when nothing else proves, push must succeed) =="
PUSHED="$T/pushed.log"
(
    rescue_check() { return 0; }
    rescue_push() { printf '%s\n' "$1" >>"$PUSHED"; return "${RESCUE_RC:-0}"; }
    clone_fixture rescue-ok; printf 'wip' >"$T/s/rescue-ok/new"; age "$T/s/rescue-ok" 90
    assert_eq "$(av "$T/s/rescue-ok")" remove "dirty young clone, rescue_check ok, rescue_push rc 0"
    assert_eq "$(proofs)" rescued "rescued label printed"
    [[ "$(cat "$PUSHED")" == "$T/s/rescue-ok" ]] && ok "rescue_push called on the tree" || bad "rescue_push not called"
    : >"$PUSHED"
    clone_fixture rescue-preview; printf 'wip' >"$T/s/rescue-preview/new"; age "$T/s/rescue-preview" 90
    assert_eq "$(av "$T/s/rescue-preview" --no-rescue-push)" kept:rescue-required "read-only preview does not claim a rescue"
    [[ ! -s "$PUSHED" ]] && ok "preview never pushes" || bad "preview pushed"
    if git -C "$T/origin.git" for-each-ref --format='%(refname)' refs/diskm-rescue | grep -q rescue-preview; then
        bad "read-only preview created a rescue ref"
    else
        ok "read-only preview creates no rescue ref"
    fi
    clone_fixture rescue-fail; printf 'wip' >"$T/s/rescue-fail/new"; age "$T/s/rescue-fail" 90
    assert_eq "$(RESCUE_RC=1 av "$T/s/rescue-fail")" kept:dirty "rescue_push rc 1 keeps the tree"
    clone_fixture rescue-skip; age "$T/s/rescue-skip" 90
    : >"$PUSHED"
    av "$T/s/rescue-skip" >/dev/null
    [[ ! -s "$PUSHED" ]] && ok "no push when on-origin already proves it" || bad "pushed despite another proof"
) || true
(
    clone_fixture rescue-absent; printf 'wip' >"$T/s/rescue-absent/new"; age "$T/s/rescue-absent" 90
    assert_eq "$(av "$T/s/rescue-absent")" kept:no-proof "rescue_check undefined: proof 3 unavailable"
) || true

(
    eval "$(declare -f _real_rescue_check | sed '1s/^_real_//')"
    eval "$(declare -f _real_rescue_push | sed '1s/^_real_//')"
    export DISK_MAGICIAN_DELETION_LOG="$T/deletions.log"
    clone_fixture rescue-real; printf 'wip' >"$T/s/rescue-real/new"; age "$T/s/rescue-real" 90
    assert_eq "$(av "$T/s/rescue-real")" remove "real rescue_ref: dirty young clone rescued"
    refs="$(git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/diskm-rescue/' | wc -l | tr -d ' ')"
    assert_eq "$refs" 1 "rescue ref exists on origin before removal"
    snap="$(git -C "$T/origin.git" for-each-ref --format='%(objectname)' 'refs/diskm-rescue/')"
    assert_eq "$(git -C "$T/origin.git" show "$snap:new" 2>/dev/null)" wip "rescue ref holds the untracked work"
    clone_fixture rescue-secret; printf 'wip' >"$T/s/rescue-secret/new"; printf 'k' >"$T/s/rescue-secret/.env"; age "$T/s/rescue-secret" 90
    assert_eq "$(av "$T/s/rescue-secret")" kept:no-proof "real rescue_ref: secret-like tree is never pushed"
) || true

echo "== proofs 4 and 6: rebuildable name, operator-named =="
mkdir_file "$T/s/proj/build"; age "$T/s/proj/build" 90
assert_eq "$(av "$T/s/proj/build")" remove "build dir idle past the 1 h rebuildable floor"
assert_eq "$(proofs)" rebuildable "rebuildable label printed"
mkdir_file "$T/s/proj3/build"; age "$T/s/proj3/build" 30
assert_eq "$(av "$T/s/proj3/build")" kept:recent-activity "build dir written minutes ago: 1 h idle veto"
mkdir_file "$T/s/proj2/build"; git init -q "$T/s/proj2/build"; age "$T/s/proj2/build" 90
assert_eq "$(av "$T/s/proj2/build")" kept:no-proof "a build-named tree holding .git is not rebuildable"
mkdir_file "$T/s/named"; age "$T/s/named" 90
assert_eq "$(DISK_MAGICIAN_OPERATOR_TARGETS="$T/s/other
$T/s/named" av "$T/s/named")" remove "operator-named, young"
assert_eq "$(proofs)" operator-named "operator-named label printed"

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

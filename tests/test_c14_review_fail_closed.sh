#!/usr/bin/env bash
# Focused regressions for fail-open C14 repository discovery and lsof probes.
set -uo pipefail

REPO_ROOT="${C14_REGRESSION_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
TMPROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/c14-review-regressions.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$TMPROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=jleechan2015@users.noreply.github.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=jleechan2015@users.noreply.github.com

PASS=0
FAIL=0
check() {
    local label=$1 expected=$2 actual=$3
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS: $label ($actual)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

candidate="$TMPROOT/candidate"
repo="$candidate/nested"
mkdir -p "$repo"
git -C "$repo" init -q -b main
printf 'tracked\n' >"$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm init
mv "$repo/.git" "$candidate/gitmeta"
ln -s ../gitmeta "$repo/.git"
printf 'dirty\n' >>"$repo/tracked.txt"
inventory="$TMPROOT/inventory.json"
probe="$REPO_ROOT/scripts/c14_probe.py"
check 'inventory succeeds' ok "$(python3 "$probe" inventory "$candidate" "$inventory")"
repos="$(C14_ROOT="$candidate" python3 "$probe" repos "$inventory" | tr '\0' '\n')"
check 'nested repository is found through .git symlink' "$repo" "$repos"

mkdir -p "$TMPROOT/no-lsof"
check 'missing lsof fails closed' kept:check-failed \
    "$(DISK_MAGICIAN_LSOF_BIN="$TMPROOT/missing-lsof" python3 "$probe" open-file "$TMPROOT/no-lsof")"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

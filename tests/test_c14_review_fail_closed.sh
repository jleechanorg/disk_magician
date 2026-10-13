#!/usr/bin/env bash
# Focused regressions for fail-open C14 repository discovery and lsof probes.
set -uo pipefail

REPO_ROOT="${C14_REGRESSION_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

# The cleanup/validation selector: only this test's own /tmp fixture roots are
# ever eligible for removal, so an empty or out-of-prefix value is refused.
is_owned_tmp_root() {
    case "$1" in
        /tmp/c14-review-regressions.*|/private/tmp/c14-review-regressions.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Explicit, validated /tmp allocation. Validate success, prefix (before and
# after canonicalization) and refuse a symlinked root so a failed mktemp can
# never resolve to "" / cwd and let the exit trap delete the repository.
TMPROOT="$(mktemp -d /tmp/c14-review-regressions.XXXXXX)" || {
    echo "FATAL: could not allocate /tmp fixture root" >&2; exit 2;
}
[[ -n "$TMPROOT" && -d "$TMPROOT" && ! -L "$TMPROOT" ]] && is_owned_tmp_root "$TMPROOT" || {
    echo "FATAL: fixture root not a real dir under /tmp: '$TMPROOT'" >&2; exit 2;
}
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 2
is_owned_tmp_root "$TMPROOT" || {
    echo "FATAL: canonical fixture root not under /tmp: '$TMPROOT'" >&2; exit 2;
}
cleanup() {
    is_owned_tmp_root "$TMPROOT" || return 0
    chmod -R u+rwx "$TMPROOT" 2>/dev/null; rm -rf -- "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"; mkdir -p "$HOME"
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"; mkdir -p "$DISK_MAGICIAN_STATE_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=jleechan2015@users.noreply.github.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=jleechan2015@users.noreply.github.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"

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

# Negative allocation guard: the selector that gates cleanup must refuse empty,
# cwd/repo and out-of-prefix roots (a failed mktemp must never become a cleanup
# target). This exercises the same function the EXIT trap uses.
if ! is_owned_tmp_root "" && ! is_owned_tmp_root "$PWD" \
   && ! is_owned_tmp_root /tmp/not-c14-review-regressions \
   && is_owned_tmp_root "$TMPROOT"; then
    echo "PASS: allocation cleanup guard refuses empty/out-of-prefix roots"
    PASS=$((PASS + 1))
else
    echo "FAIL: allocation cleanup guard accepted an unsafe root"
    FAIL=$((FAIL + 1))
fi

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

# F1: bare layouts Git accepts with HEAD/objects/refs as internal symlinks, plus
# regular control, outside/broken fail-closed, and legacy/inventory parity.
bare_fixture() {
    mkdir -p "$1"
    git -C "$1" init -q --bare -b main
    local c
    c="$(git -C "$1" commit-tree "$(git -C "$1" mktree </dev/null)" -m unpushed)"
    git -C "$1" update-ref refs/heads/main "$c"
}
check_repo_paths() {
    local label=$1 cand=$2 want_legacy=$3 want_inventory=$4 inv found_legacy found_inventory
    inv="$TMPROOT/inv-$(basename "$cand").json"
    check "$label inventory builds" ok "$(python3 "$probe" inventory "$cand" "$inv")"
    check "$label inventory path" "$want_inventory" "$(c14_repos_ok "$cand" "$inv")"
    check "$label legacy path" "$want_legacy" "$(c14_repos_ok "$cand")"
    found_legacy="$(c14_discover_repos "$cand" | tr '\0' '\n' | sort)"
    found_inventory="$(C14_ROOT="$cand" python3 "$probe" repos "$inv" | tr '\0' '\n' | sort)"
    check "$label discovery agreement" "$found_legacy" "$found_inventory"
}
bare_fixture "$TMPROOT/bare-regular/b.git"
check_repo_paths 'regular bare repo' "$TMPROOT/bare-regular" kept:not-pushed kept:not-pushed
bare_fixture "$TMPROOT/bare-head/b.git"
rm "$TMPROOT/bare-head/b.git/HEAD" && ln -s refs/heads/main "$TMPROOT/bare-head/b.git/HEAD"
check_repo_paths 'HEAD symlink' "$TMPROOT/bare-head" kept:not-pushed kept:not-pushed
bare_fixture "$TMPROOT/bare-objects/b.git"
mv "$TMPROOT/bare-objects/b.git/objects" "$TMPROOT/bare-objects/b.git/objects.real" \
    && ln -s objects.real "$TMPROOT/bare-objects/b.git/objects"
check_repo_paths 'objects symlink' "$TMPROOT/bare-objects" kept:not-pushed kept:not-pushed
bare_fixture "$TMPROOT/bare-refs/b.git"
mv "$TMPROOT/bare-refs/b.git/refs" "$TMPROOT/bare-refs/b.git/refs.real" \
    && ln -s refs.real "$TMPROOT/bare-refs/b.git/refs"
check_repo_paths 'refs symlink' "$TMPROOT/bare-refs" kept:not-pushed kept:not-pushed
# Outside/broken targets are unsupported repo-looking shapes: the inventory
# path fails closed (legacy is only asserted safe, not equal).
for variant in head-out objects-out refs-out head-broken refs-broken; do
    cand="$TMPROOT/bare-$variant"
    bare_fixture "$cand/b.git"
    case "$variant" in
        head-out) rm "$cand/b.git/HEAD" && ln -s /etc/hosts "$cand/b.git/HEAD" ;;
        objects-out) mv "$cand/b.git/objects" "$cand/b.git/objects.real" && ln -s /etc "$cand/b.git/objects" ;;
        refs-out) mv "$cand/b.git/refs" "$cand/b.git/refs.real" && ln -s /etc "$cand/b.git/refs" ;;
        head-broken) rm "$cand/b.git/HEAD" && ln -s no/such/file "$cand/b.git/HEAD" ;;
        refs-broken) mv "$cand/b.git/refs" "$cand/b.git/refs.real" && ln -s no/such/dir "$cand/b.git/refs" ;;
    esac
    inv="$TMPROOT/inv-$variant.json"
    python3 "$probe" inventory "$cand" "$inv" >/dev/null
    check "$variant inventory fails closed" kept:gitdir-invalid "$(c14_repos_ok "$cand" "$inv")"
    legacy="$(c14_repos_ok "$cand")"
    check "$variant legacy path is safe" kept "${legacy%%:*}"
done
# F4: a bounded default lsof cap (lowered here so the test stays cheap) and an
# explicit caller deadline that is sooner than the cap.
slow_lsof="$TMPROOT/slow-lsof"
printf '#!/bin/sh\nsleep 3\nexit 1\n' > "$slow_lsof" && chmod +x "$slow_lsof"
check 'lsof past the default cap defers' deferred:tree-walk \
    "$(DISK_MAGICIAN_LSOF_BIN="$slow_lsof" DISK_MAGICIAN_LSOF_CAP=0.3 python3 "$probe" open-file "$TMPROOT")"
dl="$(python3 -c 'import time; print(time.monotonic()+0.2)')"
check 'explicit deadline bounds a slow lsof' deferred:tree-walk \
    "$(DISK_MAGICIAN_LSOF_BIN="$slow_lsof" DISK_MAGICIAN_LSOF_CAP=30 python3 "$probe" open-file "$TMPROOT" "$dl")"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

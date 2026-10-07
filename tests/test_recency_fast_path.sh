#!/usr/bin/env bash
# Fixture-only equivalence and fallback tests for the optional Python scan.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$REPO_ROOT/scripts/lib/worktree_recency.sh"

PASS=0
FAIL=0
SKIP=0
ok() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        ok "$3"
    else
        bad "$3 (expected '$2', got '$1')"
    fi
}

REAL_PYTHON="$(command -v python3)" || { echo 'python3 is required for these tests'; exit 1; }
REAL_BASH="$(command -v bash)"
REAL_FIND="$(command -v find)"
REAL_DATE="$(command -v date)"
export REAL_PYTHON REAL_FIND REAL_DATE
TMPROOT="$(mktemp -d)"
cleanup() {
    # Only the disposable fixtures created by this test are removed.
    chmod -R u+rwx "$TMPROOT"
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Both scans see precisely the same clock, including empty/error/future cases.
NOW=1800000000
OLD=$((NOW - 30 * 86400))
NEW=$((NOW - 2 * 86400))
export NOW
BASE_BIN="$TMPROOT/bin-base"
PYTHON_BIN="$TMPROOT/bin-python"
STUB_BIN="$TMPROOT/bin-stub"
mkdir -p "$BASE_BIN" "$PYTHON_BIN" "$STUB_BIN"
for tool in stat awk; do
    ln -s "$(command -v "$tool")" "$BASE_BIN/$tool"
done
printf '#!%s\n' "$REAL_BASH" > "$BASE_BIN/date"
cat >> "$BASE_BIN/date" <<'SH'
if [[ "$*" == '+%s' ]]; then
    printf '%s\n' "$NOW"
else
    exec "$REAL_DATE" "$@"
fi
SH
printf '#!%s\n' "$REAL_BASH" > "$BASE_BIN/find"
cat >> "$BASE_BIN/find" <<'SH'
printf 'find\n' >> "$RECENCY_FIND_MARKER"
exec "$REAL_FIND" "$@"
SH
printf '#!%s\n' "$REAL_BASH" > "$PYTHON_BIN/python3"
cat >> "$PYTHON_BIN/python3" <<'SH'
printf 'python\n' >> "$RECENCY_PYTHON_MARKER"
exec "$REAL_PYTHON" "$@"
SH
printf '#!%s\n' "$REAL_BASH" > "$STUB_BIN/python3"
cat >> "$STUB_BIN/python3" <<'SH'
printf 'python\n' >> "$RECENCY_PYTHON_MARKER"
printf '%s' "${STUB_OUTPUT:-}"
exit "${STUB_RC:-0}"
SH
chmod +x "$BASE_BIN/date" "$BASE_BIN/find" "$PYTHON_BIN/python3" "$STUB_BIN/python3"
RECENCY_FIND_MARKER="$TMPROOT/find-calls"
RECENCY_PYTHON_MARKER="$TMPROOT/python-calls"
export RECENCY_FIND_MARKER RECENCY_PYTHON_MARKER
PATH_WITH_PYTHON="$PYTHON_BIN:$BASE_BIN"
PATH_WITHOUT_PYTHON="$BASE_BIN"
PATH_WITH_STUB="$STUB_BIN:$BASE_BIN"

touch_at() {
    "$REAL_PYTHON" - "$1" "${@:2}" <<'PY'
import os
import sys
ns = int(sys.argv[1]) * 1000000000
for path in sys.argv[2:]:
    os.utime(path, ns=(ns, ns), follow_symlinks=False)
PY
}

# Test the actual fallback by hiding Python, rather than reimplementing it.
assert_parity() {
    local label="$1" wt="$2" fast legacy
    legacy="$(PATH="$PATH_WITHOUT_PYTHON" worktree_last_activity_epoch "$wt")"
    fast="$(PATH="$PATH_WITH_PYTHON" worktree_last_activity_epoch "$wt")"
    assert_eq "$fast" "$legacy" "A1: $label matches legacy"
    if [[ $# -ge 3 ]]; then
        assert_eq "$fast" "$3" "A1: $label expected epoch"
    fi
}

assert_no_python() {
    local label="$1" wt="$2"
    : > "$RECENCY_PYTHON_MARKER"
    PATH="$PATH_WITH_PYTHON" worktree_last_activity_epoch "$wt" >/dev/null
    if [[ -s "$RECENCY_PYTHON_MARKER" ]]; then
        bad "$label stays on the legacy path"
    else
        ok "$label stays on the legacy path"
    fi
}

echo '== A1: real Python versus Python hidden from PATH =='
if PATH="$PATH_WITHOUT_PYTHON" command -v python3 >/dev/null 2>&1; then
    bad 'legacy PATH hides python3'
else
    ok 'legacy PATH hides python3'
fi

WT="$TMPROOT/nested"
mkdir -p "$WT/src/deep/nested"
: > "$WT/old.txt"
: > "$WT/src/deep/nested/new.txt"
touch_at "$OLD" "$WT/old.txt"
touch_at "$NEW" "$WT/src/deep/nested/new.txt"
assert_parity 'nested directories' "$WT" "$NEW"
: > "$RECENCY_PYTHON_MARKER"
: > "$RECENCY_FIND_MARKER"
assert_eq "$(PATH="$PATH_WITH_PYTHON" worktree_last_activity_epoch "$WT")" "$NEW" 'eligible scan returns newest content'
if [[ -s "$RECENCY_PYTHON_MARKER" && ! -s "$RECENCY_FIND_MARKER" ]]; then
    ok 'eligible scan uses Python without invoking find'
else
    bad 'eligible scan uses Python without invoking find'
fi
assert_parity 'ordinary root with trailing slashes' "$WT///" "$NEW"

for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
    WT="$TMPROOT/prune-directory/$name/tree"
    mkdir -p "$WT/$name/deep"
    : > "$WT/old.txt"
    : > "$WT/$name/deep/recent.txt"
    touch_at "$OLD" "$WT/old.txt"
    touch_at "$NEW" "$WT/$name/deep/recent.txt"
    assert_parity "pruned child directory $name" "$WT" "$OLD"

    WT="$TMPROOT/prune-file/$name/tree"
    mkdir -p "$WT"
    : > "$WT/old.txt"
    : > "$WT/$name"
    touch_at "$OLD" "$WT/old.txt"
    touch_at "$NEW" "$WT/$name"
    assert_parity "pruned child file $name" "$WT" "$OLD"

    WT="$TMPROOT/prune-root/$name"
    mkdir -p "$WT"
    : > "$WT/old.txt"
    touch_at "$OLD" "$WT/old.txt"
    assert_parity "pruned root basename $name" "$WT" "$NOW"
    assert_no_python "pruned root basename $name" "$WT"
    # BSD and GNU find may differ for a trailing slash; preserve either result.
    assert_parity "pruned root basename $name with trailing slashes" "$WT///"
    assert_no_python "pruned root basename $name with trailing slashes" "$WT///"
done

ln -s "$TMPROOT/nested" "$TMPROOT/root-link"
assert_parity 'symlink root' "$TMPROOT/root-link"
assert_no_python 'symlink root' "$TMPROOT/root-link"
assert_parity 'symlink root with trailing slash' "$TMPROOT/root-link/"
WT="$TMPROOT/internal-links"
mkdir -p "$WT" "$TMPROOT/external"
: > "$WT/old.txt"
: > "$TMPROOT/external/recent.txt"
touch_at "$OLD" "$WT/old.txt"
touch_at "$NEW" "$TMPROOT/external/recent.txt"
ln -s "$TMPROOT/external/recent.txt" "$WT/linked-file"
ln -s "$TMPROOT/external" "$WT/linked-directory"
ln -s "$TMPROOT/missing" "$WT/dangling-link"
assert_parity 'internal symlinks never follow newer external content' "$WT" "$OLD"

WT="$TMPROOT/empty"
mkdir -p "$WT"
assert_parity 'empty tree' "$WT" "$NOW"
WT="$TMPROOT/only-pruned"
mkdir -p "$WT"
for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
    mkdir -p "$WT/$name"
    : > "$WT/$name/recent.txt"
done
assert_parity 'only pruned content' "$WT" "$NOW"
WT="$TMPROOT/future"
mkdir -p "$WT"
: > "$WT/future.txt"
touch_at "$((NOW + 86400))" "$WT/future.txt"
assert_parity 'future file' "$WT" "$NOW"
WT="$TMPROOT/only-fifo"
mkdir -p "$WT"
mkfifo "$WT/pipe"
assert_parity 'only FIFO' "$WT" "$NOW"
WT="$TMPROOT/only-git"
mkdir -p "$WT"
printf 'gitdir: somewhere\n' > "$WT/.git"
assert_parity 'only .git pointer file' "$WT" "$NOW"
assert_parity 'missing path' "$TMPROOT/missing" "$NOW"

if (( EUID == 0 )); then
    printf '  SKIP: permission fixtures require a non-root user\n'
    SKIP=$((SKIP + 7))
else
    WT="$TMPROOT/mode-000-file"
    mkdir -p "$WT"
    : > "$WT/unreadable.txt"
    touch_at "$OLD" "$WT/unreadable.txt"
    chmod 000 "$WT/unreadable.txt"
    assert_parity 'mode 000 regular file is stat-able' "$WT" "$OLD"

    WT="$TMPROOT/empty-unsearchable"
    mkdir -p "$WT/empty"
    : > "$WT/old.txt"
    touch_at "$OLD" "$WT/old.txt"
    chmod 0644 "$WT/empty"
    # Do not assert now here: an empty unsearchable directory can be walked
    # successfully, including by BSD find, leaving the old sibling as newest.
    assert_parity 'empty mode 0644 subdirectory beside an old file' "$WT"

    WT="$TMPROOT/symlink-unsearchable"
    mkdir -p "$WT/locked"
    ln -s "$TMPROOT/external/recent.txt" "$WT/locked/link"
    chmod 0644 "$WT/locked"
    assert_parity 'mode 0644 subdirectory containing only a symlink' "$WT"

    # Additional, explicitly non-equivalent GNU-find case. Some find versions
    # use dirent type information to skip the inaccessible symlink without
    # lstat, retaining the readable sibling's old epoch. The mandated Python
    # lstat raises OSError and therefore protects the tree with now. Keep this
    # limitation reproducible; it is not an exact-equivalence assertion.
    WT="$TMPROOT/symlink-unsearchable-old-sibling"
    mkdir -p "$WT/locked"
    : > "$WT/old.txt"
    touch_at "$OLD" "$WT/old.txt"
    ln -s "$TMPROOT/external/recent.txt" "$WT/locked/link"
    chmod 0644 "$WT/locked"
    LIMIT_LEGACY="$(PATH="$PATH_WITHOUT_PYTHON" worktree_last_activity_epoch "$WT")"
    LIMIT_FAST="$(PATH="$PATH_WITH_PYTHON" worktree_last_activity_epoch "$WT")"
    assert_eq "$LIMIT_FAST" "$NOW" 'extra permission fixture: mandatory lstat fails closed'
    if [[ "$LIMIT_LEGACY" == "$OLD" || "$LIMIT_LEGACY" == "$NOW" ]]; then
        ok 'extra permission fixture: legacy platform outcome is old or now'
    else
        bad "extra permission fixture: unexpected legacy epoch '$LIMIT_LEGACY'"
    fi
    printf '  NOTE: additional permission fixture: Python=%s legacy=%s (exact equivalence is not claimed)\n' "$LIMIT_FAST" "$LIMIT_LEGACY"

    WT="$TMPROOT/fifo-unsearchable"
    mkdir -p "$WT/locked"
    mkfifo "$WT/locked/pipe"
    chmod 0644 "$WT/locked"
    assert_parity 'mode 0644 subdirectory containing only a FIFO' "$WT"

    WT="$TMPROOT/git-unsearchable"
    mkdir -p "$WT/locked"
    printf 'gitdir: somewhere\n' > "$WT/locked/.git"
    chmod 0644 "$WT/locked"
    assert_parity 'mode 0644 subdirectory containing only a .git entry' "$WT"

    WT="$TMPROOT/execute-only"
    mkdir -p "$WT/locked"
    : > "$WT/old.txt"
    : > "$WT/locked/recent.txt"
    touch_at "$OLD" "$WT/old.txt"
    touch_at "$NEW" "$WT/locked/recent.txt"
    chmod 0111 "$WT/locked"
    assert_parity 'execute-only subdirectory' "$WT"
fi

# Relative roots retain all of find's existing path parsing semantics.
SAVED_PWD="$PWD"
cd "$TMPROOT" || exit 1
assert_parity 'relative root' nested "$NEW"
assert_no_python 'relative root' nested
cd "$SAVED_PWD" || exit 1

echo '== A2/A3: helper status and output contract =='
WT="$TMPROOT/stub-target"
mkdir -p "$WT"
: > "$WT/old.txt"
touch_at "$OLD" "$WT/old.txt"
LEGACY="$(PATH="$PATH_WITHOUT_PYTHON" worktree_last_activity_epoch "$WT")"
assert_eq "$LEGACY" "$OLD" 'stub target has measurable old content'

assert_stub() {
    local status="$1" output="$2" expected="$3" fallback="$4" label="$5" actual
    : > "$RECENCY_FIND_MARKER"
    : > "$RECENCY_PYTHON_MARKER"
    actual="$(STUB_RC="$status" STUB_OUTPUT="$output" PATH="$PATH_WITH_STUB" worktree_last_activity_epoch "$WT")"
    assert_eq "$actual" "$expected" "$label epoch"
    if [[ ! -s "$RECENCY_PYTHON_MARKER" ]]; then
        bad "$label invokes helper"
    elif [[ "$fallback" == yes && -s "$RECENCY_FIND_MARKER" ]] || \
         [[ "$fallback" == no && ! -s "$RECENCY_FIND_MARKER" ]]; then
        ok "$label uses required fallback policy"
    else
        bad "$label uses required fallback policy"
    fi
}

for status in 1 2 127 12; do
    assert_stub "$status" "$NEW" "$LEGACY" yes "A2: helper exit $status"
done
for output in garbage '' 0 -1 001 1.5 '123 456' $'123\n456'; do
    assert_stub 0 "$output" "$LEGACY" yes "A2: malformed helper output '$output'"
done
assert_stub 0 "$NEW" "$NEW" no 'valid helper success'
assert_stub 0 "$((NOW + 86400))" "$NOW" no 'future helper success clamps to now'
for status in 10 11; do
    assert_stub "$status" '' "$NOW" no "A3: helper exit $status fails closed"
    assert_stub "$status" "$NEW" "$NOW" no "A3: helper exit $status ignores partial output"
done

echo
printf '=== %s passed, %s failed, %s skipped ===\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]

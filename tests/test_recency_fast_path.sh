#!/usr/bin/env bash
# Fixture-only safety, fallback, routing, and cleanup integration tests for the
# threshold predicate. No real worktrees or user data are scanned or removed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$LIB"
PASS=0 FAIL=0 SKIP=0 OPPOSITE=0
ok() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3";
    else bad "$3 (expected '$2', got '$1')"; fi
}
REAL_BASH="$(command -v bash)"
REAL_FIND="$(command -v find)"
REAL_STAT="$(command -v stat)"
REAL_TOUCH="$(command -v touch)"
REAL_MKTEMP="$(command -v mktemp)"
REAL_GETCONF="$(command -v getconf)"
REAL_PYTHON="$(command -v python3)" || { echo 'python3 is required to construct fixtures'; exit 1; }
export REAL_FIND REAL_STAT REAL_TOUCH REAL_MKTEMP REAL_GETCONF
# Resolve /tmp to /private/tmp on macOS before constructing any long paths.
TMPROOT="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
cleanup() {
    # This is solely disposable fixture teardown, never operational cleanup.
    chmod -R u+rwx "$TMPROOT" 2>/dev/null || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT
NOW=1800000000
OLD=$((NOW - 30 * 86400))
NEW=$((NOW - 2 * 86400))
export NOW
BASE_BIN="$TMPROOT/bin"
mkdir -p "$BASE_BIN" "$TMPROOT/references"
RECENCY_FIND_MARKER="$TMPROOT/find-calls"
RECENCY_REF_MARKER="$TMPROOT/reference-dirs"
RECENCY_LEAK_MARKER="$TMPROOT/fallback-before-cleanup"
RECENCY_PROBE_MARKER="$TMPROOT/cutoff-probes"
RECENCY_DATE_MARKER="$TMPROOT/date-calls"
export RECENCY_FIND_MARKER RECENCY_REF_MARKER RECENCY_LEAK_MARKER RECENCY_PROBE_MARKER RECENCY_DATE_MARKER
BASE_PATH="$BASE_BIN:$PATH"
export TMPDIR="$TMPROOT/references"

write_stub() { printf '#!%s\n' "$REAL_BASH" > "$BASE_BIN/$1"; cat >> "$BASE_BIN/$1"; chmod +x "$BASE_BIN/$1"; }
write_stub date <<'STUB'
printf '%s\n' "$*" >> "$RECENCY_DATE_MARKER"
if [[ "$#" == 1 && "$1" == '+%s' ]]; then printf '%s\n' "$NOW"; exit 0; fi
if [[ "${FAIL_TOOL:-}" == date ]]; then exit 1; fi
if [[ "${FAIL_TOOL:-}" == date-stamp && "$*" == *%Y%m%d%H%M.%S* ]]; then exit 1; fi
if [[ "${FAIL_TOOL:-}" == date-epoch && "$*" == *%Y%m%d%H%M.%S* && ( "${2:-}" == 1 || "${2:-}" == @1 ) ]]; then exit 1; fi
# The clock stub must not emulate another platform's date semantics.
exec /bin/date "$@"
STUB
write_stub mktemp <<'STUB'
[[ "${FAIL_TOOL:-}" == mktemp ]] && exit 1
out="$("$REAL_MKTEMP" "$@")" || exit $?
[[ -d "$out" ]] && printf '%s\n' "$out" >> "$RECENCY_REF_MARKER"
printf '%s\n' "$out"
STUB
write_stub touch <<'STUB'
[[ "${FAIL_TOOL:-}" == touch ]] && exit 1
[[ "${FAIL_TOOL:-}" == touch-epoch && "${2:-}" == 197001010000.01 ]] && exit 1
if [[ "${FAIL_TOOL:-}" == touch-wrong ]]; then
    # A successful touch with an incorrect mtime must still trigger fallback.
    target="${!#}"
    TZ=UTC0 "$REAL_TOUCH" -t 200001010000.00 "$target"
    exit $?
fi
exec "$REAL_TOUCH" "$@"
STUB
write_stub stat <<'STUB'
if [[ "${FAIL_TOOL:-}" == stat || "${FAIL_TOOL:-}" == stat-wrong || "${FAIL_TOOL:-}" == stat-epoch ]]; then
    # Fail reference readback only; preserve the actual legacy scanner.
    target="${!#}"
    while IFS= read -r dir; do
        if [[ "$target" == "$dir/"* ]]; then
            [[ "${FAIL_TOOL:-}" == stat-wrong ]] && { printf '2\n'; exit 0; }
            if [[ "${FAIL_TOOL:-}" == stat-epoch ]]; then
                value="$("$REAL_STAT" "$@")" || exit $?
                [[ "$value" == 1 ]] && exit 1
                printf '%s\n' "$value"; exit 0
            fi
            exit 1
        fi
    done < "$RECENCY_REF_MARKER"
fi
exec "$REAL_STAT" "$@"
STUB
write_stub getconf <<'STUB'
[[ "${FAIL_TOOL:-}" == getconf ]] && exit 1
if [[ "${PATH_MAX_SET:-}" == 1 || -n "${PATH_MAX_OVERRIDE:-}" ]] && [[ "${1:-}" == PATH_MAX ]]; then printf '%s\n' "${PATH_MAX_OVERRIDE:-}"; exit 0; fi
exec "$REAL_GETCONF" "$@"
STUB
write_stub find <<'STUB'
kind=legacy ref='' prev='' has_newer=0 has_path=0
for arg in "$@"; do
    [[ "$prev" == -newer ]] && ref="$arg"
    [[ "$arg" == -newer ]] && has_newer=1
    [[ "$arg" == -path ]] && has_path=1
    prev="$arg"
done
# The final traversal combines -newer and -path; record it as -newer (it is a
# fast-path probe) and keep both flags for the failure/mutation switches below.
(( has_path )) && kind=-path
(( has_newer )) && kind=-newer
printf '%s\t%s\t%s\n' "$kind" "$1" "${LC_ALL:-}" >> "$RECENCY_FIND_MARKER"
if [[ "$kind" == legacy ]]; then
    while IFS= read -r dir; do
        [[ -d "$dir" ]] && printf '%s\n' "$dir" >> "$RECENCY_LEAK_MARKER"
    done < "$RECENCY_REF_MARKER"
fi
if [[ "${FAIL_TOOL:-}" == find ]] && (( has_newer )); then exit 1; fi
if [[ "${FAIL_TOOL:-}" == find-path ]] && (( has_path )); then exit 1; fi
if (( has_newer )) && [[ ( "${MUTATE_PROBES:-}" == 1 || "${FAIL_TOOL:-}" == find-any ||
    "${FAIL_TOOL:-}" == find-final || "${FAIL_TOOL:-}" == reference-collision ) ]]; then
    # Identify cutoff probes by mtime; the epoch-1 probe is independent.
    epoch="$("$REAL_STAT" -f %m "$ref" 2>/dev/null)" || epoch="$("$REAL_STAT" -c %Y "$ref")"
    if [[ "$epoch" == 1 ]]; then
        [[ "${FAIL_TOOL:-}" == find-any ]] && exit 1
        if [[ "${FAIL_TOOL:-}" == reference-collision ]]; then printf '%s\n' "$ref"; exit 0; fi
    else
        count=0
        [[ -s "$RECENCY_PROBE_MARKER" ]] && read -r count < "$RECENCY_PROBE_MARKER"
        count=$((count + 1)); printf '%s\n' "$count" > "$RECENCY_PROBE_MARKER"
        if [[ "${MUTATE_PROBES:-}" == 1 ]]; then
            # A file changed after the any-file probe: the final traversal sees it.
            printf '%s\n' "$1/changed-after-any-file-probe.txt"
            exit 0
        fi
        [[ "${FAIL_TOOL:-}" == find-final && "$count" == 1 ]] && exit 1
    fi
fi
exec "$REAL_FIND" "$@"
STUB

reset_logs() {
    : > "$RECENCY_FIND_MARKER"; : > "$RECENCY_REF_MARKER"
    : > "$RECENCY_LEAK_MARKER"; : > "$RECENCY_DATE_MARKER"
    : > "$RECENCY_PROBE_MARKER"
}
reset_logs
# Only fixture construction uses Python; the production scan is exercised
# through its shell API, with exactly the date stub specified in A1'.
touch_at() {
    "$REAL_PYTHON" - "$1" "${@:2}" <<'PY'
import os, sys
ns = int(sys.argv[1]) * 1000000000
for path in sys.argv[2:]:
    os.utime(path, ns=(ns, ns), follow_symlinks=False)
PY
}
legacy_rc() (
    # Keep arithmetic, including invalid-N behavior, identical to legacy.
    local age min_days="${2:-7}"
    age="$(PATH="$BASE_PATH" worktree_age_days "$1")"
    (( age < min_days ))
)
predicate_rc() (
    # Fresh source prevents cached flavour detection from masking stub failures.
    source "$LIB"
    PATH="$BASE_PATH" worktree_is_recently_active "$@"
)
get_legacy_rc() { if legacy_rc "$@" >/dev/null 2>&1; then LEGACY=0; else LEGACY=$?; fi; }
get_predicate_rc() { if predicate_rc "$@" >/dev/null 2>&1; then ACTUAL=0; else ACTUAL=$?; fi; }
assert_clean_refs() {
    local label="$1" dir leaked=false
    while IFS= read -r dir; do [[ -d "$dir" ]] && leaked=true; done < "$RECENCY_REF_MARKER"
    [[ -s "$RECENCY_LEAK_MARKER" ]] && leaked=true
    if [[ "$leaked" == false ]]; then ok "$label removes references before returning/fallback";
    else bad "$label leaked references or ran fallback before removing them"; fi
}
assert_route() {
    local label="$1" expected="$2" wt="$3"
    if [[ "$expected" == fast ]]; then
        if grep -q '^-newer' "$RECENCY_FIND_MARKER"; then ok "A6': $label uses -newer";
        else bad "A6': $label did not use -newer"; fi
        # Every call must retain the caller's unstripped worktree string.
        if awk -F '\t' -v root="$wt" '$2 != root { bad=1 } END { exit bad }' "$RECENCY_FIND_MARKER"; then
            ok "A6': $label preserves find's input path byte-for-byte"
        else bad "A6': $label changed find's input path"; fi
    elif grep -q '^-newer' "$RECENCY_FIND_MARKER"; then bad "A6': $label unexpectedly uses -newer";
    else ok "A6': $label stays on existing definition"; fi
}
assert_fixture() {
    local label="$1" wt="$2" route="$3" n
    for n in 0 1 3 7 14; do
        get_legacy_rc "$wt" "$n"
        reset_logs
        get_predicate_rc "$wt" "$n"
        if [[ "$ACTUAL" != 0 && "$ACTUAL" != 1 ]]; then
            bad "A1': $label N=$n has invalid status $ACTUAL"
        elif [[ "$ACTUAL" == 1 && "$LEGACY" == 0 ]]; then
            bad "A1': UNSAFE $label N=$n: predicate=old legacy=active"
        else
            ok "A1': $label N=$n never changes legacy-active to old"
            if [[ "$ACTUAL" == 0 && "$LEGACY" == 1 ]]; then
                OPPOSITE=$((OPPOSITE + 1))
                printf '  NOTE: conservative difference: %s N=%s predicate=active legacy=old\n' "$label" "$n"
            fi
        fi
        assert_route "$label N=$n" "$route" "$wt"
        assert_clean_refs "A1': $label N=$n"
    done
}

echo "== A1'/A6': all original fixtures, floors 0/1/3/7/14, and call routing =="
WT="$TMPROOT/nested"
mkdir -p "$WT/src/deep/nested"
: > "$WT/old.txt"; : > "$WT/src/deep/nested/new.txt"
touch_at "$OLD" "$WT/old.txt"; touch_at "$NEW" "$WT/src/deep/nested/new.txt"
assert_fixture 'nested directories' "$WT" fast
assert_fixture 'ordinary root with trailing slashes' "$WT///" fast
for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do
    WT="$TMPROOT/prune-directory/$name/tree"
    mkdir -p "$WT/$name/deep"; : > "$WT/old.txt"; : > "$WT/$name/deep/recent.txt"
    touch_at "$OLD" "$WT/old.txt"; touch_at "$NEW" "$WT/$name/deep/recent.txt"
    assert_fixture "pruned child directory $name" "$WT" fast
    WT="$TMPROOT/prune-file/$name/tree"
    mkdir -p "$WT"; : > "$WT/old.txt"; : > "$WT/$name"
    touch_at "$OLD" "$WT/old.txt"; touch_at "$NEW" "$WT/$name"
    assert_fixture "pruned child file $name" "$WT" fast
    WT="$TMPROOT/prune-root/$name"
    mkdir -p "$WT"; : > "$WT/old.txt"; touch_at "$OLD" "$WT/old.txt"
    assert_fixture "pruned root basename $name" "$WT" legacy
    assert_fixture "pruned root basename $name with trailing slashes" "$WT///" legacy
done
ln -s "$TMPROOT/nested" "$TMPROOT/root-link"
assert_fixture 'symlink root' "$TMPROOT/root-link" legacy
assert_fixture 'symlink root with trailing slash' "$TMPROOT/root-link/" legacy
WT="$TMPROOT/internal-links"
mkdir -p "$WT" "$TMPROOT/external"; : > "$WT/old.txt"; : > "$TMPROOT/external/recent.txt"
touch_at "$OLD" "$WT/old.txt"; touch_at "$NEW" "$TMPROOT/external/recent.txt"
ln -s "$TMPROOT/external/recent.txt" "$WT/linked-file"
ln -s "$TMPROOT/external" "$WT/linked-directory"; ln -s "$TMPROOT/missing" "$WT/dangling-link"
assert_fixture 'internal symlinks never follow external content' "$WT" fast
mkdir -p "$TMPROOT/empty"; assert_fixture 'empty tree' "$TMPROOT/empty" fast
WT="$TMPROOT/only-pruned"; mkdir -p "$WT"
for name in "${_WT_RECENCY_PRUNE_NAMES[@]}"; do mkdir -p "$WT/$name"; : > "$WT/$name/recent.txt"; done
assert_fixture 'only pruned content' "$WT" fast
WT="$TMPROOT/future"; mkdir -p "$WT"; : > "$WT/future.txt"; touch_at "$((NOW + 86400))" "$WT/future.txt"
assert_fixture 'future file' "$WT" fast
WT="$TMPROOT/only-fifo"; mkdir -p "$WT"; mkfifo "$WT/pipe"; assert_fixture 'only FIFO' "$WT" fast
WT="$TMPROOT/only-git"; mkdir -p "$WT"; printf 'gitdir: somewhere\n' > "$WT/.git"
assert_fixture 'only .git pointer file' "$WT" fast
assert_fixture 'missing path' "$TMPROOT/missing" legacy

if (( EUID == 0 )); then
    printf '  SKIP: seven permission fixtures require a non-root user\n'; SKIP=$((SKIP + 7))
else
    WT="$TMPROOT/mode-000-file"; mkdir -p "$WT"; : > "$WT/unreadable.txt"
    touch_at "$OLD" "$WT/unreadable.txt"; chmod 000 "$WT/unreadable.txt"
    assert_fixture 'mode 000 regular file is stat-able' "$WT" fast
    WT="$TMPROOT/empty-unsearchable"; mkdir -p "$WT/empty"; : > "$WT/old.txt"
    touch_at "$OLD" "$WT/old.txt"; chmod 0644 "$WT/empty"
    assert_fixture 'empty mode 0644 subdirectory beside old file' "$WT" fast
    WT="$TMPROOT/symlink-unsearchable"; mkdir -p "$WT/locked"
    ln -s "$TMPROOT/external/recent.txt" "$WT/locked/link"; chmod 0644 "$WT/locked"
    assert_fixture 'mode 0644 subdirectory containing only symlink' "$WT" fast
    WT="$TMPROOT/symlink-unsearchable-old-sibling"; mkdir -p "$WT/locked"; : > "$WT/old.txt"
    touch_at "$OLD" "$WT/old.txt"; ln -s "$TMPROOT/external/recent.txt" "$WT/locked/link"
    chmod 0644 "$WT/locked"
    assert_fixture 'mode 0644 symlink subdirectory with old sibling' "$WT" fast
    WT="$TMPROOT/fifo-unsearchable"; mkdir -p "$WT/locked"; mkfifo "$WT/locked/pipe"; chmod 0644 "$WT/locked"
    assert_fixture 'mode 0644 subdirectory containing only FIFO' "$WT" fast
    WT="$TMPROOT/git-unsearchable"; mkdir -p "$WT/locked"; printf 'gitdir: somewhere\n' > "$WT/locked/.git"; chmod 0644 "$WT/locked"
    assert_fixture 'mode 0644 subdirectory containing only .git entry' "$WT" fast
    WT="$TMPROOT/execute-only"; mkdir -p "$WT/locked"; : > "$WT/old.txt"; : > "$WT/locked/recent.txt"
    touch_at "$OLD" "$WT/old.txt"; touch_at "$NEW" "$WT/locked/recent.txt"; chmod 0111 "$WT/locked"
    assert_fixture 'execute-only subdirectory' "$WT" fast
fi
SAVED_PWD="$PWD"; cd "$TMPROOT" || exit 1
assert_fixture 'relative root' nested legacy
cd "$SAVED_PWD" || exit 1

# Each exact second boundary is checked at every requested floor, not only 7d.
echo "== A1': exact cutoff boundaries =="
for n in 0 1 3 7 14; do
    for delta in -1 0 1; do
        WT="$TMPROOT/boundary-$n-$delta"; mkdir -p "$WT"; : > "$WT/file"
        touch_at "$((NOW - n * 86400 + delta))" "$WT/file"
        get_legacy_rc "$WT" "$n"; reset_logs; get_predicate_rc "$WT" "$n"
        expected=1; (( delta == 1 )) && expected=0
        # With N=0 the legacy future-mtime clamp keeps age=0, so it is old;
        # the threshold predicate may conservatively protect a future file.
        legacy_expected="$expected"; (( n == 0 )) && legacy_expected=1
        assert_eq "$LEGACY" "$legacy_expected" "A1': cutoff $delta seconds N=$n legacy boundary"
        assert_eq "$ACTUAL" "$expected" "A1': cutoff $delta seconds N=$n predicate boundary"
        if [[ "$ACTUAL" == 0 && "$LEGACY" == 1 ]]; then
            OPPOSITE=$((OPPOSITE + 1))
            printf '  NOTE: conservative difference: boundary delta=%s N=%s predicate=active legacy=old\n' "$delta" "$n"
        fi
    done
done
# Fractional seconds are an accepted conservative direction (legacy truncates).
WT="$TMPROOT/fractional-boundary"; mkdir -p "$WT"; : > "$WT/file"
"$REAL_PYTHON" - "$WT/file" "$((NOW - 7 * 86400))" <<'PY'
import os, sys
ns = int(sys.argv[2]) * 10**9 + 500000000
os.utime(sys.argv[1], ns=(ns, ns))
PY
assert_fixture 'fractional cutoff mtime' "$WT" fast

echo "== A2': failing reference setup always uses the cleaned-up legacy path =="
WT="$TMPROOT/stub-target"; mkdir -p "$WT"; : > "$WT/old.txt"; touch_at "$OLD" "$WT/old.txt"
for tool in date date-stamp date-epoch touch touch-epoch stat stat-epoch stat-wrong mktemp touch-wrong; do
    get_legacy_rc "$WT" 7; reset_logs
    FAIL_TOOL="$tool" get_predicate_rc "$WT" 7
    assert_eq "$ACTUAL" "$LEGACY" "A2': $tool failure matches legacy"
    assert_route "A2' $tool" legacy "$WT"
    assert_clean_refs "A2': $tool"
done
# A failed traversal must protect even under an errexit-enabled caller.
reset_logs
if FAIL_TOOL=find PATH="$BASE_PATH" "$REAL_BASH" -ec 'source "$1"; worktree_is_recently_active "$2" 7; printf "survived\n"' _ "$LIB" "$WT" > "$TMPROOT/errexit.out" 2>&1; then
    assert_eq "$(cat "$TMPROOT/errexit.out")" survived "A2': failed find is active without errexit abort"
else bad "A2': failed find aborted errexit-enabled caller"; fi
for tool in find-any find-final find-path; do
    reset_logs; FAIL_TOOL="$tool" get_predicate_rc "$WT" 7
    assert_eq "$ACTUAL" 0 "A2': $tool failure protects old tree"
    assert_clean_refs "A2': $tool"
done
get_legacy_rc "$WT" 7
reset_logs; FAIL_TOOL=reference-collision get_predicate_rc "$WT" 7
assert_eq "$ACTUAL" "$LEGACY" "A2': reference-file hit uses existing definition"
if grep -q '^legacy' "$RECENCY_FIND_MARKER"; then ok "A2': reference collision invoked legacy find";
else bad "A2': reference collision did not invoke legacy find"; fi
assert_clean_refs "A2': reference collision"

echo "== A3': invalid/unsupported floors preserve legacy results =="
for n in -1 36501 abc '' 0007; do
    get_legacy_rc "$WT" "$n"; reset_logs; get_predicate_rc "$WT" "$n"
    assert_eq "$ACTUAL" "$LEGACY" "A3': floor '$n' matches legacy"
    assert_route "A3' floor '$n'" legacy "$WT"
done

# A numerically valid floor still falls back when cutoff is not above epoch 1.
for cutoff in 0 1; do
    reset_logs
    NOW="$((86400 + cutoff))" get_predicate_rc "$WT" 1
    assert_eq "$ACTUAL" 0 "A3': cutoff=$cutoff retains legacy active result"
    assert_route "A3' cutoff=$cutoff" legacy "$WT"
done

echo "== A4': exact epoch-zero and epoch-one timestamps =="
WT="$TMPROOT/epoch-zero-one"; mkdir -p "$WT"; : > "$WT/zero"; : > "$WT/one"
TZ=UTC0 "$REAL_TOUCH" -t 197001010000.00 "$WT/zero"
TZ=UTC0 "$REAL_TOUCH" -t 197001010000.01 "$WT/one"
get_legacy_rc "$WT" 7; reset_logs; get_predicate_rc "$WT" 7
assert_eq "$ACTUAL" 0 "A4': epoch-0/1-only predicate is active"
# Expected conservative difference: legacy counts epoch 1 as positive, while
# the predicate deliberately excludes it from the newer-than-epoch-1 probe.
assert_eq "$LEGACY" 1 "A4': epoch-0/1-only legacy is old (expected conservative difference)"
if [[ "$ACTUAL" == 0 && "$LEGACY" == 1 ]]; then
    OPPOSITE=$((OPPOSITE + 1))
    printf '  NOTE: conservative difference: epoch-0/1-only N=7 predicate=active legacy=old\n'
fi
printf '  NOTE: A4 legacy age=%s; legacy counts epoch 1 as positive\n' "$(PATH="$BASE_PATH" worktree_age_days "$WT")"

echo "== A5': reference containment, symlink ancestors, and dot-dot paths =="
WT="$TMPROOT/contained"; mkdir -p "$WT/.git/tmp"; : > "$WT/.git/content"
# macOS mktemp -d ignores TMPDIR, so there the references never land inside
# the tree and the fast path legitimately runs; only safety is asserted then.
probe_dir="$(TMPDIR="$WT/.git/tmp" mktemp -d 2>/dev/null)" || probe_dir=""
mktemp_honours_tmpdir=0
[[ "$probe_dir" == "$WT/.git/tmp/"* ]] && mktemp_honours_tmpdir=1
[[ -n "$probe_dir" ]] && rm -rf -- "$probe_dir"
(( mktemp_honours_tmpdir )) || printf '  NOTE: mktemp ignores TMPDIR on this platform; A6 route checks skipped for inside/symlink\n'
for mode in inside symlink dotdot; do
    path="$WT"; refdir="$WT/.git/tmp"
    if [[ "$mode" == symlink ]]; then ln -s "$refdir" "$TMPROOT/reference-link"; refdir="$TMPROOT/reference-link"; fi
    [[ "$mode" == dotdot ]] && path="$WT/.git/.."
    reset_logs; TMPDIR="$refdir" get_predicate_rc "$path" 7
    assert_eq "$ACTUAL" 0 "A5': $mode only-pruned tree is active"
    if [[ "$mode" == dotdot ]] || (( mktemp_honours_tmpdir )); then
        assert_route "A5' $mode" legacy "$path"
    fi
    assert_clean_refs "A5': $mode"
done
ln -s "$TMPROOT" "$TMPROOT/ancestor-link"
assert_fixture 'symlinked ancestor' "$TMPROOT/ancestor-link/only-pruned" legacy

# Construct long files using relative chdir steps. Passing one enormous path to
# mkdir/open would fail before the fixture existed (especially through /tmp on
# macOS). The resulting spelling starts from the physical TMPROOT above.
make_long_file() {
    "$REAL_PYTHON" - "$1" "$2" "$OLD" "$3" <<'PY'
import os, sys
root, threshold, epoch, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
os.chdir(root)
parts = []
component = 'u' * 180 if mode == 'ascii' else '\U0001f642' * 45
while len(os.fsencode(root + '/' + '/'.join(parts + ['untracked.txt']))) <= threshold:
    os.mkdir(component)
    os.chdir(component)
    parts.append(component)
with open('untracked.txt', 'w') as output:
    output.write('untracked fixture\n')
os.utime('untracked.txt', (epoch, epoch))
path = root + '/' + '/'.join(parts + ['untracked.txt'])
print(path)
print(len(os.fsencode(path)))
print(len(path))
PY
}
echo "== A7': native PATH_MAX traversal and real cleanup dry-run =="
LONG_REPO="$TMPROOT/long-repo"; mkdir -p "$LONG_REPO" "$TMPROOT/home"
git init -q -b main "$LONG_REPO"
git -C "$LONG_REPO" config user.email fixture@users.noreply.github.com
git -C "$LONG_REPO" config user.name Fixture
printf 'old tracked file\n' > "$LONG_REPO/README.md"
git -C "$LONG_REPO" add README.md; git -C "$LONG_REPO" commit -q -m fixture
LONG_WT="$LONG_REPO/.claude/worktrees/long-path"
SHORT_WT="$LONG_REPO/.claude/worktrees/ordinary-old"
git -C "$LONG_REPO" worktree add -q -b long-fixture "$LONG_WT"
git -C "$LONG_REPO" worktree add -q -b short-fixture "$SHORT_WT"
touch_at "$OLD" "$LONG_WT/README.md" "$SHORT_WT/README.md"
NATIVE_PATH_MAX="$($REAL_GETCONF PATH_MAX "$LONG_WT")"
make_long_file "$LONG_WT" "$NATIVE_PATH_MAX" ascii > "$TMPROOT/long-description"
LONG_BYTES="$(sed -n '2p' "$TMPROOT/long-description")"
if (( LONG_BYTES > NATIVE_PATH_MAX )); then ok "A7': real untracked path is $LONG_BYTES bytes, over native PATH_MAX=$NATIVE_PATH_MAX";
else bad "A7': long fixture did not cross PATH_MAX"; fi
get_legacy_rc "$LONG_WT" 7; assert_eq "$LEGACY" 0 "A7': native over-long legacy tree is active"
reset_logs; get_predicate_rc "$LONG_WT" 7; assert_eq "$ACTUAL" 0 "A7': native over-long predicate tree is active"
assert_route "A7' native long tree" fast "$LONG_WT"
reset_logs; get_predicate_rc "$SHORT_WT" 7; assert_eq "$ACTUAL" 1 "A7': ordinary old tree is old"
# All process/discovery context belongs to this isolated HOME; only the
# canonical cleanup implementation is invoked, explicitly with --dry-run.
write_stub lsof <<'STUB'
printf 'p1\nn/\n'
STUB
reset_logs
if env -i HOME="$TMPROOT/home" PATH="$BASE_PATH" TMPDIR="$TMPDIR" NOW="$NOW" \
    REAL_FIND="$REAL_FIND" REAL_STAT="$REAL_STAT" REAL_TOUCH="$REAL_TOUCH" REAL_MKTEMP="$REAL_MKTEMP" REAL_GETCONF="$REAL_GETCONF" \
    RECENCY_FIND_MARKER="$RECENCY_FIND_MARKER" RECENCY_REF_MARKER="$RECENCY_REF_MARKER" \
    RECENCY_LEAK_MARKER="$RECENCY_LEAK_MARKER" RECENCY_DATE_MARKER="$RECENCY_DATE_MARKER" RECENCY_PROBE_MARKER="$RECENCY_PROBE_MARKER" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 "$REAL_BASH" "$REPO_ROOT/scripts/cleanup_worktrees.sh" \
    --dry-run --repos "$LONG_REPO" --min-age 14 > "$TMPROOT/cleanup.out" 2>&1; then
    ok "A7': canonical cleanup dry-run exits successfully"
else bad "A7': canonical cleanup dry-run failed"; cat "$TMPROOT/cleanup.out"; fi
if grep -F "PRESERVE  $LONG_WT | young" "$TMPROOT/cleanup.out" >/dev/null; then ok "A7': cleanup protects over-long tree as young";
else bad "A7': cleanup did not protect over-long tree through recency"; cat "$TMPROOT/cleanup.out"; fi
if grep -F "ELIGIBLE  $SHORT_WT |" "$TMPROOT/cleanup.out" >/dev/null; then ok "A7': cleanup makes ordinary old tree eligible";
else bad "A7': cleanup did not classify ordinary old tree eligible"; cat "$TMPROOT/cleanup.out"; fi
[[ -f "$LONG_WT/README.md" && -f "$SHORT_WT/README.md" ]] && ok "A7': dry-run retains both fixture worktrees" || bad "A7': dry-run changed fixture worktrees"

echo "== A8': optional shared clock validation =="
WT="$TMPROOT/clock-boundary"; mkdir -p "$WT"; : > "$WT/file"
touch_at "$((NOW - 7 * 86400 + 1))" "$WT/file"
reset_logs; get_predicate_rc "$WT" 7 "$((NOW + 2))"
assert_eq "$ACTUAL" 0 "A8': future now argument is ignored"
touch_at "$((NOW - 7 * 86400 - 1))" "$WT/file"
reset_logs; get_predicate_rc "$WT" 7 "$((NOW - 301))"
assert_eq "$ACTUAL" 1 "A8': now more than 300 seconds earlier is ignored"
reset_logs; get_predicate_rc "$WT" 7 "$((NOW - 300))"
assert_eq "$ACTUAL" 0 "A8': valid shared clock exactly 300 seconds earlier is honored"
for invalid in 0 -1 abc 001 '' 99999999999999999999999999999999999999; do
    reset_logs; get_predicate_rc "$WT" 7 "$invalid"
    assert_eq "$ACTUAL" 1 "A8': malformed/out-of-range now '$invalid' is ignored"
done
# Force fallback through an unnormalized path; valid shared now still applies.
reset_logs; get_predicate_rc "$WT/../clock-boundary" 7 "$((NOW - 300))"
assert_eq "$ACTUAL" 0 "A8': fallback uses supplied shared clock instead of worktree_age_days"
assert_route "A8' unnormalized path" legacy "$WT/../clock-boundary"

echo "== A9': UTF-8 path guard measures bytes =="
WT="$TMPROOT/unicode-path"; mkdir -p "$WT"; : > "$WT/old.txt"; touch_at "$OLD" "$WT/old.txt"
make_long_file "$WT" 1024 unicode > "$TMPROOT/unicode-description"
UNICODE_BYTES="$(sed -n '2p' "$TMPROOT/unicode-description")"
UNICODE_CHARS="$(sed -n '3p' "$TMPROOT/unicode-description")"
if (( UNICODE_BYTES >= 1024 && UNICODE_CHARS < 1023 )); then ok "A9': UTF-8 path has $UNICODE_BYTES bytes and $UNICODE_CHARS characters";
else bad "A9': UTF-8 fixture missed byte/character bounds"; fi
# Linux reports 4096, so explicitly emulate the target Mac's 1024 limit for
# this byte-guard test; A7 above independently exercises the real native limit.
if [[ "$NATIVE_PATH_MAX" != 1024 ]]; then printf '  NOTE: A9 uses getconf=1024; host native PATH_MAX=%s\n' "$NATIVE_PATH_MAX"; fi
reset_logs; LANG=en_US.UTF-8 PATH_MAX_OVERRIDE=1024 get_predicate_rc "$WT" 7
assert_eq "$ACTUAL" 0 "A9': 1024-byte UTF-8 guard protects old tree"
if grep -F -- $'-path\t' "$RECENCY_FIND_MARKER" | grep -q $'\tC$'; then ok "A9': final find explicitly sets LC_ALL=C";
else bad "A9': final find did not force byte-oriented LC_ALL=C"; fi
for invalid_limit in '' not-numeric; do
    reset_logs; PATH_MAX_SET=1 PATH_MAX_OVERRIDE="$invalid_limit" get_predicate_rc "$WT" 7
    assert_eq "$ACTUAL" 0 "A9': invalid PATH_MAX '$invalid_limit' falls back to 1024 bytes"
done
reset_logs; FAIL_TOOL=getconf get_predicate_rc "$WT" 7
assert_eq "$ACTUAL" 0 "A9': failed getconf falls back to 1024 bytes"

echo "== A10': mutation after the any-file probe, before the final traversal =="
WT="$TMPROOT/mutation"; mkdir -p "$WT"; : > "$WT/old.txt"; touch_at "$OLD" "$WT/old.txt"
reset_logs; MUTATE_PROBES=1 get_predicate_rc "$WT" 7
assert_eq "$ACTUAL" 0 "A10': file changed before the final traversal protects tree"
assert_eq "$(cat "$RECENCY_PROBE_MARKER")" 1 "A10': exactly one cutoff traversal, after the any-file probe"
fast_calls="$(awk -F '\t' '$1 != "legacy" { printf "%s;", $1 }' "$RECENCY_FIND_MARKER")"
assert_eq "$fast_calls" "-newer;-newer;" "A10': any-file probe then one combined final traversal"
assert_clean_refs "A10': mutation"

echo
printf 'Conservative predicate-active/legacy-old differences: %s\n' "$OPPOSITE"
printf '=== %s passed, %s failed, %s skipped ===\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]

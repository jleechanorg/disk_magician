#!/usr/bin/env bash
# Regression contract: one age walk per classified row, du only for eligible rows.
# All cleanup, including --clean, is confined to this test's temporary fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SHA=b0b5b9e4c713a5e9b9674cae9d81f563c37a69b1
TMP_ROOT="$(cd "$(mktemp -d -t cleanup_wt_single_age.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwX "$TMP_ROOT"; rm -rf "$TMP_ROOT"' EXIT
unset WORKTREE_APPROVED
REAL_GIT="$(command -v git)"
REAL_DU="$(command -v du)"
PASS=0
FAIL=0

# Keep every sourced helper at the corresponding revision. In particular, never
# replace worktree_recency.sh with a stub that drops worktree_is_recently_active.
mkdir -p "$TMP_ROOT/baseline" "$TMP_ROOT/branch" "$TMP_ROOT/unstubbed"
git -C "$REPO_ROOT" archive "$BASE_SHA" scripts | tar -x -C "$TMP_ROOT/baseline"
cp -R "$REPO_ROOT/scripts" "$TMP_ROOT/branch/"
cp -R "$REPO_ROOT/scripts" "$TMP_ROOT/unstubbed/"
for tree in baseline branch; do
  cat >> "$TMP_ROOT/$tree/scripts/lib/worktree_recency.sh" <<'SH'

# Test-only override appended to the complete canonical library.
worktree_age_days() {
    printf '%s\n' "$1" >> "$AGE_COUNTER"
    local value rc
    value="$(awk -F '\t' -v p="$1" '$1 == p { print $2; found=1; exit } END { if (!found) exit 1 }' "$AGE_MAP")" || return 1
    rc="$(awk -F '\t' -v p="$1" '$1 == p { print $3; exit }' "$AGE_MAP")"
    [[ "$rc" == 0 ]] || return "$rc"
    printf '%s\n' "$value"
}
SH
done

require() { "$@" || { printf '    assertion failed: %s\n' "$*" >&2; return 1; }; }
contains() { grep -qF -- "$2" "$1"; }
excludes() { ! grep -qF -- "$2" "$1"; }
ledger_has() { grep -F -- " $2 " "$1" | grep -qF -- "$3"; }

# Each case runs in a subshell under errexit; the parent records all nine cases
# even if one fails. Do not invoke case bodies in an if/&& context: doing that
# would silently disable errexit inside their fixture cleanup subprocesses.
run_case() {
  local number="$1" title="$2" fn="$3" rc
  set +e
  ( set -euo pipefail; "$fn" ) > "$TMP_ROOT/$number.log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "  PASS $number: $title"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $number: $title"
    cat "$TMP_ROOT/$number.log"
    FAIL=$((FAIL + 1))
  fi
}

init_fixture() {
  F="$TMP_ROOT/$1"
  HOME_FIX="$F/home"
  REPO="$F/repo"
  WT="$REPO/.claude/worktrees"
  AG="$HOME_FIX/.gemini/antigravity/worktrees/project"
  BIN="$F/bin"
  mkdir -p "$WT" "$AG" "$BIN"
  : > "$F/ages.tsv"; : > "$F/calls.expected"; : > "$F/eligible.expected"
  printf 'n/\n' > "$F/lsof.out"
  "$REAL_GIT" init -q -b main "$REPO"
  "$REAL_GIT" -C "$REPO" config user.name 'Fixture User'
  "$REAL_GIT" -C "$REPO" config user.email fixture@users.noreply.github.com
  printf 'base\n' > "$REPO/README.md"
  "$REAL_GIT" -C "$REPO" add README.md
  "$REAL_GIT" -C "$REPO" commit -q -m base
  MERGED_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
  "$REAL_GIT" -C "$REPO" checkout -q -b unmerged
  printf 'ahead\n' >> "$REPO/README.md"
  "$REAL_GIT" -C "$REPO" commit -q -am ahead
  AHEAD_SHA="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
  "$REAL_GIT" -C "$REPO" checkout -q main
  "$REAL_GIT" -C "$REPO" remote add origin https://github.com/fixture/repo.git
  cat > "$BIN/lsof" <<'SH'
#!/usr/bin/env bash
cat "$FIXTURE/lsof.out"
SH
  cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/gh.calls"
case "$*" in *wt-squash*) printf '%s\n' "$AHEAD_SHA";; *) exit 1;; esac
SH
  # Like the existing merged-fastpath suite, keep the gh fixture independent
  # of whether timeout is installed in the sanitized platform PATH.
  cat > "$BIN/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$BIN/du" <<'SH'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == -sk ]] || exit 2
printf '%s\n' "$2" >> "$DU_COUNTER"
case "$DU_MODE" in
  fail) exit 1;;
  real) exec "$REAL_DU" "$@";;
  *) printf '1024\t%s\n' "$2";;
esac
SH
  cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
# Exercise the existing active-orphan short circuit verbatim: it currently
# uses grep -F with literal ^/$ delimiters. Only this dedicated probe gets
# that response; repo-local discovery and every other git operation are real.
if [[ "$*" == "-C $FIXTURE/active-main worktree list --porcelain" ]]; then
  printf '^worktree %s$\n' "$FIXTURE/home/.gemini/antigravity/worktrees/project/active"
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$BIN/"*
}

map_age() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-0}" >> "$F/ages.tsv"; }
expect_calls() { printf '%s\t%s\n' "$1" "$2" >> "$F/calls.expected"; }
add_wt() {
  local name="$1" path="$2" age="$3" head="${4:-$MERGED_SHA}" calls="${5:-1}"
  mkdir -p "$(dirname "$path")"
  "$REAL_GIT" -C "$REPO" worktree add -q -b "$name" "$path" "$head"
  map_age "$path" "$age"
  expect_calls "$path" "$calls"
}
add_orphan() {
  mkdir -p "$AG/$1"
  printf 'orphan content\n' > "$AG/$1/content"
  map_age "$AG/$1" "$2"
  expect_calls "$AG/$1" 1
}
expect_eligible() { printf '%s\n' "$1" >> "$F/eligible.expected"; }

run_cleanup() {
  local tree="$1" out="$2" mode="${3:-constant}" action="${4:---dry-run}"
  : > "$F/age.calls"; : > "$F/du.calls"
  local approval=''
  if [[ "$action" == --clean ]]; then
    # Guard before granting deletion authority: both HOME and repo are fixtures.
    [[ "$F" == "$TMP_ROOT/"* && "$REPO" == "$F/repo" && "$HOME_FIX" == "$F/home" ]]
    approval='WORKTREE_APPROVED=1'
  fi
  env -i HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 FIXTURE="$F" REAL_GIT="$REAL_GIT" REAL_DU="$REAL_DU" \
    AHEAD_SHA="$AHEAD_SHA" AGE_MAP="$F/ages.tsv" AGE_COUNTER="$F/age.calls" \
    DU_COUNTER="$F/du.calls" DU_MODE="$mode" ${approval:+"$approval"} \
    bash "$TMP_ROOT/$tree/scripts/cleanup_worktrees.sh" "$action" --repos "$REPO" > "$out" 2>&1
}

mixed_fixture() {
  init_fixture "$1"
  add_wt wt-young "$WT/wt-young" 2
  add_wt wt-merged4 "$WT/wt-merged4" 4
  expect_eligible "$WT/wt-merged4"
  add_wt wt-old "$WT/wt spaced old" 10
  expect_eligible "$WT/wt spaced old"
  add_wt wt-dirty "$WT/wt-dirty" 10
  printf 'dirty\n' >> "$WT/wt-dirty/README.md"
  add_wt wt-ahead "$WT/wt-ahead" 10 "$AHEAD_SHA"
  add_wt wt-squash "$WT/wt-squash" 10 "$AHEAD_SHA"
  expect_eligible "$WT/wt-squash"
  add_wt wt-locked "$WT/wt-locked" 10
  "$REAL_GIT" -C "$REPO" worktree lock "$WT/wt-locked"
  AUTO="$F/ao/data/worktrees/wt-auto"
  add_wt wt-auto "$AUTO" 10
  "$REAL_GIT" -C "$REPO" worktree lock "$AUTO"
  expect_eligible "$AUTO"
  add_wt wt-prunable "$WT/wt-prunable" 10
  # Preserve the fixture's data while making its registered path prunable.
  mv "$WT/wt-prunable" "$F/prunable-saved"
  add_wt wt-live "$WT/wt-live" 10
  printf 'n%s\n' "$WT/wt-live" >> "$F/lsof.out"
  STD_SKIP="$HOME_FIX/.worktrees/ao-owned/wt-skip"
  add_wt wt-skip "$STD_SKIP" 10 "$MERGED_SHA" 0
  mkdir -p "$HOME_FIX/.hermes"
  printf 'projects:\n  fixture:\n    worktreeDir: %s\n' "${STD_SKIP%/*}" > "$HOME_FIX/.hermes/agent-orchestrator.yaml"
  add_orphan young 2
  add_orphan old 10
  expect_eligible "$AG/old"
}

case_t1() {
  mixed_fixture t1
  mkdir -p "$F/active-main/.git" "$AG/active" "$F/symlink-target" "$AG/outside-root"
  printf 'gitdir: %s/.git/worktrees/active\n' "$F/active-main" > "$AG/active/.git"
  expect_calls "$AG/active" 0
  ln -s "$F/symlink-target" "$AG/symlink-candidate"
  expect_calls "$AG/symlink-candidate" 0
  ln -s "$F/symlink-target" "${AG%/*}/symlink-parent"
  expect_calls "${AG%/*}/symlink-parent" 0
  # Non-searchable fixture directory causes the existing canonical-path check
  # to emit outside-root. No production path or permission is touched.
  chmod 000 "$AG/outside-root"
  expect_calls "$AG/outside-root" 0
  run_cleanup branch "$F/out"
  chmod 700 "$AG/outside-root"
  require contains "$F/out" "$AG/active | active"
  require contains "$F/out" "$STD_SKIP | ao-owned"
  require contains "$F/out" "$AG/symlink-candidate | symlink-candidate"
  require contains "$F/out" "${AG%/*}/symlink-parent | symlink-parent"
  require contains "$F/out" "$AG/outside-root | outside-root"
  python3 - "$F/calls.expected" "$F/age.calls" <<'PY'
import collections, sys
expected = {}
for line in open(sys.argv[1]):
    path, count = line.rstrip('\n').split('\t')
    assert path not in expected, path
    expected[path] = int(count)
actual = collections.Counter(line.rstrip('\n') for line in open(sys.argv[2]))
assert not (set(actual) - set(expected)), (actual, expected)
assert {p: actual[p] for p in expected} == expected, (actual, expected)
PY
}

case_t2() {
  mixed_fixture t2
  run_cleanup branch "$F/out"
  LC_ALL=C sort "$F/eligible.expected" > "$F/expected.sorted"
  LC_ALL=C sort "$F/du.calls" > "$F/actual.sorted"
  require diff -u "$F/expected.sorted" "$F/actual.sorted"
  # Standard-root early skips intentionally have no age/size suffix.
  require awk '/LEDGER repo-local +PRESERVE/ && / \| age=/ { n++; if ($0 !~ / size=- /) exit 1 } END { if (!n) exit 1 }' "$F/out"
  require awk '/LEDGER repo-local +ELIGIBLE/ { n++; if ($0 !~ / size=1M /) exit 1 } END { if (!n) exit 1 }' "$F/out"
}

case_t3() {
  init_fixture t3
  add_wt wt-sized "$WT/wt-sized" 10
  dd if=/dev/zero of="$WT/wt-sized/known-2MiB.bin" bs=1048576 count=2 2>/dev/null
  require test "$(wc -c < "$WT/wt-sized/known-2MiB.bin" | tr -d ' ')" = 2097152
  "$REAL_GIT" -C "$WT/wt-sized" add known-2MiB.bin
  "$REAL_GIT" -C "$WT/wt-sized" commit -q -m 'known size'
  "$REAL_GIT" -C "$REPO" merge -q --ff-only wt-sized
  local kb fmt gb
  kb="$("$REAL_DU" -sk "$WT/wt-sized" | awk '{print $1}')"
  fmt="$(awk -v k="$kb" 'BEGIN { if(k >= 1048576) printf "%.1fG",k/1048576; else if(k >= 1024) printf "%.0fM",k/1024; else printf "%dK",k }')"
  gb="$(awk -v k="$kb" 'BEGIN { printf "%.2f", k/1048576 }')"
  run_cleanup branch "$F/out" real
  require ledger_has "$F/out" ELIGIBLE "$WT/wt-sized | age=10d size=$fmt "
  require contains "$F/out" "Reclaimable: ~$gb GB ($kb KB)"
  require test "$(cat "$F/du.calls")" = "$WT/wt-sized"
}

case_t4() {
  init_fixture t4
  local name value rc
  for name in question dash empty leading-zero failed; do
    case "$name" in question) value='?';; dash) value=-;; empty|failed) value='';; leading-zero) value=08;; esac
    rc=0; [[ "$name" != failed ]] || rc=1
    add_wt "wt-$name" "$WT/wt-$name" "$value"
    # Replace this path's one map row to include the required failing exit.
    if [[ "$rc" == 1 ]]; then
      sed '$d' "$F/ages.tsv" > "$F/ages.new"; mv "$F/ages.new" "$F/ages.tsv"
      map_age "$WT/wt-$name" '' 1
    fi
    mkdir -p "$AG/$name"
    map_age "$AG/$name" "$value" "$rc"
  done
  run_cleanup branch "$F/out"
  for name in question dash empty leading-zero failed; do
    require ledger_has "$F/out" PRESERVE "$WT/wt-$name | age-unknown | age=?d size=- "
    require ledger_has "$F/out" PRESERVE "$AG/$name | young (age=?d < 7d)"
  done
  require excludes "$F/out" ELIGIBLE
  require test ! -s "$F/du.calls"
}

case_t5() {
  init_fixture t5
  mkdir -p "$AG/empty"
  run_cleanup unstubbed "$F/out"
  require ledger_has "$F/out" PRESERVE "$AG/empty | young (age=0d < 7d)"
  require excludes "$F/out" ELIGIBLE
}

case_t6() {
  init_fixture t6
  add_orphan exact-floor 7
  run_cleanup branch "$F/out"
  require ledger_has "$F/out" ELIGIBLE "$AG/exact-floor "
  require excludes "$F/out" "$AG/exact-floor | young"
  require test "$(cat "$F/age.calls")" = "$AG/exact-floor"
}

case_t7() {
  mixed_fixture t7
  run_cleanup baseline "$F/baseline.out"
  run_cleanup branch "$F/branch.out"
  python3 - "$F/baseline.out" "$F/branch.out" <<'PY_NORMALIZE'
import re
import sys
from pathlib import Path

for filename in sys.argv[1:]:
    path = Path(filename)
    with path.open() as source, path.with_suffix('.normalized').open('w') as target:
        for line in source:
            line = re.sub(r' [|] age=\S+d size=\S+', '', line)
            line = re.sub(r' [(]age=[^)]*[)]', '', line)
            target.write(line)
PY_NORMALIZE
  require diff -u "$F/baseline.normalized" "$F/branch.normalized"
  require contains "$F/branch.out" 'Repo-local:  4 eligible, 7 preserved.'
  require contains "$F/branch.out" 'Antigravity: 1 eligible orphan(s), 1 active preserved.'
  require contains "$F/branch.out" 'Reclaimable: ~0.00 GB (5120 KB)'
  require contains "$F/gh.calls" '--head wt-ahead'
  require contains "$F/gh.calls" '--head wt-squash'
  require contains "$F/branch.out" 'wt-prunable | prunable-unknown'
}

case_t8() {
  init_fixture t8-eligible
  add_wt wt-eligible "$WT/wt-eligible" 10
  local tree rc
  for tree in baseline branch; do
    set +e
    run_cleanup "$tree" "$F/$tree.out" fail
    rc=$?
    set -e
    require test "$rc" -ne 0
    require excludes "$F/$tree.out" ELIGIBLE
    require test -d "$WT/wt-eligible"
    require test "$(cat "$F/du.calls")" = "$WT/wt-eligible"
  done
  init_fixture t8-preserve
  add_wt wt-preserve "$WT/wt-preserve" 2
  run_cleanup branch "$F/out" fail
  require contains "$F/out" 'Repo-local:  0 eligible, 1 preserved.'
  require test ! -s "$F/du.calls"
}

case_t9() {
  init_fixture t9
  add_wt wt-old "$WT/wt-old" 10
  expect_eligible "$WT/wt-old"
  add_wt wt-merged4 "$WT/wt-merged4" 4
  expect_eligible "$WT/wt-merged4"
  AUTO="$F/ao/data/worktrees/wt-auto"
  add_wt wt-auto "$AUTO" 10
  "$REAL_GIT" -C "$REPO" worktree lock "$AUTO"
  expect_eligible "$AUTO"
  add_orphan old 10
  expect_eligible "$AG/old"
  add_wt wt-young "$WT/wt-young" 2
  add_wt wt-dirty "$WT/wt-dirty" 10
  printf 'dirty\n' >> "$WT/wt-dirty/README.md"
  add_wt wt-ahead "$WT/wt-ahead" 10 "$AHEAD_SHA"
  add_wt wt-locked "$WT/wt-locked" 10
  "$REAL_GIT" -C "$REPO" worktree lock "$WT/wt-locked"
  add_wt wt-live "$WT/wt-live" 10
  printf 'n%s\n' "$WT/wt-live" >> "$F/lsof.out"
  local name value rc
  for name in question dash empty leading-zero failed; do
    case "$name" in question) value='?';; dash) value=-;; empty|failed) value='';; leading-zero) value=08;; esac
    add_wt "wt-$name" "$WT/wt-$name" "$value"
    rc=0; [[ "$name" != failed ]] || rc=1
    if [[ "$rc" == 1 ]]; then
      sed '$d' "$F/ages.tsv" > "$F/ages.new"; mv "$F/ages.new" "$F/ages.tsv"
      map_age "$WT/wt-$name" '' 1
    fi
    mkdir -p "$AG/$name"
    map_age "$AG/$name" "$value" "$rc"
  done
  add_orphan young 2
  cut -f 1 "$F/ages.tsv" > "$F/before.paths"
  run_cleanup branch "$F/out" constant --clean
  while IFS= read -r path; do
    if grep -qFx -- "$path" "$F/eligible.expected"; then
      require test ! -e "$path"
      require ledger_has "$F/out" DELETE "$path "
    else
      require test -d "$path"
      require ledger_has "$F/out" PRESERVE "$path "
    fi
  done < "$F/before.paths"
  require contains "$F/out" 'Repo-local:  3 eligible, 10 preserved.'
  require contains "$F/out" 'Antigravity: 1 eligible orphan(s), 6 active preserved.'
}

echo '=== cleanup_worktrees single-age-walk fixture tests ==='
run_case T1 'exact age-call map, including zero-call early skips' case_t1
run_case T2 'du only on eligible rows and preserve size=-' case_t2
run_case T3 'known-size worktree and exact reclaimable total' case_t3
run_case T4 'invalid and failed ages fail closed in both scopes' case_t4
run_case T5 'unstubbed empty orphan remains young' case_t5
run_case T6 'orphan at the age floor is not young' case_t6
run_case T7 'whole-script baseline verdict and summary equivalence' case_t7
run_case T8 'du failure aborts eligible rows, preserve rows skip du' case_t8
run_case T9 'fixture-only clean removes exactly eligible paths' case_t9

echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

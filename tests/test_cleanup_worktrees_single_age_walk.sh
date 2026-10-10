#!/usr/bin/env bash
# Regression contract: exact ages only for eligible repo-local rows, du only for
# eligible rows. Antigravity classification uses predicates without exact ages.
# All cleanup, including --clean, is confined to this test's temporary fixtures.
set -euo pipefail
# These cases pin the 7-day non-merged path; the production default is now 3.
export WORKTREE_MIN_AGE_DAYS=7

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SHA=b0b5b9e4c713a5e9b9674cae9d81f563c37a69b1
TMP_ROOT="$(cd "$(mktemp -d -t cleanup_wt_single_age.XXXXXX)" && pwd -P)"
trap 'chmod -R u+rwX "$TMP_ROOT"; rm -rf "$TMP_ROOT"' EXIT
unset WORKTREE_APPROVED
REAL_GIT="$(command -v git)"
REAL_DU="$(command -v du)"
REAL_MKTEMP="$(command -v mktemp)"
REAL_TIMEOUT="$(command -v timeout || true)"
PASS=0
FAIL=0

# Keep every sourced helper at the corresponding revision. In particular, never
# replace worktree_recency.sh with a stub that drops worktree_is_recently_active.
mkdir -p "$TMP_ROOT/baseline" "$TMP_ROOT/batch_baseline" "$TMP_ROOT/branch" "$TMP_ROOT/unstubbed"
git -C "$REPO_ROOT" archive "$BASE_SHA" scripts | tar -x -C "$TMP_ROOT/baseline"
git -C "$REPO_ROOT" archive 2f35dfcd063f1c24f418b013ec9668547bccafff scripts | tar -x -C "$TMP_ROOT/batch_baseline"
cp -R "$REPO_ROOT/scripts" "$TMP_ROOT/branch/"
cp -R "$REPO_ROOT/scripts" "$TMP_ROOT/unstubbed/"
for tree in baseline batch_baseline branch; do
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
cat >> "$TMP_ROOT/branch/scripts/lib/worktree_recency.sh" <<'SH'

# Predicate fixture uses the same age map without invoking the display-age
# function: only eligible repo-local rows are allowed to request that age.
worktree_is_recently_active() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$PREDICATE_COUNTER"
    local value rc
    value="$(awk -F '\t' -v p="$1" '$1 == p { print $2; found=1; exit } END { if (!found) exit 1 }' "$AGE_MAP")" || return 0
    rc="$(awk -F '\t' -v p="$1" '$1 == p { print $3; exit }' "$AGE_MAP")"
    [[ "$rc" == 0 && "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 0
    (( value < $2 ))
}
SH

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
  printf 'worktree %s\n' "$FIXTURE/home/.gemini/antigravity/worktrees/project/active"
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
  : > "$F/age.calls"; : > "$F/du.calls"; : > "$F/predicate.calls"
  local approval=''
  if [[ "$action" == --clean ]]; then
    # Guard before granting deletion authority: both HOME and repo are fixtures.
    [[ "$F" == "$TMP_ROOT/"* && "$REPO" == "$F/repo" && "$HOME_FIX" == "$F/home" ]]
    approval='WORKTREE_APPROVED=1'
  fi
  env -i HOME="$HOME_FIX" PATH="$BIN:/usr/bin:/bin" WORKTREE_MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}" \
    HERMES_SKIP_EXAMPLE_COM_GUARD=1 FIXTURE="$F" REAL_GIT="$REAL_GIT" REAL_DU="$REAL_DU" REAL_MKTEMP="$REAL_MKTEMP" \
    AHEAD_SHA="$AHEAD_SHA" AGE_MAP="$F/ages.tsv" AGE_COUNTER="$F/age.calls" \
    PREDICATE_COUNTER="$F/predicate.calls" \
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
  python3 - "$F/calls.expected" "$F/age.calls" "$F/eligible.expected" "$AG" "$F/predicate.calls" <<'PY'
import collections, sys
expected = {}
expected_default_probes = {}
eligible = set(line.rstrip('\n') for line in open(sys.argv[3]))
for line in open(sys.argv[1]):
    path, count = line.rstrip('\n').split('\t')
    assert path not in expected, path
    expected[path] = int(path in eligible and not path.startswith(sys.argv[4] + '/'))
    # Live repo-local rows now short circuit before the threshold probe.
    expected_default_probes[path] = 0 if path.endswith('/wt-live') else int(count)
actual = collections.Counter(line.rstrip('\n') for line in open(sys.argv[2]))
assert not (set(actual) - set(expected)), (actual, expected)
assert {p: actual[p] for p in expected} == expected, (actual, expected)
assert not any(p.startswith(sys.argv[4] + '/') for p in actual), actual
probes = collections.defaultdict(list)
for line in open(sys.argv[5]):
    path, floor, now = line.rstrip('\n').split('\t')
    probes[path].append((floor, now))
assert not (set(probes) - set(expected_default_probes)), probes
assert {path: sum(floor == '7' for floor, _ in probes.get(path, [])) for path in expected_default_probes} == expected_default_probes, (probes, expected_default_probes)
for path, calls in probes.items():
    if path.startswith(sys.argv[4] + '/'):
        assert calls == [('7', '')], (path, calls)
    else:
        assert sum(floor == '7' for floor, _ in calls) == 1, (path, calls)
        assert len({now for _, now in calls}) == 1, (path, calls)
        assert all(now.isdecimal() and int(now) > 0 for _, now in calls), (path, calls)
PY
}

case_t2() {
  mixed_fixture t2
  run_cleanup branch "$F/out"
  LC_ALL=C sort "$F/eligible.expected" > "$F/expected.sorted"
  LC_ALL=C sort "$F/du.calls" > "$F/actual.sorted"
  require diff -u "$F/expected.sorted" "$F/actual.sorted"
  # Standard-root early skips intentionally have no age/size suffix.
  require awk '/LEDGER repo-local +PRESERVE/ && / \| age=/ { n++; if ($0 !~ / age=- size=- /) exit 1 } END { if (!n) exit 1 }' "$F/out"
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
    require ledger_has "$F/out" PRESERVE "$WT/wt-$name | young | age=- size=- "
    require ledger_has "$F/out" PRESERVE "$AG/$name | young (< 7 days)"
  done
  require excludes "$F/out" ELIGIBLE
  require test ! -s "$F/du.calls"
}

case_t5() {
  init_fixture t5
  mkdir -p "$AG/empty"
  run_cleanup unstubbed "$F/out"
  require ledger_has "$F/out" PRESERVE "$AG/empty | young (< 7 days)"
  require excludes "$F/out" ELIGIBLE
}

case_t6() {
  init_fixture t6
  add_orphan exact-floor 7
  run_cleanup branch "$F/out"
  require ledger_has "$F/out" PRESERVE "$AG/exact-floor | not-git"
  require excludes "$F/out" "$AG/exact-floor | young"
  require test ! -s "$F/age.calls"
  require test "$(cut -f 1 "$F/predicate.calls")" = "$AG/exact-floor"
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
            line = re.sub(r' [|] age=\S+ size=\S+', '', line)
            if '/antigravity/worktrees/project/old ' in line: continue
            if line.startswith(('Antigravity:', 'Reclaimable:')): continue
            line = re.sub(r' [(](?:age=[^)]*|< [0-9]+ days)[)]', '', line)
            target.write(line)
PY_NORMALIZE
  require diff -u "$F/baseline.normalized" "$F/branch.normalized"
  require contains "$F/branch.out" 'Repo-local:  4 eligible, 7 preserved.'
  require contains "$F/branch.out" 'Antigravity: 0 eligible orphan(s), 2 active preserved.'
  require contains "$F/branch.out" 'Reclaimable: ~0.00 GB (4096 KB)'
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
  require contains "$F/out" 'Antigravity: 0 eligible orphan(s), 7 active preserved.'
}

# GraphQL is stubbed only at the external gh boundary. Repositories, worktree
# discovery, content/merge checks, cache files, and verdicts use the real script.
batch_fixture() {
  init_fixture "$1"
  printf '{"mode":"ok"}\n' > "$F/graphql.json"
  cat > "$BIN/gh" <<'PY_GH'
#!/usr/bin/env python3
import json, os, re, sys, time
from pathlib import Path
root = Path(os.environ['FIXTURE'])
args = sys.argv[1:]
config = json.loads((root / 'graphql.json').read_text())
if args[:2] == ['api', 'graphql']:
    assert '-F' not in args, args
    assert not os.environ.get('GH_TOKEN') and not os.environ.get('GITHUB_TOKEN')
    fields = {}
    for index in range(2, len(args), 2):
        assert args[index] == '-f', args
        key, value = args[index + 1].split('=', 1)
        fields[key] = value
    query = fields.pop('query')
    branches = {key: value for key, value in fields.items() if re.fullmatch(r'b\d+', key)}
    assert 1 <= len(branches) <= 40, branches
    assert 'repository(owner: $owner, name: $name)' in query, query
    for key in fields:
        assert re.search(r'\$' + key + r':\s*String!', query), (key, query)
    for key in branches:
        assert (key + ': pullRequests(headRefName: $' + key + ', states: MERGED, first: 30, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { headRefOid } }') in query, query
    call = {'kind': 'graphql', 'fields': fields, 'branches': list(branches.values())}
    with (root / 'batch.calls').open('a') as f:
        f.write(json.dumps(call) + '\n')
    mode = config['mode']
    if mode == 'sleep':
        time.sleep(12)
    if mode == 'fail' and config['fail_branch'] in branches.values():
        sys.exit(1)
    if mode == 'invalid':
        print('{broken')
        sys.exit(0)
    nodes = {}
    for alias, branch in branches.items():
        heads = [os.environ['AHEAD_SHA']]
        if mode == 'position25':
            heads = [format(i, '040x') for i in range(30)]
            heads[24] = os.environ['AHEAD_SHA']
        if mode == 'wrong-repo' or (mode == 'collision' and branch == 'wt/a'):
            heads = []
        nodes[alias] = {'nodes': [{'headRefOid': head} for head in heads]}
    result = {'data': {'repository': nodes}}
    if mode in ('null', 'error'):
        alias = next(key for key, branch in branches.items() if branch == config['fail_branch'])
        if mode == 'null':
            nodes[alias] = None
        else:
            result['errors'] = [{'message': 'fixture alias error', 'path': ['repository', alias]}]
    print(json.dumps(result))
elif args[:2] == ['pr', 'list']:
    owner_repo = args[args.index('--repo') + 1]
    branch = args[args.index('--head') + 1]
    with (root / 'batch.calls').open('a') as f:
        f.write(json.dumps({'kind': 'pr', 'repo': owner_repo, 'branch': branch}) + '\n')
    if config['mode'] == 'wrong-repo' and owner_repo == 'fixture/repo':
        sys.exit(0)
    if config['mode'] == 'collision' and branch == 'wt/a':
        sys.exit(0)
    print(os.environ['AHEAD_SHA'])
else:
    sys.exit(2)
PY_GH
  cat > "$BIN/mktemp" <<'SH'
#!/usr/bin/env bash
result="$("$REAL_MKTEMP" "$@")" || exit $?
if [[ "$*" == -d ]]; then printf '%s\n' "$result" >> "$FIXTURE/run_tmp.paths"; fi
printf '%s\n' "$result"
SH
  chmod +x "$BIN/gh" "$BIN/mktemp"
}

batch_rows() {
  local count="$1" i branch
  for ((i=0; i<count; i++)); do
    printf -v branch 'wt-batch-%03d' "$i"
    add_wt "$branch" "$WT/$branch" 10 "$AHEAD_SHA"
  done
}

batch_equivalent() {
  : > "$F/batch.calls"
  run_cleanup batch_baseline "$F/baseline.out"
  mv "$F/batch.calls" "$F/baseline.calls"
  run_cleanup branch "$F/branch.out"
  # The amendment intentionally removes exact age labels from PRESERVE rows.
  # Keep every other byte in the batch baseline comparison unchanged.
  sed -E 's/ \| age=[^ ]+ size=/ | age=LABEL size=/' "$F/baseline.out" > "$F/baseline.batch-normalized"
  sed -E 's/ \| age=[^ ]+ size=/ | age=LABEL size=/' "$F/branch.out" > "$F/branch.batch-normalized"
  require diff -u "$F/baseline.batch-normalized" "$F/branch.batch-normalized"
}

case_b1() {
  batch_fixture b1
  batch_rows 81
  batch_equivalent
  python3 - "$F/batch.calls" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert len(calls) == 3 and all(c['kind'] == 'graphql' for c in calls), calls
branches = [b for c in calls for b in c['branches']]
assert len(branches) == 82 and len(set(branches)) == 82, branches
assert all(c['fields']['owner'] == 'fixture' and c['fields']['name'] == 'repo' for c in calls)
PY
}

case_b2() {
  batch_fixture b2
  batch_rows 81
  printf '{"mode":"fail","fail_branch":"wt-batch-040"}\n' > "$F/graphql.json"
  batch_equivalent
  python3 - "$F/batch.calls" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
chunks = [c for c in calls if c['kind'] == 'graphql']
assert len(chunks) == 3, chunks
failed = next(c['branches'] for c in chunks if 'wt-batch-040' in c['branches'])
fallback = [c['branch'] for c in calls if c['kind'] == 'pr']
assert sorted(fallback) == sorted(b for b in failed if b != 'main'), (fallback, failed)
PY
}

case_b3() {
  batch_fixture b3
  batch_rows 1
  printf '{"mode":"position25"}\n' > "$F/graphql.json"
  batch_equivalent
  require ledger_has "$F/branch.out" ELIGIBLE "$WT/wt-batch-000 "
  require test "$(wc -l < "$F/batch.calls" | tr -d ' ')" = 1
  require contains "$F/batch.calls" '"kind": "graphql"'
}

case_b4() {
  batch_fixture b4
  require test -n "$REAL_TIMEOUT"
  ln -sf "$REAL_TIMEOUT" "$BIN/timeout"
  batch_rows 1
  printf '{"mode":"sleep"}\n' > "$F/graphql.json"
  batch_equivalent
  python3 - "$F/batch.calls" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert [c['kind'] for c in calls] == ['graphql', 'pr'], calls
PY
}

case_b5() {
  batch_fixture b5
  batch_rows 1
  run_cleanup branch "$F/out"
  require test -s "$F/run_tmp.paths"
  require test "$(wc -l < "$F/run_tmp.paths" | tr -d ' ')" = 1
  while IFS= read -r path; do require test ! -e "$path"; done < "$F/run_tmp.paths"
}

case_b6() {
  batch_fixture b6
  local branch
  for branch in null 123 @x true; do add_wt "$branch" "$WT/wt-$branch" 10 "$AHEAD_SHA"; done
  batch_equivalent
  python3 - "$F/batch.calls" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert len(calls) == 1 and calls[0]['kind'] == 'graphql', calls
assert sorted(calls[0]['branches']) == sorted(['main', 'null', '123', '@x', 'true']), calls
assert all(isinstance(value, str) for value in calls[0]['fields'].values())
PY
}

case_b7() {
  batch_fixture b7
  batch_rows 1
  printf '{"mode":"wrong-repo"}\n' > "$F/graphql.json"
  # An unscoped gh call would see the invoking checkout's matching PR.
  local own_head
  own_head="$(FIXTURE="$F" AHEAD_SHA="$AHEAD_SHA" "$BIN/gh" pr list --repo invoking/checkout --head wt-batch-000)"
  require test "$own_head" = "$AHEAD_SHA"
  batch_equivalent
  require ledger_has "$F/branch.out" PRESERVE "$WT/wt-batch-000 | ahead-of-main"
  require excludes "$F/branch.out" ELIGIBLE
  require test "$(wc -l < "$F/batch.calls" | tr -d ' ')" = 1
  require contains "$F/batch.calls" '"kind": "graphql"'
}

case_b8() {
  batch_fixture b8
  add_wt wt/a "$WT/wt-slash" 10 "$AHEAD_SHA"
  add_wt wt_a "$WT/wt-underscore" 10 "$AHEAD_SHA"
  printf '{"mode":"collision"}\n' > "$F/graphql.json"
  batch_equivalent
  require ledger_has "$F/branch.out" PRESERVE "$WT/wt-slash | ahead-of-main"
  require ledger_has "$F/branch.out" ELIGIBLE "$WT/wt-underscore "
  require test "$(wc -l < "$F/batch.calls" | tr -d ' ')" = 1
}

case_b_errors() {
  local mode
  for mode in invalid null error; do
    batch_fixture "b-errors-$mode"
    batch_rows 2
    printf '{"mode":"%s","fail_branch":"wt-batch-000"}\n' "$mode" > "$F/graphql.json"
    batch_equivalent
    python3 - "$F/batch.calls" "$mode" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
chunks = [c for c in calls if c['kind'] == 'graphql']
assert len(chunks) == 1, chunks
fallback = sorted(c['branch'] for c in calls if c['kind'] == 'pr')
expected = ['wt-batch-000', 'wt-batch-001'] if sys.argv[2] == 'invalid' else ['wt-batch-000']
assert fallback == expected, (fallback, expected)
PY
  done
}

echo '=== cleanup_worktrees single-age-walk fixture tests ==='
run_case T1 'exact age once per eligible repo-local row, never preserved or Antigravity' case_t1
run_case T2 'du only on eligible rows and preserve size=-' case_t2
run_case T3 'known-size worktree and exact reclaimable total' case_t3
run_case T4 'invalid and failed ages fail closed in both scopes' case_t4
run_case T5 'unstubbed empty orphan remains young' case_t5
run_case T6 'orphan at the age floor is not young' case_t6
run_case T7 'whole-script baseline verdict and summary equivalence' case_t7
run_case T8 'du failure aborts eligible rows, preserve rows skip du' case_t8
run_case T9 'fixture-only clean removes exactly eligible paths' case_t9
run_case B1 '40-alias chunks match per-row baseline without per-row calls' case_b1
run_case B2 'only failed-chunk branches fall back to per-row lookups' case_b2
run_case B3 'matching merged head at position 25 remains eligible' case_b3
run_case B4 '12-second GraphQL call times out and falls back' case_b4
run_case B5 'one run temp directory is removed at exit' case_b5
run_case B6 'null, 123, @x, and true remain literal branch strings' case_b6
run_case B7 'foreign invoking-repo merged PR cannot approve target repo' case_b7
run_case B8 'slash and underscore branches have distinct cache records' case_b8
run_case B-errors 'malformed JSON, alias null, and alias errors fail closed' case_b_errors

echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_worktree_recency.sh — the worktree "last 2 weeks" protection rule.
#
# Each case builds a fake worktree with hand-set mtimes and asserts the
# helper's verdict. The first two cases are regression tests for the two
# proxies that were replaced: both reported ~20 days for worktrees whose newest
# file was ~13 days old on the live worldarchitect.ai registry (2026-07-27).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$REPO_ROOT/scripts/lib/worktree_recency.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" what="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$what (= $expected)"; else bad "$what — expected '$expected', got '$actual'"; fi
}

# days_ago <n> -> epoch
days_ago() { echo $(( $(date +%s) - ($1 * 86400) )); }
# touch_at <epoch> <path...>
touch_at() {
    local epoch="$1"; shift
    touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$@"
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# mk_worktree <name> — a linked-worktree shape: .git is a pointer FILE into a
# fake admin dir, matching what `git worktree add` produces.
mk_worktree() {
    local name="$1" wt="$TMPROOT/$1"
    mkdir -p "$wt/src/deep/nested" "$TMPROOT/.gitadmin/$name"
    echo "gitdir: $TMPROOT/.gitadmin/$name" > "$wt/.git"
    : > "$TMPROOT/.gitadmin/$name/HEAD"
    : > "$TMPROOT/.gitadmin/$name/index"
    : > "$wt/src/deep/nested/code.py"
    : > "$wt/README.md"
    echo "$wt"
}

echo "== case 1: deep edit today, everything else 30d old =="
# This is the exact shape both replaced proxies got wrong: the .git pointer and
# the worktree root dir are stale, but real work happened today.
WT="$(mk_worktree active_deep_edit)"
OLD="$(days_ago 30)"
touch_at "$OLD" "$WT/.git" "$TMPROOT/.gitadmin/active_deep_edit/HEAD" \
    "$TMPROOT/.gitadmin/active_deep_edit/index" "$WT/README.md" "$WT"
touch "$WT/src/deep/nested/code.py"   # edited now
assert_eq "$(worktree_age_days "$WT")" "0" "deep edit today is age 0"
if worktree_is_recently_active "$WT" 14; then ok "protected by the 14-day floor"; else bad "NOT protected — this is the work-loss bug"; fi
# Prove the old proxies would have failed here.
GITPTR_AGE=$(( ( $(date +%s) - $(stat -f '%m' "$WT/.git") ) / 86400 ))
if (( GITPTR_AGE >= 14 )); then ok "old .git-pointer proxy would have said ${GITPTR_AGE}d (deletable) — regression covered"; else bad "fixture did not reproduce the old proxy's false-old reading"; fi

echo "== case 2: git metadata must NOT count as activity =="
# Deliberate: `git status --porcelain` rewrites the index to refresh its stat
# cache, and worktree_hygiene.sh runs it on every candidate during triage. If
# index mtime counted, triage would mark every candidate "active" and the next
# run would exempt exactly the worktrees it had just identified. Same decision
# as tests/test_worktree_hygiene.py's fresh-.git-pointer case (jleechan-20gm).
WT="$(mk_worktree git_metadata_only)"
touch_at "$OLD" "$WT/.git" "$WT/README.md" "$WT/src/deep/nested/code.py" "$WT"
touch "$TMPROOT/.gitadmin/git_metadata_only/index" \
      "$TMPROOT/.gitadmin/git_metadata_only/HEAD" "$WT/.git"
AGE="$(worktree_age_days "$WT")"
if (( AGE >= 29 )); then ok "index/HEAD/.git-pointer writes ignored — still ${AGE}d"; else bad "git metadata leaked into recency (${AGE}d) — sweeper would self-poison"; fi

echo "== case 3: genuinely dormant worktree =="
WT="$(mk_worktree dormant)"
OLD40="$(days_ago 40)"
touch_at "$OLD40" "$WT/.git" "$WT/README.md" "$WT/src/deep/nested/code.py" "$WT" \
    "$TMPROOT/.gitadmin/dormant/HEAD" "$TMPROOT/.gitadmin/dormant/index"
AGE="$(worktree_age_days "$WT")"
if (( AGE >= 39 && AGE <= 41 )); then ok "dormant worktree reports ${AGE}d"; else bad "dormant worktree reported '$AGE', expected ~40"; fi
if worktree_is_recently_active "$WT" 14; then bad "dormant worktree wrongly protected"; else ok "dormant worktree is eligible"; fi

echo "== case 4: venv churn must not reset the clock =="
# cleanup_worktree_venvs.sh deletes venv/ inside these trees. If venv counted
# as activity, one cleanup pass would mark the entire dormant pool "too young"
# and the next pass would skip everything forever.
WT="$(mk_worktree venv_churn)"
mkdir -p "$WT/venv/lib" "$WT/node_modules/pkg" "$WT/__pycache__"
touch_at "$OLD40" "$WT/.git" "$WT/README.md" "$WT/src/deep/nested/code.py" "$WT" \
    "$TMPROOT/.gitadmin/venv_churn/HEAD" "$TMPROOT/.gitadmin/venv_churn/index"
touch "$WT/venv/lib/site.py" "$WT/node_modules/pkg/index.js" "$WT/__pycache__/x.pyc"
AGE="$(worktree_age_days "$WT")"
if (( AGE >= 39 )); then ok "venv/node_modules/__pycache__ pruned — still ${AGE}d"; else bad "pruned dirs leaked into recency — got ${AGE}d"; fi

echo "== case 5: fail closed on unmeasurable input =="
assert_eq "$(worktree_age_days "$TMPROOT/does-not-exist")" "0" "nonexistent path fails closed to age 0"
EMPTY="$TMPROOT/empty_no_git"; mkdir -p "$EMPTY"
assert_eq "$(worktree_age_days "$EMPTY")" "0" "empty dir with no .git fails closed to age 0"
if worktree_is_recently_active "$TMPROOT/does-not-exist" 14; then ok "unmeasurable path is treated as PROTECTED"; else bad "unmeasurable path was treated as deletable — fails open"; fi

echo "== case 6: future mtime must not read as ancient =="
WT="$(mk_worktree clock_skew)"
touch -t "$(date -r "$(( $(date +%s) + 86400 ))" +%Y%m%d%H%M.%S)" "$WT/README.md"
assert_eq "$(worktree_age_days "$WT")" "0" "future mtime clamps to age 0"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

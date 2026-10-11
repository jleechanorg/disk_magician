#!/usr/bin/env bash
# test_worktree_merged_pr.sh — gh-verified merged-PR head proof (plan Task 3b).
#
# worktree_head_is_merged_pr must fail closed: rc 1 on gh failure, on a
# non-matching head (an OPEN PR's newer head), on an empty branch (detached
# HEAD — without calling gh at all), and when the cache cannot prove anything.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/worktree_merged_pr.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_rc() { # <expected-rc> <cmd...> <what>
    local want="$1" what="${@: -1}"
    local got=0
    "${@:2:$(( $# - 2 ))}" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then ok "$what (rc $want)"; else bad "$what — expected rc $want, got rc $got"; fi
}

TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { [[ -n "$TMPROOT" && "$TMPROOT" == /private/tmp.* ]] && rm -rf "$TMPROOT"; [[ -n "$TMPROOT" && "$TMPROOT" == /tmp.* ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"

MERGED_HEAD="1111111111111111111111111111111111111111"
OPEN_HEAD="2222222222222222222222222222222222222222"

# fixture repo with an origin remote and one linked worktree on merged-branch
REPO="$TMPROOT/repo"
git init -q -b main "$REPO" 2>/dev/null
git -C "$REPO" config user.email fixture@users.noreply.github.com
git -C "$REPO" config user.name Fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin https://github.com/fixture/repo.git
git -C "$REPO" worktree add -q -b merged-branch "$TMPROOT/wt-m" 2>/dev/null

# mock gh
GH_CALLED="$TMPROOT/gh.called"
ALL_ALIASES="$(python3 -c 'print(",".join("b%d" % i for i in range(40)))')"
GRAPHQL_JSON="$(python3 - "$MERGED_HEAD" <<'PY'
import json, sys
head = sys.argv[1]
print(json.dumps({"data": {"repository": {
    ("b%d" % i): {"nodes": [{"headRefOid": head}]} for i in range(40)}}}))
PY
)"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/bin/bash
touch "$GH_CALLED"
case "\$1 \$2" in
  "api graphql")
    if [[ "\${GH_FAIL_ALL:-}" == 1 ]]; then exit 1; fi
    printf '%s\n' '$GRAPHQL_JSON'
    exit 0 ;;
  "pr list")
    if [[ "\${GH_FAIL_ALL:-}" == 1 ]]; then exit 1; fi
    case "\$*" in
      *merged-branch*) echo "$MERGED_HEAD"; exit 0 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/gh"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$BIN/timeout"
chmod +x "$BIN/timeout"
export PATH="$BIN:$PATH"

echo "== exact merged PR head -> rc 0 =="
assert_rc 0 worktree_head_is_merged_pr "$REPO" merged-branch "$MERGED_HEAD" "merged-branch at its merged head"
[[ -f "$TMPROOT/state/pr_cache/fixture/repo.tsv" ]] && ok "cache file written under state pr_cache" || bad "cache file missing"

echo "== TTL short-circuit: fresh cache answers without gh =="
rm -f "$GH_CALLED"
GH_FAIL_ALL=1 assert_rc 0 worktree_head_is_merged_pr "$REPO" merged-branch "$MERGED_HEAD" "fresh cache hit needs no gh"
[[ ! -e "$GH_CALLED" ]] && ok "gh was not called on cache hit" || bad "gh was called on cache hit"

echo "== OPEN PR's newer head -> rc 1 =="
assert_rc 1 worktree_head_is_merged_pr "$REPO" merged-branch "$OPEN_HEAD" "differing head fails closed"

echo "== gh failing entirely -> rc 1 =="
rm -rf "$TMPROOT/state"    # force populate to run again
rm -f "$GH_CALLED"
GH_FAIL_ALL=1 assert_rc 1 worktree_head_is_merged_pr "$REPO" merged-branch "$MERGED_HEAD" "gh outage fails closed"

echo "== empty branch -> rc 1 without calling gh =="
rm -f "$GH_CALLED"
unset GH_FAIL_ALL
assert_rc 1 worktree_head_is_merged_pr "$REPO" "" "$MERGED_HEAD" "empty (detached) branch fails closed"
[[ ! -e "$GH_CALLED" ]] && ok "gh not called for empty branch" || bad "gh was called for empty branch"

echo "== populate writes an atomic, epoch-stamped cache =="
rm -rf "$TMPROOT/state"
worktree_pr_cache_populate "$REPO" && ok "populate rc 0" || bad "populate failed"
HEAD1="$(awk 'NR==1' "$TMPROOT/state/pr_cache/fixture/repo.tsv")"
[[ "$HEAD1" == "#epoch "* ]] && ok "cache starts with epoch marker" || bad "cache lacks epoch marker (got: $HEAD1)"
grep -q "^merged-branch	$MERGED_HEAD$" "$TMPROOT/state/pr_cache/fixture/repo.tsv" && ok "cache records merged-branch head" || bad "cache missing merged-branch line"
H="$(worktree_cached_pr_heads "$REPO" merged-branch)"
[[ "$H" == "$MERGED_HEAD" ]] && ok "cached_pr_heads returns the head" || bad "cached_pr_heads returned: $H"
worktree_cached_pr_heads "$REPO" never-a-branch 2>/dev/null && bad "unknown branch should miss" || ok "unknown branch misses the cache"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

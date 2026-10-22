#!/usr/bin/env bash
# Clean DETACHED worktrees: removable only when HEAD is on a LIVE origin ref.
set -euo pipefail
export WORKTREE_MIN_AGE_DAYS=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_pushed.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1)); fi; }
age_days_ago() {
  local wt="$1" days="$2" ts gitdir
  if ! ts=$(date -v-"${days}"d +%Y%m%d%H%M 2>/dev/null); then
    ts=$(date -d "${days} days ago" +%Y%m%d%H%M)
  fi
  /usr/bin/find "$wt" -name .git -prune -o -exec touch -h -t "$ts" {} +
  touch -t "$ts" "$wt/.git"
  gitdir=$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)
  /usr/bin/find "$gitdir" -exec touch -t "$ts" {} +
}
export HERMES_SKIP_EXAMPLE_COM_GUARD=1
REPO="$TMP_ROOT/repo"; WT="$REPO/.claude/worktrees"; mkdir -p "$WT"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email f@users.noreply.github.com
git -C "$REPO" config user.name F
printf '.env*\ndata/\ndata.pyc/\n.testmondata/\nnode_modules/\n.ruff_cache/\ntest-results/\nbuild/\n' > "$REPO/.gitignore"; printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add .gitignore README.md; git -C "$REPO" commit -q -m base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b ahead; printf 'ahead\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin ahead
printf 'gone\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am gone
GONE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin "ahead:refs/heads/gone"   # advertised, then deleted below
git -C "$REPO" fetch -q origin
printf 'local\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am local
LOCAL_SHA=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
# origin tip AHEAD_SHA is the advertised ref; the stale tracking ref for "gone"
# keeps pointing at GONE_SHA after the branch is deleted upstream.
git -C "$REPO" update-ref refs/remotes/origin/gone "$GONE_SHA"
git -C "$TMP_ROOT/origin.git" update-ref -d refs/heads/gone
add_det() { git -C "$REPO" worktree add -q --detach "$WT/wt-$1" "$2"; age_days_ago "$WT/wt-$1" 4; }
add_det doriginok "$AHEAD_SHA"
add_det dlocal "$LOCAL_SHA"
add_det ddirty "$AHEAD_SHA"; printf 'x\n' >> "$WT/wt-ddirty/README.md"
add_det dstale "$GONE_SHA"
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
printf '#!/bin/sh\nprintf "p1\\nn/\\n"\n' > "$TMP_ROOT/bin/lsof"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"
run() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1; }
OUT="$(run)"
check "detached clean HEAD on live origin is ELIGIBLE" "ELIGIBLE  $WT/wt-doriginok |" "$OUT"
check "eligible line carries the reason" "reason=detached-on-origin" "$OUT"
check "detached HEAD only local is kept" "wt-dlocal | ahead-of-main" "$OUT"
check "detached dirty is kept" "wt-ddirty | dirty" "$OUT"
check "branch deleted upstream (stale tracking ref) is kept" "wt-dstale | ahead-of-main" "$OUT"
git -C "$REPO" remote set-url origin "$TMP_ROOT/missing.git"
OUT="$(run)"
check "ls-remote failure keeps detached worktree" "wt-doriginok | ahead-of-main" "$OUT"
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

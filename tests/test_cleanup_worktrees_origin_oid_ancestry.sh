#!/usr/bin/env bash
# The on-origin proof is the advertised ref SET, not refs/heads/<this branch>:
#   * a renamed branch whose oid is a live origin ref is ELIGIBLE;
#   * a branch-attached tip that is an ANCESTOR of a live origin tip is ELIGIBLE;
#   * untracked entries the repo's own allowlist calls rebuildable (.husky/_,
#     node_modules) no longer block; untracked source / ambiguous build/ /
#     agent tool-state still do.
# Preserved as before: real tracked edits, hidden index state, non-rebuildable
# untracked content, live cwd, unpushed commits, unreachable origin.
set -euo pipefail
export WORKTREE_MIN_AGE_DAYS=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_originoid.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); return 0; fi
  echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1))
  local key="${2%% *}"; key="${key##*/ct-}"; key="${key##*/}"
  grep -F -- "${key##wt-}" <<<"$3" | sed 's/^/        actual: /' | head -3
}
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
printf 'base\n' > "$REPO/README.md"
# .husky/ is tracked (real hooks); husky's generated _/ subdir is what stays untracked.
mkdir -p "$REPO/.husky"; printf '#!/bin/sh\n' > "$REPO/.husky/pre-commit"
git -C "$REPO" add README.md .husky/pre-commit; git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
# t1: pushed then RENAMED upstream-visible name -- same oid, other ref name.
git -C "$REPO" checkout -q -b renamed-local; printf 'renamed\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am renamed
RENAMED_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin "$RENAMED_SHA:refs/heads/reclaimed/pr-original-name"
# t2: ancestry -- c1 is an ancestor of the live origin tip c2.
git -C "$REPO" checkout -q -b ancestry main; printf 'c1\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am c1
ANCESTOR_SHA=$(git -C "$REPO" rev-parse HEAD)
printf 'c2\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am c2
TIP_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin "$TIP_SHA:refs/heads/moved-on"
git -C "$REPO" checkout -q -b unpushed main; printf 'local\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am local
LOCAL_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$3"; }
# positives introduced by this change
add_wt renamed       "$WT/wt-renamed"   "$RENAMED_SHA"
add_wt ancestry      "$WT/wt-ancestry"  "$ANCESTOR_SHA"
add_wt husky         "$WT/wt-husky"     "$RENAMED_SHA"; mkdir -p "$WT/wt-husky/.husky/_"; printf '#!/bin/sh\n' > "$WT/wt-husky/.husky/_/husky.sh"
add_wt nodemodules   "$WT/wt-nodemodules" "$RENAMED_SHA"; mkdir -p "$WT/wt-nodemodules/node_modules/x"; printf 'x\n' > "$WT/wt-nodemodules/node_modules/x/i.js"
# must stay preserved
add_wt dirty         "$WT/wt-dirty"     "$RENAMED_SHA"; printf 'edit\n' >> "$WT/wt-dirty/README.md"
add_wt hidden        "$WT/wt-hidden"    "$RENAMED_SHA"; printf 'edit\n' >> "$WT/wt-hidden/README.md"; git -C "$WT/wt-hidden" update-index --assume-unchanged README.md
add_wt srcuntracked  "$WT/wt-srcuntracked" "$RENAMED_SHA"; mkdir -p "$WT/wt-srcuntracked/src"; printf 'real source\n' > "$WT/wt-srcuntracked/src/module.py"
add_wt builduntracked "$WT/wt-builduntracked" "$RENAMED_SHA"; mkdir -p "$WT/wt-builduntracked/build"; printf 'hand-made evidence\n' > "$WT/wt-builduntracked/build/manual.db"
add_wt agentstate    "$WT/wt-agentstate" "$RENAMED_SHA"; mkdir -p "$WT/wt-agentstate/.agents/logs"; printf 'session\n' > "$WT/wt-agentstate/.agents/logs/s.jsonl"
add_wt livecwd       "$WT/wt-livecwd"   "$RENAMED_SHA"
add_wt unpushed      "$WT/wt-unpushed"  "$LOCAL_SHA"
for n in renamed ancestry husky nodemodules dirty hidden srcuntracked builduntracked agentstate livecwd unpushed; do age_days_ago "$WT/wt-$n" 4; done
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
LIVE_REAL="$(cd "$WT/wt-livecwd" && pwd -P)"
cat > "$TMP_ROOT/bin/lsof" <<SH
#!/bin/sh
echo "p1"
echo "n/"
echo "p2"
echo "n$LIVE_REAL"
SH
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
# Linux hosts prefer the root cwd scanner over lsof; supply the same observation
# through the sanctioned sandbox hook so both platforms exercise live-cwd.
cat > "$TMP_ROOT/bin/cwdscan" <<SCAN
#!/bin/sh
printf '1\t0\t/\0'
printf '4242\t0\t$LIVE_REAL\0'
SCAN
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout" "$TMP_ROOT/bin/cwdscan"
run() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
  DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" DISK_MAGICIAN_CWD_SCAN_CMD="$TMP_ROOT/bin/cwdscan" \
  bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1; }
OUT="$(run)"
check "renamed branch whose oid is a live origin ref is ELIGIBLE" "ELIGIBLE  $WT/wt-renamed |" "$OUT"
check "tip that is an ancestor of a live origin tip is ELIGIBLE" "ELIGIBLE  $WT/wt-ancestry |" "$OUT"
check "untracked .husky/_ only is ELIGIBLE" "ELIGIBLE  $WT/wt-husky |" "$OUT"
check "untracked node_modules only is ELIGIBLE" "ELIGIBLE  $WT/wt-nodemodules |" "$OUT"
check "real tracked edit still preserved as dirty" "wt-dirty | dirty" "$OUT"
check "assume-unchanged index state still preserved" "wt-hidden | hidden-state" "$OUT"
check "untracked non-rebuildable source still preserved" "wt-srcuntracked | untracked" "$OUT"
check "untracked ambiguous build/ dir still preserved" "wt-builduntracked | untracked" "$OUT"
check "untracked agent tool-state still preserved" "wt-agentstate | untracked" "$OUT"
check "live cwd still preserved" "wt-livecwd | live-cwd" "$OUT"
check "unpushed commit still preserved as ahead-of-main" "wt-unpushed | ahead-of-main" "$OUT"
git -C "$REPO" remote set-url origin "$TMP_ROOT/missing.git"
OUT="$(run)"
check "ls-remote failure keeps renamed-branch worktree" "wt-renamed | ahead-of-main" "$OUT"
check "ls-remote failure keeps ancestor worktree" "wt-ancestry | ahead-of-main" "$OUT"
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# A clean worktree whose branch tip is already on origin is ELIGIBLE (past the
# floor); unpushed, diverged, dirty and hidden-secret worktrees stay preserved.
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
  ts=$(date -v-"${days}"d +%Y%m%d%H%M)
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
printf '.env*\n' > "$REPO/.gitignore"; printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add .gitignore README.md; git -C "$REPO" commit -q -m base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b ahead; printf 'ahead\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$3"; }
add_wt pushed "$WT/wt-pushed" "$AHEAD_SHA";   git -C "$REPO" push -q origin pushed
add_wt unpushed "$WT/wt-unpushed" "$AHEAD_SHA"
add_wt diverged "$WT/wt-diverged" "$AHEAD_SHA"; git -C "$REPO" push -q origin "$BASE_SHA:refs/heads/diverged"
add_wt pdirty "$WT/wt-pdirty" "$AHEAD_SHA";   git -C "$REPO" push -q origin pdirty; printf 'x\n' >> "$WT/wt-pdirty/README.md"
add_wt psecret "$WT/wt-psecret" "$AHEAD_SHA"; git -C "$REPO" push -q origin psecret; printf 'T=1\n' > "$WT/wt-psecret/.env.local"
add_wt pyoung "$WT/wt-pyoung" "$AHEAD_SHA";   git -C "$REPO" push -q origin pyoung
for n in pushed unpushed diverged pdirty psecret; do age_days_ago "$WT/wt-$n" 4; done
mkdir -p "$TMP_ROOT/home"
run() { env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 HERMES_SKIP_EXAMPLE_COM_GUARD=1 bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1; }
OUT="$(run)"
check "clean pushed-equal worktree is ELIGIBLE" "ELIGIBLE  $WT/wt-pushed |" "$OUT"
check "unpushed stays ahead-of-main" "wt-unpushed | ahead-of-main" "$OUT"
check "diverged remote stays ahead-of-main" "wt-diverged | ahead-of-main" "$OUT"
check "dirty pushed worktree is preserved" "wt-pdirty | dirty" "$OUT"
check "pushed worktree with ignored .env is preserved" "wt-psecret | hidden-state" "$OUT"
check "young pushed worktree is preserved" "wt-pyoung | young" "$OUT"
git -C "$REPO" remote set-url origin "$TMP_ROOT/missing.git"
OUT="$(run)"
check "unreachable origin fails closed" "wt-pushed | ahead-of-main" "$OUT"
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

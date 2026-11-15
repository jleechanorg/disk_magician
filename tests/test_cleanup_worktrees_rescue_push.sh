#!/usr/bin/env bash
# TDD tests for cleanup_worktrees.sh --rescue-push (and --extra-clones-file):
# 1. >48h ahead-of-main worktree -> pushed to refs/heads/backup/diskm-rescue/... on origin, verified, removed.
# 2. >48h dirty + untracked source + ignored .beads/cache -> snapshot commit on origin has dirty+untracked, removed.
# 3. >48h worktree with untracked .env secret -> PRESERVE (secret-like), NOT pushed, NOT deleted.
# 4. <48h (young) dirty worktree -> PRESERVE (young), NOT touched.
# 5. --dry-run --rescue-push -> previews WOULD-RESCUE-PUSH-AND-DELETE without pushing or deleting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_rescue.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
check() {
    if grep -qF -- "$2" <<<"$3"; then
        echo "  PASS  $1"; PASS=$((PASS+1))
    else
        echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1))
    fi
}
check_not() {
    if ! grep -qF -- "$2" <<<"$3"; then
        echo "  PASS  $1"; PASS=$((PASS+1))
    else
        echo "  FAIL  $1 (unexpectedly found: $2)"; FAIL=$((FAIL+1))
    fi
}
check_cond() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS  $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL  $desc"; FAIL=$((FAIL+1))
    fi
}

age_days_ago() {
    local wt="$1" days="$2" ts gitdir
    if ! ts=$(date -v-"${days}"d +%Y%m%d%H%M 2>/dev/null); then
        ts=$(date -d "${days} days ago" +%Y%m%d%H%M)
    fi
    /usr/bin/find "$wt" -name .git -prune -o -exec touch -h -t "$ts" {} +
    touch -t "$ts" "$wt/.git"
    gitdir=$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)
    [[ -n "$gitdir" ]] && /usr/bin/find "$gitdir" -exec touch -t "$ts" {} +
}

export HERMES_SKIP_EXAMPLE_COM_GUARD=1
REPO="$TMP_ROOT/repo"
WT="$REPO/.claude/worktrees"
ORIGIN="$TMP_ROOT/origin.git"
mkdir -p "$WT" "$TMP_ROOT/home" "$TMP_ROOT/bin"

git init -q --bare -b main "$ORIGIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email f@users.noreply.github.com
git -C "$REPO" config user.name F
printf '.env*\n.beads/cache/\nnode_modules/\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add .gitignore README.md
git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main

# 1. >48h ahead-of-main worktree (unpushed commit)
git -C "$REPO" checkout -q -b feat-unpushed main
printf 'unpushed commit line\n' >> "$REPO/README.md"
git -C "$REPO" commit -q -am "unpushed work"
UNPUSHED_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" worktree add -q -B feat-unpushed "$WT/wt-unpushed" "$UNPUSHED_SHA"
age_days_ago "$WT/wt-unpushed" 3

# 2. >48h dirty modified + untracked source + ignored .beads/cache
git -C "$REPO" worktree add -q -b feat-dirty "$WT/wt-dirty" main
printf 'dirty modification\n' >> "$WT/wt-dirty/README.md"
printf 'new_helper() { echo ok; }\n' > "$WT/wt-dirty/helper.sh"
mkdir -p "$WT/wt-dirty/.beads/cache"
printf 'cache-blob\n' > "$WT/wt-dirty/.beads/cache/state.db"
age_days_ago "$WT/wt-dirty" 3

# 3. >48h worktree with untracked .env secret (must be PRESERVED, never pushed or deleted)
git -C "$REPO" worktree add -q -b feat-secret "$WT/wt-secret" main
printf 'API_KEY=supersecret123\n' > "$WT/wt-secret/.env"
printf 'safe change\n' >> "$WT/wt-secret/README.md"
age_days_ago "$WT/wt-secret" 3

# 4. <48h (young) dirty worktree (must be PRESERVED as young)
git -C "$REPO" worktree add -q -b feat-young "$WT/wt-young" main
printf 'fresh wip\n' > "$WT/wt-young/wip.txt"

cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
printf 'p1\nn/\n'
SH
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/timeout"

run_cleanup() {
    env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" \
        WORKTREE_APPROVED=1 HERMES_SKIP_EXAMPLE_COM_GUARD=1 \
        bash "$CLEANUP_SCRIPT" "$@" --repos "$REPO" 2>&1
}

echo "--- Dry-run --rescue-push ---"
DRY_OUT="$(run_cleanup --dry-run --rescue-push)"
echo "$DRY_OUT"
check "dry-run previews WOULD-RESCUE-PUSH-AND-DELETE for unpushed" "WOULD-RESCUE-PUSH-AND-DELETE" "$DRY_OUT"
check_cond "dry-run does not delete wt-unpushed" test -d "$WT/wt-unpushed"
check_cond "dry-run does not push rescue branches" bash -c "test -z \"\$(git -C '$ORIGIN' for-each-ref 'refs/heads/backup/diskm-rescue/')\""

echo "--- Clean --rescue-push ---"
CLEAN_OUT="$(run_cleanup --clean --rescue-push)"
echo "$CLEAN_OUT"

check_cond "1. wt-unpushed removed" test ! -e "$WT/wt-unpushed"
check_cond "2. wt-dirty removed" test ! -e "$WT/wt-dirty"
check_cond "3. wt-secret preserved" test -d "$WT/wt-secret"
check "3b. wt-secret reason mentions secret-like" "secret-like" "$CLEAN_OUT"
check_cond "4. wt-young preserved" test -d "$WT/wt-young"
check "4b. wt-young reason is young" "wt-young | young" "$CLEAN_OUT"

RESCUE_REFS="$(git -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname)' 'refs/heads/backup/diskm-rescue/')"
echo "Origin rescue refs:"
echo "$RESCUE_REFS"

check "origin has backup/diskm-rescue ref for wt-unpushed" "wt-unpushed" "$RESCUE_REFS"
check "origin has backup/diskm-rescue ref for wt-dirty" "wt-dirty" "$RESCUE_REFS"
check_not "origin has NO backup ref for wt-secret" "wt-secret" "$RESCUE_REFS"
check_not "origin has NO backup ref for wt-young" "wt-young" "$RESCUE_REFS"

DIRTY_REF="$(awk '/wt-dirty/ {print $1; exit}' <<<"$RESCUE_REFS")"
if [[ -n "$DIRTY_REF" ]]; then
    DIRTY_TREE_FILES="$(git -C "$ORIGIN" ls-tree -r --name-only "$DIRTY_REF")"
    check "wt-dirty snapshot includes untracked helper.sh" "helper.sh" "$DIRTY_TREE_FILES"
    check_not "wt-dirty snapshot excludes ignored .beads/cache" ".beads/cache" "$DIRTY_TREE_FILES"
    DIRTY_README="$(git -C "$ORIGIN" show "${DIRTY_REF}:README.md")"
    check "wt-dirty snapshot includes dirty README.md edit" "dirty modification" "$DIRTY_README"
else
    echo "  FAIL  missing DIRTY_REF in origin"; FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

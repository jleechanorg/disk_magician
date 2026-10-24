#!/usr/bin/env bash
# test_worktree_sparse_exclude.sh — wtn_apply_sparse_excludes in worktree_new.sh
#
# Covers the worktree-create path keeping heavy tracked dirs out of NEW checkouts
# (docs/ is 156.8 MB per worldarchitect.ai worktree; see
# findings_wiki/2026-10-22-worktree-sizing-and-sparse-docs.md).
#
# Run: bash tests/test_worktree_sparse_exclude.sh
set -uo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW_LIB="$REPO_ROOT/scripts/worktree_new.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

TMPROOT="$(CDPATH= cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset DISK_MAGICIAN_SPARSE_EXCLUDES DISK_MAGICIAN_SPARSE_EXCLUDE_OFF

# shellcheck source=scripts/worktree_new.sh
source "$NEW_LIB"

mk_repo() { # mk_repo <dir> [exclude-config...]
  local dir="$1"; shift
  mkdir -p "$dir/docs/user-stories-ui" "$dir/src"
  printf 'x' > "$dir/src/keep.py"
  head -c 100000 /dev/zero > "$dir/docs/user-stories-ui/big.png"
  ( cd "$dir" && git init -q . && git add -A && git commit -qm init )
  local ex
  for ex in "$@"; do git -C "$dir" config --add diskm.sparseExclude "$ex"; done
}

mk_repo "$TMPROOT/configured" docs
mk_repo "$TMPROOT/plain"

# --- case 1: opted-in repo gets a sparse checkout --------------------------
WT1="$TMPROOT/wt1"
wtn_apply_sparse_excludes_pre() { :; }
if wtn_create "$TMPROOT/configured" worktree-t1 "$WT1" HEAD >/dev/null 2>&1; then
  if [[ ! -e "$WT1/docs/user-stories-ui/big.png" ]]; then ok "docs excluded from the new checkout"
  else bad "docs excluded from the new checkout" "big.png still materialized"; fi
  if [[ -f "$WT1/src/keep.py" ]]; then ok "non-excluded content still checked out"
  else bad "non-excluded content still checked out" "src/keep.py missing"; fi
  GD="$(git -C "$WT1" rev-parse --absolute-git-dir)"
  if [[ -f "$GD/info/sparse-checkout" ]]; then ok "per-worktree sparse-checkout written"
  else bad "per-worktree sparse-checkout written" "no sparse-checkout file"; fi
  if git -C "$TMPROOT/configured" ls-tree -r --name-only HEAD | grep -q 'docs/user-stories-ui/big.png'; then
    ok "git history untouched"
  else bad "git history untouched" "blob missing from HEAD"; fi
  # Sibling isolation: the main repo keeps its docs.
  if [[ -f "$TMPROOT/configured/docs/user-stories-ui/big.png" ]]; then ok "main repo unaffected"
  else bad "main repo unaffected" "main repo lost docs"; fi
else
  bad "wtn_create on configured repo" "create failed"
fi

# --- case 2: repo without the config still gets a full checkout ------------
WT2="$TMPROOT/wt2"
if wtn_create "$TMPROOT/plain" worktree-t2 "$WT2" HEAD >/dev/null 2>&1; then
  if [[ -f "$WT2/docs/user-stories-ui/big.png" ]]; then ok "no opt-in -> full checkout kept"
  else bad "no opt-in -> full checkout kept" "docs unexpectedly removed"; fi
else
  bad "wtn_create on plain repo" "create failed"
fi

# --- case 3: env override applies without repo config ----------------------
WT3="$TMPROOT/wt3"
if DISK_MAGICIAN_SPARSE_EXCLUDES=docs wtn_create "$TMPROOT/plain" worktree-t3 "$WT3" HEAD >/dev/null 2>&1; then
  if [[ ! -e "$WT3/docs/user-stories-ui/big.png" ]]; then ok "env override excludes docs"
  else bad "env override excludes docs" "big.png still present"; fi
else
  bad "wtn_create with env override" "create failed"
fi

# --- case 4: kill switch restores a full checkout --------------------------
WT4="$TMPROOT/wt4"
if DISK_MAGICIAN_SPARSE_EXCLUDE_OFF=1 wtn_create "$TMPROOT/configured" worktree-t4 "$WT4" HEAD >/dev/null 2>&1; then
  if [[ -f "$WT4/docs/user-stories-ui/big.png" ]]; then ok "kill switch keeps full checkout"
  else bad "kill switch keeps full checkout" "docs removed despite opt-out"; fi
else
  bad "wtn_create with kill switch" "create failed"
fi

# --- case 5: a second exclusion path is honoured ---------------------------
mk_repo "$TMPROOT/multi" docs evidence
mkdir -p "$TMPROOT/multi/evidence"
printf 'e' > "$TMPROOT/multi/evidence/log.json"
( cd "$TMPROOT/multi" && git add -A && git commit -qm evidence )
WT5="$TMPROOT/wt5"
if wtn_create "$TMPROOT/multi" worktree-t5 "$WT5" HEAD >/dev/null 2>&1; then
  if [[ ! -e "$WT5/docs" && ! -e "$WT5/evidence/log.json" ]]; then ok "multiple excludes applied"
  else bad "multiple excludes applied" "docs/evidence still present"; fi
else
  bad "wtn_create on multi-exclude repo" "create failed"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

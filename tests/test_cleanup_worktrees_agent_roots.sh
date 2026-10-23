#!/usr/bin/env bash
# Worktrees under the extra agent roots (dwr_agent_roots) are discovered with no
# --repos override and swept under the unchanged gates, whatever they are named;
# a worktree outside those roots with a non-matching name is never listed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
TMP_ROOT=$(cd "$(mktemp -d -t cleanup_wt_agent_roots.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1)); fi; }
refute() { if grep -qF -- "$2" <<<"$3"; then echo "  FAIL  $1 (unexpected: $2)"; FAIL=$((FAIL+1)); else echo "  PASS  $1"; PASS=$((PASS+1)); fi; }
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
HOME_DIR="$TMP_ROOT/home"; REPO="$HOME_DIR/main-repo"; mkdir -p "$HOME_DIR" "$TMP_ROOT/bin"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git -C "$REPO" init -q -b main 2>/dev/null || { mkdir -p "$REPO"; git -C "$REPO" init -q -b main; }
git -C "$REPO" config user.email f@users.noreply.github.com
git -C "$REPO" config user.name F
printf 'base\n' > "$REPO/README.md"; git -C "$REPO" add README.md; git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"; git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b ahead; printf 'ahead\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" checkout -q main
add_wt() {  # <branch> <path>: pushed, aged 4d
  mkdir -p "$(dirname "$2")"
  git -C "$REPO" worktree add -q -B "$1" "$2" "$AHEAD_SHA"; git -C "$REPO" push -q origin "$1"
  age_days_ago "$2" 4
}
ROOTS_WT=("wc-wt/advice-x" "llm_wiki.worktrees/clean-x" "project_agento/wa-techdebt" \
  "project_worldai_frontend/wf-x" "worldarchitect.ai.worktrees/pr-x")
i=0; for rel in "${ROOTS_WT[@]}"; do i=$((i+1)); add_wt "b$i" "$HOME_DIR/$rel"; done
add_wt dirty "$HOME_DIR/wc-wt/dirty-x"; printf 'x\n' >> "$HOME_DIR/wc-wt/dirty-x/README.md"; age_days_ago "$HOME_DIR/wc-wt/dirty-x" 4
add_wt outside "$HOME_DIR/elsewhere/plain-x"
cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
printf 'p1\nn/\n'
SH
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"
OUT="$(env -i HOME="$HOME_DIR" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" WORKTREE_MIN_AGE_DAYS=3 \
  HERMES_SKIP_EXAMPLE_COM_GUARD=1 bash "$CLEANUP_SCRIPT" --dry-run 2>&1)"
for rel in "${ROOTS_WT[@]}"; do
  check "clean pushed worktree under ${rel%%/*} is ELIGIBLE" "ELIGIBLE  $HOME_DIR/$rel |" "$OUT"
done
check "dirty worktree under an agent root stays preserved" "dirty-x | dirty" "$OUT"
refute "non-matching worktree outside the agent roots is not listed" "plain-x" "$OUT"
echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

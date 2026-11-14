#!/usr/bin/env bash
# Default worktree recency floor is 48 h (operator decision 2026-11-12, Jeffrey: "Make this
# default 48hr"; supersedes the 3 d / 7 d floors). Config and CLI may only RAISE it; an
# unmeasurable worktree stays kept. Every other removal gate is covered by sibling tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktrees.sh"
SAFETY_LIB="$SCRIPT_DIR/../scripts/safety_lib.sh"
TMP_ROOT=$(cd "$(mktemp -d -t wt_floor48.XXXXXX)" && pwd -P)
trap 'chmod -R u+rwx "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (missing: $2)"; FAIL=$((FAIL+1)); fi; }
eq() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (got '$3', want '$2')"; FAIL=$((FAIL+1)); fi; }
age_hours_ago() {
  local wt="$1" hours="$2" ts gitdir
  if ! ts=$(date -v-"${hours}"H +%Y%m%d%H%M 2>/dev/null); then
    ts=$(date -d "${hours} hours ago" +%Y%m%d%H%M)
  fi
  /usr/bin/find "$wt" -name .git -prune -o -exec touch -h -t "$ts" {} +
  touch -t "$ts" "$wt/.git"
  gitdir=$(sed -n 's/^gitdir: *//p' "$wt/.git" | head -1)
  /usr/bin/find "$gitdir" -exec touch -t "$ts" {} +
}
export HERMES_SKIP_EXAMPLE_COM_GUARD=1

echo "== safety_worktree_floor_minutes =="
floor_with() {  # floor_with '<json>' -> minutes (empty json = no config file at all)
  local f="$TMP_ROOT/safety.json"
  printf '%s' "$1" > "$f"
  env -i HOME="$TMP_ROOT/nohome" PATH="$PATH" DISK_MAGICIAN_SAFETY_FILE="$f" bash -c "source '$SAFETY_LIB'; safety_worktree_floor_minutes"
}
eq "default config: 2880" 2880 "$(floor_with '{}')"
eq "template-like min_stale_days=7 does not raise" 2880 "$(floor_with '{"min_stale_days": 7}')"
eq "worktree_min_stale_days=7 honored (10080)" 10080 "$(floor_with '{"worktree_min_stale_days": 7}')"
eq "legacy min_stale_days=14 honored" 20160 "$(floor_with '{"min_stale_days": 14}')"
eq "worktree_min_stale_hours=72 honored" 4320 "$(floor_with '{"worktree_min_stale_hours": 72}')"
eq "worktree_min_stale_days=1 ignored (never below 48 h)" 2880 "$(floor_with '{"worktree_min_stale_days": 1}')"
eq "worktree_min_stale_hours=12 ignored" 2880 "$(floor_with '{"worktree_min_stale_hours": 12}')"
eq "malformed config falls back to 2880" 2880 "$(floor_with '{not json')"
eq "no config file: 2880" 2880 "$(env -i HOME="$TMP_ROOT/nohome" PATH="$PATH" bash -c "source '$SAFETY_LIB'; _SAFETY_REPO_ROOT='$TMP_ROOT/none'; safety_worktree_floor_minutes")"
eq "resolve: --min-age 0 cannot lower" 2880 "$(env -i PATH="$PATH" bash -c "source '$SAFETY_LIB'; worktree_floor_resolve_minutes 2880 0")"
eq "resolve: --min-age 08 (octal-looking) raises to 8 d" 11520 "$(env -i PATH="$PATH" bash -c "source '$SAFETY_LIB'; worktree_floor_resolve_minutes 2880 08")"

echo "== cleanup_worktrees.sh dry-run =="
REPO="$TMP_ROOT/repo"; WT="$REPO/.claude/worktrees"; mkdir -p "$WT"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email f@users.noreply.github.com
git -C "$REPO" config user.name F
printf '.venv/\nnode_modules/\n' > "$REPO/.gitignore"
printf 'base\n' > "$REPO/README.md"; mkdir -p "$REPO/docs"; printf 'doc\n' > "$REPO/docs/a.md"
git -C "$REPO" add .gitignore README.md docs; git -C "$REPO" commit -q -m base
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b ahead; printf 'ahead\n' >> "$REPO/README.md"; git -C "$REPO" commit -q -am ahead
AHEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q origin ahead
git -C "$REPO" checkout -q main
add_wt() { git -C "$REPO" worktree add -q -B "$1" "$2" "$AHEAD_SHA"; git -C "$REPO" push -q origin "$1"; }
add_wt h47 "$WT/wt-h47"; add_wt h49 "$WT/wt-h49"; add_wt d8 "$WT/wt-d8"; add_wt unmeas "$WT/wt-unmeas"
age_hours_ago "$WT/wt-h47" 47
age_hours_ago "$WT/wt-h49" 49
age_hours_ago "$WT/wt-d8" 192
age_hours_ago "$WT/wt-unmeas" 192
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/lsof" <<'SH'
#!/bin/sh
case "$*" in *+D*) exit 1 ;; esac
printf 'p1\nn/\n'
SH
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$TMP_ROOT/bin/timeout"
chmod +x "$TMP_ROOT/bin/lsof" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/timeout"
# No WORKTREE_MIN_AGE_DAYS: the 48 h default is under test. SAFETY is the config file in force.
run() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_SAFETY_FILE="$TMP_ROOT/safety.json" "$@" bash "$CLEANUP_SCRIPT" --dry-run --repos "$REPO" 2>&1; }

printf '{}' > "$TMP_ROOT/safety.json"
[[ "$(id -u)" -eq 0 ]] || chmod 000 "$WT/wt-unmeas"
OUT="$(run)"
chmod 755 "$WT/wt-unmeas"
check "default: 47h-idle clean pushed worktree is kept (young)" "wt-h47 | young" "$OUT"
check "default: 49h-idle clean pushed worktree is ELIGIBLE" "ELIGIBLE  $WT/wt-h49 |" "$OUT"
check "default: 8d-idle worktree is ELIGIBLE" "ELIGIBLE  $WT/wt-d8 |" "$OUT"
[[ "$(id -u)" -eq 0 ]] || check "default: unmeasurable worktree is kept" "PRESERVE  $WT/wt-unmeas |" "$OUT"
check "banner reports the 48h floor" "others: 48h" "$OUT"

OUT="$(run WORKTREE_MIN_AGE_DAYS=0)"
check "WORKTREE_MIN_AGE_DAYS=0 cannot lower the floor" "wt-h47 | young" "$OUT"

printf '{"worktree_min_stale_days": 7}' > "$TMP_ROOT/safety.json"
OUT="$(run)"
check "config 7d: 49h-idle worktree becomes young" "wt-h49 | young" "$OUT"
check "config 7d: 8d-idle worktree stays ELIGIBLE" "ELIGIBLE  $WT/wt-d8 |" "$OUT"

printf '{"worktree_min_stale_days": 1}' > "$TMP_ROOT/safety.json"
OUT="$(run)"
check "config 1d is ignored: 47h still young" "wt-h47 | young" "$OUT"
check "config 1d is ignored: 49h still ELIGIBLE" "ELIGIBLE  $WT/wt-h49 |" "$OUT"

printf '{}' > "$TMP_ROOT/safety.json"
OUT="$(run DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12)"
check "env DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=12 override still lowers" "ELIGIBLE  $WT/wt-h47 |" "$OUT"

echo "== sibling cleaners: deps, venvs, slim =="
add_wt s47 "$WT/wt-s47"; add_wt s49 "$WT/wt-s49"
for w in s47 s49; do
  mkdir -p "$WT/wt-$w/node_modules/pkg" "$WT/wt-$w/.venv/lib"
  printf 'x\n' > "$WT/wt-$w/node_modules/pkg/i.js"
  printf 'home = /usr/bin\n' > "$WT/wt-$w/.venv/pyvenv.cfg"
done
age_hours_ago "$WT/wt-s47" 47
age_hours_ago "$WT/wt-s49" 49
sib() { env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin" HERMES_SKIP_EXAMPLE_COM_GUARD=1 DISK_MAGICIAN_SAFETY_FILE="$TMP_ROOT/safety.json" DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state" DISK_MAGICIAN_LOAD5_OVERRIDE=0.1 "$@" 2>&1; }
OUT="$(sib bash "$SCRIPT_DIR/../scripts/cleanup_worktree_deps.sh" --dry-run --roots "$WT")"
check "deps: banner reports 48h" "floor 48h" "$OUT"
check "deps: 49h worktree node_modules would strip" "WOULD-STRIP" "$OUT"
check "deps: 49h worktree is the one stripped" "wt-s49/node_modules" "$OUT"
[[ "$OUT" != *"wt-s47/node_modules"* ]] && { echo "  PASS  deps: 47h worktree kept"; PASS=$((PASS+1)); } || { echo "  FAIL  deps: 47h worktree listed"; FAIL=$((FAIL+1)); }

OUT="$(sib bash "$SCRIPT_DIR/../scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$WT")"
check "venvs: 49h worktree venv would strip at the default 48h floor" "would strip $WT/wt-s49/.venv" "$OUT"
[[ "$OUT" != *"would strip $WT/wt-s47/.venv"* ]] && { echo "  PASS  venvs: 47h worktree kept"; PASS=$((PASS+1)); } || { echo "  FAIL  venvs: 47h worktree listed"; FAIL=$((FAIL+1)); }

printf '{"worktree_min_stale_days": 7}' > "$TMP_ROOT/safety.json"
OUT="$(sib bash "$SCRIPT_DIR/../scripts/cleanup_worktree_venvs.sh" --dry-run --roots "$WT")"
[[ "$OUT" != *"would strip $WT/wt-s49/.venv"* ]] && { echo "  PASS  venvs: configured 7d floor keeps 49h worktree"; PASS=$((PASS+1)); } || { echo "  FAIL  venvs: configured 7d floor listed 49h worktree"; FAIL=$((FAIL+1)); }
printf '{"worktree_min_stale_days": 1}' > "$TMP_ROOT/safety.json"

OUT="$(sib bash "$SCRIPT_DIR/../scripts/slim_worktree_checkouts.sh" --dry-run --roots "$WT")"
check "slim: banner reports 48h" "floor 48h" "$OUT"
check "slim: 49h worktree would slim" "WOULD-SLIM" "$OUT"
check "slim: 49h worktree listed" "wt-s49" "$OUT"
[[ "$OUT" != *"WOULD-SLIM"*"wt-s47"* ]] && { echo "  PASS  slim: 47h worktree kept"; PASS=$((PASS+1)); } || { echo "  FAIL  slim: 47h worktree listed"; FAIL=$((FAIL+1)); }

echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]

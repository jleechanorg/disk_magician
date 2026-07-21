#!/usr/bin/env bash
# test_history_diff_dispatch.sh — dispatcher wiring for `history diff [ref]`
# (sandboxed: fixture STATE_DIR via DISK_MAGICIAN_STATE_REPO, no real $HOME).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DM="$REPO_ROOT/disk_magician.sh"
TMP_ROOT=$(mktemp -d -t history_diff_dispatch.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/ledger"
git -C "$STATE" init -q -b main 2>/dev/null \
  || { git -C "$STATE" init -q && git -C "$STATE" symbolic-ref HEAD refs/heads/main; }
gib=$((1024*1024))
cat > "$STATE/ledger/topdown-5g.json" <<EOF
{"schema_version":1,"disk_used_kb":$((4*gib)),"residual_kb":0,
 "residual_label":"t","buckets":[{"path":"/a","measured_kb":$((4*gib))}]}
EOF
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm base
cat > "$STATE/ledger/topdown-5g.json" <<EOF
{"schema_version":1,"disk_used_kb":$((8*gib)),"residual_kb":0,
 "residual_label":"t","buckets":[{"path":"/a","measured_kb":$((4*gib))},
 {"path":"/fixture_growth","measured_kb":$((4*gib))}]}
EOF
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm grown

echo "Test 1: history diff (no ref) names the grown bucket first, residual last"
OUT=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
      DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff 2>&1)
RC=$?
[[ $RC -eq 0 ]] && ok "dispatch exits 0" || bad "dispatch rc" "$RC: $OUT"
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$OUT")
[[ "$FIRST_LINE" == *"/fixture_growth"* ]] && ok "grown bucket is the top line" \
  || bad "top line" "$FIRST_LINE"
[[ "$LAST_LINE" == "residual delta: +0.00 GiB" ]] && ok "residual delta is the last line" \
  || bad "last line" "$LAST_LINE"

echo "Test 2: history diff HEAD (explicit ref) still routes to history_diff.py"
OUT2=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
       DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff HEAD 2>&1)
[[ "$OUT2" == "residual delta: +0.00 GiB" ]] && ok "diff HEAD == HEAD is empty + residual line" \
  || bad "diff HEAD" "$OUT2"

echo "Test 3: bare 'history' (no diff) still falls through to disk_history.sh"
OUT3=$(env -i HOME="$TMP_ROOT/home2" PATH="/usr/bin:/bin" "$DM" history 2>&1)
echo "$OUT3" | grep -qi "history_diff" && bad "bare history unaffected" "leaked into history_diff: $OUT3" \
  || ok "bare history is not rerouted"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

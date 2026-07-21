#!/usr/bin/env bash
# test_state_repo.sh — lifecycle tests for scripts/state_repo.sh (sandboxed).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SR="$REPO_ROOT/scripts/state_repo.sh"
TMP_ROOT=$(mktemp -d -t state_repo_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
run_sr() { # run_sr <home> <fake_bin_or_-> <args...>
  local home="$1" fb="$2"; shift 2
  local path="/usr/bin:/bin"
  [[ "$fb" != "-" ]] && path="$fb:$path"
  env -i HOME="$home" PATH="$path" bash "$SR" "$@"
}

echo "Test 1: init creates a git state repo with MACHINE marker at XDG default"
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
OUT1=$(run_sr "$H1" - init 2>&1); RC1=$?
SD1="$H1/.local/state/disk-magician"
[[ $RC1 -eq 0 ]] && ok "init exits 0" || bad "init exits 0" "rc=$RC1: $OUT1"
[[ -d "$SD1/.git" ]] && ok "git repo created" || bad "git repo created" "no $SD1/.git"
[[ -f "$SD1/MACHINE" ]] && ok "MACHINE marker written" || bad "MACHINE marker" "missing"
C1=$(git -C "$SD1" rev-list --count HEAD 2>/dev/null)
[[ "$C1" == "1" ]] && ok "first commit exists" || bad "first commit" "count=$C1"
echo "$OUT1" | grep -q "local-only" && ok "reports local-only (no gh)" || bad "local-only report" "$OUT1"

echo "Test 2: second init adopts (no new commit), status reports"
OUT2=$(run_sr "$H1" - init 2>&1)
C2=$(git -C "$SD1" rev-list --count HEAD)
[[ "$C2" == "1" ]] && ok "re-init makes no new commit" || bad "idempotent init" "count=$C2"
echo "$OUT2" | grep -q "adopted existing" && ok "reports adoption" || bad "adoption report" "$OUT2"
OUT2b=$(run_sr "$H1" - status 2>&1); RC2b=$?
[[ $RC2b -eq 0 ]] && ok "status exits 0" || bad "status rc" "$RC2b"
echo "$OUT2b" | grep -q "$SD1" && ok "status names the state dir" || bad "status dir" "$OUT2b"
echo "$OUT2b" | grep -qi "remote: none" && ok "status shows no remote" || bad "status remote" "$OUT2b"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

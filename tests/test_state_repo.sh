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
  # env -i wipes the outer shell's environment (by design, for sandboxing);
  # forward the two prompt-override vars explicitly so callers can drive
  # init's non-interactive accept/decline path from outside this function.
  env -i HOME="$home" PATH="$path" \
    ${DISK_MAGICIAN_ASSUME_YES:+DISK_MAGICIAN_ASSUME_YES=$DISK_MAGICIAN_ASSUME_YES} \
    ${DISK_MAGICIAN_ASSUME_NO:+DISK_MAGICIAN_ASSUME_NO=$DISK_MAGICIAN_ASSUME_NO} \
    bash "$SR" "$@"
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

echo "Test 3: gh present + accept -> creates repo and sets origin"
H3="$TMP_ROOT/h3"; FB3="$TMP_ROOT/fb3"; mkdir -p "$H3" "$FB3"
GH_LOG="$TMP_ROOT/gh3.log"
cat > "$FB3/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
case "\$1" in
  auth) exit 0 ;;
  repo) exit 0 ;;
esac
exit 0
EOF
chmod +x "$FB3/gh"
OUT3=$(DISK_MAGICIAN_ASSUME_YES=1 run_sr "$H3" "$FB3" init 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "init+offer exits 0" || bad "offer rc" "$RC3: $OUT3"
grep -q "repo create" "$GH_LOG" && ok "gh repo create invoked" || bad "gh repo create" "$(cat "$GH_LOG")"
echo "$OUT3" | grep -q "origin" && ok "reports origin wiring" || bad "origin report" "$OUT3"

echo "Test 4: decline is recorded and never re-asked"
H4="$TMP_ROOT/h4"; mkdir -p "$H4"
OUT4=$(DISK_MAGICIAN_ASSUME_NO=1 run_sr "$H4" "$FB3" init 2>&1)
SD4="$H4/.local/state/disk-magician"
[[ -f "$SD4/.offer-declined" ]] && ok "decline marker written" || bad "decline marker" "missing"
OUT4b=$(DISK_MAGICIAN_ASSUME_YES=1 run_sr "$H4" "$FB3" init 2>&1)
echo "$OUT4b" | grep -qi "declined earlier" && ok "no re-nag after decline" || bad "re-nag" "$OUT4b"

echo "Test 5: no gh on PATH -> silent local-only, no crash"
H5="$TMP_ROOT/h5"; mkdir -p "$H5"
OUT5=$(run_sr "$H5" - init 2>&1); RC5=$?
[[ $RC5 -eq 0 ]] && ok "no-gh init exits 0" || bad "no-gh rc" "$RC5"
echo "$OUT5" | grep -q "local-only" && ok "no-gh reports local-only" || bad "no-gh report" "$OUT5"

echo "Test 6: remote <url> wires origin; push publishes commits"
H6="$TMP_ROOT/h6"; mkdir -p "$H6"
BARE6="$TMP_ROOT/bare6.git"; git init -q --bare "$BARE6"
run_sr "$H6" - init >/dev/null 2>&1
SD6="$H6/.local/state/disk-magician"
run_sr "$H6" - remote "$BARE6" >/dev/null 2>&1; RC6=$?
[[ $RC6 -eq 0 ]] && ok "remote cmd exits 0" || bad "remote rc" "$RC6"
[[ "$(git -C "$SD6" remote get-url origin)" == "$BARE6" ]] && ok "origin set" || bad "origin" "$(git -C "$SD6" remote get-url origin 2>&1)"
run_sr "$H6" - push >/dev/null 2>&1; RC6b=$?
[[ $RC6b -eq 0 ]] && ok "push exits 0" || bad "push rc" "$RC6b"
[[ "$(git -C "$BARE6" rev-list --count HEAD 2>/dev/null)" == "1" ]] && ok "commit on remote" || bad "remote commits" "none"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

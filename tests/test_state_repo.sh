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
BARE6="$TMP_ROOT/bare6.git"; git init -q --bare --initial-branch=main "$BARE6"
INIT6=$(run_sr "$H6" - init 2>&1) || { echo "init6 failed: $INIT6"; }
SD6="$H6/.local/state/disk-magician"
run_sr "$H6" - remote "$BARE6" >/dev/null 2>&1; RC6=$?
[[ $RC6 -eq 0 ]] && ok "remote cmd exits 0" || bad "remote rc" "$RC6"
[[ "$(git -C "$SD6" remote get-url origin)" == "$BARE6" ]] && ok "origin set" || bad "origin" "$(git -C "$SD6" remote get-url origin 2>&1)"
run_sr "$H6" - push >/dev/null 2>&1; RC6b=$?
[[ $RC6b -eq 0 ]] && ok "push exits 0" || bad "push rc" "$RC6b"
[[ "$(git -C "$BARE6" rev-list --count HEAD 2>/dev/null)" == "1" ]] && ok "commit on remote" || bad "remote commits" "none"

echo "Test 7: disk_magician.sh routes 'state' to state_repo.sh"
H7="$TMP_ROOT/h7"; mkdir -p "$H7"
OUT7=$(env -i HOME="$H7" PATH="/usr/bin:/bin" bash "$REPO_ROOT/disk_magician.sh" state init 2>&1); RC7=$?
[[ $RC7 -eq 0 ]] && ok "dispatcher state init exits 0" || bad "dispatcher rc" "$RC7: $OUT7"
[[ -f "$H7/.local/state/disk-magician/MACHINE" ]] && ok "dispatcher created state repo" || bad "dispatcher create" "missing"

echo "Test 8: MACHINE marker without .git — init re-inits instead of crashing"
H8="$TMP_ROOT/h8"; SD8="$H8/.local/state/disk-magician"; mkdir -p "$SD8"
printf 'hostname: x\n' > "$SD8/MACHINE"
OUT8=$(run_sr "$H8" - init 2>&1); RC8=$?
[[ $RC8 -eq 0 ]] && ok "corrupt-adopt init exits 0" || bad "corrupt-adopt rc" "$RC8: $OUT8"
[[ -d "$SD8/.git" ]] && ok "git re-initialized" || bad "git re-init" "missing .git"

echo "Test 9: gh fallback with failing 'gh api user' never wires a guessed origin"
H9="$TMP_ROOT/h9"; FB9="$TMP_ROOT/fb9"; mkdir -p "$H9" "$FB9"
cat > "$FB9/gh" <<'EOF9'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api)  exit 1 ;;
  repo) exit 1 ;;
esac
exit 1
EOF9
chmod +x "$FB9/gh"
OUT9=$(DISK_MAGICIAN_ASSUME_YES=1 run_sr "$H9" "$FB9" init 2>&1); RC9=$?
SD9="$H9/.local/state/disk-magician"
[[ $RC9 -eq 0 ]] && ok "failed-create init exits 0" || bad "failed-create rc" "$RC9"
git -C "$SD9" remote get-url origin >/dev/null 2>&1 && bad "no guessed origin" "origin was set: $(git -C "$SD9" remote get-url origin)" || ok "no guessed origin wired"
echo "$OUT9" | grep -q "local-only" && ok "reports local-only on create failure" || bad "failure report" "$OUT9"

echo "Test 10: conflicting divergence — push fails safely, both sides intact, no mid-rebase state"
H10="$TMP_ROOT/h10"; mkdir -p "$H10"
BARE10="$TMP_ROOT/bare10.git"; git init -q --bare --initial-branch=main "$BARE10"
INIT10=$(run_sr "$H10" - init 2>&1) || { echo "init10 failed: $INIT10"; }
SD10="$H10/.local/state/disk-magician"
run_sr "$H10" - remote "$BARE10" >/dev/null 2>&1
run_sr "$H10" - push >/dev/null 2>&1
git clone -q "$BARE10" "$TMP_ROOT/other10"
( cd "$TMP_ROOT/other10" && echo remote-side > MACHINE && git -c user.email=o@o -c user.name=o commit -qam remote-conflict && git push -q )
REMOTE_HEAD=$(git -C "$BARE10" rev-parse HEAD)
( cd "$SD10" && echo local-side > MACHINE && git -c user.email=a@a -c user.name=a commit -qam local-conflict )
run_sr "$H10" - push >/dev/null 2>&1; RC10=$?
[[ $RC10 -ne 0 ]] && ok "conflicted push exits nonzero" || bad "conflicted push rc" "rc=0"
[[ "$(git -C "$BARE10" rev-parse HEAD)" == "$REMOTE_HEAD" ]] && ok "remote history untouched" || bad "remote intact" "remote moved"
git -C "$SD10" log --format=%s | grep -q local-conflict && ok "local commit preserved" || bad "local preserved" "missing"
[[ ! -d "$SD10/.git/rebase-merge" && ! -d "$SD10/.git/rebase-apply" ]] && ok "no mid-rebase state" || bad "mid-rebase" "rebase dirs left"
[[ -n "$(git -C "$SD10" branch --show-current)" ]] && ok "still on a branch" || bad "on branch" "detached"

echo "Test 11: state_repo_path config key grandfathers an existing directory"
H11="$TMP_ROOT/h11"; mkdir -p "$H11"
LEGACY11="$TMP_ROOT/legacy11"; mkdir -p "$LEGACY11"
mkdir -p "$H11/.config/disk-magician"
python3 - "$H11/.config/disk-magician/config.json" "$LEGACY11" <<'PY'
import json, sys
json.dump({"state_repo_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
OUT11=$(run_sr "$H11" - init 2>&1); RC11=$?
[[ $RC11 -eq 0 ]] && ok "grandfathered init exits 0" || bad "grandfathered init rc" "$RC11: $OUT11"
[[ -f "$LEGACY11/MACHINE" ]] && ok "state repo created at the configured legacy dir" || bad "grandfathered dir" "missing MACHINE at $LEGACY11"
[[ ! -d "$H11/.local/state/disk-magician" ]] && ok "XDG default dir NOT created when grandfathered" || bad "no stray XDG dir" "found $H11/.local/state/disk-magician"

echo "Test 12: DISK_MAGICIAN_STATE_REPO env still wins over a configured state_repo_path"
H12="$TMP_ROOT/h12"; mkdir -p "$H12"
LEGACY12="$TMP_ROOT/legacy12"; ENVOVERRIDE12="$TMP_ROOT/envoverride12"
mkdir -p "$H12/.config/disk-magician"
python3 - "$H12/.config/disk-magician/config.json" "$LEGACY12" <<'PY'
import json, sys
json.dump({"state_repo_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
OUT12=$(env -i HOME="$H12" PATH="/usr/bin:/bin" DISK_MAGICIAN_STATE_REPO="$ENVOVERRIDE12" bash "$SR" init 2>&1); RC12=$?
[[ $RC12 -eq 0 ]] && ok "env-override init exits 0" || bad "env-override rc" "$RC12: $OUT12"
[[ -f "$ENVOVERRIDE12/MACHINE" ]] && ok "env override beats configured state_repo_path" || bad "env override" "missing MACHINE at $ENVOVERRIDE12"
[[ ! -d "$LEGACY12" || ! -f "$LEGACY12/MACHINE" ]] && ok "configured legacy dir untouched by env override" || bad "legacy untouched" "unexpectedly initialized $LEGACY12"

echo "Test 13: 'disk_magician.sh snapshot' routes through snapshot_commit.sh (new layout)"
H13="$TMP_ROOT/h13"; mkdir -p "$H13"
STUB13="$TMP_ROOT/stub13"; mkdir -p "$STUB13"
cat > "$STUB13/snap.sh" <<'EOF'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in --output) out="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$(dirname "$out")"; printf '{"schema_version":2}\n' > "$out"
EOF
chmod +x "$STUB13/snap.sh"
OUT13=$(env -i HOME="$H13" PATH="/usr/bin:/bin" DISK_MAGICIAN_SNAPSHOT_BIN="$STUB13/snap.sh" \
  bash "$REPO_ROOT/disk_magician.sh" snapshot 2>&1); RC13=$?
[[ $RC13 -eq 0 ]] && ok "dispatcher snapshot exits 0" || bad "dispatcher snapshot rc" "$RC13: $OUT13"
[[ -f "$H13/.local/state/disk-magician/snapshots/disk_snapshot.json" ]] && ok "snapshot in new-layout state repo" || bad "new-layout snapshot" "missing"

echo "Test 12: push to a PUBLIC github origin is refused (confidentiality guard, jleechan-v78q)"
HVIS="$TMP_ROOT/hvis"; FBVIS="$TMP_ROOT/fbvis"; mkdir -p "$HVIS" "$FBVIS"
BAREVIS="$TMP_ROOT/barevis.git"; git init -q --bare --initial-branch=main "$BAREVIS"
# fake gh reporting the repo is PUBLIC
cat > "$FBVIS/gh" <<'EOF12'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo "public" ;;
  *) exit 0 ;;
esac
EOF12
chmod +x "$FBVIS/gh"
run_sr "$HVIS" - init >/dev/null 2>&1
SDVIS="$HVIS/.local/state/disk-magician"
# wire a github.com origin so the visibility guard engages
git -C "$SDVIS" remote add origin https://github.com/jleechan2015/disk-magician-state-h12.git 2>/dev/null ||   git -C "$SDVIS" remote set-url origin https://github.com/jleechan2015/disk-magician-state-h12.git
OUTVIS=$(env -i HOME="$HVIS" PATH="$FBVIS:/usr/bin:/bin" bash "$SR" push 2>&1); RCVIS=$?
[[ $RCVIS -ne 0 ]] && ok "public-origin push refused (nonzero)" || bad "public refused" "rc=0: $OUTVIS"
echo "$OUTVIS" | grep -qi "public\|private\|visibility" && ok "explains the visibility refusal" || bad "visibility message" "$OUTVIS"

echo "Test 13: DISK_MAGICIAN_ALLOW_PUBLIC_STATE=1 overrides the public refusal"
OUTVISB=$(env -i HOME="$HVIS" PATH="$FBVIS:/usr/bin:/bin" DISK_MAGICIAN_ALLOW_PUBLIC_STATE=1 bash "$SR" push 2>&1); RCVISB=$?
# origin is a bogus URL so the actual push fails, but it must get PAST the visibility guard
echo "$OUTVISB" | grep -qi "public visibility refused\|refusing.*public" && bad "override bypasses guard" "still blocked: $OUTVISB" || ok "override bypasses the visibility guard"

echo "Test 14: non-github origin skips the visibility check (local bare remote pushes fine)"
HVIS2="$TMP_ROOT/hvis2"; mkdir -p "$HVIS2"
BAREVIS2="$TMP_ROOT/barevis2.git"; git init -q --bare --initial-branch=main "$BAREVIS2"
run_sr "$HVIS2" - init >/dev/null 2>&1
run_sr "$HVIS2" - remote "$BAREVIS2" >/dev/null 2>&1
OUTVIS2=$(run_sr "$HVIS2" - push 2>&1); RCVIS2=$?
[[ $RCVIS2 -eq 0 ]] && ok "non-github push not blocked by visibility guard" || bad "non-github push" "rc=$RCVIS2: $OUTVIS2"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

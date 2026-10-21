#!/usr/bin/env bash
# test_git_shim_admit.sh — tools/guards/git.patch + apply_git_admit.sh (plan Task B2, spec 7.6 door 1).
# The fixture shim (tests/fixtures/guards) is the base the patch was cut from; the live shim is never
# touched. The scratch root sits under $HOME because the shim passes every temp-space HOME/cwd straight
# through to git, which would hide the admission call.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$REPO_ROOT/tools/guards/apply_git_admit.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

REALHOME="$HOME"
R="$(mktemp -d "$REALHOME/.dm-shim-test.XXXXXX")"
trap '[[ "$R" == "$REALHOME"/.dm-shim-test.* ]] && rm -rf "$R"' EXIT
mkdir -p "$R/bin" "$R/home/.worktrees/repo" "$R/home/src"
cp "$REPO_ROOT/tests/fixtures/guards/git" "$REPO_ROOT/tests/fixtures/guards/_guard_lib.sh" "$R/bin/"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL=/opt/homebrew/bin/git; [[ -x "$REAL" ]] || REAL=/usr/bin/git
"$REAL" init -q -b main "$R/home/src/repo" && "$REAL" -C "$R/home/src/repo" commit -q --allow-empty -m init

echo "== fixture is the patch base =="
want="$(sed -n 's/^# base-sha256: //p' "$REPO_ROOT/tools/guards/git.patch")"
have="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$R/bin/git")"
assert_eq "$have" "$want" "fixture sha256 matches base-sha256"

echo "== apply_git_admit.sh gates =="
export DISK_MAGICIAN_POLICY_FILE="$R/policy.json"
cp "$R/bin/git" "$R/git.orig"
bash "$APPLY" --shim "$R/bin/git" >"$R/apply.out" 2>&1; assert_eq "$?" 75 "unrecorded external_edits refuses"
cmp -s "$R/bin/git" "$R/git.orig" && ok "refusal leaves the shim untouched" || bad "shim changed on refusal"
grep -q "^+admit_exec()" "$R/apply.out" && ok "refusal prints the patch" || bad "no diff printed"
echo '{"external_edits": {"id": "external_edits", "revoked_at": null}}' >"$DISK_MAGICIAN_POLICY_FILE"
cp "$R/bin/git" "$R/drifted"; echo "# local edit" >>"$R/drifted"
bash "$APPLY" --shim "$R/drifted" >/dev/null 2>"$R/apply.err"; assert_eq "$?" 75 "hash mismatch refuses"
grep -q "sha256" "$R/apply.err" && ok "hash mismatch names the reason" || bad "stderr: $(cat "$R/apply.err")"
bash "$APPLY" --shim "$R/bin/git" >/dev/null 2>&1; assert_eq "$?" 0 "recorded decision + matching hash applies"
cmp -s "$R/bin/git.pre-admit.bak" "$R/git.orig" && ok "backup kept" || bad "no backup"
[[ -x "$R/bin/git" ]] && ok "patched shim executable" || bad "patched shim not executable"
bash "$APPLY" --shim "$R/bin/git" 2>&1 | grep -q "already applied" && ok "second apply is a no-op" || bad "second apply did not detect the patch"

cat >"$R/bin/admit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$R/admit.log"
[[ "\$1" == --confirm ]] && exit 0
rc="\$(head -1 "$R/admit.rcs")"; sed -i.bak 1d "$R/admit.rcs"
[[ "\$rc" == 0 || "\$rc" == 10 ]] && echo "admit_id=abc123"
exit "\${rc:-0}"
EOF
chmod +x "$R/bin/admit"

# shim <rcs> <git args…> — runs the patched shim from the repo; sets RC, ERR, ADMITS, CONFIRMS
shim() {
    local rcs="$1"; shift
    : >"$R/admit.log"; tr ' ' '\n' <<<"$rcs" >"$R/admit.rcs"
    (cd "$R/home/src/repo" && HOME="$R/home" DISK_MAGICIAN_ADMIT_BIN="${ADMIT_BIN:-$R/bin/admit}" \
        DISK_MAGICIAN_ADMIT_RETRY_S=0 bash "$R/bin/git" "$@" >/dev/null 2>"$R/err")
    RC=$?; ERR="$(cat "$R/err")"
    ADMITS="$(grep -vc -- '^--confirm' "$R/admit.log")"; CONFIRMS="$(grep -c -- '^--confirm' "$R/admit.log")"
}
wt() { echo "$R/home/.worktrees/repo/$1"; }

echo "== git worktree add: admit exit-code matrix =="
shim 0 worktree add -q "$(wt w0)"
assert_eq "$RC/$ADMITS/$CONFIRMS" "0/1/1" "0: created, admitted once, confirmed"
[[ -d "$(wt w0)" ]] && ok "0: worktree exists" || bad "0: no worktree"
grep -q -- "--class worktrees --producer git-shim --dest $(wt w0) --source shim" "$R/admit.log" && ok "admit args" || bad "args: $(cat "$R/admit.log")"
grep -q -- "--est-gb" "$R/admit.log" && bad "caller passed --est-gb" || ok "estimate left to the calibrated producer estimate"
shim 10 worktree add -q "$(wt w10)"
assert_eq "$RC" 0 "10: rc"; [[ -d "$(wt w10)" ]] && ok "10: created" || bad "10: no worktree"
grep -q "disk-admission: warn class=worktrees" <<<"$ERR" && ok "10: warning line" || bad "10 stderr: $ERR"
shim 75 worktree add -q "$(wt w75)"
assert_eq "$RC/$CONFIRMS" "75/0" "75: refused, nothing confirmed"
[[ ! -e "$(wt w75)" ]] && ok "75: no worktree" || bad "75: worktree created"
grep -q "disk-admission: refused class=worktrees" <<<"$ERR" && ok "75: refusal line" || bad "75 stderr: $ERR"
shim "76 0" worktree add -q "$(wt w760)"
assert_eq "$RC/$ADMITS" "0/2" "76 then 0: created after one wait"
[[ -d "$(wt w760)" ]] && ok "76 then 0: worktree exists" || bad "76 then 0: no worktree"
shim "76 76" worktree add -q "$(wt w7676)"
assert_eq "$RC/$ADMITS" "75/2" "76 then 76: refused"
[[ ! -e "$(wt w7676)" ]] && ok "76 then 76: no worktree" || bad "76 then 76: worktree created"
ADMIT_BIN="$R/bin/missing" shim 75 worktree add -q "$(wt wmiss)"
assert_eq "$RC" 0 "missing admit: rc"; [[ -d "$(wt wmiss)" ]] && ok "missing admit: created" || bad "missing admit: no worktree"
grep -q "admission_degraded:caller" <<<"$ERR" && ok "missing admit: degraded line" || bad "missing admit stderr: $ERR"
DISK_MAGICIAN_WORKTREE_GUARD=off shim 75 worktree add -q "$(wt woff)"
assert_eq "$RC/$ADMITS" "0/0" "guard off bypasses admission"
shim 75 worktree add -q "$R/home/outside/w"
assert_eq "$RC/$ADMITS" "2/0" "placement block still wins, no admit"

echo "== git clone into a governed root =="
shim 75 clone -q --depth 1 "file://$R/home/src/repo" "$(wt c75)"
assert_eq "$RC/$ADMITS" "75/1" "clone into ~/.worktrees refused at 75"
[[ ! -e "$(wt c75)" ]] && ok "refused clone not created" || bad "refused clone created"
shim 0 clone -q -b main "$R/home/src/repo" "$(wt c0)"
assert_eq "$RC/$CONFIRMS" "0/1" "clone admitted and confirmed"
grep -q -- "--class worktrees .*--dest $(wt c0) " "$R/admit.log" && ok "clone dest parsed past -b <value>" || bad "args: $(cat "$R/admit.log")"
shim 75 clone -q "$R/home/src/repo" "/tmp/dm-shim-clone-$$"
assert_eq "$RC/$ADMITS" "75/1" "clone into /tmp refused at 75"
grep -q -- "--class tmp_containers" "$R/admit.log" && ok "/tmp clone charged to tmp_containers" || bad "args: $(cat "$R/admit.log")"
shim 75 clone -q "$R/home/src/repo" "$R/home/src/plain"
assert_eq "$RC/$ADMITS" "0/0" "clone outside governed roots: no admit"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

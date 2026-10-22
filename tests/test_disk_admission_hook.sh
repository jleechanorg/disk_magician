#!/usr/bin/env bash
# test_disk_admission_hook.sh — hooks/disk-admission.sh (plan Task 7, spec C6).
#
# Hook JSON is fed on stdin with a stub admit (DISK_MAGICIAN_ADMIT_BIN) that logs
# its argv and exits STUB_RC. State lives in a temp DISK_MAGICIAN_STATE_DIR.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/disk-admission.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/home/.worktrees/r" "$T/tmpdir" && ln -s "$T" "$T/alias"
export TMPDIR="$T/tmpdir" HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" DISK_MAGICIAN_ADMIT_BIN="$T/bin/admit" DISK_MAGICIAN_ADMIT_RETRY_S=0
if [[ "$(uname -s)" == Darwin ]]; then CANON_TMP=/private/tmp; else CANON_TMP=/tmp; fi
cat >"$T/bin/admit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/admit.log"
if [[ -s "$T/rcs" ]]; then rc="\$(head -1 "$T/rcs")"; sed -i.bak 1d "$T/rcs"; exit "\$rc"; fi
exit "\${STUB_RC:-0}"
EOF
chmod +x "$T/bin/admit"

# hook <event> <command> [tool_response json] — runs the hook; sets OUT, RC, ADMITS
hook() {
    : >"$T/admit.log"
    python3 - "$1" "$2" "${3:-null}" >"$T/in.json" <<'PY'
import json, sys
ev, cmd, resp = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = dict(session_id="s1", cwd="/repo", hook_event_name=ev, tool_name="Bash", tool_use_id="tu-1",
         tool_input=dict(command=cmd, description="d", timeout=600000, run_in_background=True, x_future=1))
if resp is not None: d["tool_response"] = resp
print(json.dumps(d))
PY
    OUT="$(bash "$HOOK" <"$T/in.json")"; RC=$?
    ADMITS="$(wc -l <"$T/admit.log" | tr -d ' ')"
}
valid() {  # empty, or valid PreToolUse output JSON with no updatedInput
    python3 - "$OUT" <<'PY'
import json, sys
s = sys.argv[1]
if not s.strip(): sys.exit(0)
d = json.loads(s)
assert set(d) <= {"systemMessage", "hookSpecificOutput", "continue", "suppressOutput"}, d
h = d.get("hookSpecificOutput", {})
assert set(h) <= {"hookEventName", "permissionDecision", "permissionDecisionReason"}, h
assert not h or (h["hookEventName"] == "PreToolUse" and h["permissionDecision"] in ("allow", "deny", "ask", "defer")), h
assert "updatedInput" not in s
PY
}
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(eval(sys.argv[2]))' "$OUT" "$1" 2>/dev/null; }
logged() { grep -q -- "$1" "$T/admit.log"; }

echo "── 1. governed forms: admit args, no output on rc 0 ──"
W="$T/home/.worktrees"
forms=(
  "git worktree add $W/r/n|worktrees|--dest $W/r/n|hook:git-worktree-add:repo"
  "cd /repo && git clone https://github.com/o/r.git $CANON_TMP/r/x|tmp_containers|--dest $CANON_TMP/r/x|hook:git-clone:github.com/o/r"
  "git -C $W/r/main worktree add ../n2|worktrees|--dest $W/r/n2|hook:git-worktree-add:main"
  "FOO=1 git clone git@github.com:o/r.git /tmp/r/y|tmp_containers|--dest $CANON_TMP/r/y|hook:git-clone:github.com/o/r"
  "cp -R a $W/r/z|worktrees|--dest $W/r/z|hook:cp-R"
)
for f in "${forms[@]}"; do
    IFS='|' read -r cmd cls dest prod <<<"$f"
    STUB_RC=0 hook PreToolUse "$cmd"
    assert_eq "$RC" 0 "exit 0: $cmd"; assert_eq "$OUT" "" "no output on admit 0"
    valid && ok "valid JSON" || bad "invalid output: $OUT"
    assert_eq "$ADMITS" 1 "admit called once"
    logged "--class $cls " && logged -- "$dest " && logged "--producer $prod " && logged "--source hook" && logged "--tool-use-id tu-1" \
        && ok "admit args ($cls, $prod)" || bad "admit args: $(cat "$T/admit.log")"
done

echo "── 2. decisions: 10 / 3 → systemMessage only; 75 / 76 → deny; never updatedInput ──"
STUB_RC=10 hook PreToolUse "git worktree add $W/r/n"
valid && ok "valid" || bad "invalid: $OUT"
assert_eq "$(field '"hookSpecificOutput" in d')" False "10: no permission decision"
[[ "$(field 'd["systemMessage"]')" == *warn* ]] && ok "10: systemMessage" || bad "10: $OUT"
STUB_RC=3 hook PreToolUse "git worktree add $W/r/n"
valid && ok "valid" || bad "invalid: $OUT"
assert_eq "$(field '"hookSpecificOutput" in d')" False "3: no permission decision"
[[ "$(field 'd["systemMessage"]')" == *admission_degraded:caller* ]] && ok "3: admission_degraded:caller" || bad "3: $OUT"
STUB_RC=75 hook PreToolUse "git worktree add $W/r/n"
valid && ok "valid" || bad "invalid: $OUT"
assert_eq "$(field 'd["hookSpecificOutput"]["permissionDecision"]')" deny "75: deny"
[[ "$(field 'd["hookSpecificOutput"]["permissionDecisionReason"]')" == *reuse* ]] && ok "75: reuse reason" || bad "75: $OUT"
STUB_RC=76 hook PreToolUse "git worktree add $W/r/n"
assert_eq "$(field 'd["hookSpecificOutput"]["permissionDecision"]')" deny "76: deny"
[[ "$(field 'd["hookSpecificOutput"]["permissionDecisionReason"]')" == *retry_after_s* ]] && ok "76: names retry_after_s" || bad "76: $OUT"
assert_eq "$ADMITS" 2 "76: one wait, one re-admit"
printf '76\n0\n' >"$T/rcs"; STUB_RC=75 hook PreToolUse "git worktree add $W/r/n"
assert_eq "$ADMITS/$OUT" "2/" "76 then 0: allowed silently after one wait"
assert_eq "$RC" 0 "deny still exits 0"
for rc in 0 3 10 75 76; do STUB_RC=$rc hook PreToolUse "git worktree add $W/r/n"
    [[ "$OUT" != *updatedInput* ]] && ok "rc $rc: no updatedInput" || bad "rc $rc: $OUT"; done

echo "── 3. compound vs single simple; PostToolUse confirm ──"
STUB_RC=0 hook PreToolUse "git clone bad-url $CANON_TMP/r/x || mkdir -p $CANON_TMP/r/x"
logged "--compound" && ok "|| compound flagged" || bad "compound: $(cat "$T/admit.log")"
STUB_RC=0 hook PreToolUse "cd /repo && git clone url $CANON_TMP/r/x"
logged "--compound" && ok "&& compound flagged" || bad "compound: $(cat "$T/admit.log")"
STUB_RC=0 hook PreToolUse "FOO=1 git clone url $CANON_TMP/r/y"
logged "--compound" && bad "env-prefixed simple flagged compound" || ok "env-prefixed is simple"
STUB_RC=0 hook PostToolUse "FOO=1 git clone url $CANON_TMP/r/y" '{"stdout":"","exit_code":0}'
assert_eq "$(cat "$T/admit.log")" "--confirm-tool-use tu-1" "simple exit 0 → confirm"; assert_eq "$OUT" "" "confirm prints nothing"
STUB_RC=0 hook PostToolUse "FOO=1 git clone url $CANON_TMP/r/y" '{"stdout":"","exit_code":128}'
assert_eq "$ADMITS" 0 "simple exit 128 → no confirm"
STUB_RC=0 hook PostToolUseFailure "FOO=1 git clone url $CANON_TMP/r/y" '{"exit_code":1}'
assert_eq "$ADMITS" 0 "PostToolUseFailure → no confirm"
for c in "git clone bad-url $CANON_TMP/r/x || mkdir -p $CANON_TMP/r/x" "cd /repo && git clone url $CANON_TMP/r/x" \
         "git clone url $CANON_TMP/r/x &"; do
    STUB_RC=0 hook PostToolUse "$c" '{"exit_code":0}'; assert_eq "$ADMITS" 0 "compound never confirmed: $c"
done

echo "── 4. ungoverned and unparsed → silent, admit not called ──"
for c in "ls -la" "git clone url /var/tmp/dm-hook-elsewhere/x" "cp -R a /opt/x" "git status"; do
    STUB_RC=0 hook PreToolUse "$c"; assert_eq "$ADMITS:$OUT" "0:" "ungoverned: $c"
done
assert_eq "$(grep -c hook_unparsed "$T/state/admission/events.jsonl" 2>/dev/null || echo 0)" 0 "no hook_unparsed yet"
n=0
for c in $'cat <<EOF\ngit clone url '$CANON_TMP$'/r/h\nEOF' $'true\ngit clone url '$CANON_TMP$'/r/n' \
         'echo $(git clone url '$CANON_TMP'/r/s)' 'echo `git clone url '$CANON_TMP'/r/b`' \
         'eval git clone url '$CANON_TMP'/r/e' '( git clone url '$CANON_TMP'/r/p )'; do
    STUB_RC=0 hook PreToolUse "$c"; n=$((n + 1))
    assert_eq "$ADMITS:$OUT:$RC" "0::0" "unparsed silent: ${c//$'\n'/\\n}"
    assert_eq "$(grep -c '"event": "hook_unparsed"' "$T/state/admission/events.jsonl")" "$n" "hook_unparsed +1"
done

echo "── 5. canonical dests, redirections, value options, copy into a dir ──"
mkdir -p "$CANON_TMP/dm-hook-test-$$"; R="$CANON_TMP/dm-hook-test-$$"
forms5=(
  "cp -R a $T/alias/tmpdir/x|tmpdir_scratch|--dest $T/tmpdir/x"
  "cp -R a /tmp/x|tmp_containers|--dest $CANON_TMP/x"
  "cp -R a /tmp/r/x 2>/dev/null|tmp_containers|--dest $CANON_TMP/r/x"
  "git clone url /tmp/r/x >log 2>&1|tmp_containers|--dest $CANON_TMP/r/x"
  "cp -R a $CANON_TMP/r/x &>/dev/null <in|tmp_containers|--dest $CANON_TMP/r/x"
  "cp -R a \$HOME/.worktrees/r/h|worktrees|--dest $W/r/h"
  "cp -R a ~/.worktrees/r/t|worktrees|--dest $W/r/t"
  "cp -a a $W/r/a|worktrees|--dest $W/r/a"
  "git clone --jobs 4 url /tmp/r/j|tmp_containers|--dest $CANON_TMP/r/j"
  "git --git-dir $W/r/main/.git worktree add $W/r/g|worktrees|--dest $W/r/g"
  "cp -R src $T/tmpdir/|tmpdir_scratch|--dest $T/tmpdir/src"
  "cp -R src /tmp/|tmp_containers|--dest $CANON_TMP/src"
  "cp -R src $R|tmp_containers|--dest $R/src"
)
for f in "${forms5[@]}"; do
    IFS='|' read -r cmd cls dest <<<"$f"
    STUB_RC=75 hook PreToolUse "$cmd"
    valid && ok "valid JSON" || bad "invalid output: $OUT"
    assert_eq "$ADMITS" 1 "admit called once: $cmd"
    logged "--class $cls " && logged -- "$dest " && ok "dest $dest" || bad "admit args for '$cmd': $(cat "$T/admit.log")"
    assert_eq "$(field 'd["hookSpecificOutput"]["permissionDecision"]')" deny "75 denies: $cmd"
done
rmdir "$R"

echo "== diskm setup --hooks installer (plan Task B1) =="
S="$T/settings"; mkdir -p "$S"
setup_hooks() { bash "$REPO_ROOT/disk_magician.sh" setup --hooks --settings "$1" >/dev/null 2>"$T/setup.err"; }
count_entries() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hooks"]; print(*[sum(h.get("command")=="diskm admission-hook" for g in d.get(e,[]) if g.get("matcher")=="Bash" for h in g["hooks"]) for e in ("PreToolUse","PostToolUse")])' "$1"; }
cat >"$S/three.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "diskm guard-worktree-add", "timeout": 10}]}],
    "WorktreeCreate": [{"hooks": [{"type": "command", "command": "diskm worktree-create-hook"}]}],
    "WorktreeRemove": [{"hooks": [{"type": "command", "command": "diskm worktree-remove-hook"}]}]
  },
  "model": "x"
}
JSON
cp "$S/three.json" "$S/three.orig"
export DISK_MAGICIAN_POLICY_FILE="$T/policy.json"; rm -f "$DISK_MAGICIAN_POLICY_FILE"
setup_hooks "$S/three.json"; assert_eq "$?" 75 "unrecorded external_edits refuses"
cmp -s "$S/three.json" "$S/three.orig" && ok "refusal leaves settings untouched" || bad "settings changed on refusal"
echo '{"external_edits": {"id": "external_edits", "revoked_at": null}}' >"$DISK_MAGICIAN_POLICY_FILE"
setup_hooks "$S/three.json"; assert_eq "$?" 0 "install rc"
assert_eq "$(count_entries "$S/three.json")" "1 1" "one Pre and one Post Bash entry"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); g=d["hooks"]["PreToolUse"][0]["hooks"]; assert g[0]["command"]=="diskm guard-worktree-add" and len(d["hooks"]["PreToolUse"])==1 and d["model"]=="x" and "WorktreeCreate" in d["hooks"]' "$S/three.json" \
    && ok "existing hooks and keys kept, entry joins the Bash group" || bad "existing content lost: $(cat "$S/three.json")"
cp "$S/three.json" "$S/three.once"
setup_hooks "$S/three.json"; assert_eq "$?" 0 "second run rc"
cmp -s "$S/three.json" "$S/three.once" && ok "second run byte-identical" || bad "second run changed the file"
echo '{"hooks": {}}' >"$S/empty.json"
setup_hooks "$S/empty.json"; assert_eq "$(count_entries "$S/empty.json")" "1 1" "empty hooks object gets both arrays"
echo '{"hooks": {"PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "diskm admission-hook"}]}]}}' >"$S/other.json"
setup_hooks "$S/other.json"; assert_eq "$(count_entries "$S/other.json")" "1 1" "a non-Bash matcher entry does not count as installed"
setup_hooks "$S/no-such-dir/settings.json"; assert_eq "$?" 2 "unwritable settings dir rc 2"
printf '{"hooks": [' >"$S/bad.json"; cp "$S/bad.json" "$S/bad.orig"
setup_hooks "$S/bad.json"; assert_eq "$?" 2 "malformed JSON rc 2"
cmp -s "$S/bad.json" "$S/bad.orig" && ok "malformed file untouched" || bad "malformed file changed"
unset DISK_MAGICIAN_POLICY_FILE

echo "== diskm admission-hook dispatches to hooks/disk-admission.sh =="
OUT="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_input":{"command":"ls"}}' | bash "$REPO_ROOT/disk_magician.sh" admission-hook)"; RC=$?
assert_eq "$RC/$OUT" "0/" "ungoverned command: rc 0, no output"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/home/.worktrees/r"
export TMPDIR="$T/tmpdir" HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state" DISK_MAGICIAN_ADMIT_BIN="$T/bin/admit"
cat >"$T/bin/admit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/admit.log"
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
  "cd /repo && git clone https://github.com/o/r.git /private/tmp/r/x|tmp_containers|--dest /private/tmp/r/x|hook:git-clone:github.com/o/r"
  "git -C $W/r/main worktree add ../n2|worktrees|--dest $W/r/n2|hook:git-worktree-add:main"
  "FOO=1 git clone git@github.com:o/r.git /tmp/r/y|tmp_containers|--dest /private/tmp/r/y|hook:git-clone:github.com/o/r"
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
assert_eq "$RC" 0 "deny still exits 0"
for rc in 0 3 10 75 76; do STUB_RC=$rc hook PreToolUse "git worktree add $W/r/n"
    [[ "$OUT" != *updatedInput* ]] && ok "rc $rc: no updatedInput" || bad "rc $rc: $OUT"; done

echo "── 3. compound vs single simple; PostToolUse confirm ──"
STUB_RC=0 hook PreToolUse "git clone bad-url /private/tmp/r/x || mkdir -p /private/tmp/r/x"
logged "--compound" && ok "|| compound flagged" || bad "compound: $(cat "$T/admit.log")"
STUB_RC=0 hook PreToolUse "cd /repo && git clone url /private/tmp/r/x"
logged "--compound" && ok "&& compound flagged" || bad "compound: $(cat "$T/admit.log")"
STUB_RC=0 hook PreToolUse "FOO=1 git clone url /private/tmp/r/y"
logged "--compound" && bad "env-prefixed simple flagged compound" || ok "env-prefixed is simple"
STUB_RC=0 hook PostToolUse "FOO=1 git clone url /private/tmp/r/y" '{"stdout":"","exit_code":0}'
assert_eq "$(cat "$T/admit.log")" "--confirm-tool-use tu-1" "simple exit 0 → confirm"; assert_eq "$OUT" "" "confirm prints nothing"
STUB_RC=0 hook PostToolUse "FOO=1 git clone url /private/tmp/r/y" '{"stdout":"","exit_code":128}'
assert_eq "$ADMITS" 0 "simple exit 128 → no confirm"
STUB_RC=0 hook PostToolUseFailure "FOO=1 git clone url /private/tmp/r/y" '{"exit_code":1}'
assert_eq "$ADMITS" 0 "PostToolUseFailure → no confirm"
for c in "git clone bad-url /private/tmp/r/x || mkdir -p /private/tmp/r/x" "cd /repo && git clone url /private/tmp/r/x" \
         "git clone url /private/tmp/r/x &"; do
    STUB_RC=0 hook PostToolUse "$c" '{"exit_code":0}'; assert_eq "$ADMITS" 0 "compound never confirmed: $c"
done

echo "── 4. ungoverned and unparsed → silent, admit not called ──"
for c in "ls -la" "git clone url $T/elsewhere/x" "cp -R a /opt/x" "git status"; do
    STUB_RC=0 hook PreToolUse "$c"; assert_eq "$ADMITS:$OUT" "0:" "ungoverned: $c"
done
assert_eq "$(grep -c hook_unparsed "$T/state/admission/events.jsonl" 2>/dev/null || echo 0)" 0 "no hook_unparsed yet"
n=0
for c in $'cat <<EOF\ngit clone url /private/tmp/r/h\nEOF' $'true\ngit clone url /private/tmp/r/n' \
         'echo $(git clone url /private/tmp/r/s)' 'echo `git clone url /private/tmp/r/b`' \
         'eval git clone url /private/tmp/r/e' '( git clone url /private/tmp/r/p )'; do
    STUB_RC=0 hook PreToolUse "$c"; n=$((n + 1))
    assert_eq "$ADMITS:$OUT:$RC" "0::0" "unparsed silent: ${c//$'\n'/\\n}"
    assert_eq "$(grep -c '"event": "hook_unparsed"' "$T/state/admission/events.jsonl")" "$n" "hook_unparsed +1"
done

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

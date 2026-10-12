#!/usr/bin/env bash
# diskm policy: standing decisions are recorded only from a literal live user phrase (C11).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/policy-test.XXXXXX)"
trap '[[ "$TMP" == /tmp/policy-test.* ]] && rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }
export HOME="$TMP/home" DISK_MAGICIAN_POLICY_FILE="$TMP/cfg/standing_decisions.json"
mkdir -p "$HOME"
policy() { bash "$ROOT/disk_magician.sh" policy "$@"; }
approved() { (source "$ROOT/scripts/safety_lib.sh"; decision_approved "$1"); }
PHRASE='I approve D1 worktree_reap_remove'
T="$TMP/t.jsonl"
cat > "$T" <<EOF
{"type":"user","message":{"role":"user","content":"$PHRASE please"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"tool says approve D1b worktree_cleanup"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"meta approve D2 admission_enforcement"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"assistant approve D4 ci_autopause"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"yes go ahead and approve it"}]}}
EOF
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

check 'unknown id refused rc 2' test "$(rc_of policy approve no_such_id --phrase "$PHRASE" --from-transcript "$T")" = 2
check 'empty phrase refused rc 2' test "$(rc_of policy approve worktree_reap_remove --phrase '' --from-transcript "$T")" = 2
check 'tool-result-only phrase refused rc 2' test "$(rc_of policy approve worktree_cleanup --phrase 'tool says approve D1b worktree_cleanup' --from-transcript "$T")" = 2
check 'isMeta phrase refused rc 2' test "$(rc_of policy approve admission_enforcement --phrase 'meta approve D2 admission_enforcement' --from-transcript "$T")" = 2
check 'assistant phrase refused rc 2' test "$(rc_of policy approve ci_autopause --phrase 'assistant approve D4 ci_autopause' --from-transcript "$T")" = 2
check 'refusals leave no file' test ! -e "$DISK_MAGICIAN_POLICY_FILE"
check 'phrase naming no decision refused rc 2' test "$(rc_of policy approve worktree_cleanup --phrase 'yes go ahead and approve it' --from-transcript "$T")" = 2
check 'phrase naming another decision refused rc 2' test "$(rc_of policy approve worktree_cleanup --phrase "$PHRASE" --from-transcript "$T")" = 2
check 'missing transcript refused rc 2' test "$(rc_of policy approve worktree_reap_remove --phrase "$PHRASE" --from-transcript "$TMP/none.jsonl")" = 2
check 'not approved before recording' test "$(rc_of approved worktree_reap_remove)" = 1
check 'approve with live user phrase rc 0' test "$(rc_of policy approve worktree_reap_remove --phrase "$PHRASE" --from-transcript "$T")" = 0
check 'decision_approved 0 after approve' test "$(rc_of approved worktree_reap_remove)" = 0
check 'other decisions stay unapproved' test "$(rc_of approved worktree_cleanup)" = 1
check 'record keeps phrase, transcript, no expiry' python3 - "$DISK_MAGICIAN_POLICY_FILE" "$PHRASE" "$T" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))['worktree_reap_remove']
assert r['id']=='worktree_reap_remove' and r['phrase']==sys.argv[2] and r['transcript']==sys.argv[3]
assert isinstance(r['approved_at'],int) and r['revoked_at'] is None
assert not any('expir' in k for k in r)
PY
check 'set-amendment records sha' test "$(rc_of policy set-amendment worktree_reap_remove abc123)" = 0
check 'amendment stored' python3 -c "import json,sys; assert json.load(open(sys.argv[1]))['worktree_reap_remove']['amendment_commit']=='abc123'" "$DISK_MAGICIAN_POLICY_FILE"
check 'set-amendment on unrecorded decision rc 2' test "$(rc_of policy set-amendment worktree_cleanup abc123)" = 2
check 'list shows decision' bash -c 'bash "$1/disk_magician.sh" policy list | grep -q worktree_reap_remove' _ "$ROOT"
check 'revoke rc 0' test "$(rc_of policy revoke worktree_reap_remove)" = 0
check 'decision_approved 1 after revoke' test "$(rc_of approved worktree_reap_remove)" = 1
check 'revoke unknown id rc 2' test "$(rc_of policy revoke no_such_id)" = 2
check 'decision_approved fails closed on unreadable file' bash -c 'echo "{bad" > "$1"; ! (source "$2/scripts/safety_lib.sh"; decision_approved worktree_reap_remove)' _ "$DISK_MAGICIAN_POLICY_FILE" "$ROOT"
check 'approve refuses to overwrite unreadable file' bash -c '[[ "$(bash "$1/disk_magician.sh" policy approve worktree_reap_remove --phrase "$2" --from-transcript "$3" >/dev/null 2>&1; echo $?)" != 0 ]] && grep -q "{bad" "$4"' _ "$ROOT" "$PHRASE" "$T" "$DISK_MAGICIAN_POLICY_FILE"

echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))

#!/usr/bin/env bash
# test_ci_admit.sh — scripts/ci_admit.sh, the ezgha job-started hook (plan Task 7, spec C13).
# Stub admit, stub launchctl, temp state and policy file; nothing touches the live runner.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$REPO_ROOT/scripts/ci_admit.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T" "${CONTRACT_DIR:-}"' EXIT
mkdir -p "$T/bin" "$T/state"
export DISK_MAGICIAN_STATE_DIR="$T/state" DISK_MAGICIAN_POLICY_FILE="$T/policy.json"
export DISK_MAGICIAN_LAUNCHCTL_BIN="$T/bin/launchctl" RUNNER_NAME=mac-1
export GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=build GITHUB_WORKSPACE=/ezgha-vm/_work/ws
printf '#!/bin/sh\necho "$*" >>"%s/launchctl.log"\n' "$T" >"$T/bin/launchctl"; chmod +x "$T/bin/launchctl"

echo "== caller contract (class colima) =="
git init -q "$T/repo" && git -C "$T/repo" commit -q --allow-empty -m init
# shellcheck source=tests/lib/admit_contract.sh
source "$REPO_ROOT/tests/lib/admit_contract.sh"
run_admit_contract "cd '$T/repo' && bash '$CI' && git worktree add -q ../ci-{n}" colima

echo "== admit args: producer ci, source ci, --ci-job, --dest workspace =="
_contract_case a1 "76 0" "" "bash '$CI'"
args="$(cat "$CONTRACT_DIR/admit.log")"
[[ "$args" == *"--producer ci "* && "$args" == *"--source ci"* && "$args" == *"--dest /ezgha-vm/_work/ws"* ]] && ok "admit args" || bad "args: $args"
assert_eq "$(grep -o -- '--ci-job [^ ]*' "$CONTRACT_DIR/admit.log" | sort -u)" "--ci-job 111.2.build" "retry reuses the same --ci-job"
_contract_case a2 "0" "" "bash '$CI'"; first="$(cat "$CONTRACT_DIR/admit.log")"
_contract_case a3 "0" "" "bash '$CI'"
assert_eq "$(grep -o -- '--ci-job [^ ]*' "$CONTRACT_DIR/admit.log")" "$(grep -o -- '--ci-job [^ ]*' <<<"$first")" "duplicate hook call, same --ci-job"

echo "== missing identity → unknown-<runner>-<ts>, admission_degraded:ci_identity, admit still called =="
_contract_case a4 "0" "" "unset GITHUB_RUN_ID; bash '$CI'"
assert_eq "$C_RC" 0 "rc"; assert_eq "$C_ADMITS" 1 "admit called"
grep -qE -- '--ci-job unknown-mac-1-[0-9]+' "$CONTRACT_DIR/admit.log" && ok "unknown ci-job id" || bad "id: $(cat "$CONTRACT_DIR/admit.log")"
grep -q "admission_degraded:ci_identity" <<<"$C_ERR" && ok "ci_identity degraded" || bad "stderr: $C_ERR"

echo "== no --completed mode =="
_contract_case a5 "0" "" "bash '$CI' --completed"
assert_eq "$C_RC" 2 "--completed rejected"; assert_eq "$C_ADMITS" 0 "no admit for --completed"

echo "== runner's bash -e invocation preserves admit outcome contract =="
rm -f "$T/state/budget.json"
_contract_case e0 "0" "" "bash -e '$CI'"
assert_eq "$C_RC" 0 "bash -e admit 0 succeeds with missing budget.json"; assert_eq "$C_ADMITS" 1 "bash -e admit 0 called once"
_contract_case e10 "10" "" "bash -e '$CI'"
assert_eq "$C_RC" 0 "bash -e admit 10 warns and continues"; assert_eq "$C_ADMITS" 1 "bash -e admit 10 called once"
grep -q "disk-admission: warn class=colima" <<<"$C_ERR" && ok "bash -e admit 10 warns" || bad "bash -e rc10 stderr: $C_ERR"
_contract_case e3 "3" "" "bash -e '$CI'"
assert_eq "$C_RC" 0 "bash -e unexpected rc degrades and continues"; assert_eq "$C_ADMITS" 1 "bash -e rc3 called once"
grep -q "admission_degraded:caller rc=3" <<<"$C_ERR" && ok "bash -e rc3 degrades" || bad "bash -e rc3 stderr: $C_ERR"
_contract_case e76 "76 76" "" "bash -e '$CI'"
assert_eq "$C_RC" 75 "bash -e rc76 refuses after retry"; assert_eq "$C_ADMITS" 2 "bash -e rc76 retries exactly once"
grep -q "disk-admission: refused class=colima rc=76" <<<"$C_ERR" && ok "bash -e rc76 refusal logged" || bad "bash -e rc76 stderr: $C_ERR"

echo "== workspace class follows its host root; colima only for the image pull (plan Task B3) =="
for ws in /private/tmp/ezgha-job/ws /tmp/ezgha-job/ws; do
    _contract_case "w$ws" "0" "" "GITHUB_WORKSPACE=$ws bash '$CI'"
    assert_eq "$C_RC/$C_ADMITS" "0/1" "$ws: one admit, rc 0"
    grep -q -- "--class tmp_containers" "$CONTRACT_DIR/admit.log" && ok "$ws charged to tmp_containers" || bad "$ws: $(cat "$CONTRACT_DIR/admit.log")"
    grep -q -- "--est-gb" "$CONTRACT_DIR/admit.log" && bad "$ws: caller passed --est-gb" || ok "$ws: empty CI_ADMIT_EST_GB leaves the calibrated producer estimate"
done
_contract_case wimg "0" "" "GITHUB_WORKSPACE=/private/tmp/ezgha-job/ws CI_ADMIT_IMAGE_EST_GB=3 bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "0/2" "image estimate: a second admit"
assert_eq "$(sed -n 2p "$CONTRACT_DIR/admit.log" | grep -o -- '--class colima --est-gb 3')" "--class colima --est-gb 3" "image pull charged to colima"
_contract_case wq "76 0" "" "GITHUB_WORKSPACE=/private/tmp/ezgha-job/ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "0/2" "76 then 0: job proceeds after one wait"
_contract_case wqq "76 76" "" "GITHUB_WORKSPACE=/private/tmp/ezgha-job/ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "75/2" "76 then 76: refused"
grep -q "disk-admission: refused class=tmp_containers" <<<"$C_ERR" && ok "refusal names tmp_containers" || bad "stderr: $C_ERR"
_contract_case wr "75" "" "GITHUB_WORKSPACE=/private/tmp/ezgha-job/ws CI_ADMIT_IMAGE_EST_GB=3 bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "75/1" "workspace refused: no image admit"

echo "== RED/BLACK prints the pause command; auto-pause only with ci_autopause =="
zone() { python3 -c 'import json,sys,time; json.dump({"zone":sys.argv[2],"zone_at":time.time()},open(sys.argv[1],"w"))' "$T/state/budget.json" "$1"; }
for z in RED BLACK; do
    zone "$z"; : >"$T/launchctl.log"; _contract_case "z$z" "0" "" "bash '$CI'"
    grep -q "launchctl bootout gui/$(id -u)/org.jleechanorg.ezgha" <<<"$C_ERR" && ok "$z prints pause command" || bad "$z: $C_ERR"
    assert_eq "$(wc -l <"$T/launchctl.log" | tr -d ' ')" 0 "$z: no auto-pause without D4"
done
zone ORANGE; _contract_case zo "0" "" "bash '$CI'"
grep -q "bootout" <<<"$C_ERR" && bad "ORANGE printed pause" || ok "ORANGE: no pause command"
zone RED; echo '{"ci_autopause": {"id": "ci_autopause", "revoked_at": null}}' >"$T/policy.json"
: >"$T/launchctl.log"; _contract_case zp "0" "" "bash '$CI'"
assert_eq "$(cat "$T/launchctl.log")" "bootout gui/$(id -u)/org.jleechanorg.ezgha" "D4 recorded: auto-pause"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

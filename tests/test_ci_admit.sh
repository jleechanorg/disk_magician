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
# Hosted runners leave TMPDIR unset; the hook classifies workspaces by it.
export TMPDIR="${TMPDIR:-$(dirname "$T")}"
trap 'rm -rf "$T" "${CONTRACT_DIR:-}"' EXIT
mkdir -p "$T/bin" "$T/state"
REAL_PS="$(command -v ps)"
export DISK_MAGICIAN_STATE_DIR="$T/state" DISK_MAGICIAN_POLICY_FILE="$T/policy.json"
export DISK_MAGICIAN_LAUNCHCTL_BIN="$T/bin/launchctl" RUNNER_NAME=mac-1
export GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=build GITHUB_WORKSPACE=/ezgha-vm/_work/ws
printf '#!/bin/sh\necho "$*" >>"%s/launchctl.log"\n' "$T" >"$T/bin/launchctl"; chmod +x "$T/bin/launchctl"
cat >"$T/bin/ps" <<'EOF'
#!/usr/bin/env bash
pid="" fmt=""
while [[ $# -gt 0 ]]; do
    case "$1" in -p) pid="$2"; shift 2 ;; -o) fmt="$2"; shift 2 ;; *) shift ;; esac
done
[[ "${CI_TEST_WORKER_DEAD:-0}" != 1 && -n "$pid" ]] || exit 1
case "$fmt" in
    ppid=,comm=) if [[ "$pid" == 900 ]]; then echo "1 Runner.Worker"; elif [[ "$pid" == 1 ]]; then echo "0 launchd"; else echo "900 bash"; fi ;;
    lstart=) [[ "$pid" == 900 ]] && echo "Thu Oct  9 12:00:00 2026" || exit 1 ;;
    args=) [[ "$pid" == 900 ]] && echo "Runner.Worker" || echo "bash" ;;
    comm=) [[ "$pid" == 900 ]] && echo "Runner.Worker" || echo "bash" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/ps"
export DISK_MAGICIAN_PS_BIN="$T/bin/ps"
cat >"$T/bin/ps_scratch" <<EOF
#!/usr/bin/env bash
pid="" fmt=""
while [[ \$# -gt 0 ]]; do
    case \$1 in -p) pid=\$2; shift 2 ;; -o) fmt=\$2; shift 2 ;; *) shift ;; esac
done
if [[ \$pid == 900 ]]; then
    case \$fmt in
        ppid=,comm=) echo "1 Runner.Worker" ;;
        lstart=) echo "Thu Oct  9 12:00:00 2026" ;;
        args=|comm=) echo "Runner.Worker" ;;
        *) exit 1 ;;
    esac
elif [[ \$pid == 1 ]]; then
    case \$fmt in ppid=,comm=) echo "0 launchd" ;; *) exec "$REAL_PS" -p "\$pid" -o "\$fmt" ;; esac
else
    case \$fmt in
        ppid=,comm=) echo "900 bash" ;;
        *) exec "$REAL_PS" -p "\$pid" -o "\$fmt" ;;
    esac
fi
EOF
chmod +x "$T/bin/ps_scratch"

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
echo "== real CI hook creates a worker lease, preserves prior owners, and refuses unknown ancestry =="
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
cat >"$T/quota-config.json" <<'EOF'
{"volumes":{"classes":{"scratch":{"mountpoint":"/quota-mount"}}}}
EOF
export DISK_MAGICIAN_CONFIG="$T/quota-config.json"
volume_ws="/quota-mount/aged-output"
_contract_case ci_volume "0" "" "GITHUB_WORKSPACE=$volume_ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "0/1" "quota-volume workspace remains admitted once"
grep -q -- "--class colima" "$CONTRACT_DIR/admit.log" && ok "quota volume keeps existing colima admission class" || bad "volume class: $(cat "$CONTRACT_DIR/admit.log")"
_contract_case ci_volume_unexpected "3" "" "GITHUB_WORKSPACE=$volume_ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "75/1" "quota-volume workspace fails closed on unexpected admission result"
grep -q "disk-admission: unavailable class=colima rc=3" <<<"$C_ERR" && ok "quota-volume unavailable result diagnosed" || bad "unexpected admission stderr: $C_ERR"
printf '0\n' >"$CONTRACT_DIR/admit.rcs"; : >"$CONTRACT_DIR/admit.log"
PATH="$CONTRACT_DIR/bin:$PATH" DISK_MAGICIAN_ADMIT_BIN="$T/bin/missing-admit" GITHUB_WORKSPACE="$volume_ws" bash "$CI" >"$T/missing-out" 2>"$T/missing-err"
MISSING_RC=$?
assert_eq "$MISSING_RC" 75 "quota-volume workspace fails closed when admission executable is missing"
grep -q "admission_degraded:caller admit missing" "$T/missing-err" && ok "missing quota-volume admission diagnosed" || bad "missing admission stderr: $(cat "$T/missing-err")"
volume_lease="$(lease_path_for "$volume_ws")"
python3 - "$volume_lease" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["producer"]=="ci-admit"
assert any(o.get("pid")==900 and o.get("comm")=="Runner.Worker" for o in d["owners"])
PY
[[ $? -eq 0 ]] && ok "configured quota-volume workspace receives Runner.Worker lease before C14 cleanup" || bad "quota-volume worker owner missing"
assert_eq "$(lease_owner_state "$volume_lease")" "alive" "lease reports live Runner.Worker owner"
_contract_case ci_volume_unknown "0" "" "CI_TEST_WORKER_DEAD=1 GITHUB_WORKSPACE=$volume_ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "75/0" "quota-volume workspace fails closed for unknown worker"
cat >"$T/quota-config-tmp.json" <<'EOF'
{"volumes":{"classes":{"scratch":{"mountpoint":"/tmp/quota-mount"}}}}
EOF
export DISK_MAGICIAN_CONFIG="$T/quota-config-tmp.json"
tmp_volume_ws="/tmp/quota-mount/aged-output"
_contract_case ci_volume_tmp "0" "" "GITHUB_WORKSPACE=$tmp_volume_ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "0/1" "quota volume under /tmp retains tmp admission class"
grep -q -- "--class tmp_containers" "$CONTRACT_DIR/admit.log" && ok "configured /tmp volume uses existing tmp class" || bad "tmp volume class: $(cat "$CONTRACT_DIR/admit.log")"
tmp_volume_lease="$(lease_path_for "$tmp_volume_ws")"
python3 - "$tmp_volume_lease" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert any(o.get("pid")==900 and o.get("comm")=="Runner.Worker" for o in d["owners"])
PY
[[ $? -eq 0 ]] && ok "configured /tmp quota-volume workspace also receives worker lease" || bad "tmp volume worker owner missing"
export DISK_MAGICIAN_CONFIG="$T/quota-config.json"

ci_ws="$T/ci-workspace"; mkdir -p "$ci_ws"
_contract_case ci_new "0" "" "GITHUB_WORKSPACE=$ci_ws bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "0/1" "CI hook acquires owner before admission"
lease="$(lease_path_for "$ci_ws")"
python3 - "$lease" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["kind"]=="scratch" and d["producer"]=="ci-admit"
assert any(o.get("pid")==900 and o.get("comm")=="Runner.Worker" for o in d["owners"])
PY
[[ $? -eq 0 ]] && ok "missing lease created with live Runner.Worker" || bad "missing CI owner"
assert_eq "$(lease_owner_state "$lease")" "alive" "CI worker owner holds lease while process lives"
assert_eq "$(CI_TEST_WORKER_DEAD=1 lease_owner_state "$lease")" "dead" "worker death retires CI owner naturally"
echo "== scratch-new evidence lease retains the CI Runner.Worker owner =="
mkdir -p "$T/worktrees" "$T/evidence"
cat >"$T/bin/diskm-volume" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "volume path scratch" ]] || exit 2
echo "$T/evidence"
EOF
chmod +x "$T/bin/diskm-volume"
printf '0\n' >"$CONTRACT_DIR/admit.rcs"; : >"$CONTRACT_DIR/admit.log"
OUT="$(PATH="$CONTRACT_DIR/bin:$PATH" STANDARD_WORKTREE_ROOT="$T/worktrees" EVIDENCE_TMP_ROOT="$T/evidence" \
    DISK_MAGICIAN_ADMIT_BIN="$CONTRACT_DIR/bin/admit" DISK_MAGICIAN_PS_BIN="$T/bin/ps_scratch" \
    DISK_MAGICIAN_DISKM_BIN="$T/bin/diskm-volume" GITHUB_ACTIONS=true GITHUB_WORKSPACE="$T/repo" \
    bash "$REPO_ROOT/disk_magician.sh" scratch-new "$T/repo" ci-evidence --kind evidence 2>"$T/scratch.err")"; SCRATCH_RC=$?
if [[ "$SCRATCH_RC" != 0 ]]; then cat "$T/scratch.err" >&2; fi
assert_eq "$SCRATCH_RC" 0 "CI scratch-new succeeds"
scratch_lease="$(lease_path_for "$OUT")"
python3 - "$scratch_lease" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert any(o.get("pid")==900 and o.get("comm")=="Runner.Worker" for o in d["owners"])
PY
[[ $? -eq 0 ]] && ok "scratch-new artifact lease retains Runner.Worker" || bad "scratch-new artifact lease lost Runner.Worker"
assert_eq "$(lease_owner_state "$scratch_lease")" "alive" "CI artifact lease is live while Runner.Worker lives"
prior_ws="$T/ci-existing"; mkdir -p "$prior_ws"
lease_prior="$(lease_path_for "$prior_ws")"
mkdir -p "$(dirname "$lease_prior")"
python3 - "$lease_prior" "$prior_ws" <<'PY'
import json,sys
json.dump({"path":sys.argv[2],"owner":{"pid":901,"start_epoch":1,"comm":"parent"},
           "owners":[{"pid":901,"start_epoch":1,"comm":"parent"}],"released_at":None},open(sys.argv[1],"w"))
PY
_contract_case ci_existing "0" "" "GITHUB_WORKSPACE=$prior_ws bash '$CI'"
python3 - "$lease_prior" <<'PY'
import json,sys
owners=json.load(open(sys.argv[1]))["owners"]
assert any(o.get("pid")==901 for o in owners) and any(o.get("pid")==900 for o in owners)
PY
[[ $? -eq 0 ]] && ok "existing lease owner preserved and worker appended" || bad "existing lease overwritten"
_contract_case ci_unknown "0" "" "CI_TEST_WORKER_DEAD=1 GITHUB_WORKSPACE=$T/ci-unknown bash '$CI'"
assert_eq "$C_RC/$C_ADMITS" "75/0" "unknown worker ancestry fails closed before admission"
grep -q "admission_degraded:ci_owner_identity" <<<"$C_ERR" && ok "unknown ancestry reported" || bad "unknown ancestry stderr: $C_ERR"
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

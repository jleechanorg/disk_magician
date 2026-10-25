#!/usr/bin/env bash
# ci_admit.sh — ezgha job-started hook (spec C13): admit the workspace once per <run>.<attempt>.<job> (caller
# contract); in a fresh RED/BLACK/FLOOR zone print the runner pause command, and pause only if D4 is recorded.
# The workspace is charged to the class of the host root it lives under (admit_class_for; colima when it is
# on no host root); CI_ADMIT_IMAGE_EST_GB additionally admits the image pull as
# colima. admit_gate waits out one 76 inside the hook, so a job is delayed, never failed, by a single 76.
_CI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
source "$_CI_DIR/lib/admit_caller.sh"
[[ $# -eq 0 ]] || { echo "usage: ci_admit.sh (job-started hook; no arguments)" >&2; exit 2; }
if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_RUN_ATTEMPT:-}" && -n "${GITHUB_JOB:-}" ]]; then
    job="$GITHUB_RUN_ID.$GITHUB_RUN_ATTEMPT.$GITHUB_JOB"
else
    job="unknown-${RUNNER_NAME:-$(hostname -s)}-$(date +%s)"; echo "admission_degraded:ci_identity" >&2
fi
ws="${GITHUB_WORKSPACE:-$PWD}"
cls="$(admit_class_for "$ws")"; cls="${cls:-colima}"
if [[ "$cls" != colima ]]; then
    source "$_CI_DIR/lib/worktree_lease.sh"
    owner="$(lease_resolve_runner_worker "$$")" || {
        echo "admission_degraded:ci_owner_identity" >&2
        exit 75
    }
    owner_pid="$(cut -f1 <<<"$owner")"; owner_start="$(cut -f2 <<<"$owner")"; owner_comm="$(cut -f3 <<<"$owner")"
    lease_ensure_ci_owner "$ws" "$owner_pid" "$owner_start" "$owner_comm" || {
        echo "admission_degraded:ci_owner_lease" >&2
        exit 75
    }
fi
rc=0
admit_gate "$cls" "${CI_ADMIT_EST_GB:-}" ci "$ws" ci --ci-job "$job" || rc=$?
if [[ "$rc" == 0 && "$cls" != colima && -n "${CI_ADMIT_IMAGE_EST_GB:-}" ]]; then
    admit_gate colima "$CI_ADMIT_IMAGE_EST_GB" ci "$ws" ci --ci-job "$job" || rc=$?
fi
zone="$(python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(d["zone"] if time.time()-d["zone_at"]<=900 else "")' \
    "${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}/budget.json" 2>/dev/null)" || zone=""
if [[ "$zone" == RED || "$zone" == BLACK || "$zone" == FLOOR ]]; then
    target="gui/$(id -u)/${EZGHA_LAUNCHD_LABEL:-org.jleechanorg.ezgha}"
    echo "disk-admission: zone=$zone; pause CI with: launchctl bootout $target" >&2
    python3 "$_CI_DIR/policy_provenance.py" approved ci_autopause >/dev/null 2>&1 &&
        "${DISK_MAGICIAN_LAUNCHCTL_BIN:-launchctl}" bootout "$target"
fi
exit "$rc"

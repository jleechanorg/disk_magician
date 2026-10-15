#!/usr/bin/env bash
# ci_admit.sh — ezgha job-started hook (spec C13): admit the workspace once per <run>.<attempt>.<job> (caller
# contract); in a fresh RED/BLACK/FLOOR zone print the runner pause command, and pause only if D4 is recorded.
_CI_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
source "$_CI_DIR/lib/admit_caller.sh"
[[ $# -eq 0 ]] || { echo "usage: ci_admit.sh (job-started hook; no arguments)" >&2; exit 2; }
if [[ -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_RUN_ATTEMPT:-}" && -n "${GITHUB_JOB:-}" ]]; then
    job="$GITHUB_RUN_ID.$GITHUB_RUN_ATTEMPT.$GITHUB_JOB"
else
    job="unknown-${RUNNER_NAME:-$(hostname -s)}-$(date +%s)"; echo "admission_degraded:ci_identity" >&2
fi
if admit_gate colima "${CI_ADMIT_EST_GB:-}" ci "${GITHUB_WORKSPACE:-$PWD}" ci --ci-job "$job"; then
    rc=0
else
    rc=$?
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

# shellcheck shell=bash
# removal_activation_ok <id>: rc 0 only if approved, C14 self-test ok and (D1) amendment on a fresh origin/main; else prints activation_blocked:<why>.
_RA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RA_LIB/../safety_lib.sh"
removal_activation_ok() {
  local why=decision_missing
  decision_approved "$1" && why=c14_missing &&
    [[ -f "$_RA_LIB/artifact_verdict.sh" && "$( (source "$_RA_LIB/artifact_verdict.sh" && artifact_removal_verdict --self-test) 2>/dev/null)" == ok ]] && why= &&
    [[ "$1" == worktree_reap_remove ]] && { why="$(python3 "$_RA_LIB/../policy_provenance.py" amendment "$1" "${DISK_MAGICIAN_POLICY_REPO:-$_RA_LIB/../..}" 2>/dev/null)" || why="${why:-policy_unverified}"; }
  [[ -z "$why" ]] || { echo "activation_blocked:$why"; return 1; }
}

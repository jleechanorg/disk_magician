# shellcheck shell=bash
# removal_activation_ok <id>: rc 0 only when the decision is approved, C14 (artifact_verdict.sh beside this
# file) self-tests ok, and for D1 the amendment is on a fresh origin/main; else prints activation_blocked:<why>.
_RA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RA_LIB/../safety_lib.sh"
removal_activation_ok() {
  local why=decision_missing
  if decision_approved "$1"; then
    why=c14_missing
    if [[ -f "$_RA_LIB/artifact_verdict.sh" && "$( (source "$_RA_LIB/artifact_verdict.sh" && artifact_removal_verdict --self-test) 2>/dev/null)" == ok ]]; then
      [[ "$1" == worktree_reap_remove ]] || return 0
      why="$(python3 "$_RA_LIB/../policy_provenance.py" amendment "$1" "${DISK_MAGICIAN_POLICY_REPO:-$_RA_LIB/../..}" 2>/dev/null)" && return 0
      why="${why:-policy_unverified}"
    fi
  fi
  echo "activation_blocked:$why"; return 1
}

# shellcheck shell=bash
# quarantine_remove <path>: C14 two-phase removal (spec §7.2), no callers yet; prints quarantined:<id>, quarantine_conflict:<id> or kept:<why>.
_Q_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_Q_LIB/artifact_verdict.sh" ]] && source "$_Q_LIB/artifact_verdict.sh"
quarantine_remove() {
  local v inv; inv="$(mktemp "${TMPDIR:-/tmp}/dm-q-inv.XXXXXX")" || { echo kept:check-failed; return 0; }
  v="$(artifact_removal_verdict "$1" --inventory-out "$inv" 2>/dev/null)" || v=kept:check-failed
  [[ "$v" == remove ]] && v="$(python3 "$_Q_LIB/../quarantine_rename.py" phase1 "$1" "$inv" 2>/dev/null)"
  rm -f "$inv"
  [[ "$v" == quarantined:* ]] && v="$(quarantine_phase2 "${v#quarantined:}")"
  echo "${v:-kept:check-failed}"
}
quarantine_phase2() { echo "quarantined:$1"; }  # phase 2 (fd-based delete inside .dm-quarantine/<id>) lands separately

# shellcheck shell=bash
# quarantine_remove <path>: C14 two-phase removal (spec §7.2), no callers yet; prints quarantined:<id>, quarantine_conflict:<id> or kept:<why>.
_Q_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_Q_LIB/artifact_verdict.sh" ]] && source "$_Q_LIB/artifact_verdict.sh"
quarantine_remove() {
  local v inv binding verdict_path qid; inv="$(mktemp "${TMPDIR:-/tmp}/dm-q-inv.XXXXXX")" || { echo kept:check-failed; return 0; }
  binding="$(mktemp "${TMPDIR:-/tmp}/dm-q-parent.XXXXXX")" || { rm -f "$inv"; echo kept:check-failed; return 0; }
  if ! python3 "$_Q_LIB/../quarantine_rename.py" bind "$1" "$binding" >/dev/null 2>&1; then
    rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0
  fi
  verdict_path="$(python3 "$_Q_LIB/../quarantine_rename.py" candidate "$binding" 2>/dev/null)" || verdict_path=""
  if [[ -z "$verdict_path" ]]; then rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0; fi
  v="$(artifact_removal_verdict "$verdict_path" --inventory-out "$inv" 2>/dev/null)" || v=kept:check-failed
  [[ "$v" == remove ]] && v="$(python3 "$_Q_LIB/../quarantine_rename.py" phase1 "$1" "$inv" "$binding" 2>/dev/null)"
  if [[ "$v" == quarantined:* ]]; then
    qid="${v#quarantined:}"
    v="$(quarantine_phase2 "$binding" "$qid")" || v=kept:quarantine_partial_kept
    [[ "$v" == removed ]] && v="removed:$qid"
  fi
  rm -f "$inv" "$binding"
  echo "${v:-kept:check-failed}"
}
quarantine_phase2() {
  local result
  result="$(python3 "$_Q_LIB/../quarantine_rename.py" phase2 "$1" "$2" 2>/dev/null)" || { echo kept:quarantine_partial_kept; return 0; }
  [[ "$result" == removed ]] || { echo kept:quarantine_partial_kept; return 0; }
  echo removed
}
quarantine_reconcile() {
  python3 "$_Q_LIB/../quarantine_rename.py" reconcile "$@"
}
quarantine_restore() {
  [[ $# -eq 1 ]] || { echo "kept:unknown-quarantine-id"; return 0; }
  python3 "$_Q_LIB/../quarantine_rename.py" restore "$1"
}

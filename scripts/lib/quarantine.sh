# shellcheck shell=bash
# quarantine_remove <path>: C14 two-phase removal (spec §7.2), no callers yet; prints quarantined:<id>, quarantine_conflict:<id> or kept:<why>.
_Q_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_Q_LIB/artifact_verdict.sh" ]] && source "$_Q_LIB/artifact_verdict.sh"
quarantine_remove() {
  local v inv binding path_arg verdict_path qid deadline='' deadline_seen=0
  [[ $# -ge 1 ]] || { echo kept:check-failed; return 0; }
  path_arg="$1"; verdict_path="$1"; shift
  local -a caller_verdict_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deadline-at)
        [[ $# -ge 2 && "$deadline_seen" -eq 0 ]] || { echo kept:check-failed; return 0; }
        python3 -c 'import math,sys; x=float(sys.argv[1]); sys.exit(0 if math.isfinite(x) and x >= 0 else 1)' "$2" >/dev/null 2>&1 || { echo kept:check-failed; return 0; }
        deadline="$2"; deadline_seen=1; caller_verdict_args+=("$1" "$2"); shift 2 ;;
      --inventory-out) echo kept:check-failed; return 0 ;;
      --kind|--frozen-identity|--frozen-parent-identity|--frozen-root-identity)
        [[ $# -ge 2 ]] || { echo kept:check-failed; return 0; }
        caller_verdict_args+=("$1" "$2"); shift 2 ;;
      *) echo kept:check-failed; return 0 ;;
    esac
  done
  local -a verdict_args=(--inventory-out)
  # Bash 3.2 with nounset treats expanding an empty array as an unbound
  # variable. Keep the no-option caller contract portable without disabling
  # nounset for the function or the caller.
  if ((${#caller_verdict_args[@]})); then
    verdict_args+=("${caller_verdict_args[@]}")
  fi
  inv="$(mktemp "${TMPDIR:-/tmp}/dm-q-inv.XXXXXX")" || { echo kept:check-failed; return 0; }
  binding="$(mktemp "${TMPDIR:-/tmp}/dm-q-parent.XXXXXX")" || { rm -f "$inv"; echo kept:check-failed; return 0; }
  if ! python3 "$_Q_LIB/../quarantine_rename.py" bind "$path_arg" "$binding" >/dev/null 2>&1; then
    rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0
  fi
  verdict_path="$(python3 "$_Q_LIB/../quarantine_rename.py" candidate "$binding" 2>/dev/null)" || verdict_path=""
  if [[ -z "$verdict_path" ]]; then rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0; fi
  v="$(artifact_removal_verdict "$verdict_path" "${verdict_args[@]:0:1}" "$inv" "${verdict_args[@]:1}" 2>/dev/null)" || v=kept:check-failed
  if [[ "$v" == remove ]]; then
    if [[ "$deadline_seen" == 1 ]]; then
      v="$(python3 "$_Q_LIB/../quarantine_rename.py" remove "$path_arg" "$inv" "$binding" --deadline-at "$deadline" 2>/dev/null)"
    else
      v="$(python3 "$_Q_LIB/../quarantine_rename.py" remove "$path_arg" "$inv" "$binding" 2>/dev/null)"
    fi
  fi
  rm -f "$inv" "$binding"
  echo "${v:-kept:check-failed}"
}
quarantine_phase2() {
  local result
  result="$(python3 "$_Q_LIB/../quarantine_rename.py" phase2 "$@" 2>/dev/null)" || { echo kept:quarantine_partial_kept; return 0; }
  [[ "$result" == deferred:* ]] && { echo "$result"; return 0; }
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

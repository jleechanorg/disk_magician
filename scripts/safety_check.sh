#!/usr/bin/env bash
# safety_check.sh — CLI over safety_lib.sh for agents and pre-delete hooks.
#
# Usage: safety_check.sh <path> [<path>...]
#
# Prints one verdict line per path:
#   PROTECTED  <path>  <rule: pattern (reason)>
#   OK         <path>
# Exit codes: 0 = all OK, 1 = at least one PROTECTED, 2 = usage error.
#
# Consult this BEFORE any manual or scripted deletion of aged directories.
# Machine-local rules live in safety.local.json (gitignored) — see
# safety.local.json.template for the schema.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"

if [[ "${1:-}" == "--findings" ]]; then
  if findings_wiki_docs; then
    exit 0
  fi
  echo "no machine-local findings recorded (see findings_wiki/README.md)" >&2
  exit 1
fi

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
fi

echo "safety file: $(safety_file_in_use || echo '<none>')"
ANY_PROTECTED=false
for path in "$@"; do
  reason="$(safety_is_protected "$path")" && rc=0 || rc=$?
  case "$rc" in
    0) echo "PROTECTED  $path  $reason"; ANY_PROTECTED=true ;;
    1) echo "OK         $path" ;;
    *) echo "PROTECTED  $path  (safety file unreadable — failing closed)"; ANY_PROTECTED=true ;;
  esac
done
[[ "$ANY_PROTECTED" == false ]]

#!/usr/bin/env bash
# Read-only CLI view over scratch_budget_measure_files.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/actuator_deadline.sh"
source "$SCRIPT_DIR/lib/scratch_budget.sh"

usage() {
  echo "Usage: diskm measure-files PATH [--deadline-at MONOTONIC]" >&2
}

[[ $# -ge 1 && -n "$1" ]] || { usage; exit 2; }
path="$1"
shift
act_parse_deadline_args "$@" || { usage; exit 2; }
if ((${#ACT_ARGS[@]} != 0)) || [[ -n "$ACT_CURSOR" ]]; then
  usage
  exit 2
fi
scratch_budget_measure_files "$path" 100

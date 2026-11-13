#!/usr/bin/env bash
# Read-only CLI view over scratch_budget_measure_files.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/actuator_deadline.sh"
source "$SCRIPT_DIR/lib/scratch_budget.sh"

usage() {
  echo "Usage: diskm measure-files PATH [--deadline-at MONOTONIC]" >&2
}
help() {
  cat <<'EOF'
Usage: diskm measure-files PATH [--deadline-at MONOTONIC]

Outputs tab-separated rows: bytes, files, newest_epoch, flag, path.
Sizes are file-summed apparent bytes; directories below 100 MiB may aggregate.
Flags: A=aggregated, F=file, L=symlink, G=opaque Git, E=unreadable/unmeasured.
G and E rows with zero values mean unknown, not empty or old; either makes the
measurement incomplete. Symlinks are never followed.
EOF
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  help
  exit 0
fi
[[ $# -ge 1 && -n "$1" ]] || { usage; exit 2; }
path="$1"
shift
act_parse_deadline_args "$@" || { usage; exit 2; }
if ((${#ACT_ARGS[@]} != 0)) || [[ -n "$ACT_CURSOR" ]]; then
  usage
  exit 2
fi
scratch_budget_measure_files "$path" 100

#!/usr/bin/env bash
# quarantine_reconcile.sh — finish deferred C14 two-phase removals (phase 2).
# Index-bound and fail-closed (see quarantine_reconcile.py); --clean is
# deadline-bounded so a slow tree walk defers to the next run instead of hanging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$SCRIPT_DIR/lib/scratch_roots.sh"

MODE=plan
SECONDS_ARG=""
ROOT_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run|--clean] [--deadline-seconds N]

  --dry-run   Report what would be finished/kept (default; read-only).
  --clean     Finish phase 2 for entries whose manifest identity still matches,
              prune stale sidecar update files, log each purge.
  --root PATH Scan only PATH for orphan stores (repeatable; default: scratch roots, user temp, $HOME).
  --deadline-seconds N  Bound the run (default 300 clean / 30 scan).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE=plan ;;
    --clean) MODE=clean ;;
    --root) ROOT_ARGS+=(--root "${2:?--root needs a path}"); shift ;;
    --deadline-seconds) SECONDS_ARG="${2:?--deadline-seconds needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ${#ROOT_ARGS[@]} -eq 0 ]]; then
while IFS= read -r root; do
  [[ -n "$root" ]] && ROOT_ARGS+=(--root "$root")
done < <({ scratch_roots_get_unique; scratch_roots_get_user_tmp; echo "$HOME"; } 2>/dev/null | awk 'NF && !seen[$0]++')
fi

TIME_ARGS=()
[[ -n "$SECONDS_ARG" ]] && TIME_ARGS=("--$([[ $MODE == clean ]] && echo deadline || echo scan)-seconds" "$SECONDS_ARG")

LOGF="$(mktemp "${TMPDIR:-/tmp}/dm-qr-log.XXXXXX")"
trap 'rm -f "$LOGF"' EXIT
rc=0
DM_QR_LOG_FILE="$LOGF" python3 "$SCRIPT_DIR/quarantine_reconcile.py" "$MODE" ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"} ${TIME_ARGS[@]+"${TIME_ARGS[@]}"} || rc=$?
while IFS=$'\t' read -r action kb path; do
  [[ -n "$path" ]] && deletion_log_removal "$path" "$kb" "$action"
done <"$LOGF"
exit "$rc"

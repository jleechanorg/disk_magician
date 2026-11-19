#!/usr/bin/env bash
# Remove exactly one C14-approved direct child of the registered Scratch volume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISKM="${DISK_MAGICIAN_DISKM_BIN:-$SCRIPT_DIR/../disk_magician.sh}"
MODE=dry-run
MODE_SEEN=0
TARGET=""
usage() {
  echo "Usage: diskm quarantine remove-scratch <direct-child> [--dry-run|--clean]" >&2
  exit 2
}

[[ $# -ge 1 && "${1:-}" != --* ]] || usage
TARGET="$1"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      [[ "$MODE_SEEN" -eq 0 ]] || usage
      MODE_SEEN=1
      MODE=dry-run
      shift
      ;;
    --clean)
      [[ "$MODE_SEEN" -eq 0 ]] || usage
      MODE_SEEN=1
      MODE=clean
      shift
      ;;
    *) usage ;;
  esac
done

ROOT="$("$DISKM" volume path scratch --for-reclaim 2>/dev/null)" || {
  echo "kept:volume-identity" >&2
  exit 75
}
[[ -n "$ROOT" && "$ROOT" != "/" && -d "$ROOT" && ! -L "$ROOT" ]] || {
  echo "kept:volume-identity" >&2
  exit 75
}
"$DISKM" volume verify-mount "$ROOT" >/dev/null 2>&1 || {
  echo "kept:volume-identity" >&2
  exit 75
}

IDENTITIES="$(python3 - "$ROOT" "$TARGET" <<'PY'
import os
import stat
import sys

root, target = sys.argv[1:]
target_without_trailing_slash = target.rstrip("/")
if not os.path.isabs(root) or not os.path.isabs(target):
    print("refused:target-must-be-absolute", file=sys.stderr)
    raise SystemExit(2)
if os.path.realpath(root) != root or root == "/":
    print("refused:invalid-scratch-root", file=sys.stderr)
    raise SystemExit(2)
if os.path.normpath(target) != target_without_trailing_slash:
    print("refused:target-must-be-normalized", file=sys.stderr)
    raise SystemExit(2)
if os.path.dirname(target_without_trailing_slash) != root:
    print("refused:target-must-be-one-direct-child", file=sys.stderr)
    raise SystemExit(2)
try:
    root_stat = os.lstat(root)
    target_stat = os.lstat(target_without_trailing_slash)
except OSError:
    print("refused:target-identity-unavailable", file=sys.stderr)
    raise SystemExit(2)
if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
    print("refused:invalid-scratch-root", file=sys.stderr)
    raise SystemExit(2)
if stat.S_ISLNK(target_stat.st_mode) or not stat.S_ISDIR(target_stat.st_mode):
    print("refused:target-must-be-real-directory", file=sys.stderr)
    raise SystemExit(2)
if target_stat.st_dev != root_stat.st_dev or os.path.realpath(os.path.dirname(target_without_trailing_slash)) != root:
    print("refused:target-volume-mismatch", file=sys.stderr)
    raise SystemExit(2)
parent_stat = os.lstat(os.path.dirname(target_without_trailing_slash))
def identity(value):
    return str(value.st_dev) + ":" + str(value.st_ino) + ":" + str(value.st_uid)
print("\t".join((target_without_trailing_slash, identity(root_stat), identity(parent_stat), identity(target_stat))))
PY
)" || exit $?
IFS=$'\t' read -r TARGET ROOT_ID PARENT_ID TARGET_ID <<<"$IDENTITIES"
[[ "$ROOT_ID" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$PARENT_ID" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$TARGET_ID" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || {
  echo "kept:identity-unavailable" >&2
  exit 75
}
FROZEN_ARGS=(--frozen-identity "$TARGET_ID" --frozen-parent-identity "$PARENT_ID" --frozen-root-identity "$ROOT_ID")

# Recheck the registered volume immediately before the C14 verdict/removal.
"$DISKM" volume verify-mount "$ROOT" >/dev/null 2>&1 || {
  echo "kept:volume-identity" >&2
  exit 75
}

source "$SCRIPT_DIR/lib/quarantine.sh"
export C14_NO_RESCUE_PUSH=1
unset DISK_MAGICIAN_AGE_FLOOR_MINUTES DISK_MAGICIAN_C14_LEDGER DISK_MAGICIAN_C14_PROOF_OUT
if [[ "$MODE" == dry-run ]]; then
  verdict="$(artifact_removal_verdict "$TARGET" --kind ephemeral "${FROZEN_ARGS[@]}" --no-rescue-push)" || verdict=kept:check-failed
  printf '%s\n' "$verdict"
  exit 0
fi

result="$(quarantine_remove "$TARGET" --kind ephemeral "${FROZEN_ARGS[@]}")" || result=kept:check-failed
printf '%s\n' "$result"
case "$result" in
  removed:*) exit 0 ;;
  *) exit 75 ;;
esac

#!/usr/bin/env bash
# cleanup_agent_artifacts.sh — Clean up agent logs, worktrees, and large caches.
#
# Defaults to dry-run (use --clean to actually delete).
set -euo pipefail

TARGETS=(
  "$HOME/.cursor/worktrees"
  "$HOME/.cursor/chats"
  "$HOME/.claude/debug"
  "$HOME/.config/superpowers/worktrees"
  "$HOME/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"
  "$HOME/Library/Caches/com.google.antigravity.ShipIt"
  "$HOME/Library/Caches/ms-playwright"
  "$HOME/Library/Caches/ms-playwright-go"
  "$HOME/Library/Caches/pip"
)

DRY_RUN=true
EXISTED_BEFORE=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

Options:
  --clean     Actually delete contents (default: dry-run).
  -h|--help   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

size_of() {
  local path="$1"
  du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "0K"
}

clear_dir_contents() {
  local path="$1"
  # Expand path manually
  path="${path/#\~/$HOME}"
  path=$(eval echo "$path")

  if [[ ! -d "$path" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  find "$path" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$path" 2>/dev/null || true
}

echo "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
echo

echo "Before:"
target_index=0
for target in "${TARGETS[@]}"; do
  expanded="${target/#\~/$HOME}"
  expanded=$(eval echo "$expanded")
  if [[ -d "$expanded" ]]; then
    EXISTED_BEFORE[$target_index]=1
    echo "  $(size_of "$expanded")  $target"
  else
    EXISTED_BEFORE[$target_index]=0
    echo "  (missing)  $target"
  fi
  target_index=$(( target_index + 1 ))
done

echo
for target in "${TARGETS[@]}"; do
  clear_dir_contents "$target"
done

echo "After:"
target_index=0
for target in "${TARGETS[@]}"; do
  expanded="${target/#\~/$HOME}"
  expanded=$(eval echo "$expanded")
  if [[ -d "$expanded" ]]; then
    echo "  $(size_of "$expanded")  $target"
  else
    if [[ "${EXISTED_BEFORE[$target_index]:-0}" -eq 1 ]]; then
      echo "  (removed)  $target"
    else
      echo "  (was missing)  $target"
    fi
  fi
  target_index=$(( target_index + 1 ))
done

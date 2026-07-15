#!/usr/bin/env bash
# cleanup_agent_artifacts.sh — Clean up agent logs, worktrees, and large caches.
#
# Defaults to dry-run (use --clean to actually delete).
#
# Some targets are gated by directory mtime (see TARGETS_MTIME_GATE_DAYS):
# when a gate is set, the directory is only cleared if it has not been
# modified within the gate window. The gate is the directory mtime (most
# recent write to anything inside). A gate of -1 means "no gate" (clear
# unconditionally — the original behavior for the worktree / cache dirs).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

# Optional extra dirs (colon-separated absolute or ~ paths):
#   DISK_MAGICIAN_EXTRA_ARTIFACT_DIRS="$HOME/my-agent-app"
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
  # Idle/stale agent-app targets (regrowth-prevention Fix #6):
  "$HOME/.gemini/antigravity-ide"
  "$HOME/.gemini/antigravity-browser-profile"
)

# mtime gate in days. -1 = no gate (clear unconditionally).
# Parallel to TARGETS. Bump a value to be MORE conservative (keep more).
TARGETS_MTIME_GATE_DAYS=(
  -1   # ~/.cursor/worktrees
  -1   # ~/.cursor/chats
  -1   # ~/.claude/debug
  -1   # ~/.config/superpowers/worktrees
  -1   # ShipIt (todesktop)
  -1   # ShipIt (antigravity)
  -1   # ms-playwright
  -1   # ms-playwright-go
  -1   # pip cache
   30  # antigravity-ide — idle since 2026-05-29, 2.5 GB
   30  # antigravity-browser-profile — idle since 2026-03-28, 1.5 GB
)


if [[ -n "${DISK_MAGICIAN_EXTRA_ARTIFACT_DIRS:-}" ]]; then
  IFS=':' read -r -a _extra_dirs <<< "${DISK_MAGICIAN_EXTRA_ARTIFACT_DIRS}"
  for _d in "${_extra_dirs[@]}"; do
    [[ -n "$_d" ]] || continue
    _d="${_d/#\~/$HOME}"
    TARGETS+=("$_d")
    TARGETS_MTIME_GATE_DAYS+=(-1)
  done
fi

if [[ "${#TARGETS[@]}" -ne "${#TARGETS_MTIME_GATE_DAYS[@]}" ]]; then
  echo "ERROR: TARGETS and TARGETS_MTIME_GATE_DAYS length mismatch" >&2
  exit 3
fi

DRY_RUN=true
EXISTED_BEFORE=()
GATE_RESULT=()  # "passed" | "skipped-recent" | "missing"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [-h|--help]

Options:
  --clean     Actually delete contents (default: dry-run).
  --dry-run   Preview cleanup without deleting.
  -h|--help   Show this help.

Each target may have an mtime gate (see TARGETS_MTIME_GATE_DAYS). When set,
the directory is only cleared if its mtime is older than the gate.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

size_of() {
  local path="$1"
  du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "0K"
}

mtime_epoch_of() {
  local path="$1"
  stat -f '%m' "$path" 2>/dev/null || echo 0
}

expand_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  eval echo "$path"
}

clear_dir_contents() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  find "$path" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$path" 2>/dev/null || true
}

gate_check() {
  # gate_check <expanded_path> <gate_days>
  # Echoes "passed" if the directory is missing OR mtime is older than gate.
  # Echoes "skipped-recent" if directory is newer than gate.
  local path="$1"
  local gate_days="$2"
  if [[ ! -d "$path" ]]; then
    echo "missing"
    return
  fi
  if [[ "$gate_days" -lt 0 ]]; then
    echo "passed"
    return
  fi
  local mtime_epoch now_epoch age_days
  mtime_epoch=$(mtime_epoch_of "$path")
  now_epoch=$(date '+%s')
  age_days=$(( (now_epoch - mtime_epoch) / 86400 ))
  if (( age_days >= gate_days )); then
    echo "passed"
  else
    echo "skipped-recent"
  fi
}

echo "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"
echo

echo "Before:"
target_index=0
for target in "${TARGETS[@]}"; do
  expanded=$(expand_path "$target")
  gate_days="${TARGETS_MTIME_GATE_DAYS[$target_index]}"
  if [[ -d "$expanded" ]]; then
    EXISTED_BEFORE[$target_index]=1
    mtime_epoch=$(mtime_epoch_of "$expanded")
    now_epoch=$(date '+%s')
    age_days=$(( (now_epoch - mtime_epoch) / 86400 ))
    if [[ "$gate_days" -lt 0 ]]; then
      echo "  $(size_of "$expanded")  $target  (age=${age_days}d, gate=none)"
    else
      echo "  $(size_of "$expanded")  $target  (age=${age_days}d, gate=${gate_days}d)"
    fi
  else
    EXISTED_BEFORE[$target_index]=0
    echo "  (missing)  $target"
  fi
  target_index=$(( target_index + 1 ))
done

echo
echo "Applying mtime gates and clearing ..."
target_index=0
for target in "${TARGETS[@]}"; do
  expanded=$(expand_path "$target")
  gate_days="${TARGETS_MTIME_GATE_DAYS[$target_index]}"
  result=$(gate_check "$expanded" "$gate_days")
  if [[ "$result" == "passed" ]] && ! _safety_reason="$(safety_gate "$expanded")"; then
    result="safety-skip"
    echo "  SAFETY-SKIP ($_safety_reason): $target"
  fi
  GATE_RESULT[$target_index]="$result"
  if [[ "$result" == "passed" ]]; then
    clear_dir_contents "$expanded"
  elif [[ "$result" == "skipped-recent" ]]; then
    mtime_epoch=$(mtime_epoch_of "$expanded")
    now_epoch=$(date '+%s')
    age_days=$(( (now_epoch - mtime_epoch) / 86400 ))
    echo "  GATE-SKIP (${age_days}d < ${gate_days}d): $target"
  fi
  target_index=$(( target_index + 1 ))
done

echo
echo "After:"
target_index=0
for target in "${TARGETS[@]}"; do
  expanded=$(expand_path "$target")
  gate_days="${TARGETS_MTIME_GATE_DAYS[$target_index]}"
  result="${GATE_RESULT[$target_index]:-missing}"
  if [[ -d "$expanded" ]]; then
    if [[ "$result" == "safety-skip" ]]; then
      echo "  $(size_of "$expanded")  $target  (kept — safety.local protected)"
    elif [[ "$result" == "skipped-recent" ]]; then
      echo "  $(size_of "$expanded")  $target  (kept — gate-skipped)"
    elif [[ "$DRY_RUN" == true ]]; then
      echo "  $(size_of "$expanded")  $target  (dry-run — would clear)"
    else
      echo "  $(size_of "$expanded")  $target  (NOT removed — see warnings above)"
    fi
  else
    if [[ "${EXISTED_BEFORE[$target_index]:-0}" -eq 1 ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        echo "  (would remove)  $target"
      else
        echo "  (removed)  $target"
      fi
    else
      echo "  (was missing)  $target"
    fi
  fi
  target_index=$(( target_index + 1 ))
done
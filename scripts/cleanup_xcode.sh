#!/usr/bin/env bash
# cleanup_xcode.sh — Clear rebuildable Xcode and simulator caches.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quarantine.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_roots.sh"

DRY_RUN=true
DELETE_ALL_SIMULATORS=false

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
SIM_TEMP="$HOME/Library/Developer/CoreSimulator/Temp"
SIM_CACHES="$HOME/Library/Developer/CoreSimulator/Caches"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--all-simulators] [-h|--help]

Options:
  --clean           Actually clear rebuildable Xcode data.
  --dry-run         Preview cleanup without deleting.
  --all-simulators  Also erase all simulator devices. Requires SIMULATORS_APPROVED=1 with --clean.
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)          DRY_RUN=false ;;
    --dry-run)        DRY_RUN=true ;;
    --all-simulators) DELETE_ALL_SIMULATORS=true ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && "$DELETE_ALL_SIMULATORS" == true && "${SIMULATORS_APPROVED:-0}" != "1" ]]; then
  echo "Refusing all-simulator deletion: set SIMULATORS_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  [[ -e "$path" ]] || { echo 0; return; }
  du -sk "$path" 2>/dev/null | awk '{print $1+0}' || echo 0
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
    else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
    else                  printf \"%dK\", $kb
  }"
}

clear_contents() {
  local label="$1" path="$2"
  if [[ ! -d "$path" ]]; then
    log "$label: missing, skipping ($path)"
    return
  fi
  local before_kb
  before_kb=$(size_kb "$path")
  if [[ "$DRY_RUN" == true ]]; then
    log "$label: [dry-run] would delete contents of $path ($(fmt_kb "$before_kb"))"
  else
    log "$label: deleting contents of $path ($(fmt_kb "$before_kb"))"
    if ! _safety_reason="$(safety_gate "$path" 2>/dev/null)"; then
      echo "SAFETY-SKIP $path ($_safety_reason)"
      return 0
    fi
    # Per-entry so every cache entry gets the same C14 rebuildable verdict and
    # a kept entry does not stop the rest of the sweep.
    local entry
    while IFS= read -r -d '' entry; do
      [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
      c14_remove "$entry" --kind rebuildable || true
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi
}

# Custom -derivedDataPath dirs sit outside DERIVED_DATA (~/dd_*, /private/tmp/pr*/dd,
# worldai_frontend build dirs). Only a dir that is itself DerivedData-shaped (or whose
# DerivedData/ child is) is a candidate; the removal goes through the C14 verdict
# (kind xcode-derived-data: live cwd, open files, secrets, repos) and is logged by
# quarantine_remove. Dirs written within CUSTOM_DD_IDLE_MINUTES, or whose recency
# cannot be measured, are kept.
CUSTOM_DD_IDLE_MINUTES=60

clean_custom_derived_data() {
  local ptmp utmp cand target seen=$'\n' before_kb
  # Same overridable roots as the other scratch sweepers; an unresolved root drops its globs.
  ptmp="$(scratch_roots_get_private_tmp)"
  utmp="$(scratch_roots_get_user_tmp)"
  for cand in "$HOME"/dd_* "$HOME"/wf*_dd* "$HOME"/*_dd* "$HOME"/.dd_* \
      ${ptmp:+"$ptmp"/*_dd* "$ptmp"/dd_* "$ptmp"/pr* "$ptmp"/pr*/dd \
      "$ptmp"/worldai_frontend/* "$ptmp"/worldai_frontend/*/* \
      "$ptmp"/worldai_claw/*/* "$ptmp"/ipad*/*} \
      ${utmp:+"$utmp"/tmp.* "$utmp"/*_dd* "$utmp"/dd_*}; do
    [[ -d "$cand" && ! -L "$cand" ]] || continue
    if _av_derived_data_shape "$cand"; then
      target="$cand"
    elif _av_derived_data_shape "$cand/DerivedData"; then
      target="$cand/DerivedData"
    else
      continue
    fi
    [[ "$seen" == *$'\n'"$target"$'\n'* ]] && continue
    seen+="$target"$'\n'
    local _safety_reason
    if ! _safety_reason="$(safety_gate "$target" 2>/dev/null)"; then
      log "Custom Xcode DerivedData: SAFETY-SKIP $target ($_safety_reason)"
      continue
    fi
    if worktree_is_recently_active_minutes "$target" "$CUSTOM_DD_IDLE_MINUTES"; then
      log "Custom Xcode DerivedData: written within ${CUSTOM_DD_IDLE_MINUTES}m or recency unmeasurable, keeping $target"
      continue
    fi
    before_kb=$(size_kb "$target")
    if [[ "$DRY_RUN" == true ]]; then
      log "Custom Xcode DerivedData: [dry-run] would remove $target ($(fmt_kb "$before_kb"))"
    else
      log "Custom Xcode DerivedData: removing $target ($(fmt_kb "$before_kb"))"
      c14_remove "$target" --kind xcode-derived-data || true
    fi
  done
}

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"

clear_contents "Xcode DerivedData" "$DERIVED_DATA"
clean_custom_derived_data
clear_contents "CoreSimulator Temp" "$SIM_TEMP"
clear_contents "CoreSimulator Caches" "$SIM_CACHES"

if command -v xcrun >/dev/null 2>&1; then
  if [[ "$DELETE_ALL_SIMULATORS" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would run: xcrun simctl shutdown all"
      log "[dry-run] would run: xcrun simctl delete all"
    else
      log "running: xcrun simctl shutdown all"
      xcrun simctl shutdown all 2>/dev/null || true
      log "running: xcrun simctl delete all"
      xcrun simctl delete all 2>/dev/null || true
    fi
  else
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would run: xcrun simctl delete unavailable"
    else
      log "running: xcrun simctl delete unavailable"
      xcrun simctl delete unavailable 2>/dev/null || true
    fi
  fi
else
  log "xcrun not found; simulator cleanup skipped."
fi

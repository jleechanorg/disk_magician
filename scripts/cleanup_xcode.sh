#!/usr/bin/env bash
# cleanup_xcode.sh — Clear rebuildable Xcode and simulator caches.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
DELETE_ALL_SIMULATORS=false
DELETE_SHUTDOWN_PR_SIMULATORS=false

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
SIM_TEMP="$HOME/Library/Developer/CoreSimulator/Temp"
SIM_CACHES="$HOME/Library/Developer/CoreSimulator/Caches"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--all-simulators] [--shutdown-pr-simulators] [-h|--help]

Options:
  --clean                    Actually clear rebuildable Xcode data.
  --dry-run                  Preview cleanup without deleting.
  --all-simulators           Also erase all simulator devices. Requires SIMULATORS_APPROVED=1 with --clean.
  --shutdown-pr-simulators   Delete Shutdown custom/PR simulator clones (preserves Booted and stock Apple devices). Requires SIMULATORS_APPROVED=1 with --clean.
  -h, --help                 Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)                    DRY_RUN=false ;;
    --dry-run)                  DRY_RUN=true ;;
    --all-simulators)           DELETE_ALL_SIMULATORS=true ;;
    --shutdown-pr-simulators)   DELETE_SHUTDOWN_PR_SIMULATORS=true ;;
    -h|--help)                  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && ( "$DELETE_ALL_SIMULATORS" == true || "$DELETE_SHUTDOWN_PR_SIMULATORS" == true ) && "${SIMULATORS_APPROVED:-0}" != "1" ]]; then
  echo "Refusing simulator deletion: set SIMULATORS_APPROVED=1 after reviewing dry-run output." >&2
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
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi
}

clean_custom_derived_data() {
  local cand
  local candidates=()
  for cand in "$HOME"/wf*_dd* "$HOME"/*_dd* "$HOME"/.dd_* /private/tmp/*_dd* /private/tmp/pr* /private/tmp/worldai_frontend/* /private/tmp/worldai_frontend/*/* /private/tmp/worldai_claw/*/* /private/tmp/ipad*/*; do
    [[ -d "$cand" && ! -L "$cand" ]] || continue
    local dup=false
    local c
    for c in "${candidates[@]:-}"; do
      if [[ "$c" == "$cand" ]]; then
        dup=true
        break
      fi
    done
    if [[ "$dup" == false ]]; then
      candidates+=("$cand")
    fi
  done

  local lsof_out=""
  local lsof_rc=0
  local lsof_timeout="${DISK_MAGICIAN_LSOF_TIMEOUT:-30s}"
  if command -v timeout >/dev/null 2>&1; then
    lsof_out="$(timeout "$lsof_timeout" lsof +w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    lsof_out="$(gtimeout "$lsof_timeout" lsof +w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  else
    lsof_out="$(lsof +w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  fi

  for cand in "${candidates[@]:-}"; do
    # Require at least one Xcode DerivedData marker
    if [[ ! -e "$cand/Build/Products" && \
          ! -e "$cand/ModuleCache.noindex" && \
          ! -e "$cand/Index.noindex" && \
          ! -e "$cand/CompilationCache.noindex" ]]; then
      continue
    fi

    # Check machine-local safety guidelines
    local _safety_reason
    if ! _safety_reason="$(safety_gate "$cand" 2>/dev/null)"; then
      log "Custom Xcode DerivedData: SAFETY-SKIP $cand ($_safety_reason)"
      continue
    fi

    # Check for active processes referencing this path in ps aux (e.g. xcodebuild, SWBBuildService)
    # shellcheck disable=SC2009
    if ps aux | grep -F "$cand" | grep -v grep >/dev/null 2>&1; then
      log "Custom Xcode DerivedData: active process referencing $cand, skipping"
      continue
    fi

    if [[ "$lsof_rc" -ne 0 || -z "$lsof_out" ]]; then
      log "Custom Xcode DerivedData: lsof failed or timed out (rc=$lsof_rc) on $cand, failing closed (skipping)"
      continue
    fi
    local alt_cand="${cand#/private}"
    if grep -qE "^n(${cand}|${alt_cand})(/|$)" <<<"$lsof_out"; then
      log "Custom Xcode DerivedData: open file handles in $cand, skipping"
      continue
    fi

    local before_kb
    before_kb=$(size_kb "$cand")
    if [[ "$DRY_RUN" == true ]]; then
      log "Custom Xcode DerivedData: [dry-run] would remove $cand ($(fmt_kb "$before_kb"))"
    else
      log "Custom Xcode DerivedData: removing $cand ($(fmt_kb "$before_kb"))"
      chmod -R u+w "$cand" 2>/dev/null || true
      rm -rf "$cand" 2>/dev/null || true
      if declare -f deletion_log >/dev/null 2>&1; then
        deletion_log "cleanup_xcode.sh" "remove" "$before_kb" "$cand" 2>/dev/null || true
      fi
    fi
  done
}

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"

clear_contents "Xcode DerivedData" "$DERIVED_DATA"
clean_custom_derived_data
clear_contents "CoreSimulator Temp" "$SIM_TEMP"
clear_contents "CoreSimulator Caches" "$SIM_CACHES"

clean_shutdown_pr_simulators() {
  local devices_dir="$HOME/Library/Developer/CoreSimulator/Devices"
  local sim_json
  sim_json="$(xcrun simctl list devices -j 2>/dev/null || true)"
  [[ -n "$sim_json" ]] || return 0

  while IFS=$'\t' read -r udid name; do
    [[ -n "$udid" ]] || continue
    local dev_path="$devices_dir/$udid"
    local _safety_reason
    if [[ -d "$dev_path" ]] && ! _safety_reason="$(safety_gate "$dev_path" 2>/dev/null)"; then
      log "Shutdown PR Simulators: SAFETY-SKIP $name ($udid) ($_safety_reason)"
      continue
    fi
    local before_kb=0
    [[ -d "$dev_path" ]] && before_kb=$(size_kb "$dev_path")
    if [[ "$DRY_RUN" == true ]]; then
      log "Shutdown PR Simulators: [dry-run] would delete $name ($udid) ($(fmt_kb "$before_kb"))"
    else
      log "Shutdown PR Simulators: deleting $name ($udid) ($(fmt_kb "$before_kb"))"
      xcrun simctl delete "$udid" 2>/dev/null || true
      if declare -f deletion_log >/dev/null 2>&1; then
        deletion_log "cleanup_xcode.sh" "simctl-delete" "$before_kb" "$dev_path ($name)" 2>/dev/null || true
      fi
    fi
  done < <(python3 -c '
import json, re, sys
stock_re = re.compile(r"^(iPhone|iPad|iPod|Apple Watch|Apple TV|Apple Vision)\b")
try:
    d = json.loads(sys.stdin.read())
    for runtime, devs in (d.get("devices") or {}).items():
        for dev in devs:
            if dev.get("state") != "Shutdown":
                continue
            name = (dev.get("name") or "").strip()
            udid = (dev.get("udid") or "").strip()
            if not udid or not name or stock_re.match(name):
                continue
            print(f"{udid}\t{name}")
except Exception:
    pass
' <<<"$sim_json")
}

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
    if [[ "$DELETE_SHUTDOWN_PR_SIMULATORS" == true ]]; then
      clean_shutdown_pr_simulators
    fi
  fi
else
  log "xcrun not found; simulator cleanup skipped."
fi

#!/usr/bin/env bash
# cleanup_xcode.sh — Clear rebuildable Xcode and simulator caches.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quarantine.sh"

DRY_RUN=true
DELETE_ALL_SIMULATORS=false
DELETE_SHUTDOWN_PR_SIMULATORS=false
PRUNE_SUPERSEDED_RUNTIMES=false

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
SIM_TEMP="$HOME/Library/Developer/CoreSimulator/Temp"
SIM_CACHES="$HOME/Library/Developer/CoreSimulator/Caches"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--all-simulators] [--shutdown-pr-simulators] [--prune-superseded-runtimes] [-h|--help]

Options:
  --clean                       Actually clear rebuildable Xcode data.
  --dry-run                     Preview cleanup without deleting.
  --all-simulators              Also erase all simulator devices. Requires SIMULATORS_APPROVED=1 with --clean.
  --shutdown-pr-simulators      Delete Shutdown custom/PR simulator clones (and idle >=2h Booted PR simulators with no active test runner). Requires SIMULATORS_APPROVED=1 with --clean.
  --prune-superseded-runtimes   Delete older deletable Simulator runtimes when a newer Ready runtime for the same platform is installed and 0 devices use the older runtime. Requires SIMULATORS_APPROVED=1 with --clean.
  -h, --help                    Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)                       DRY_RUN=false ;;
    --dry-run)                     DRY_RUN=true ;;
    --all-simulators)              DELETE_ALL_SIMULATORS=true ;;
    --shutdown-pr-simulators)      DELETE_SHUTDOWN_PR_SIMULATORS=true ;;
    --prune-superseded-runtimes)   PRUNE_SUPERSEDED_RUNTIMES=true ;;
    -h|--help)                     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && ( "$DELETE_ALL_SIMULATORS" == true || "$DELETE_SHUTDOWN_PR_SIMULATORS" == true || "$PRUNE_SUPERSEDED_RUNTIMES" == true ) && "${SIMULATORS_APPROVED:-0}" != "1" ]]; then
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
    # Per-entry so every cache entry gets the same C14 rebuildable verdict and
    # a kept entry does not stop the rest of the sweep.
    local entry
    while IFS= read -r -d '' entry; do
      [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
      c14_remove "$entry" --kind rebuildable || true
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi
}

clean_custom_derived_data() {
  local cand
  local candidates=()
  local darwin_tmp=""
  if command -v getconf >/dev/null 2>&1; then
    darwin_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    darwin_tmp="${darwin_tmp%/}"
    if [[ -n "$darwin_tmp" && -d "$darwin_tmp" ]]; then
      darwin_tmp="$(cd "$darwin_tmp" 2>/dev/null && pwd -P || printf '%s' "$darwin_tmp")"
    fi
  fi
  for cand in "$HOME"/dd_* "$HOME"/wf*_dd* "$HOME"/*_dd* "$HOME"/.dd_* /private/tmp/*_dd* /private/tmp/dd_* /private/tmp/pr* /private/tmp/pr*/dd /private/tmp/worldai_frontend/* /private/tmp/worldai_frontend/*/* /private/tmp/worldai_claw/*/* /private/tmp/ipad*/* ${darwin_tmp:+"$darwin_tmp"/tmp.* "$darwin_tmp"/*_dd* "$darwin_tmp"/dd_*}; do
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
    lsof_out="$(timeout "$lsof_timeout" lsof -w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    lsof_out="$(gtimeout "$lsof_timeout" lsof -w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  else
    lsof_out="$(lsof -w -n -P -F n 2>/dev/null)" || lsof_rc=$?
  fi

  for cand in "${candidates[@]:-}"; do
    if [[ ! -e "$cand/Build/Products" && \
          ! -e "$cand/ModuleCache.noindex" && \
          ! -e "$cand/Index.noindex" && \
          ! -e "$cand/CompilationCache.noindex" ]]; then
      continue
    fi
    local _safety_reason
    if ! _safety_reason="$(safety_gate "$cand" 2>/dev/null)"; then
      log "Custom Xcode DerivedData: SAFETY-SKIP $cand ($_safety_reason)"
      continue
    fi
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
      DM_DELETION_LOGGED=1 c14_remove "$cand" --kind rebuildable || true
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

  while IFS=$'\t' read -r udid name state; do
    [[ -n "$udid" ]] || continue
    local dev_path="$devices_dir/$udid"
    local _safety_reason
    if [[ -d "$dev_path" ]] && ! _safety_reason="$(safety_gate "$dev_path" 2>/dev/null)"; then
      log "PR Simulators: SAFETY-SKIP $name ($udid) ($_safety_reason)"
      continue
    fi
    if [[ "$state" == "Booted" ]]; then
      # Only shut down Booted non-stock PR simulator if no active xcodebuild/simctl/idb test runner references it
      # and its device plist / lastBootedAt is >= 2 hours old.
      # shellcheck disable=SC2009
      if ps aux | grep -E "(xcodebuild|simctl|xctest|maestro|detox).*($udid|$name)" | grep -v grep >/dev/null 2>&1; then
        log "PR Simulators: active test runner referencing Booted $name ($udid), skipping"
        continue
      fi
    fi
    local before_kb=0
    [[ -d "$dev_path" ]] && before_kb=$(size_kb "$dev_path")
    if [[ "$DRY_RUN" == true ]]; then
      log "PR Simulators: [dry-run] would delete $name ($udid, state=$state) ($(fmt_kb "$before_kb"))"
    else
      if [[ "$state" == "Booted" ]]; then
        log "PR Simulators: shutting down idle Booted PR simulator $name ($udid)"
        xcrun simctl shutdown "$udid" 2>/dev/null || true
      fi
      log "PR Simulators: deleting $name ($udid) ($(fmt_kb "$before_kb"))"
      xcrun simctl delete "$udid" 2>/dev/null || true
      if declare -f deletion_log >/dev/null 2>&1; then
        deletion_log "cleanup_xcode.sh" "simctl-delete" "$before_kb" "$dev_path ($name)" 2>/dev/null || true
      fi
    fi
  done < <(python3 - "$devices_dir" "$sim_json" <<'PY'
import json, os, re, sys, time
devices_dir = sys.argv[1]
stock_re = re.compile(r"^(iPhone|iPad|iPod|Apple Watch|Apple TV|Apple Vision)\b")
now = time.time()
try:
    d = json.loads(sys.argv[2])
    for runtime, devs in (d.get("devices") or {}).items():
        for dev in devs:
            state = dev.get("state") or ""
            name = (dev.get("name") or "").strip()
            udid = (dev.get("udid") or "").strip()
            if not udid or not name or stock_re.match(name):
                continue
            if state == "Shutdown":
                print(f"{udid}\t{name}\tShutdown")
            elif state == "Booted":
                plist_path = os.path.join(devices_dir, udid, "device.plist")
                try:
                    st = os.stat(plist_path)
                    if now - st.st_mtime >= 7200:
                        print(f"{udid}\t{name}\tBooted")
                except Exception:
                    pass
except Exception:
    pass
PY
  )

  # If no simulators remain Booted, clean stale /private/tmp/idb* staging directories
  local any_booted
  any_booted="$(xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    booted = [dev.get("udid") for devs in (d.get("devices") or {}).values() for dev in devs if dev.get("state") == "Booted"]
    print(len(booted))
except Exception:
    print(1)
')"
  if [[ "$any_booted" == "0" ]]; then
    local idb_dir
    for idb_dir in /private/tmp/idb /private/tmp/idb_*; do
      [[ -d "$idb_dir" && ! -L "$idb_dir" ]] || continue
      local idb_kb
      idb_kb=$(size_kb "$idb_dir")
      if [[ "$DRY_RUN" == true ]]; then
        log "Simulator IDB staging: [dry-run] would remove $idb_dir ($(fmt_kb "$idb_kb"))"
      else
        log "Simulator IDB staging: removing $idb_dir ($(fmt_kb "$idb_kb"))"
        c14_remove "$idb_dir" --kind rebuildable || true
      fi
    done
  fi
}

clean_superseded_runtimes() {
  local rt_json dev_json
  rt_json="$(xcrun simctl runtime list -j 2>/dev/null || true)"
  dev_json="$(xcrun simctl list devices -j 2>/dev/null || true)"
  [[ -n "$rt_json" && -n "$dev_json" ]] || return 0

  while IFS=$'\t' read -r rt_uuid rt_id version build size_bytes; do
    [[ -n "$rt_uuid" ]] || continue
    local size_kb_val=$(( size_bytes / 1024 ))
    if [[ "$DRY_RUN" == true ]]; then
      log "Superseded Simulator Runtimes: [dry-run] would delete $rt_id ($version / $build, uuid=$rt_uuid) ($(fmt_kb "$size_kb_val"))"
    else
      log "Superseded Simulator Runtimes: deleting $rt_id ($version / $build, uuid=$rt_uuid) ($(fmt_kb "$size_kb_val"))"
      xcrun simctl runtime delete "$rt_uuid" 2>/dev/null || true
      if declare -f deletion_log >/dev/null 2>&1; then
        deletion_log "cleanup_xcode.sh" "simctl-runtime-delete" "$size_kb_val" "$rt_id ($rt_uuid)" 2>/dev/null || true
      fi
    fi
  done < <(python3 - "$rt_json" "$dev_json" <<'PY'
import json, sys

def ver_tuple(v):
    parts = []
    for p in str(v or "").split("."):
        try:
            parts.append(int(p))
        except Exception:
            parts.append(0)
    return tuple(parts)

try:
    rts = json.loads(sys.argv[1])
    devs = json.loads(sys.argv[2]).get("devices") or {}
    by_plat = {}
    for uuid, info in (rts or {}).items():
        if not isinstance(info, dict):
            continue
        if info.get("state") != "Ready" or not info.get("deletable"):
            continue
        plat = info.get("platformIdentifier") or ""
        if not plat:
            continue
        by_plat.setdefault(plat, []).append(info)
    for plat, items in by_plat.items():
        if len(items) < 2:
            continue
        items.sort(key=lambda x: ver_tuple(x.get("version")), reverse=True)
        # Keep the newest Ready runtime for each platform; prune older ones if 0 devices remain on them
        for old in items[1:]:
            rt_id = old.get("runtimeIdentifier") or ""
            rt_devs = devs.get(rt_id) or []
            if len(rt_devs) == 0:
                print(f"{old.get('identifier')}\t{rt_id}\t{old.get('version')}\t{old.get('build')}\t{int(old.get('sizeBytes') or 0)}")
except Exception:
    pass
PY
  )
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
    if [[ "$PRUNE_SUPERSEDED_RUNTIMES" == true ]]; then
      clean_superseded_runtimes
    fi
  fi
else
  log "xcrun not found; simulator cleanup skipped."
fi

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

Environment:
  DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS  Per-call bound for `xcrun simctl` (default 60).
                                        A timed-out call is logged and skipped;
                                        it never fails the sweep.
  DISK_MAGICIAN_TIMEOUT_BIN             Timeout binary to use instead of probing
                                        timeout/gtimeout. Tests/diagnostics only.
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
    local entry kind
    while IFS= read -r -d '' entry; do
      [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
      kind=rebuildable
      # A per-project DerivedData dir gets the xcode-derived-data kind so its generated
      # build output (e.g. NativeRequestCredentials.o) is not read as a secret.
      [[ "$path" == "$DERIVED_DATA" ]] && _av_derived_data_shape "$entry" && kind=xcode-derived-data
      c14_remove "$entry" --kind "$kind" || true
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

# Simulator housekeeping talks to CoreSimulator, which can wedge for minutes
# (bead disk_magician-wcxs: an unbounded `simctl delete unavailable` produced no
# output for 6+ minutes and suppressed the rest of the run). Every simctl call
# goes through run_simctl, bounded by a timeout resolved with the same ladder as
# scripts/pressure_sweep.sh. A timeout is a logged SKIP, never fatal.
SIMCTL_TIMEOUT_SECONDS="${DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS:-60}"
if [[ "$SIMCTL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  # 10# keeps a leading-zero value from being parsed as invalid octal.
  SIMCTL_TIMEOUT_SECONDS=$((10#$SIMCTL_TIMEOUT_SECONDS))
else
  SIMCTL_TIMEOUT_SECONDS=60
fi
(( SIMCTL_TIMEOUT_SECONDS >= 1 )) || SIMCTL_TIMEOUT_SECONDS=60
SIMCTL_KILL_AFTER_S=10

TIMEOUT_CMD=""
if [[ -n "${DISK_MAGICIAN_TIMEOUT_BIN:-}" ]]; then
  if [[ "${DISK_MAGICIAN_TIMEOUT_BIN}" == */* ]]; then
    [[ -x "$DISK_MAGICIAN_TIMEOUT_BIN" ]] && TIMEOUT_CMD="$DISK_MAGICIAN_TIMEOUT_BIN"
  else
    TIMEOUT_CMD="$(command -v "$DISK_MAGICIAN_TIMEOUT_BIN" 2>/dev/null || true)"
  fi
elif command -v timeout &>/dev/null; then TIMEOUT_CMD="$(command -v timeout)"
elif command -v gtimeout &>/dev/null; then TIMEOUT_CMD="$(command -v gtimeout)"
elif [[ -x /opt/homebrew/bin/gtimeout ]]; then TIMEOUT_CMD=/opt/homebrew/bin/gtimeout
elif [[ -x /opt/homebrew/bin/timeout ]]; then TIMEOUT_CMD=/opt/homebrew/bin/timeout
elif [[ -x /usr/local/bin/gtimeout ]]; then TIMEOUT_CMD=/usr/local/bin/gtimeout
elif [[ -x /usr/local/bin/timeout ]]; then TIMEOUT_CMD=/usr/local/bin/timeout
fi
# Only GNU coreutils timeout/gtimeout understand --kill-after; probe with `true`
# so a non-supporting implementation falls back to the plain invocation.
TIMEOUT_KILL_AFTER_SUPPORTED=false
if [[ -n "$TIMEOUT_CMD" ]] && "$TIMEOUT_CMD" --kill-after=1 5 true >/dev/null 2>&1; then
  TIMEOUT_KILL_AFTER_SUPPORTED=true
fi

# reported in the final summary line so a skipped simulator section is visible
SIMCTL_STATUS="not-run"

# run_simctl <simctl args...> — always returns 0, like the previous `|| true`.
run_simctl() {
  local rc=0
  if [[ -z "$TIMEOUT_CMD" ]]; then
    log "simulator housekeeping skipped: no timeout(1)/gtimeout available to bound 'xcrun simctl $*'"
    SIMCTL_STATUS="skipped (no timeout binary)"
    return 0
  fi
  if [[ "$TIMEOUT_KILL_AFTER_SUPPORTED" == true ]]; then
    "$TIMEOUT_CMD" --kill-after="$SIMCTL_KILL_AFTER_S" "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl "$@" 2>/dev/null || rc=$?
  else
    "$TIMEOUT_CMD" "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl "$@" 2>/dev/null || rc=$?
  fi
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    log "CoreSimulator unavailable (simctl timed out after ${SIMCTL_TIMEOUT_SECONDS}s) — skipping simulator housekeeping"
    SIMCTL_STATUS="degraded (simctl timed out after ${SIMCTL_TIMEOUT_SECONDS}s)"
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    log "xcrun simctl $*: rc=${rc} (non-fatal)"
  fi
  SIMCTL_STATUS="completed"
  return 0
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
      SIMCTL_STATUS="dry-run"
    else
      log "running: xcrun simctl shutdown all"
      run_simctl shutdown all
      log "running: xcrun simctl delete all"
      run_simctl delete all
    fi
  else
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would run: xcrun simctl delete unavailable"
      SIMCTL_STATUS="dry-run"
    else
      log "running: xcrun simctl delete unavailable"
      run_simctl delete unavailable
    fi
  fi
else
  log "xcrun not found; simulator cleanup skipped."
  SIMCTL_STATUS="skipped (xcrun not found)"
fi

log "summary: simulator housekeeping ${SIMCTL_STATUS}"

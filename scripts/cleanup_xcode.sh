#!/usr/bin/env bash
# cleanup_xcode.sh — Clear rebuildable Xcode and simulator caches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AV_DIR="$SCRIPT_DIR/lib"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$SCRIPT_DIR/lib/quarantine.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$SCRIPT_DIR/lib/scratch_roots.sh"

DRY_RUN=true
DELETE_ALL_SIMULATORS=false
# Approval-gated targeted removals; when any is selected ONLY those run (no default sweep).
DELETE_RUNTIMES=""
DEVICE_SUPPORT=false
DELETE_DEVICES=()
XCODE_APPS=()
DEVICE_SUPPORT_DIR="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
XCODE_APP_ROOT="${DISK_MAGICIAN_XCODE_APP_ROOT:-/Applications}"  # tests only

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
SIM_TEMP="$HOME/Library/Developer/CoreSimulator/Temp"
SIM_CACHES="$HOME/Library/Developer/CoreSimulator/Caches"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--all-simulators]
       [--delete-runtimes <id,...>] [--device-support] [--delete-device <udid>]
       [--remove-xcode-app <path>] [-h|--help]

Options:
  --clean           Actually clear rebuildable Xcode data.
  --dry-run         Preview cleanup without deleting.
  --all-simulators  Also erase all simulator devices. Requires SIMULATORS_APPROVED=1 with --clean.
  --delete-runtimes <id,...>   Delete simulator runtimes (image id or build, e.g. 22G86).
                    Refuses a runtime with any non-Shutdown device. Needs RUNTIMES_APPROVED=1 with --clean.
  --device-support  Clear ~/Library/Developer/Xcode/iOS DeviceSupport (regenerates on device
                    reconnect). Needs DEVICE_SUPPORT_APPROVED=1 with --clean.
  --delete-device <udid>       Delete one simulator device (repeatable). Refuses a non-Shutdown
                    device. Needs DEVICES_APPROVED=1 with --clean.
  --remove-xcode-app <path>    Remove an /Applications/Xcode*.app bundle (repeatable). Refuses the
                    xcode-select active one or a running one. Needs XCODE_APP_APPROVED=1 with --clean.
  With any of the four options above ONLY those removals run (dry-run unless --clean).
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
    --delete-runtimes) [[ $# -ge 2 ]] || { echo "--delete-runtimes needs a value" >&2; exit 2; }
                       DELETE_RUNTIMES="${DELETE_RUNTIMES:+$DELETE_RUNTIMES,}$2"; shift ;;
    --device-support) DEVICE_SUPPORT=true ;;
    --delete-device)  [[ $# -ge 2 ]] || { echo "--delete-device needs a udid" >&2; exit 2; }
                      DELETE_DEVICES+=("$2"); shift ;;
    --remove-xcode-app) [[ $# -ge 2 ]] || { echo "--remove-xcode-app needs a path" >&2; exit 2; }
                      XCODE_APPS+=("$2"); shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && "$DELETE_ALL_SIMULATORS" == true && "${SIMULATORS_APPROVED:-0}" != "1" ]]; then
  echo "Refusing all-simulator deletion: set SIMULATORS_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

# Each approval-gated removal needs its own env var for a real (--clean) run.
require_approval() { # <var> <what>
  if [[ "$DRY_RUN" != true && "${!1:-0}" != "1" ]]; then
    echo "Refusing $2: set $1=1 after reviewing the dry-run output." >&2
    exit 3
  fi
}
[[ -n "$DELETE_RUNTIMES" ]] && require_approval RUNTIMES_APPROVED "simulator runtime deletion"
[[ "$DEVICE_SUPPORT" == true ]] && require_approval DEVICE_SUPPORT_APPROVED "iOS DeviceSupport removal"
[[ ${#DELETE_DEVICES[@]} -gt 0 ]] && require_approval DEVICES_APPROVED "simulator device deletion"
[[ ${#XCODE_APPS[@]} -gt 0 ]] && require_approval XCODE_APP_APPROVED "Xcode app removal"

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

# _av_xcode_device_support <path>: rc 0 only for an entry dir directly under
# ~/Library/Developer/Xcode/iOS DeviceSupport that passes _av_rebuildable.
_av_xcode_device_support() (
  local p="$1" ds_root
  [[ -n "${HOME:-}" && "$HOME" != / && -d "$p" && ! -L "$p" ]] || return 1
  ds_root="$(cd "${DEVICE_SUPPORT_DIR:-$HOME/Library/Developer/Xcode/iOS DeviceSupport}" 2>/dev/null && pwd -P)" || return 1
  p="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$ds_root" && "${p%/*}" == "$ds_root" ]] || return 1
  _av_rebuildable "$p" >/dev/null
)

artifact_removal_verdict() {
  [[ "${1:-}" == --self-test ]] && { _av_self_test; return 0; }
  local tmpdir inv result reason admin_inv secret_kind="" a prev=""
  local -a args=()
  for a in "$@"; do
    if [[ "$prev" == "--kind" && "$a" == "xcode-device-support" ]]; then
      secret_kind="xcode-device-support"
      if _av_xcode_device_support "${1:-}"; then
        args+=("rebuildable")
      else
        args+=("$a")
      fi
    else
      args+=("$a")
    fi
    prev="$a"
  done
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/c14-verdict.XXXXXX")" || { echo kept:check-failed; return 0; }
  inv="$tmpdir/inventory.json"
  admin_inv="$tmpdir/admin.jsonl"
  result="$(GIT_OPTIONAL_LOCKS=0 C14_SECRET_KIND="$secret_kind" C14_INVENTORY_FILE="$inv" C14_ADMIN_INVENTORY="$admin_inv" C14_INVENTORY_OUT="$admin_inv" _av_artifact_removal_verdict "${args[@]+"${args[@]}"}")"
  if [[ ( "$result" == kept:* || "$result" == deferred:* ) && -f "$inv" && -n "${DISK_MAGICIAN_C14_LEDGER:-}" ]]; then
    reason=${result#*:}
    python3 "$_AV_DIR/../c14_probe.py" account "$inv" "$DISK_MAGICIAN_C14_LEDGER" "$reason" >/dev/null 2>&1 || true
  fi
  rm -f "$inv" "$admin_inv"
  rmdir "$tmpdir" 2>/dev/null || true
  echo "${result:-kept:check-failed}"
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
      # build output (e.g. NativeRequestCredentials.o) is not read as a secret; an
      # iOS DeviceSupport entry gets xcode-device-support so extracted system symbols
      # under Symbols/ (e.g. SharedWebCredentials.framework) do not trip the secret gate.
      [[ "$path" == "$DERIVED_DATA" ]] && _av_derived_data_shape "$entry" && kind=xcode-derived-data
      [[ "$path" == "$DEVICE_SUPPORT_DIR" && -d "$entry" && ! -L "$entry" ]] && kind=xcode-device-support
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
# These are safety retention floors, not operator tuning knobs. Keep them fixed
# so an ambient environment cannot make freshly-written build output eligible.
CUSTOM_DD_IDLE_MINUTES=60

clean_custom_derived_data() {
  local ptmp utmp cand target seen=$'\n' before_kb
  # Same overridable roots as the other scratch sweepers; an unresolved root drops its globs.
  ptmp="$(scratch_roots_get_private_tmp)"
  utmp="$(scratch_roots_get_user_tmp)"
  for cand in "$HOME"/dd_* "$HOME"/wf*_dd* "$HOME"/*_dd* "$HOME"/.dd_* \
      ${ptmp:+"$ptmp"/*_dd* "$ptmp"/dd_* "$ptmp"/dd-* "$ptmp"/pr* "$ptmp"/pr*/dd \
      "$ptmp"/worldai-ios-* \
      "$ptmp"/worldai_frontend*/* "$ptmp"/worldai_frontend*/*/* \
      "$ptmp"/*-native*/* "$ptmp"/*-native*/build/* \
      "$ptmp"/worldai_claw/*/* "$ptmp"/ipad*/*} \
      ${utmp:+"$utmp"/tmp.* "$utmp"/*_dd* "$utmp"/dd_* "$utmp"/dd-*}; do
    [[ -d "$cand" && ! -L "$cand" ]] || continue
    [[ "${cand##*/}" =~ ^worldai-ios-release-[0-9]+-[0-9]+$ ]] && continue
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

# worldai iOS release CI leaves /private/tmp/worldai-ios-release-<run>-<attempt>/ with
# rebuildable DerivedData/ and verify-unpacked/ beside the archive, export/ and receipts
# (kept: they await App Store Connect processing). Only a finished dir (receipts/export.json)
# whose newest content is idle IOS_RELEASE_IDLE_MINUTES loses those two children, through
# the same C14 verdict (live cwd, open files, secrets).
IOS_RELEASE_IDLE_MINUTES=1440

clean_ios_release_scratch() {
  local ptmp dir sub before_kb _safety_reason
  ptmp="$(scratch_roots_get_private_tmp)"
  [[ -n "$ptmp" ]] || return 0
  for dir in "$ptmp"/worldai-ios-release-*-*; do
    [[ "${dir##*/}" =~ ^worldai-ios-release-[0-9]+-[0-9]+$ && -d "$dir" && ! -L "$dir" ]] || continue
    if [[ ! -f "$dir/receipts/export.json" || -L "$dir/receipts/export.json" ]]; then
      log "iOS release scratch: no completion receipt, keeping $dir"
      continue
    fi
    if worktree_is_recently_active_minutes "$dir" "$IOS_RELEASE_IDLE_MINUTES"; then
      log "iOS release scratch: written within ${IOS_RELEASE_IDLE_MINUTES}m or recency unmeasurable, keeping $dir"
      continue
    fi
    for sub in DerivedData verify-unpacked; do
      [[ -d "$dir/$sub" && ! -L "$dir/$sub" ]] || continue
      if ! _safety_reason="$(safety_gate "$dir/$sub" 2>/dev/null)"; then
        log "iOS release scratch: SAFETY-SKIP $dir/$sub ($_safety_reason)"
        continue
      fi
      before_kb=$(size_kb "$dir/$sub")
      if [[ "$DRY_RUN" == true ]]; then
        log "iOS release scratch: [dry-run] would remove $dir/$sub ($(fmt_kb "$before_kb"))"
      else
        log "iOS release scratch: removing $dir/$sub ($(fmt_kb "$before_kb"))"
        local _retry=5
        while (( _retry-- > 0 )); do
          c14_remove "$dir/$sub" --kind xcode-derived-data && break
          [[ -e "$dir/$sub" ]] || break
          sleep 1
        done
      fi
    done
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
  # The WORST outcome wins: a later successful call must never overwrite an
  # earlier timeout/skip, or the summary would report "completed" for a run in
  # which simulator housekeeping was actually degraded and silently dropped
  # (/advice review of PR #249 raised exactly this). Precedence:
  # degraded > skipped > completed.
  if [[ "$SIMCTL_STATUS" != degraded* && "$SIMCTL_STATUS" != skipped* ]]; then
    SIMCTL_STATUS="completed"
  fi
  return 0
}

log "Cleanup mode: $( [[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY )"

# --- Approval-gated targeted removals ----------------------------------------
# Shared bounded simctl invocation that captures stdout (run_simctl is for
# fire-and-forget calls). rc 124/137 = timeout; callers fail closed on any rc != 0.
simctl_bounded() {
  [[ -n "$TIMEOUT_CMD" ]] || return 127
  if [[ "$TIMEOUT_KILL_AFTER_SUPPORTED" == true ]]; then
    "$TIMEOUT_CMD" --kill-after="$SIMCTL_KILL_AFTER_S" "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl "$@" 2>/dev/null
  else
    "$TIMEOUT_CMD" "$SIMCTL_TIMEOUT_SECONDS" xcrun simctl "$@" 2>/dev/null
  fi
}

TARGETED_FAILED=0
SIM_TMP=""
sim_snapshot() { # writes runtime + device JSON; rc 1 (fail closed) if either listing fails
  SIM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-xcode-sim.XXXXXX")" || return 1
  command -v xcrun >/dev/null 2>&1 || { log "xcrun not found; cannot verify simulator state"; return 1; }
  simctl_bounded runtime list -j >"$SIM_TMP/rt.json" && simctl_bounded list devices -j >"$SIM_TMP/dev.json" \
    || { log "simctl listing failed or timed out; refusing simulator removals (fail closed)"; return 1; }
}

# Prints one line: "OK<TAB>fields..." or "REFUSE<TAB>reason".
sim_resolve() { # <kind: runtime|device> <id>
  python3 -I -c '
import json, sys
kind, want, rtf, devf = sys.argv[1:5]
try:
    rts = json.load(open(rtf)); devs = json.load(open(devf)).get("devices", {})
except Exception as e:
    print("REFUSE\tunparseable simctl JSON"); sys.exit(0)
if kind == "runtime":
    hits = [r for r in rts.values() if want in (r.get("identifier"), r.get("build"))]
    if len(hits) != 1:
        print("REFUSE\t%d runtimes match %s" % (len(hits), want)); sys.exit(0)
    r = hits[0]
    users = [d for d in devs.get(r.get("runtimeIdentifier"), []) if d.get("state") != "Shutdown"]
    if users:
        print("REFUSE\truntime %s in use by %s device %s" % (r.get("version"), users[0].get("state"), users[0].get("name"))); sys.exit(0)
    print("OK\t%s\t%s\t%s\t%d" % (r["identifier"], r.get("build"), r.get("version"), int(r.get("sizeBytes", 0)) // 1024))
else:
    for ds in devs.values():
        for d in ds:
            if d.get("udid") == want:
                if d.get("state") != "Shutdown":
                    print("REFUSE\tdevice %s is %s" % (d.get("name"), d.get("state"))); sys.exit(0)
                print("OK\t%s\t%s\t%d" % (d["udid"], d.get("name"), int(d.get("dataPathSize", 0)) // 1024)); sys.exit(0)
    print("REFUSE\tdevice %s not found" % want)
' "$1" "$2" "$SIM_TMP/rt.json" "$SIM_TMP/dev.json"
}

remove_runtime() { # <id|build>
  local out kind uuid build version kb
  out="$(sim_resolve runtime "$1")"
  IFS=$'\t' read -r kind uuid build version kb <<<"$out"
  if [[ "$kind" != OK ]]; then log "runtime $1: REFUSED (${uuid:-no reason})"; TARGETED_FAILED=1; return 0; fi
  if [[ "$DRY_RUN" == true ]]; then
    log "runtime $1: [dry-run] would run: xcrun simctl runtime delete $uuid (iOS $version $build, ~$(fmt_kb "$kb"))"
    return 0
  fi
  log "runtime $1: deleting $uuid (iOS $version $build, ~$(fmt_kb "$kb"))"
  if simctl_bounded runtime delete "$uuid" >/dev/null; then
    deletion_log_removal "simruntime:$uuid" "$kb" remove_runtime "iOS $version $build"
  else
    log "runtime $1: simctl runtime delete failed or timed out"; TARGETED_FAILED=1
  fi
}

remove_device() { # <udid>
  local out kind udid name kb
  out="$(sim_resolve device "$1")"
  IFS=$'\t' read -r kind udid name kb <<<"$out"
  if [[ "$kind" != OK ]]; then log "device $1: REFUSED (${udid:-no reason})"; TARGETED_FAILED=1; return 0; fi
  if [[ "$DRY_RUN" == true ]]; then
    log "device $1: [dry-run] would run: xcrun simctl delete $udid ($name, ~$(fmt_kb "$kb"))"
    return 0
  fi
  log "device $1: deleting $udid ($name, ~$(fmt_kb "$kb"))"
  if simctl_bounded delete "$udid" >/dev/null; then
    deletion_log_removal "simdevice:$udid" "$kb" remove_sim_device "$name"
  else
    log "device $1: simctl delete failed or timed out"; TARGETED_FAILED=1
  fi
}

remove_xcode_app() { # <path>
  local app="${1%/}" active active_app ver kb reason=""
  if [[ ! -d "$app" || -L "$app" || "$app" != "$XCODE_APP_ROOT"/*.app ]]; then
    reason="not a real directory $XCODE_APP_ROOT/*.app"
  elif [[ "$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)" != com.apple.dt.Xcode ]]; then
    reason="not an Xcode bundle"
  elif ! active="$(xcode-select -p 2>/dev/null)" || [[ -z "$active" ]]; then
    reason="cannot determine the xcode-select active developer dir (fail closed)"
  else
    app="$(cd "$app" && pwd -P)"
    active_app="${active%%.app/*}.app"
    if [[ "$app" == "$active_app" ]]; then reason="is the xcode-select active Xcode ($active)"
    elif pgrep -f "$app/Contents/MacOS/Xcode" >/dev/null 2>&1; then reason="Xcode from this bundle is running"
    fi
  fi
  if [[ -n "$reason" ]]; then log "xcode app $1: REFUSED ($reason)"; TARGETED_FAILED=1; return 0; fi
  ver="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
  kb=$(size_kb "$app")
  if [[ "$DRY_RUN" == true ]]; then
    log "xcode app $app: [dry-run] would remove Xcode $ver (du ~$(fmt_kb "$kb"); APFS clone sharing with other Xcodes can make the real df gain smaller)"
    return 0
  fi
  if ! _safety_reason="$(safety_gate "$app" 2>/dev/null)"; then
    echo "SAFETY-SKIP $app ($_safety_reason)"; TARGETED_FAILED=1; return 0
  fi
  log "xcode app $app: removing Xcode $ver (du ~$(fmt_kb "$kb"))"
  c14_remove "$app" --kind rebuildable || { log "xcode app $app: removal failed"; TARGETED_FAILED=1; }
}

run_targeted_removals() {
  local id udid app
  if [[ -n "$DELETE_RUNTIMES" || ${#DELETE_DEVICES[@]} -gt 0 ]]; then
    if sim_snapshot; then
      if [[ -n "$DELETE_RUNTIMES" ]]; then
        local -a ids; IFS=, read -r -a ids <<<"$DELETE_RUNTIMES"
        for id in "${ids[@]}"; do [[ -n "$id" ]] && remove_runtime "$id"; done
      fi
      for udid in ${DELETE_DEVICES[@]+"${DELETE_DEVICES[@]}"}; do remove_device "$udid"; done
    else
      TARGETED_FAILED=1
    fi
    [[ -n "$SIM_TMP" ]] && rm -rf "${SIM_TMP:?}"
  fi
  [[ "$DEVICE_SUPPORT" == true ]] && clear_contents "iOS DeviceSupport" "$DEVICE_SUPPORT_DIR"
  for app in ${XCODE_APPS[@]+"${XCODE_APPS[@]}"}; do remove_xcode_app "$app"; done
  log "summary: targeted removals $( [[ "$TARGETED_FAILED" == 0 ]] && echo completed || echo 'had refusals/failures')"
  return "$TARGETED_FAILED"
}

if [[ -n "$DELETE_RUNTIMES" || "$DEVICE_SUPPORT" == true || ${#DELETE_DEVICES[@]} -gt 0 || ${#XCODE_APPS[@]} -gt 0 ]]; then
  log "Targeted removals only: default sweeps skipped"
  run_targeted_removals
  exit $?
fi

clear_contents "Xcode DerivedData" "$DERIVED_DATA"
clean_custom_derived_data
clean_ios_release_scratch
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

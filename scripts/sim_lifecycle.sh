#!/bin/bash
# shellcheck shell=bash
# sim_lifecycle.sh — lease/prune lifecycle for iOS Simulator devices.
#
# Design: ~/roadmap/sq-ios-simulator-reuse-design-2026-11-16.md
# Contract: ~/roadmap/sq-ios-simulator-lease-contract-2026-11-16.md
#
# Safety rules this module implements (all fail closed):
#   * A device is reclaimable ONLY with a durable release receipt for its current
#     lease generation. Age never substitutes for a release receipt, and device
#     directory mtime / CoreSimulator logs / boot history are NOT proof of
#     abandonment.
#   * A Booted device is never a prune candidate.
#   * Unknown liveness or unmeasurable state preserves the device.
#   * Release is fenced by an opaque per-generation token, never by UDID or PID.
#   * The raw token never reaches a receipt or a log; only a fingerprint does.
#
# The lease registry is a directory per UDID under the state dir, which gives
# atomic acquisition via mkdir (the same single-writer primitive the worktree
# lease registry already uses).

# Resolved on EVERY call, never captured at source time: a captured value ignores
# a caller's DISK_MAGICIAN_STATE_DIR override, which made the test suite write
# leases into the real state dir (found 2026-11-16).
sim_state_root()    { printf '%s\n' "${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"; }
sim_lease_dir()     { printf '%s/sim_leases\n' "$(sim_state_root)"; }
sim_receipt_dir()   { printf '%s/receipts\n' "$(sim_state_root)"; }
SIM_DEFAULT_FLOOR_MINUTES=2880

sim_now() { date +%s; }

# The simulator floor is FIXED at 48 h. Unlike disposable scratch, a device is
# expensive-to-rebuild evidence state, so DISK_MAGICIAN_AGE_FLOOR_MINUTES can
# lengthen it but NEVER shorten it (review finding, 2026-11-16: an env var must
# not turn a 48 h floor into 2 h).
SIM_HARD_FLOOR_MINUTES=2880

sim_floor_minutes() {
  local m="${DISK_MAGICIAN_AGE_FLOOR_MINUTES:-}" out=$SIM_HARD_FLOOR_MINUTES
  if [[ "$m" =~ ^[0-9]{1,7}$ ]]; then
    m=$((10#$m))
    (( m > out )) && out=$m
  fi
  printf '%s\n' "$out"
}

# sim_device_root — the CoreSimulator device store, or the test fixture root.
sim_device_root() {
  if [[ -n "${DISK_MAGICIAN_SIM_FIXTURE_ROOT:-}" ]]; then
    printf '%s\n' "${DISK_MAGICIAN_SIM_FIXTURE_ROOT}"
  else
    printf '%s\n' "$HOME/Library/Developer/CoreSimulator/Devices"
  fi
}

# sim_fixture_device <root> <udid> <name> <state> <age_hours|-1>
# Test-only helper; never called in production paths.
sim_fixture_device() {
  local root="$1" udid="$2" name="$3" state="$4" age_h="$5"
  local d="$root/$udid"
  mkdir -p "$d"
  printf '%s\n' "$name" >"$d/.name"
  printf '%s\n' "$state" >"$d/.state"
  if [[ "$age_h" == "-1" ]]; then
    # unmeasurable: remove the marker the age reader depends on
    : >"$d/.no_mtime"
  else
    local f="$d/payload.bin"
    : >"$f"
    local t=$(( $(sim_now) - age_h * 3600 ))
    touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)" "$f" 2>/dev/null || true
  fi
}

# sim_devices — one line per device: udid<TAB>name<TAB>state<TAB>newest_mtime
#
# Production reads `xcrun simctl list devices --json`, which is authoritative for
# name and state. `lastUsedAt` is used ONLY to measure idle time/order candidates;
# it is never proof of abandonment (the release receipt is). The fixture root is
# a test-only path and is never consulted unless the env var is set.
sim_devices() {
  if [[ -z "${DISK_MAGICIAN_SIM_FIXTURE_ROOT:-}" ]] && command -v xcrun >/dev/null 2>&1; then
    xcrun simctl list devices --json 2>/dev/null | python3 -c '
import json,sys,calendar,time
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
now=time.time()
for runtime, devs in (d.get("devices") or {}).items():
    for x in devs or []:
        lu=x.get("lastUsedAt") or ""
        ts=""
        if lu:
            try: ts=int(calendar.timegm(time.strptime(lu,"%Y-%m-%dT%H:%M:%SZ")))
            except Exception: ts=""
        print("\t".join([x.get("udid",""), x.get("name",""), x.get("state","unknown"), str(ts)]))
' 2>/dev/null
    return 0
  fi

  local root udid name state newest
  root="$(sim_device_root)"
  [[ -d "$root" ]] || return 0
  for udid_path in "$root"/*; do
    [[ -d "$udid_path" && ! -L "$udid_path" ]] || continue
    udid="$(basename "$udid_path")"
    if [[ -f "$udid_path/.name" ]]; then
      name="$(cat "$udid_path/.name" 2>/dev/null)"
      state="$(cat "$udid_path/.state" 2>/dev/null)"
      if [[ -f "$udid_path/.no_mtime" ]]; then
        newest=""
      else
        newest="$(find "$udid_path" -type f ! -name '.*' -exec stat -f '%m' {} + 2>/dev/null \
                  | sort -rn | head -1)"
        [[ -z "$newest" ]] && newest="$(stat -f '%m' "$udid_path" 2>/dev/null)"
      fi
    else
      name="$(basename "$udid_path")"
      state="unknown"
      newest=""
    fi
    printf '%s\t%s\t%s\t%s\n' "$udid" "$name" "$state" "$newest"
  done
}

sim_lease_path()   { printf '%s/%s\n' "$(sim_lease_dir)" "$1"; }

# Generation is persisted in its OWN file that survives release, so a later lease
# can never reuse a superseded generation number (review finding: release deleted
# the lease dir, so generation reset to 1 and receipt validation could not tell a
# new lease from the old one).
sim_generation_path() { printf '%s/gen/%s\n' "$(sim_state_root)" "$1"; }
sim_release_lock_path() { printf '%s/lock/%s.release-lock\n' "$(sim_state_root)" "$1"; }
sim_next_generation() {
  local udid="$1" p prev=0
  p="$(sim_generation_path "$udid")"
  mkdir -p "$(dirname "$p")" 2>/dev/null || true
  [[ -f "$p" ]] && prev="$(cat "$p" 2>/dev/null)"
  # Corruption must NOT reset the counter to 1 (review): a lower generation would
  # let an old receipt validate again. Fail closed instead.
  if [[ -f "$p" && ! "$prev" =~ ^[0-9]+$ ]]; then
    echo "sim: generation counter corrupt at $p; refusing (delete it deliberately to reset)" >&2
    return 1
  fi
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  if ! printf '%s\n' "$(( prev + 1 ))" >"$p" 2>/dev/null; then
    echo "sim: cannot persist generation at $p; refusing" >&2
    return 1
  fi
  printf '%s\n' "$(( prev + 1 ))"
}
sim_generation()   { cat "$(sim_lease_path "$1")/generation" 2>/dev/null; }
sim_lease_owner()  { cat "$(sim_lease_path "$1")/owner" 2>/dev/null; }

sim_is_leased() {
  local d; d="$(sim_lease_path "$1")"
  [[ -d "$d" && -f "$d/token_fingerprint" ]]
}

sim_token_fingerprint() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1; }

sim_status_json() {
  local first=1 udid name state newest leased owner gen age
  printf '{\n  "schema_version": 1,\n  "devices": [\n'
  while IFS=$'\t' read -r udid name state newest; do
    [[ -n "$udid" ]] || continue
    leased=false; owner=""; gen=""
    if sim_is_leased "$udid"; then leased=true; owner="$(sim_lease_owner "$udid")"; gen="$(sim_generation "$udid")"; fi
    age=null
    [[ "$newest" =~ ^[0-9]+$ ]] && age=$(( ($(sim_now) - newest) / 60 ))
    [[ "$first" -eq 1 ]] || printf ',\n'
    first=0
    printf '    {"udid": "%s", "name": "%s", "state": "%s", "lease_owner": %s, "lease_generation": %s, "idle_minutes": %s}' \
      "$udid" "$name" "$state" \
      "$( [[ -n "$owner" ]] && printf '"%s"' "$owner" || printf 'null' )" \
      "$( [[ -n "$gen" ]] && printf '%s' "$gen" || printf 'null' )" \
      "$age"
  done < <(sim_devices)
  printf '\n  ]\n}\n'
}

# sim_lease — atomically acquire one unleased device. mkdir is the single-writer
# primitive: exactly one racer wins per UDID.
sim_lease() {
  local wait_seconds=120 runtime=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait-seconds) wait_seconds="${2:?}"; shift 2 ;;
      --runtime) runtime="${2:?}"; shift 2 ;;
      --json) shift ;;
      *) shift ;;
    esac
  done
  mkdir -p "$(sim_lease_dir)" || { echo "sim lease: cannot create lease dir" >&2; return 22; }

  local deadline=$(( $(sim_now) + wait_seconds )) udid name state newest
  while :; do
    while IFS=$'\t' read -r udid name state newest; do
      [[ -n "$udid" ]] || continue
      # only pool devices are leaseable; task-named devices need explicit adopt
      [[ "$name" == wai-shared-* ]] || continue
      # Never hand out a Booted (in-use) device, and require a positive safe state.
      [[ "$state" == "Shutdown" ]] || continue
      # Honour the requested runtime. Names are the only runtime signal the
      # device list exposes, so this is a name match by necessity; the device
      # type is verified at create time.
      if [[ -n "$runtime" ]]; then
        local rt_slug; rt_slug="$(printf '%s' "$runtime" | tr ' .' '--' | tr 'A-Z' 'a-z')"
        [[ "$name" == *"$runtime"* || "$name" == *"$rt_slug"* ]] || continue
      fi
      # A device still being registered by `create` is not yet leaseable
      # (review P0: it became leaseable before create finished registering it).
      sim_name_reserved "$udid" "$name" && continue
      local d; d="$(sim_lease_path "$udid")"
      # Serialize against prune/release with the same per-UDID lock. Without this,
      # prune's locked re-check could still race an acquire and delete a device
      # that a caller had just leased (review P0, reproduced by /dot).
      local alock; alock="$(sim_release_lock_path "$udid")"
      mkdir -p "$(dirname "$alock")" 2>/dev/null || true
      local aw=0 alock_held=false
      # alock_held reflects OUR successful mkdir only. Checking `[[ -d $alock ]]`
      # was wrong: a foreign holder's directory also satisfies it, so a losing
      # acquirer proceeded and then rmdir'd the other process's lock (review P0).
      if mkdir "$alock" 2>/dev/null; then
        alock_held=true
      else
        while (( aw < 50 )); do
          sleep 0.1; aw=$((aw+1))
          if mkdir "$alock" 2>/dev/null; then alock_held=true; break; fi
        done
      fi
      if [[ "$alock_held" != true ]]; then
        echo "sim lease: acquire lock busy for $udid; skipping" >&2
        continue
      fi
      if ! mkdir "$d" 2>/dev/null; then
        rmdir "$alock" 2>/dev/null || true
        continue
      fi
      if true; then
        local token="lt_$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        local gen
        if ! gen="$(sim_next_generation "$udid")" || [[ -z "$gen" ]]; then
          rmdir "$d" 2>/dev/null || true
          rmdir "$alock" 2>/dev/null || true
          echo "sim lease: cannot allocate generation (corrupt/unwritable counter); refusing" >&2
          return 22
        fi
        printf '%s\n' "$gen" >"$d/generation"
        printf '%s\n' "${WORLDAI_SIM_OWNER:-$(id -un)}" >"$d/owner"
        printf '%s\n' "$(sim_token_fingerprint "$token")" >"$d/token_fingerprint"
        chmod 600 "$d/token_fingerprint" "$d/generation" "$d/owner" 2>/dev/null || true
        printf '{"schema_version": 1, "udid": "%s", "name": "%s", "state": "%s", "lease_generation": %s, "lease_token": "%s"}\n' \
          "$udid" "$name" "$state" "$gen" "$token"
        rmdir "$alock" 2>/dev/null || true
        return 0
      fi
    done < <(sim_devices)

    # no pool device at all is distinct from "all busy"
    if ! sim_devices | awk -F'\t' '$2 ~ /^wai-shared-/ {found=1} END{exit !found}'; then
      echo "sim lease: no pool device exists; create one with 'diskm sim create --reason <why>' (WORLDAI_SIM_ALLOW_CREATE=1 does not bypass the pool)" >&2
      return 21
    fi
    (( $(sim_now) < deadline )) || { echo "sim lease: no free slot within ${wait_seconds}s" >&2; return 20; }
    sleep 1
  done
}

# sim_release <udid> --token <token> — fenced by the current generation's token.
sim_release() {
  local udid="" token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) token="${2:?}"; shift 2 ;;
      --json) shift ;;
      -*) shift ;;
      *) udid="${1:-}"; shift ;;
    esac
  done
  [[ -n "$udid" && -n "$token" ]] || {
    echo "sim release: usage: diskm sim release <udid> --token <lease-token>" >&2
    return 2
  }
  local d; d="$(sim_lease_path "$udid")"
  [[ -d "$d" ]] || { echo "sim release: no lease for $udid" >&2; return 23; }

  # Serialize check-and-delete. Without this lock two releases can both pass the
  # token check, and a delayed one can then delete a NEWLY acquired lease
  # (review finding, 2026-11-16). The lock covers validate -> receipt -> delete.
  local lock; lock="$(sim_release_lock_path "$udid")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  local waited=0
  until mkdir "$lock" 2>/dev/null; do
    sleep 0.1
    waited=$((waited+1))
    (( waited < 300 )) || { echo "sim release: could not serialize (lock busy)" >&2; return 25; }
  done
  # No RETURN trap: a RETURN trap outlives this function and later fires with
  # ${lock} out of scope, aborting the caller under `set -u` (found by the
  # concurrency test). Every exit path below removes the lock explicitly.

  # Re-read the fingerprint UNDER the lock: a concurrent acquire may have swapped it.
  local expected actual gen
  expected="$(cat "$d/token_fingerprint" 2>/dev/null)"
  actual="$(sim_token_fingerprint "$token")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rmdir "${lock}" 2>/dev/null || true
    echo "sim release: stale-lease-token (generation superseded)" >&2
    return 23
  fi
  gen="$(sim_generation "$udid")"

  # A receipt-write failure must fail the release, not be ignored: the receipt is
  # the ONLY thing that makes a device prunable, so silently dropping it would
  # leave a released device permanently unpickable while reporting success.
  mkdir -p "$(sim_receipt_dir)" 2>/dev/null || {
    rmdir "${lock}" 2>/dev/null || true
    echo "sim release: cannot create receipt dir; refusing" >&2
    return 24
  }
  if ! printf '{"action": "release", "udid": "%s", "lease_generation": %s, "token_fingerprint": "%s", "released_at": "%s"}\n' \
    "$udid" "${gen:-0}" "$expected" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$(sim_receipt_dir)/sim_release_receipts.jsonl" 2>/dev/null; then
    rmdir "${lock}" 2>/dev/null || true
    echo "sim release: receipt write failed; refusing" >&2
    return 24
  fi
  rm -rf "${d:?}" 2>/dev/null
  rmdir "${lock}" 2>/dev/null || true
  return 0
}

# sim_released_and_idle <udid> — true only with a receipt for the current
# generation AND the floor elapsed since the recorded release time.
sim_released_and_idle() {
  local udid="$1" receipts; receipts="$(sim_receipt_dir)/sim_release_receipts.jsonl"
  [[ -f "$receipts" ]] || return 1
  # The receipt must match the CURRENT persisted generation, and a NEWER lease
  # must invalidate an older receipt. Generation is read from the persisted file
  # that survives release (review finding: it used to reset to 1).
  local cur_gen; cur_gen="$(cat "$(sim_generation_path "$udid")" 2>/dev/null)"
  [[ "$cur_gen" =~ ^[0-9]+$ ]] || return 1
  python3 - "$receipts" "$udid" "$(sim_floor_minutes)" "$cur_gen" <<'PY' 2>/dev/null
import json,sys,time
path,udid,floor,cur=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
best=None
for line in open(path, errors='replace'):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    if r.get('udid')!=udid or r.get('action')!='release': continue
    # only the receipt for the CURRENT generation counts
    try:
        if int(r.get('lease_generation'))!=cur: continue
    except Exception: continue
    try:
        t=time.mktime(time.strptime(r['released_at'],'%Y-%m-%dT%H:%M:%SZ'))-time.timezone
    except Exception: continue
    if best is None or t>best: best=t
if best is None: sys.exit(1)
if time.time()-best < floor*60: sys.exit(1)
sys.exit(0)
PY
}

sim_prune() {
  local dry=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) dry=false; shift ;;
      --dry-run) dry=true; shift ;;
      *) shift ;;
    esac
  done
  local udid name state newest removed=0 kept=0
  while IFS=$'\t' read -r udid name state newest; do
    [[ -n "$udid" ]] || continue
    # 1. Booted is never a candidate
    if [[ "$state" == "Booted" ]]; then echo "keep:booted $name"; kept=$((kept+1)); continue; fi
    # 2. a live lease excludes it
    if sim_is_leased "$udid"; then echo "keep:leased $name"; kept=$((kept+1)); continue; fi
    # 3. unmeasurable mtime fails closed
    [[ "$newest" =~ ^[0-9]+$ ]] || { echo "keep:mtime-unmeasurable $name"; kept=$((kept+1)); continue; }
    # 4. the only proof: a release receipt for the current generation, past the floor
    if ! sim_released_and_idle "$udid"; then
      echo "keep:no-release-receipt $name"
      kept=$((kept+1)); continue
    fi
    echo "remove:candidate $name"
    if [[ "$dry" == false ]]; then
      local root target
      root="$(sim_device_root)"
      [[ -n "$root" && "$root" == /* && -d "$root" ]] || { echo "sim prune: unsafe device root, refusing" >&2; return 1; }
      target="${root%/}/${udid}"
      case "$target" in
        "$root"|""|"/") echo "sim prune: refusing unsafe target '$target'" >&2; return 1 ;;
      esac

      # Exclusion: take the same per-UDID lock release uses, so a release or a
      # new lease cannot interleave with this delete (review P0).
      local plock; plock="$(sim_release_lock_path "$udid")"
      mkdir -p "$(dirname "$plock")" 2>/dev/null || true
      mkdir "$plock" 2>/dev/null || { echo "keep:exclusion-busy $name"; kept=$((kept+1)); continue; }

      # FINAL positive re-check, under the lock. This must re-verify the RECEIPT
      # and the 48 h floor too, not just state and lease: a lease/release cycle
      # that advanced the generation while prune was paused would otherwise let
      # prune act on a stale generation-1 receipt (review P0, reproduced).
      local still_state still_leased
      still_state="$(sim_devices | awk -F'\t' -v u="$udid" '$1==u {print $3}')"
      still_leased=0; sim_is_leased "$udid" && still_leased=1
      if [[ "$still_state" != "Shutdown" || "$still_leased" -eq 1 ]]; then
        rmdir "$plock" 2>/dev/null || true
        echo "keep:state-changed $name"
        kept=$((kept+1)); continue
      fi
      if ! sim_released_and_idle "$udid"; then
        rmdir "$plock" 2>/dev/null || true
        echo "keep:receipt-stale-under-lock $name"
        kept=$((kept+1)); continue
      fi

      # The shared removal verdict is MANDATORY, not best-effort: a deletion may
      # only proceed when the gate is present, exits 0, and returns an explicit
      # `remove` verdict. A missing gate, a non-zero exit, or empty/unknown output
      # all fail closed (review P0: a gate returning 42 with no output still
      # authorized a deletion because stderr was masked and empty fell through).
      if ! declare -F artifact_removal_verdict >/dev/null 2>&1; then
        local _lib; _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/artifact_verdict.sh"
        if [[ -f "$_lib" ]]; then
          # shellcheck source=/dev/null
          source "$_lib" >/dev/null 2>&1 || true
        fi
      fi
      if ! declare -F artifact_removal_verdict >/dev/null 2>&1; then
        rmdir "$plock" 2>/dev/null || true
        echo "keep:verdict-unavailable $name"
        kept=$((kept+1)); continue
      fi
      # Separate streams: merging stderr into stdout let a diagnostic line win the
      # "last line" and override the real verdict (review P0). Only the COMPLETE
      # stdout is considered, and it must be exactly `remove`.
      local verdict raw vrc=0
      raw="$(artifact_removal_verdict "$target" 2>/dev/null)" || vrc=$?
      verdict="$(printf '%s' "$raw" | tr -d '[:space:]')"
      if [[ "$vrc" -ne 0 ]]; then
        rmdir "$plock" 2>/dev/null || true
        echo "keep:verdict-error-$vrc $name"
        kept=$((kept+1)); continue
      fi
      if [[ "$verdict" != remove ]]; then
        rmdir "$plock" 2>/dev/null || true
        echo "keep:verdict-${verdict:-empty} $name"
        kept=$((kept+1)); continue
      fi

      if declare -F deletion_log >/dev/null 2>&1; then deletion_log "$target" "sim-prune"; fi
      rm -rf "${target:?}" 2>/dev/null && removed=$((removed+1))
      rmdir "$plock" 2>/dev/null || true
    fi
  done < <(sim_devices)
  echo "sim prune: candidates_removed=$removed kept=$kept dry_run=$dry"
  return 0
}

# ---------------------------------------------------------------------------
# sim_create — authorised create-and-register.
#
# Contract: ~/roadmap/sq-ios-simulator-lease-contract-2026-11-16.md § Creation
# flow. Crash-safety is the hard part (review requirement, 2026-11-16):
#
#   1. Reserve the slot DURABLY under the pool lock BEFORE invoking simctl.
#      The reservation is a directory, so mkdir is the single-writer atomic
#      primitive — a crashed create leaves a recoverable reservation, never a
#      half-made device invisible to the pool.
#   2. Record the reservation state (`status=reserving`, then `created` with the
#      UDID) so recovery can tell "crashed before simctl" from "crashed after".
#   3. A failed/interrupted create must not leak capacity and must never expose
#      an unleased device to prune. Because prune requires a release RECEIPT and
#      a created device holds a live lease from birth, an orphan is inert: it is
#      leased, so prune skips it, and it is visible in `sim status`.
# ---------------------------------------------------------------------------
SIM_POOL_SLOTS="${DISK_MAGICIAN_SIM_POOL_SLOTS:-3}"
# sim_name_reserved <udid> <name> — true while an unfinished `create` reservation
# owns this device name or UDID, so lease cannot hand it out mid-registration.
sim_name_reserved() {
  local udid="$1" name="$2" rdir rn ru
  rdir="$(sim_reserve_dir)"
  [[ -d "$rdir" ]] || return 1
  for r in "$rdir"/*; do
    [[ -d "$r" && ! -L "$r" ]] || continue
    # Same format create writes: name= lives in meta, udid may be a file.
    rn="$(sed -n 's/^name=//p' "$r/meta" 2>/dev/null | head -1)"
    [[ -z "$rn" ]] && rn="$(cat "$r/name" 2>/dev/null)"
    ru="$(cat "$r/udid" 2>/dev/null)"
    [[ -n "$udid" && "$ru" == "$udid" ]] && return 0
    [[ -n "$name" && "$rn" == "$name" ]] && return 0
  done
  return 1
}

sim_reserve_dir() { printf '%s\n' "${DISK_MAGICIAN_SIM_RESERVE_DIR:-$(sim_state_root)/sim_reservations}"; }

sim_pool_slots() {
  local n="${SIM_POOL_SLOTS:-3}"
  [[ "$n" =~ ^[1-9][0-9]?$ ]] || n=3
  printf '%s\n' "$n"
}

# count pool devices + in-flight reservations (a reservation consumes a slot)
sim_pool_used() {
  local devices reservations
  devices="$(sim_devices | awk -F'\t' '$2 ~ /^wai-shared-/ {n++} END{print n+0}')"
  reservations="$(find "$(sim_reserve_dir)" -maxdepth 1 -type d ! -path "$(sim_reserve_dir)" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\n' "$(( ${devices:-0} + ${reservations:-0} ))"
}

# sim_recover_reservations — finish or clear interrupted creates.
# A reservation whose simctl never produced a UDID is cleared (capacity
# reclaimed). One that recorded a UDID is reconciled: if the device exists it is
# kept as an inert leased device; the reservation itself is released.
sim_recover_reservations() {
  local rdir_override; rdir_override="$(sim_reserve_dir)"
  [[ -d "$rdir_override" ]] || return 0
  local rf udid r
  for r in "$rdir_override"/*; do
    [[ -d "$r" && ! -L "$r" ]] || continue
    # An existing ORPHAN record is a durable exclusion, not a live reservation:
    # preserve it verbatim on every later run. Previously a second recovery fell
    # through to "reservation-cleared" and deleted it, re-opening the device to
    # lease (review P0).
    if grep -qx 'status=orphan' "$r/meta" 2>/dev/null; then
      echo "recover:orphan-exclusion-retained $(basename "$r")" >&2
      continue
    fi
    # Ownership: never reap a reservation whose creating process is alive.
    local owner_pid
    owner_pid="$(sed -n 's/^pid=//p' "$r/meta" 2>/dev/null | head -1)"
    if [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      echo "recover:skipped-live-creator $(basename "$r") pid=$owner_pid" >&2
      continue
    fi
    udid="$(cat "$r/udid" 2>/dev/null)"
    # A crash AFTER simctl succeeded but BEFORE the UDID was recorded is not proof
    # that no device was made: look for the reserved NAME in the live device list.
    if [[ -z "$udid" ]]; then
      local rname found
      # create records name= inside meta (not a separate file)
      rname="$(sed -n 's/^name=//p' "$r/meta" 2>/dev/null | head -1)"
      [[ -z "$rname" ]] && rname="$(cat "$r/name" 2>/dev/null)"
      if [[ -n "$rname" ]]; then
        found="$(sim_devices | awk -F'\t' -v n="$rname" '$2==n {print $1; exit}')"
        if [[ -n "$found" ]]; then
          # Keep a DURABLE exclusion: deleting the reservation here let the very
          # next lease succeed on an unregistered device (review P0, reproduced
          # by /dot). The reservation is rewritten in place as an orphan record
          # that sim_name_reserved keeps honouring until explicit reconciliation.
          printf 'status=orphan\nudid=%s\nname=%s\npid=%s\n' \
            "$found" "$rname" "$owner_pid" >"$r/meta" 2>/dev/null || true
          printf '%s\n' "$found" >"$r/udid"
          echo "recover:orphan-device $found ($rname) created but never registered; exclusion retained, needs operator reconcile" >&2
          continue
        fi
      fi
    fi
    if [[ -n "$udid" ]] && sim_devices | awk -F'\t' -v u="$udid" '$1==u {found=1} END{exit !found}'; then
      echo "recover:created $udid (inert: leased, never prunable without a release receipt)" >&2
    else
      echo "recover:reservation-cleared $(basename "$r") (no device was produced; capacity reclaimed)" >&2
    fi
    rm -rf "${r:?}"
  done
  return 0
}

# sim_create --reason <text> [--runtime R] [--name N] [--json]
sim_create() {
  local reason="" runtime="" name="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      --runtime) runtime="${2:-}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      --json) json=true; shift ;;
      *) shift ;;
    esac
  done

  sim_recover_reservations >/dev/null 2>&1 || true

  # Refuse without a stated reason: creation is an exception, not a default.
  [[ -n "${reason// /}" ]] || {
    echo "sim create: --reason is required (a pool slot insuffices only for a stated reason)" >&2
    return 2
  }
  # An available slot must be used instead of creating.
  if sim_devices | awk -F'\t' '$2 ~ /^wai-shared-/ && $3 != "Booted" {n++} END{exit !(n>0)}'; then
    echo "sim create: refused — a pool slot is available; use 'diskm sim lease'" >&2
    return 21
  fi
  local slots used
  slots="$(sim_pool_slots)"; used="$(sim_pool_used)"
  (( used < slots )) || {
    echo "sim create: refused — pool cap reached (${used}/${slots}); an env var does not bypass the cap" >&2
    return 21
  }

  # Step 1: durable reservation BEFORE touching simctl.
  mkdir -p "$(sim_reserve_dir)" || { echo "sim create: cannot create reservation dir" >&2; return 22; }
  local stamp rdir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  rdir="$(sim_reserve_dir)/${stamp}-$$"
  mkdir "$rdir" 2>/dev/null || { echo "sim create: reservation race lost" >&2; return 21; }
  local device_type="${DISK_MAGICIAN_SIM_DEVICE_TYPE:-iPhone 17 Pro}"
  local rt="${runtime:-iOS 26.5}"
  name="${name:-wai-shared-$(printf '%s' "$rt" | tr ' .' '--' | tr 'A-Z' 'a-z')-$(printf '%s' "$stamp" | tail -c 6)}"

  # name is recorded BEFORE simctl so a crash-after-create-before-register is
  # detectable by name (review P0).
  printf 'status=reserving\nreason=%s\npid=%s\nruntime=%s\nname=%s\n' "$reason" "$$" "$runtime" "$name" >"$rdir/meta"

  local udid rc=0
  if [[ -n "${DISK_MAGICIAN_SIM_FIXTURE_ROOT:-}" ]]; then
    # Test/fixture mode: NEVER call real simctl. A unit test must not be able to
    # create a real device on the host (a fixture run did exactly that on
    # 2026-11-16, creating wai-shared-ios-26-5-11739Z).
    if [[ -n "${DISK_MAGICIAN_SIM_FIXTURE_CREATE_FAIL:-}" ]]; then
      rc=1
      udid=""
    else
      udid="$(printf 'FAKE-%s' "$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')")"
      sim_fixture_device "$DISK_MAGICIAN_SIM_FIXTURE_ROOT" "$udid" "$name" "Shutdown" 0
    fi
  else
    udid="$(xcrun simctl create "$name" "$device_type" "$rt" 2>/dev/null)" || rc=$?
  fi
  if [[ "$rc" -ne 0 || -z "$udid" ]]; then
    # Step 3a: no device produced — release capacity immediately.
    rm -rf "${rdir:?}"
    echo "sim create: simctl create failed (rc=$rc); reservation released, no capacity leaked" >&2
    return 1
  fi

  # Step 2: record the produced UDID, then lease it so it is never unleased.
  printf '%s\n' "$udid" >"$rdir/udid"
  printf 'status=created\n' >>"$rdir/meta"
  mkdir -p "$(sim_lease_dir)" || {
    echo "sim create: cannot create lease dir; refusing (device $udid was created and is NOT leased)" >&2
    return 24
  }
  local d; d="$(sim_lease_path "$udid")"
  # Never overwrite an existing lease directory (review P0).
  if ! mkdir "$d" 2>/dev/null; then
    echo "sim create: lease dir already exists for $udid; refusing to overwrite" >&2
    return 24
  fi
  local token="lt_$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  local gen
  if ! gen="$(sim_next_generation "$udid")" || [[ -z "$gen" ]]; then
    echo "sim create: cannot allocate generation; device $udid left unleased, needs operator handling" >&2
    return 24
  fi
  printf '%s\n' "$gen" >"$d/generation"
  printf '%s\n' "${WORLDAI_SIM_OWNER:-$(id -un)}" >"$d/owner"
  printf '%s\n' "$(sim_token_fingerprint "$token")" >"$d/token_fingerprint"
  chmod 600 "$d/generation" "$d/last_generation" "$d/owner" "$d/token_fingerprint" 2>/dev/null || true
  rm -rf "${rdir:?}"

  if [[ "$json" == true ]]; then
    printf '{"schema_version": 1, "udid": "%s", "name": "%s", "state": "Shutdown", "lease_generation": %s, "lease_token": "%s", "created": true}\n' \
      "$udid" "$name" "$gen" "$token"
  else
    # Print the token as well: a caller that only received the UDID could never
    # release the device it just created (review finding).
    printf '%s %s\n' "$udid" "$token"
  fi
  return 0
}

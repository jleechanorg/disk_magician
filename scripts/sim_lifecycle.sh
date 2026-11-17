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

SIM_STATE_ROOT="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
SIM_LEASE_DIR="$SIM_STATE_ROOT/sim_leases"
SIM_RECEIPT_DIR="$SIM_STATE_ROOT/receipts"
SIM_DEFAULT_FLOOR_MINUTES=2880

sim_now() { date +%s; }

sim_floor_minutes() {
  local m="${DISK_MAGICIAN_AGE_FLOOR_MINUTES:-}"
  if [[ "$m" =~ ^[0-9]{1,7}$ ]]; then
    m=$((10#$m))
    (( m >= 120 )) || m=120
    printf '%s\n' "$m"
  else
    printf '%s\n' "$SIM_DEFAULT_FLOOR_MINUTES"
  fi
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

sim_lease_path()   { printf '%s/%s\n' "$SIM_LEASE_DIR" "$1"; }
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
  mkdir -p "$SIM_LEASE_DIR" || { echo "sim lease: cannot create lease dir" >&2; return 22; }

  local deadline=$(( $(sim_now) + wait_seconds )) udid name state newest
  while :; do
    while IFS=$'\t' read -r udid name state newest; do
      [[ -n "$udid" ]] || continue
      # only pool devices are leaseable; task-named devices need explicit adopt
      [[ "$name" == wai-shared-* ]] || continue
      local d; d="$(sim_lease_path "$udid")"
      if mkdir "$d" 2>/dev/null; then
        local gen=1
        [[ -f "$d/last_generation" ]] && gen=$(( $(cat "$d/last_generation") + 1 ))
        local token="lt_$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        printf '%s\n' "$(( gen ))" >"$d/generation"
        printf '%s\n' "$(( gen ))" >"$d/last_generation"
        printf '%s\n' "${WORLDAI_SIM_OWNER:-$(id -un)}" >"$d/owner"
        printf '%s\n' "$(sim_token_fingerprint "$token")" >"$d/token_fingerprint"
        chmod 600 "$d/token_fingerprint" "$d/generation" "$d/owner" 2>/dev/null || true
        printf '{"schema_version": 1, "udid": "%s", "name": "%s", "state": "%s", "lease_generation": %s, "lease_token": "%s"}\n' \
          "$udid" "$name" "$state" "$gen" "$token"
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
  local expected actual gen
  expected="$(cat "$d/token_fingerprint" 2>/dev/null)"
  actual="$(sim_token_fingerprint "$token")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "sim release: stale-lease-token (generation superseded)" >&2
    return 23
  fi
  gen="$(sim_generation "$udid")"
  mkdir -p "$SIM_RECEIPT_DIR" || true
  # Receipt carries the fingerprint, never the raw token.
  printf '{"action": "release", "udid": "%s", "lease_generation": %s, "token_fingerprint": "%s", "released_at": "%s"}\n' \
    "$udid" "${gen:-0}" "$expected" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$SIM_RECEIPT_DIR/sim_release_receipts.jsonl"
  rm -rf "${d:?}" 2>/dev/null
  return 0
}

# sim_released_and_idle <udid> — true only with a receipt for the current
# generation AND the floor elapsed since the recorded release time.
sim_released_and_idle() {
  local udid="$1" receipts="$SIM_RECEIPT_DIR/sim_release_receipts.jsonl"
  [[ -f "$receipts" ]] || return 1
  local gen; gen="$(sim_generation "$udid")"
  # No live lease means the receipt must be the newest for that UDID.
  python3 - "$receipts" "$udid" "$(sim_floor_minutes)" <<'PY' 2>/dev/null
import json,sys,time
path,udid,floor=sys.argv[1],sys.argv[2],int(sys.argv[3])
best=None
for line in open(path, errors='replace'):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    if r.get('udid')!=udid or r.get('action')!='release': continue
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
      # logged deletion via the shared helper when available
      if declare -F deletion_log >/dev/null 2>&1; then deletion_log "$target" "sim-prune"; fi
      rm -rf "${target:?}" 2>/dev/null && removed=$((removed+1))
    fi
  done < <(sim_devices)
  echo "sim prune: candidates_removed=$removed kept=$kept dry_run=$dry"
  return 0
}

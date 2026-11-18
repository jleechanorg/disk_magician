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

# simctl_delete_device <udid> — remove through CoreSimulator so its inventory and
# on-disk state remain consistent. Fixture runs require an explicitly supplied
# fake transport; they can never fall through to the host's real xcrun.
simctl_delete_device() {
  local udid="$1"
  if [[ -n "${DISK_MAGICIAN_SIM_FIXTURE_ROOT:-}" ]]; then
    [[ -n "${DISK_MAGICIAN_SIM_FIXTURE_XCRUN:-}" && -x "$DISK_MAGICIAN_SIM_FIXTURE_XCRUN" ]] || return 127
    "$DISK_MAGICIAN_SIM_FIXTURE_XCRUN" simctl delete "$udid"
    return $?
  fi
  command -v xcrun >/dev/null 2>&1 || return 127
  xcrun simctl delete "$udid"
}

# sim_fixture_device <root> <udid> <name> <state> <age_hours|-1> [runtime-key]
# Test-only helper; never called in production paths.
sim_fixture_device() {
  local root="$1" udid="$2" name="$3" state="$4" age_h="$5"
  local d="$root/$udid"
  mkdir -p "$d"
  printf '%s\n' "$name" >"$d/.name"
  printf '%s\n' "$state" >"$d/.state"
  [[ -n "${6:-}" ]] && printf '%s\n' "$6" >"$d/.runtime"
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

# sim_mtime <path> / sim_newest_mtime <dir> — epoch seconds, GNU stat first and
# BSD stat second (`stat -f '%m'` on GNU is a filesystem query, not an mtime).
sim_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }
sim_newest_mtime() {
  local n
  n="$(find "$1" -type f ! -name '.*' -exec stat -c '%Y' {} + 2>/dev/null | sort -rn | head -1)"
  [[ -n "$n" ]] || n="$(find "$1" -type f ! -name '.*' -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)"
  [[ -n "$n" ]] || n="$(sim_mtime "$1")"
  printf '%s\n' "$n"
}

# sim_snapshot — ONE validated inventory snapshot.
#
# Returns 0 and prints udid<TAB>name<TAB>state<TAB>last_used<TAB>runtime rows (an
# unknown last_used or runtime is "-", because read collapses empty tab fields)
# only when the
# producer, the parser AND the schema all succeed. Any failure returns non-zero
# with no rows, so callers can distinguish "no devices" from "could not read".
# Previous code discarded one xcrun call's status and then trusted a second,
# silently-reading call, so a failing inventory produced an empty list that every
# caller treated as fact (review P0, reproduced with exit 75 and with malformed
# JSON at exit 0).
sim_snapshot() {
  local root out rc=0
  if [[ -z "${DISK_MAGICIAN_SIM_FIXTURE_ROOT:-}" ]]; then
    command -v xcrun >/dev/null 2>&1 || return 1
    out="$(xcrun simctl list devices --json 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out" | python3 -c '
import json,sys,calendar,time
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)                      # parser failure -> caller must not trust
if not isinstance(d,dict) or not isinstance(d.get("devices"),dict):
    sys.exit(4)                      # schema failure
# Buffer ALL rows first. Printing as we validate meant a valid row reached the
# caller before a later malformed row failed the parse, and the caller status
# masking then acted on a partial inventory (review P0 reproduced).
buf=[]
for runtime,devs in d["devices"].items():
    if not isinstance(devs,list):
        sys.exit(4)
    for x in devs:
        if not isinstance(x,dict) or not x.get("udid") or not x.get("state"):
            sys.exit(4)
        lu=x.get("lastUsedAt") or ""
        ts="-"
        if lu:
            try: ts=int(calendar.timegm(time.strptime(lu,"%Y-%m-%dT%H:%M:%SZ")))
            except Exception: ts="-"
        nm=str(x.get("name","")).replace("\t"," ").replace("\n"," ")
        buf.append("\t".join([x.get("udid",""), nm, x.get("state","unknown"), str(ts), runtime]))
for row in buf:
    print(row)
' || return 1
    return 0
  fi

  # Fixture mode is trusted input by construction.
  root="$(sim_device_root)"
  [[ -d "$root" ]] || return 0
  local udid_path udid name state newest rtk
  for udid_path in "$root"/*; do
    [[ -d "$udid_path" && ! -L "$udid_path" ]] || continue
    udid="$(basename "$udid_path")"
    if [[ -f "$udid_path/.name" ]]; then
      name="$(cat "$udid_path/.name" 2>/dev/null)"
      state="$(cat "$udid_path/.state" 2>/dev/null)"
      rtk="$(cat "$udid_path/.runtime" 2>/dev/null)"
      if [[ -f "$udid_path/.no_mtime" ]]; then
        newest=""
      else
        newest="$(sim_newest_mtime "$udid_path")"
      fi
    else
      name="$udid"
      state="unknown"
      newest=""
      rtk=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$udid" "$name" "$state" "${newest:--}" "${rtk:--}"
  done
  return 0
}

# sim_devices — rows, or EMPTY on a failed snapshot. Callers that must not act on
# an unreadable inventory use `sim_snapshot || fail-closed` directly.
sim_devices() {
  sim_snapshot 2>/dev/null || true
}

sim_lease_path()   { printf '%s/%s\n' "$(sim_lease_dir)" "$1"; }

# sim_json k=v ... — one JSON object via a real serializer. Only named internal
# fields carry types; string fields such as names and tokens are always strings,
# even when they begin with JSON-looking marker characters.
sim_json() {
  python3 -I -c '
import json,sys
o={"schema_version":1}
for kv in sys.argv[1:]:
    k,sep,v=kv.partition("=")
    if not sep: sys.exit(2)
    if k=="lease_generation":
        try: o[k]=int(v)
        except ValueError: sys.exit(2)
    elif k=="created":
        if v not in ("true","false"): sys.exit(2)
        o[k]=(v=="true")
    else:
        o[k]=v
print(json.dumps(o))' "$@"
}

# Locks are directories holding the holder pid. A lock is broken ONLY when its
# recorded pid is provably dead; no pid file or a live pid means unknown/held.
_sim_pid_is_dead() {
  local rc=0 out
  out="$(ps -p "$1" -o pid= 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && -z "${out//[[:space:]]/}" ]]
}

sim_lock_break_if_dead() {
  local dir="$1" p current gate
  p="$(cat "$dir/pid" 2>/dev/null)"
  [[ "$p" =~ ^[1-9][0-9]*$ && ${#p} -le 10 ]] || return 1
  if [[ ${#p} -eq 10 ]] && (( 10#$p > 2147483647 )); then return 1; fi
  _sim_pid_is_dead "$p" || return 1
  # All stale recoverers for this lock use one sibling gate. Do not rename and
  # restore the target: a new owner can acquire the vacant path during restore.
  gate="$dir.reclaim_gate"
  mkdir "$gate" 2>/dev/null || return 1
  # Revalidate after winning the gate. New takers cannot create $dir until its
  # current directory is removed; once rmdir succeeds this function never
  # mutates the target path again.
  if [[ -d "$dir" && ! -L "$dir" && -f "$dir/pid" && ! -L "$dir/pid" ]]; then
    current="$(cat "$dir/pid" 2>/dev/null)"
    if [[ "$current" == "$p" ]] && _sim_pid_is_dead "$current"; then
      rm -f "$dir/pid" 2>/dev/null
      if rmdir "$dir" 2>/dev/null; then
        rmdir "$gate" 2>/dev/null || true
        echo "sim: recovered stale lock $dir (holder pid $p is dead)" >&2
        return 0
      fi
    fi
  fi
  rmdir "$gate" 2>/dev/null || true
  return 1
}
# sim_lock_take <dir> [extra-0.1s-retries] — 0 only when WE hold the lock.
sim_lock_take() {
  local dir="$1" tries="${2:-0}" n=0
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "${BASHPID:-$$}" >"$dir/pid" 2>/dev/null && return 0
      rm -f "$dir/pid"; rmdir "$dir" 2>/dev/null
      return 1
    fi
    sim_lock_break_if_dead "$dir" && continue
    (( n < tries )) || return 1
    sleep 0.1; n=$((n+1))
  done
}
sim_lock_drop() { rm -f "$1/pid" 2>/dev/null; rmdir "$1" 2>/dev/null || true; }
sim_cap_lock_path() { printf '%s/lock/create.cap-lock\n' "$(sim_state_root)"; }

# sim_pool_leaseable <udid> <name> <state> <runtime-key> [requested-runtime]
# True only for a device lease could actually hand out: pool name, Shutdown, no
# lease (complete or half-written), not reserved, and the requested runtime when
# one is given. The runtime is matched on the simctl runtime KEY, never the name.
sim_pool_leaseable() {
  local udid="$1" name="$2" state="$3" rtk="$4" want="${5:-}"
  [[ "$name" == wai-shared-* && "$state" == "Shutdown" ]] || return 1
  if [[ -n "$want" ]]; then
    local ws ks
    ws="$(printf '%s' "$want" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')"
    ks="$(printf '%s' "$rtk" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')"
    [[ "$ks" == "$ws" || "$ks" == *"-$ws" ]] || return 1
  fi
  [[ "$(sim_lease_state "$udid")" == "absent" ]] || return 1
  sim_name_reserved "$udid" "$name" && return 1
  return 0
}

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

# A lease is complete only when the fingerprint is non-empty AND the generation
# and owner are present. An empty fingerprint file previously counted as a lease,
# so recovery cleared the exclusion for a device with no real lease (review P0).
sim_lease_state() {
  local d fp gen owner
  d="$(sim_lease_path "$1")"
  [[ -e "$d" || -L "$d" ]] || { printf 'absent\n'; return 0; }
  [[ -d "$d" && ! -L "$d" ]] || { printf 'indeterminate\n'; return 0; }
  fp="$(cat "$d/token_fingerprint" 2>/dev/null)"
  gen="$(cat "$d/generation" 2>/dev/null)"
  owner="$(cat "$d/owner" 2>/dev/null)"
  if [[ -n "$fp" && "$fp" =~ ^[0-9a-f]{64}$ && -n "$gen" && "$gen" =~ ^[0-9]+$ && -n "$owner" ]]; then
    printf 'complete\n'
  else
    # A lease dir exists but is not fully written. This is NOT "unleased": whether
    # a caller holds it is unknown, so every destructive or exclusive decision must
    # fail closed (review P0: prune deleted a device whose lease had no owner or
    # generation).
    printf 'indeterminate\n'
  fi
}

sim_is_leased() { [[ "$(sim_lease_state "$1")" == "complete" ]]; }

sim_token_fingerprint() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1; }

sim_status_json() {
  # A failed inventory is an error, never an empty device list; a valid empty
  # inventory still prints devices: [].
  local snap udid name state newest rtk leased owner gen age
  if ! snap="$(sim_snapshot 2>/dev/null)"; then
    echo "sim status: inventory unavailable" >&2
    return 22
  fi
  {
    while IFS=$'\t' read -r udid name state newest rtk; do
      [[ -n "$udid" ]] || continue
      owner=""; gen=""
      if sim_is_leased "$udid"; then owner="$(sim_lease_owner "$udid" | tr -d '\t\n')"; gen="$(sim_generation "$udid")"; fi
      age=""
      [[ "$newest" =~ ^[0-9]+$ ]] && age=$(( ($(sim_now) - newest) / 60 ))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$udid" "$name" "$state" "$owner" "$gen" "$age"
    done <<<"$snap"
  } | python3 -I -c '
import json,sys
devs=[]
for line in sys.stdin:
    u,n,st,ow,g,a=line.rstrip("\n").split("\t")
    devs.append({"udid":u,"name":n,"state":st,"lease_owner":ow or None,
                 "lease_generation":int(g) if g else None,"idle_minutes":int(a) if a else None})
print(json.dumps({"schema_version":1,"devices":devs},indent=2))'
}

# sim_lease — atomically acquire one unleased device. mkdir is the single-writer
# primitive: exactly one racer wins per UDID.
sim_lease() {
  local wait_seconds=120 runtime=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait-seconds|--runtime)
        [[ $# -ge 2 ]] || { echo "sim lease: $1 requires a value" >&2; return 2; }
        if [[ "$1" == --runtime ]]; then runtime="$2"; else wait_seconds="$2"; fi
        shift 2 ;;
      --json) shift ;;
      *) shift ;;
    esac
  done
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || { echo "sim lease: --wait-seconds must be a non-negative integer" >&2; return 2; }
  mkdir -p "$(sim_lease_dir)" || { echo "sim lease: cannot create lease dir" >&2; return 22; }

  local deadline=$(( $(sim_now) + wait_seconds )) udid name state newest rtk snap
  while :; do
    # Refuse on an unreadable inventory rather than reporting "no free slot",
    # which would be a conclusion drawn from a failed read (review P0).
    if ! snap="$(sim_snapshot 2>/dev/null)"; then
      echo "sim lease: inventory unavailable; refusing to guess" >&2
      return 22
    fi
    while IFS=$'\t' read -r udid name state newest rtk; do
      [[ -n "$udid" ]] || continue
      # Pool, Shutdown, unleased, unreserved, requested runtime (matched on the
      # simctl runtime key). Task-named devices need explicit adopt.
      sim_pool_leaseable "$udid" "$name" "$state" "$rtk" "$runtime" || continue
      local d; d="$(sim_lease_path "$udid")"
      # Serialize against prune/release with the same per-UDID lock. Without this,
      # prune's locked re-check could still race an acquire and delete a device
      # that a caller had just leased (review P0, reproduced by /dot).
      local alock; alock="$(sim_release_lock_path "$udid")"
      mkdir -p "$(dirname "$alock")" 2>/dev/null || true
      # Only OUR successful take counts: a foreign holder's directory also exists
      # (review P0: a losing acquirer once rmdir'd the other process's lock).
      if ! sim_lock_take "$alock" 50; then
        echo "sim lease: acquire lock busy for $udid; skipping" >&2
        continue
      fi
      # Re-verify UNDER the lock: prune may have removed this device while we
      # waited, and a stale listing must not produce a lease for a missing device
      # (review P0).
      local live
      live="$(sim_devices | awk -F'\t' -v u="$udid" '$1==u {print $3}')"
      if [[ "$live" != "Shutdown" ]] || sim_is_leased "$udid" || sim_name_reserved "$udid" "$name"; then
        sim_lock_drop "$alock"
        continue
      fi
      if ! mkdir "$d" 2>/dev/null; then
        sim_lock_drop "$alock"
        continue
      fi
      if true; then
        local token="lt_$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        local gen
        if ! gen="$(sim_next_generation "$udid")" || [[ -z "$gen" ]]; then
          rmdir "$d" 2>/dev/null || true
          sim_lock_drop "$alock"
          echo "sim lease: cannot allocate generation (corrupt/unwritable counter); refusing" >&2
          return 22
        fi
        local out
        if ! { printf '%s\n' "$gen" >"$d/generation" \
            && printf '%s\n' "${WORLDAI_SIM_OWNER:-$(id -un)}" >"$d/owner" \
            && printf '%s\n' "$(sim_token_fingerprint "$token")" >"$d/token_fingerprint"; } 2>/dev/null \
          || [[ "$(sim_lease_state "$udid")" != "complete" ]] \
          || ! out="$(sim_json "udid=$udid" "name=$name" "state=$state" "lease_generation=$gen" "lease_token=$token")"; then
          # We created $d under the lock, so we own the partial lease. The
          # generation stays advanced so a stale token can never validate again.
          rm -rf "${d:?}"
          sim_lock_drop "$alock"
          echo "sim lease: could not persist a complete lease for $udid; no token issued" >&2
          return 22
        fi
        chmod 600 "$d/token_fingerprint" "$d/generation" "$d/owner" 2>/dev/null || true
        sim_lock_drop "$alock"
        printf '%s\n' "$out"
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
      --token) [[ $# -ge 2 ]] || { echo "sim release: --token requires a value" >&2; return 2; }
        token="$2"; shift 2 ;;
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
  sim_lock_take "$lock" 300 || { echo "sim release: could not serialize (lock busy)" >&2; return 25; }
  # No RETURN trap: a RETURN trap outlives this function and later fires with
  # ${lock} out of scope, aborting the caller under `set -u` (found by the
  # concurrency test). Every exit path below removes the lock explicitly.

  # Re-read the fingerprint UNDER the lock: a concurrent acquire may have swapped it.
  local expected actual gen
  expected="$(cat "$d/token_fingerprint" 2>/dev/null)"
  actual="$(sim_token_fingerprint "$token")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    sim_lock_drop "$lock"
    echo "sim release: stale-lease-token (generation superseded)" >&2
    return 23
  fi
  gen="$(sim_generation "$udid")"

  # A receipt-write failure must fail the release, not be ignored: the receipt is
  # the ONLY thing that makes a device prunable, so silently dropping it would
  # leave a released device permanently unpickable while reporting success.
  mkdir -p "$(sim_receipt_dir)" 2>/dev/null || {
    sim_lock_drop "$lock"
    echo "sim release: cannot create receipt dir; refusing" >&2
    return 24
  }
  # ORDER MATTERS. Remove the lease BEFORE writing the receipt. A crash between
  # the two then leaves "leased, no receipt" (a device nothing will ever prune),
  # never "released and still leased" (a device whose state is contradictory).
  local saved_meta; saved_meta="$(cat "$d/generation" "$d/owner" "$d/token_fingerprint" 2>/dev/null)"
  rm -rf "${d:?}" 2>/dev/null
  if [[ -d "$d" ]]; then
    sim_lock_drop "$lock"
    echo "sim release: could not remove the lease dir; refusing to write a receipt" >&2
    return 24
  fi
  if ! printf '{"action": "release", "udid": "%s", "lease_generation": %s, "token_fingerprint": "%s", "released_at": "%s"}\n' \
    "$udid" "${gen:-0}" "$expected" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$(sim_receipt_dir)/sim_release_receipts.jsonl" 2>/dev/null; then
    sim_lock_drop "$lock"
    echo "sim release: receipt write failed AFTER lease removal; device is unleased and unpickable (report for reconciliation)" >&2
    return 24
  fi
  sim_lock_drop "$lock"
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
import json,sys,time,calendar
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
        t=calendar.timegm(time.strptime(r['released_at'],'%Y-%m-%dT%H:%M:%SZ'))
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
  # A prune pass must start from a validated snapshot; otherwise no verdict is
  # trustworthy (review P0: valid-looking rows followed by exit 75 were used).
  local snap
  if ! snap="$(sim_snapshot)"; then
    echo "sim prune: inventory unavailable; refusing to act" >&2
    return 24
  fi
  local udid name state newest rtk removed=0 kept=0
  while IFS=$'\t' read -r udid name state newest rtk; do
    [[ -n "$udid" ]] || continue
    # 1. Booted is never a candidate
    if [[ "$state" == "Booted" ]]; then echo "keep:booted $name"; kept=$((kept+1)); continue; fi
    # 2. a live lease — or an INDETERMINATE one — excludes it
    local lstate; lstate="$(sim_lease_state "$udid")"
    if [[ "$lstate" == "complete" ]]; then echo "keep:leased $name"; kept=$((kept+1)); continue; fi
    if [[ "$lstate" == "indeterminate" ]]; then echo "keep:lease-indeterminate $name"; kept=$((kept+1)); continue; fi
    # 3. the only proof: a release receipt for the current generation, past the
    # floor measured from the RECORDED RELEASE TIME (design: "the 48 h floor
    # counted from the recorded release time"). A device mtime is NOT the basis,
    # so an unmeasurable/absent `lastUsedAt` must not veto a valid receipt --
    # otherwise a freshly created, never-booted device (lastUsedAt: null) could
    # never be reclaimed. Found by the uslx live proof on 2026-11-17.
    if ! sim_released_and_idle "$udid"; then
      # No trustworthy receipt. If mtime is also unmeasurable, say so explicitly
      # rather than implying a receipt exists and is merely young.
      if [[ ! "$newest" =~ ^[0-9]+$ ]]; then
        echo "keep:mtime-unmeasurable-no-receipt $name"
      else
        echo "keep:no-release-receipt $name"
      fi
      kept=$((kept+1)); continue
    fi
    local root target plock="" lock_held=0
    root="$(sim_device_root)"
    [[ -n "$root" && "$root" == /* && -d "$root" ]] || { echo "sim prune: unsafe device root, refusing" >&2; return 1; }
    target="${root%/}/${udid}"
    case "$target" in
      "$root"|""|"/") echo "sim prune: refusing unsafe target '$target'" >&2; return 1 ;;
    esac

    if [[ "$dry" == false ]]; then
      # Exclusion: take the same per-UDID lock release uses, so a release or a
      # new lease cannot interleave with this delete (review P0).
      plock="$(sim_release_lock_path "$udid")"
      mkdir -p "$(dirname "$plock")" 2>/dev/null || true
      sim_lock_take "$plock" 0 || { echo "keep:exclusion-busy $name"; kept=$((kept+1)); continue; }
      lock_held=1

      # FINAL positive re-check, under the lock. This must re-verify the RECEIPT
      # and the 48 h floor too, not just state and lease: a lease/release cycle
      # that advanced the generation while prune was paused would otherwise let
      # prune act on a stale generation-1 receipt (review P0, reproduced).
      local still_state still_leased
      still_state="$(sim_devices | awk -F'\t' -v u="$udid" '$1==u {print $3}')"
      # ANY lease presence that is not cleanly absent blocks: complete means in
      # use, indeterminate means we cannot know.
      still_leased=0
      [[ "$(sim_lease_state "$udid")" != "absent" ]] && still_leased=1
      if [[ "$still_state" != "Shutdown" || "$still_leased" -eq 1 ]]; then
        sim_lock_drop "$plock"
        echo "keep:state-changed $name"
        kept=$((kept+1)); continue
      fi
      if ! sim_released_and_idle "$udid"; then
        sim_lock_drop "$plock"
        echo "keep:receipt-stale-under-lock $name"
        kept=$((kept+1)); continue
      fi
    fi

    # The shared removal verdict is mandatory in dry-run and clean modes alike.
    # It independently validates the simulator receipt/state proof, then runs
    # every common C14 veto (leases, cwd/open files, secrets, content recency,
    # identity and other preservation checks) before reporting eligibility.
    if ! declare -F artifact_removal_verdict >/dev/null 2>&1; then
      local _lib; _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/artifact_verdict.sh"
      if [[ -f "$_lib" ]]; then
        # shellcheck source=/dev/null
        source "$_lib" >/dev/null 2>&1 || true
      fi
    fi
    if ! declare -F artifact_removal_verdict >/dev/null 2>&1; then
      (( lock_held == 0 )) || sim_lock_drop "$plock"
      echo "keep:verdict-unavailable $name"
      kept=$((kept+1)); continue
    fi
    # Separate streams: only complete stdout may authorize removal.
    local verdict raw vrc=0
    raw="$(artifact_removal_verdict "$target" --kind simulator-device 2>/dev/null)" || vrc=$?
    verdict="$(printf '%s' "$raw" | tr -d '[:space:]')"
    if [[ "$vrc" -ne 0 ]]; then
      (( lock_held == 0 )) || sim_lock_drop "$plock"
      echo "keep:verdict-error-$vrc $name"
      kept=$((kept+1)); continue
    fi
    if [[ "$verdict" != remove ]]; then
      (( lock_held == 0 )) || sim_lock_drop "$plock"
      echo "keep:verdict-${verdict:-empty} $name"
      kept=$((kept+1)); continue
    fi

    if [[ "$dry" == true ]]; then
      echo "remove:eligible $name"
    else
      echo "remove:candidate $name"
    fi
    if [[ "$dry" == false ]]; then
      # Measure before the canonical transport removes it, then verify inventory
      # no longer reports the UDID. Never rm the device-store directory directly:
      # simctl owns inventory consistency and a failed delete remains fail-closed.
      local kb delete_rc=0 after
      kb="$(du -sk "$target" 2>/dev/null | cut -f1)"
      [[ "$kb" =~ ^[0-9]+$ ]] || kb=-1
      simctl_delete_device "$udid" >/dev/null 2>&1 || delete_rc=$?
      if [[ "$delete_rc" -ne 0 ]]; then
        sim_lock_drop "$plock"
        echo "keep:delete-failed-$delete_rc $name"
        kept=$((kept+1)); continue
      fi
      # Record the successful transport before the independent inventory check:
      # if that verification fails, the deletion still happened and must be logged.
      if declare -F deletion_log >/dev/null 2>&1; then deletion_log "sim_lifecycle.sh" "sim-prune" "$kb" "$target"; fi
      if ! after="$(sim_snapshot)"; then
        sim_lock_drop "$plock"
        echo "keep:delete-inventory-unavailable $name"
        kept=$((kept+1)); continue
      fi
      if printf '%s\n' "$after" | awk -F'\t' -v u="$udid" '$1==u {found=1} END{exit !found}'; then
        sim_lock_drop "$plock"
        echo "keep:delete-not-confirmed $name"
        kept=$((kept+1)); continue
      fi
      removed=$((removed+1))
      sim_lock_drop "$plock"
    fi
  done < <(printf '%s\n' "$snap")
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
  local n="${DISK_MAGICIAN_SIM_POOL_SLOTS:-3}"
  [[ "$n" =~ ^[1-9][0-9]?$ ]] || n=3
  printf '%s\n' "$n"
}

# count pool devices + in-flight reservations (a reservation consumes a slot)
sim_pool_used() {
  local devices reservations snap
  # A failed inventory is not "zero devices": fail so the caller refuses.
  snap="$(sim_snapshot 2>/dev/null)" || return 1
  devices="$(printf '%s\n' "$snap" | awk -F'\t' '$2 ~ /^wai-shared-/ {n++} END{print n+0}')"
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
  # create writes its reservation meta under this same lock, so a reservation seen
  # here is either fully initialised or abandoned. If the lock is busy no
  # conclusion is drawn.
  local clock; clock="$(sim_cap_lock_path)"
  if ! sim_lock_take "$clock" 50; then
    echo "recover:busy — create in progress; reservations preserved" >&2
    return 0
  fi
  # ONE validated snapshot for the whole pass. If it cannot be produced, no
  # conclusion may be drawn about any reservation (review P0).
  local snap snap_ok=1
  snap="$(sim_snapshot)" || snap_ok=0
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
    if [[ ! "$owner_pid" =~ ^[1-9][0-9]*$ ]]; then
      echo "recover:skipped-unknown-owner $(basename "$r") — no creator pid recorded; preserved" >&2
      continue
    fi
    if ps -p "$owner_pid" >/dev/null 2>&1; then
      echo "recover:skipped-live-creator $(basename "$r") pid=$owner_pid" >&2
      continue
    fi
    # Re-take the snapshot per reservation. A device can appear between the pass
    # snapshot and this check, so a stale snapshot would clear the exclusion for a
    # device that now exists (review P0, reproduced).
    local snap_fresh
    if ! snap_fresh="$(sim_snapshot)"; then
      echo "recover:inventory-unavailable $(basename "$r") — reservation preserved, no conclusion drawn" >&2
      continue
    fi
    snap="$snap_fresh"
    udid="$(cat "$r/udid" 2>/dev/null)"
    # A crash AFTER simctl succeeded but BEFORE the UDID was recorded is not proof
    # that no device was made: look for the reserved NAME in the live device list.
    if [[ -z "$udid" ]]; then
      local rname found
      # create records name= inside meta (not a separate file)
      rname="$(sed -n 's/^name=//p' "$r/meta" 2>/dev/null | head -1)"
      [[ -z "$rname" ]] && rname="$(cat "$r/name" 2>/dev/null)"
      if [[ -n "$rname" ]]; then
        found="$(printf '%s\n' "$snap" | awk -F'\t' -v n="$rname" '$2==n {print $1; exit}')"
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
    if [[ -n "$udid" ]] && printf '%s\n' "$snap" | awk -F'\t' -v u="$udid" '$1==u {found=1} END{exit !found}'; then
      # The device exists. Do NOT assume it is leased: a creator can die after
      # recording the UDID but before writing the lease, leaving it unleased and
      # thus leaseable to the next caller (review P0). Only a COMPLETE lease
      # permits removing the reservation; otherwise mark it orphaned.
      if sim_is_leased "$udid"; then
        echo "recover:created $udid (inert: leased, never prunable without a release receipt)" >&2
      else
        printf 'status=orphan\nudid=%s\nname=%s\npid=%s\n' \
          "$udid" "$(sed -n 's/^name=//p' "$r/meta" 2>/dev/null | head -1)" "$owner_pid" >"$r/meta" 2>/dev/null || true
        printf '%s\n' "$udid" >"$r/udid"
        echo "recover:orphan-device $udid (created but NEVER leased; exclusion retained)" >&2
        continue
      fi
    else
      echo "recover:reservation-cleared $(basename "$r") (no device was produced; capacity reclaimed)" >&2
    fi
    rm -rf "${r:?}"
  done
  sim_lock_drop "$clock"
  return 0
}

# sim_create --reason <text> [--runtime R] [--name N] [--json]
sim_create() {
  local reason="" runtime="" name="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason|--runtime|--name)
        [[ $# -ge 2 ]] || { echo "sim create: $1 requires a value" >&2; return 2; }
        case "$1" in --reason) reason="$2" ;; --runtime) runtime="$2" ;; *) name="$2" ;; esac
        shift 2 ;;
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
  # A failed inventory read is NOT spare capacity (review P0: with every read
  # failing, create still called simctl and returned success).
  local snap_c cu cn cs cnew crt
  if ! snap_c="$(sim_snapshot)"; then
    echo "sim create: inventory unavailable; refusing (cannot prove a slot is needed)" >&2
    return 22
  fi
  # An available slot must be used instead of creating. Only a device lease could
  # actually hand out counts: a leased, reserved or other-runtime device does not.
  while IFS=$'\t' read -r cu cn cs cnew crt; do
    [[ -n "$cu" ]] || continue
    if sim_pool_leaseable "$cu" "$cn" "$cs" "$crt" "$runtime"; then
      echo "sim create: refused — a pool slot is available; use 'diskm sim lease'" >&2
      return 21
    fi
  done <<<"$snap_c"
  # Cap check AND reservation creation must be atomic. Without one lock two
  # simultaneous creates both passed the cap check and both succeeded at cap=1
  # (review P0, reproduced).
  local clock; clock="$(sim_cap_lock_path)"
  if ! sim_lock_take "$clock" 100; then
    echo "sim create: cap lock busy; refusing rather than racing the cap" >&2
    return 21
  fi

  local slots used
  slots="$(sim_pool_slots)"
  if ! used="$(sim_pool_used)"; then
    sim_lock_drop "$clock"
    echo "sim create: inventory unavailable under the cap lock; refusing" >&2
    return 22
  fi
  if (( used >= slots )); then
    sim_lock_drop "$clock"
    echo "sim create: refused — pool cap reached (${used}/${slots}); an env var does not bypass the cap" >&2
    return 21
  fi

  # Step 1: durable reservation BEFORE touching simctl, still under the cap lock.
  mkdir -p "$(sim_reserve_dir)" || { sim_lock_drop "$clock"; echo "sim create: cannot create reservation dir" >&2; return 22; }
  local stamp rdir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local me="${BASHPID:-$$}"
  rdir="$(sim_reserve_dir)/${stamp}-$me"
  local device_type="${DISK_MAGICIAN_SIM_DEVICE_TYPE:-iPhone 17 Pro}"
  local rt="${runtime:-iOS 26.5}"
  name="${name:-wai-shared-$(printf '%s' "$rt" | tr ' .' '--' | tr 'A-Z' 'a-z')-$(printf '%s' "$stamp" | tail -c 6)}"
  # Create AND initialise the reservation under the cap lock: recovery takes the
  # same lock, so it can never see a reservation whose meta is not yet written.
  # name is recorded BEFORE simctl so a crash-after-create-before-register is
  # detectable by name (review P0).
  if ! mkdir "$rdir" 2>/dev/null; then
    sim_lock_drop "$clock"
    echo "sim create: reservation race lost" >&2
    return 21
  fi
  if ! printf 'status=reserving\nreason=%s\npid=%s\nruntime=%s\nname=%s\n' "$reason" "$me" "$runtime" "$name" >"$rdir/meta" 2>/dev/null; then
    rm -f "$rdir/meta"; rmdir "$rdir" 2>/dev/null
    sim_lock_drop "$clock"
    echo "sim create: cannot write reservation metadata; refusing" >&2
    return 22
  fi
  # The initialised reservation consumes a slot; release the cap lock before the
  # slow simctl call so other creates can proceed.
  sim_lock_drop "$clock"

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
    # Distinguish "simctl failed and produced nothing" from "a device may exist".
    # A non-zero exit can still have created the device (review P0: a create that
    # emitted a UUID then exited 75 had its reservation deleted, and the next
    # lease handed out the now-unreserved device). Kept unless we can prove the
    # device is absent.
    local snap_after present=0
    if snap_after="$(sim_snapshot 2>/dev/null)"; then
      printf '%s\n' "$snap_after" | awk -F'\t' -v n="$name" '$2==n {found=1} END{exit !found}' && present=1
    else
      present=1   # cannot prove absence -> treat as present
    fi
    if [[ "$present" -eq 1 ]]; then
      printf 'status=pending-reconcile\n' >>"$rdir/meta"
      echo "sim create: simctl create reported failure (rc=$rc) but a device may exist; reservation RETAINED for reconciliation" >&2
      return 24
    fi
    rmdir "$rdir" 2>/dev/null || rm -rf "${rdir:?}"
    echo "sim create: simctl create failed (rc=$rc) and no device exists; reservation released" >&2
    return 1
  fi

  # Step 2: record the produced UDID, then lease it so it is never unleased.
  if ! { printf '%s\n' "$udid" >"$rdir/udid" && printf 'status=created\n' >>"$rdir/meta"; } 2>/dev/null; then
    echo "sim create: cannot record created UDID $udid; device EXISTS but is unmanaged; reservation retained" >&2
    return 24
  fi
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
    # The device exists but is unmanaged. Keep the reservation so the name/UDID
    # stays excluded, and say so explicitly.
    printf 'status=pending-reconcile\n' >>"$rdir/meta"
    echo "sim create: cannot allocate generation; device $udid EXISTS but is unmanaged; reservation retained" >&2
    return 24
  fi
  printf '%s\n' "$gen" >"$d/generation"
  printf '%s\n' "${WORLDAI_SIM_OWNER:-$(id -un)}" >"$d/owner"
  printf '%s\n' "$(sim_token_fingerprint "$token")" >"$d/token_fingerprint"
  chmod 600 "$d/generation" "$d/owner" "$d/token_fingerprint" 2>/dev/null || true
  # Only drop the reservation once the lease is verifiably complete.
  if [[ "$(sim_lease_state "$udid")" != "complete" ]]; then
    printf 'status=pending-reconcile\n' >>"$rdir/meta"
    echo "sim create: created $udid but its lease is not complete; reservation retained" >&2
    return 24
  fi
  rm -rf "${rdir:?}"

  if [[ "$json" == true ]]; then
    sim_json "udid=$udid" "name=$name" "state=Shutdown" "lease_generation=$gen" "lease_token=$token" "created=true"
  else
    # Print the token as well: a caller that only received the UDID could never
    # release the device it just created (review finding).
    printf '%s %s\n' "$udid" "$token"
  fi
  return 0
}

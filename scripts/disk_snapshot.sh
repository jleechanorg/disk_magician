#!/usr/bin/env bash
# disk_snapshot.sh — Write a JSON snapshot of disk usage for monitored paths
#
# Reads configuration from config.json (or config.json.template).
# Supports --discover to scan home folder for large untracked folders.
set -euo pipefail

# A snapshot writer may never invoke another snapshot writer.  The launchd
# orchestrator is the sole owner of this process tree; fail closed if its
# environment re-enters this script before another expensive scan starts.
# The orchestrator's internal `--measure-one` workers are the one sanctioned
# re-entry: they measure a single path and never write a snapshot.
MEASURE_ONE=false
[[ "${1:-}" == "--measure-one" ]] && MEASURE_ONE=true
SNAPSHOT_REENTRY_DEPTH="${DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH:-0}"
if ! [[ "$SNAPSHOT_REENTRY_DEPTH" =~ ^[0-9]+$ ]]; then
  echo "Error: invalid DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH." >&2
  exit 75
fi
if (( SNAPSHOT_REENTRY_DEPTH > 0 )) && [[ "$MEASURE_ONE" != true ]]; then
  echo "Error: nested snapshot invocation rejected." >&2
  exit 75
fi
export DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH=1

OUTPUT=""
DRY_RUN=false
DISCOVER=false
DISCOVER_JSON=false
DU_TIMEOUT=30
SNAPSHOT_BUDGET_SECONDS="${DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS:-1500}"
MEASURE_PATH_MAX_SECONDS="${DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS:-}"
LIBRARY_FRONTIER_BUDGET_SECONDS="${DISK_MAGICIAN_LIBRARY_FRONTIER_BUDGET_SECONDS:-120}"
# Track how many measured paths returned a real value (vs null/timeout)
# so we can surface a measurement_status sentinel (complete | partial |
# timeout | empty) — never a silent zero.
MEASURED_OK=0
MEASURED_TOTAL=0

if [[ "$MEASURE_ONE" == true ]]; then
  [[ $# -eq 5 ]] || { echo "Usage: $0 --measure-one KEY PATH TIMEOUT OUTPUT_FILE" >&2; exit 2; }
  M1_KEY="$2"; M1_PATH="$3"; M1_TIMEOUT="$4"; M1_OUT="$5"
  set --
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)   OUTPUT="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --discover) DISCOVER=true; shift ;;
    --json)     DISCOVER_JSON=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--output file.json] [--dry-run] [--discover [--json]]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/snapshot_budget.sh
source "$SCRIPT_DIR/lib/snapshot_budget.sh"
# Per-path clamp: env > user config snapshot_measure.path_max_seconds > 0
# (0 = unclamped: honor each path's configured timeout).
if [[ -z "$MEASURE_PATH_MAX_SECONDS" ]]; then
  MEASURE_PATH_MAX_SECONDS="$(snapshot_measure_setting path_max_seconds)"
  MEASURE_PATH_MAX_SECONDS="${MEASURE_PATH_MAX_SECONDS:-0}"
fi
SNAPSHOT_STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
CARRY_STATE_FILE="$SNAPSHOT_STATE_DIR/last_good_measurements.json"
export DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS="$MEASURE_PATH_MAX_SECONDS"

# Config resolution order:
#   1. DISK_MAGICIAN_CONFIG env var (caller-supplied path, e.g. user_scope's
#      site-specific config) — lets an external repo reuse this script with its
#      own monitored-dir set without forking it.
#   2. $REPO_ROOT/config.json
#   3. $REPO_ROOT/config.json.template
CONFIG_FILE="${DISK_MAGICIAN_CONFIG:-}"
if [[ -n "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
  echo "Error: DISK_MAGICIAN_CONFIG points to a missing file: $CONFIG_FILE" >&2
  exit 1
fi
if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$REPO_ROOT/config.json"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$REPO_ROOT/config.json.template"
  fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config file not found." >&2
  exit 1
fi

# Portable timeout detection
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
fi

# probe_timeout <secs> <cmd...>: bounded non-file-signal probe. TERM at <secs>,
# KILL 2s later so a TERM-ignoring tool cannot hold the snapshot lock; rc 127
# (read as a failed probe) when no timeout command exists.
probe_timeout() {
  local secs="$1"
  shift
  [[ -n "$TIMEOUT_CMD" ]] || return 127
  "$TIMEOUT_CMD" -k 2 "$secs" "$@"
}

# --measure-one sets this to a per-attempt sidecar. Keeping it separate from
# numeric stdout preserves the existing kb-or-empty contract for all callers.
MEASURE_DIAGNOSTIC_FILE=""
record_measure_diagnostic() {
  local reason="$1" backend="${2:-}" backend_exit="${3:-}" stderr_text="${4:-}"
  [[ -n "${MEASURE_DIAGNOSTIC_FILE:-}" ]] || return 0
  stderr_text=$(printf '%s' "$stderr_text" | tr '\r\n' '  ' | cut -c1-256)
  {
    printf 'reason=%s\n' "$reason"
    printf 'backend=%s\n' "$backend"
    printf 'backend_exit=%s\n' "$backend_exit"
    printf 'stderr=%s\n' "$stderr_text"
  } > "$MEASURE_DIAGNOSTIC_FILE"
}

remaining_measurement_seconds() {
  local remaining=$(( MEASUREMENT_DEADLINE_EPOCH - $(date +%s) ))
  (( remaining > 0 )) && echo "$remaining" || echo 0
}

dir_size_kb() {
  local raw_path="$1"
  local to="${2:-$DU_TIMEOUT}"
  local max_seconds="${3:-$MEASURE_PATH_MAX_SECONDS}"
  # Expand ~ or $HOME manually
  local path
  path="${raw_path/#\~/$HOME}"
  path=$(eval echo "$path")

  if [[ ! -e "$path" ]]; then
    record_measure_diagnostic success filesystem 0 ""
    echo 0
    return
  fi

  local remaining path_budget result=""
  remaining=$(remaining_measurement_seconds)
  if (( remaining <= 0 )); then
    record_measure_diagnostic orchestrator_deadline "" "" "measurement deadline exhausted"
    echo ""
    return
  fi
  if [[ -z "$TIMEOUT_CMD" ]]; then
    record_measure_diagnostic backend_unavailable du "" "timeout command unavailable"
    echo ""
    return
  fi
  [[ "$to" =~ ^[0-9]+$ && "$to" -gt 0 ]] || to="$DU_TIMEOUT"
  [[ "$max_seconds" =~ ^[0-9]+$ ]] || max_seconds="$MEASURE_PATH_MAX_SECONDS"
  : "${LOAD_FACTOR:=$(load_factor)}"
  path_budget=$(scaled_path_budget "$to" "$LOAD_FACTOR")
  (( max_seconds > 0 && path_budget > max_seconds )) && path_budget="$max_seconds"
  (( path_budget > remaining )) && path_budget="$remaining"
  # A numeric dua result can omit unreadable children while exiting zero.
  # Use one bounded du walk whose nonzero exit rejects partial totals.
  local du_stdout du_stderr du_rc du_value
  du_stdout=$(mktemp -t disk_magician_du.XXXXXX)
  du_stderr=$(mktemp -t disk_magician_du_err.XXXXXX)
  if "$TIMEOUT_CMD" "$path_budget" du -sk "$path" >"$du_stdout" 2>"$du_stderr"; then
    du_value=$(awk 'BEGIN{n=0; ok=1} /^[0-9]+[[:space:]]/ {n++; v=$1; next} NF {ok=0} END{if(ok && n==1) print v}' "$du_stdout")
    if [[ "$du_value" =~ ^[0-9]+$ ]]; then
      result="$du_value"
      record_measure_diagnostic success du 0 ""
    else
      record_measure_diagnostic backend_error du 0 "malformed du output"
    fi
  else
    du_rc=$?
    if [[ "$du_rc" -eq 124 ]]; then
      record_measure_diagnostic backend_timeout du "$du_rc" "$(head -c 256 "$du_stderr" 2>/dev/null || true)"
    else
      record_measure_diagnostic backend_error du "$du_rc" "$(head -c 256 "$du_stderr" 2>/dev/null || true)"
    fi
  fi
  rm -f "$du_stdout" "$du_stderr"

  if [[ -z "$result" ]]; then
    # An unsuccessful measurement is null (empty string), never zero.
    echo ""
    return
  fi
  echo "$result"
}

glob_size_kb() {
  local raw_pattern="$1"
  local pattern
  pattern="${raw_pattern/#\~/$HOME}"
  pattern=$(eval echo "$pattern")

  local total=0
  for d in $pattern; do
    [[ -e "$d" ]] || continue
    local s
    s=$(dir_size_kb "$d" "$DU_TIMEOUT")
    [[ -n "$s" ]] || { echo ""; return; }
    total=$(( total + s ))
  done
  echo "$total"
}

# Shared serialization for standalone workers and serial snapshot attempts.
write_measurement_result() {
  python3 - "$@" <<'PY'
import json, sys

out, key, path, kb_text, elapsed, diagnostic_file, attempt = sys.argv[1:]
diagnostic = {}
try:
    with open(diagnostic_file) as f:
        for line in f:
            name, _, value = line.rstrip("\n").partition("=")
            diagnostic[name] = value
except OSError:
    pass
kb = int(kb_text) if kb_text.isdigit() else None
reason = "success" if kb is not None else (diagnostic.get("reason") or "missing_diagnostic")
data = {"key": key, "kb": kb, "path": path, "elapsed_s": int(elapsed),
        "timed_out": reason == "backend_timeout", "reason": reason, "attempt": int(attempt)}
for name in ("backend", "stderr"):
    if diagnostic.get(name):
        data[name] = diagnostic[name][:256]
if diagnostic.get("backend_exit", "").lstrip("-").isdigit():
    data["backend_exit"] = int(diagnostic["backend_exit"])
with open(out, "w") as f:
    json.dump(data, f, separators=(",", ":"))
PY
}

# Internal worker mode for snapshot_measure.py: one dir_size_kb call, one JSON file.
if [[ "$MEASURE_ONE" == true ]]; then
  # set -u safe: the orchestrator passes its deadline; standalone use gets the key's own timeout.
  MEASUREMENT_DEADLINE_EPOCH="${DISK_MAGICIAN_WORKER_DEADLINE_EPOCH:-$(( $(date +%s) + M1_TIMEOUT ))}"
  # GNU timeout otherwise moves its child into a new process group, which the
  # orchestrator's tree-kill must not depend on.
  if [[ -n "$TIMEOUT_CMD" ]]; then
    TIMEOUT_REAL="$(command -v "$TIMEOUT_CMD")"
    timeout_fg() { "$TIMEOUT_REAL" --foreground "$@"; }
    TIMEOUT_CMD=timeout_fg
  fi
  m1_start=$(date +%s)
  M1_DIAGNOSTIC_FILE="${M1_OUT}.diag"
  export MEASURE_DIAGNOSTIC_FILE="$M1_DIAGNOSTIC_FILE"
  m1_kb=$(dir_size_kb "$M1_PATH" "$M1_TIMEOUT")
  m1_elapsed=$(( $(date +%s) - m1_start ))
  write_measurement_result "$M1_OUT" "$M1_KEY" "$M1_PATH" "$m1_kb" "$m1_elapsed" "$M1_DIAGNOSTIC_FILE" 1
  rm -f "$M1_DIAGNOSTIC_FILE"
  exit 0
fi

get_disk_stats() {
  local target="/"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if df "/System/Volumes/Data" >/dev/null 2>&1; then
      target="/System/Volumes/Data"
    fi
  fi
  df -k "$target" 2>/dev/null | awk 'NR==2{
    total = $2+0
    used  = $3+0
    avail = $4+0
    pct   = int(used * 100 / (total > 0 ? total : 1))
    printf "%d %d %d %d", total, used, avail, pct
  }'
}

# ────────── SWAP / VM VOLUME (bead disk_magician-8to) ──────────
# Swap and the hidden /System/Volumes/VM volume consume real disk space
# outside the "Data volume" df accounting that disk_used_gb above is
# computed from — a large swapfile can silently eat tens of GiB that never
# show up in the primary floor/bucket accounting. Prints "<total_mb>
# <used_mb>"; tolerates a missing/non-darwin sysctl by printing "0 0".
get_swap_stats() {
  if [[ "$OSTYPE" != "darwin"* ]] || ! command -v sysctl &>/dev/null; then
    echo "0 0"
    return
  fi
  sysctl vm.swapusage 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "total" && $(i+1) == "=") { tot = $(i+2) }
        if ($i == "used"  && $(i+1) == "=") { usd = $(i+2) }
      }
    }
    END {
      gsub(/M/, "", tot); gsub(/M/, "", usd)
      if (tot == "") tot = 0
      if (usd == "") usd = 0
      printf "%s %s", tot, usd
    }'
}

# /System/Volumes/VM backs the macOS swapfile(s) and sleepimage on modern
# APFS layouts. Reports used KB; 0 when unmeasurable (non-darwin, or the
# volume isn't mounted/visible).
get_vm_volume_used_kb() {
  local kb=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    kb=$(df -k /System/Volumes/VM 2>/dev/null | awk 'NR==2{print $3+0}')
  fi
  echo "${kb:-0}"
}

# ────────── APFS PER-VOLUME CONSUMED + CONTAINER FREE (bead disk_magician-rpv) ──────────
# disk_used_gb/disk_free_gb above are df's view of the Data volume only. The
# same APFS container also carries System/Preboot/Update/VM volumes whose
# CapacityInUse can shift within one 35-min interval (kernel staging,
# snapshot churn, swap growth) with zero corresponding change under any
# monitored_dirs path — one of the non-file signals disk_magician-rpv needs
# to attribute df's observed ±8-62 GiB swings. Bounded by `timeout`; any
# failure (non-darwin, missing diskutil, malformed plist) degrades to "{}"
# rather than aborting the snapshot. Piping `diskutil apfs list -plist`
# straight into `plutil -convert json -o - -` (stdin in, stdout out) never
# touches a file on disk, so it cannot hit the plutil-corrupts-live-plist
# footgun that bit this repo's own launchd plists (2026-09-11 postmortem).
# disk_frontier_scan.py's get_sibling_volumes()/get_purgeable_info() compute
# the equivalent per-volume/purgeable data for the nightly frontier scan;
# this is a separate, dependency-free probe sized for the 35-min cadence
# rather than an import of that heavier module.
get_apfs_volume_stats_json() {
  if [[ "$OSTYPE" != "darwin"* ]] || ! command -v diskutil &>/dev/null || ! command -v plutil &>/dev/null; then
    echo "{}"
    return
  fi
  local plist_json
  plist_json=$(probe_timeout 8 diskutil apfs list -plist 2>/dev/null | probe_timeout 5 plutil -convert json -o - - 2>/dev/null)
  if [[ -z "$plist_json" ]]; then
    echo "{}"
    return
  fi
  printf '%s' "$plist_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("{}")
    sys.exit(0)
result = {"volumes_bytes": {}, "container_free_bytes": None, "container_capacity_bytes": None}
for container in data.get("Containers", []):
    volumes = container.get("Volumes", []) or []
    roles_seen = {r for v in volumes for r in (v.get("Roles") or [])}
    if "Data" not in roles_seen:
        continue
    result["container_free_bytes"] = container.get("CapacityFree")
    result["container_capacity_bytes"] = container.get("CapacityCeiling")
    for v in volumes:
        for role in (v.get("Roles") or []):
            if role in ("Data", "VM", "Preboot", "Update"):
                result["volumes_bytes"][role] = v.get("CapacityInUse")
    break
print(json.dumps(result))
' 2>/dev/null || echo "{}"
}

# tmutil listlocalsnapshots is the verifiable proxy for purgeable/reclaimable
# local-snapshot space — diskutil exposes no distinct "purgeable" field on
# this macOS version (verified empirically; disk_frontier_scan.py's
# get_purgeable_info() docstring records the same finding). Prints
# "<count>\t<comma-joined snapshot names>"; degrades to "0\t" on any failure.
#
# Null-vs-zero (/advice review, Codex + Opus, both high confidence,
# 2026-09-25): "we measured and got zero" and "we could not measure" must
# stay distinguishable, or a transient tool failure reads to the correlator
# as a real multi-GiB swing in the signal itself. A genuine tmutil failure
# (nonzero exit, e.g. timeout) prints count "-1" (never a legitimate count),
# which the JSON builder below turns into null — never a fabricated 0.
get_local_snapshots_line() {
  if [[ "$OSTYPE" != "darwin"* ]] || ! command -v tmutil &>/dev/null; then
    printf -- '-1\t\n'
    return
  fi
  local raw rc names count
  raw=$(probe_timeout 10 tmutil listlocalsnapshots / 2>/dev/null)
  rc=$?
  # Real tmutil success always emits at least the "Snapshots for disk /:"
  # header, so empty output plus a nonzero exit both mean the call itself
  # failed (killed by timeout, tmutil error) — never "confirmed zero".
  if [[ $rc -ne 0 || -z "$raw" ]]; then
    printf -- '-1\t\n'
    return
  fi
  names=$(printf '%s\n' "$raw" | grep -v '^Snapshots for' | sed '/^[[:space:]]*$/d' | paste -sd, -)
  count=0
  [[ -n "$names" ]] && count=$(printf '%s' "$names" | awk -F, '{print NF}')
  printf '%s\t%s\n' "$count" "$names"
}

# Colima's guest disk (~/.colima/_lima/colima/diffdisk — NOT _lima/_disks,
# see this repo's CLAUDE.md) is a sparse file: its logical size is unrelated
# to host bytes actually consumed. `stat`'s block count and `du`'s block
# count are two independent syscalls over that sparseness and have been
# observed to disagree, so both are recorded rather than picking one. Prints
# "<stat_allocated_bytes>\t<du_allocated_kb>". A missing diffdisk (Colima not
# installed/never started) is a real, meaningful 0 — there truly is zero
# Colima disk usage — but a failure of `stat`/`du` on an *existing* diffdisk
# (permission error, timeout) is a measurement failure and must not be
# reported as that same 0; each measurement independently prints "-1" on
# failure, which the JSON builder below turns into null (/advice review,
# Codex + Opus, both high confidence, 2026-09-25: a `du` timeout silently
# recording 0 would read to the correlator as a fabricated multi-GiB swing).
get_colima_diffdisk_stats() {
  local diffdisk="$HOME/.colima/_lima/colima/diffdisk"
  if [[ ! -e "$diffdisk" ]]; then
    # Absent is a real 0 only when the parent is searchable (or absent);
    # an unsearchable parent hides the file, so the size is unknown.
    local parent="${diffdisk%/*}"
    if [[ ! -e "$parent" || -x "$parent" ]]; then
      printf '0\t0\n'
    else
      printf -- '-1\t-1\n'
    fi
    return
  fi
  local stat_blocks stat_rc du_raw du_rc stat_bytes du_kb
  stat_blocks=$(probe_timeout 5 stat -f "%b" "$diffdisk" 2>/dev/null)
  stat_rc=$?
  if [[ $stat_rc -ne 0 || -z "$stat_blocks" ]]; then
    stat_bytes="-1"
  else
    stat_bytes=$(( stat_blocks * 512 ))
  fi
  du_raw=$(probe_timeout 10 du -k "$diffdisk" 2>/dev/null)
  du_rc=$?
  if [[ $du_rc -ne 0 || -z "$du_raw" ]]; then
    du_kb="-1"
  else
    du_kb=$(printf '%s' "$du_raw" | awk '{print $1+0}')
    [[ -z "$du_kb" ]] && du_kb="-1"
  fi
  printf '%s\t%s\n' "$stat_bytes" "$du_kb"
}

# ────────── DISCOVER MODE ──────────
if [[ "$DISCOVER" == true ]]; then
  if [[ "$DISCOVER_JSON" != true ]]; then
    echo "Discover mode: scanning for >5 GB dirs not in monitored config..."
    echo ""
  fi

  # Extract configured paths. Temp-file sets keep discover mode compatible
  # with the stock Bash 3.2 shipped by macOS.
  MONITORED_PATHS_FILE=$(mktemp -t disk_magician_monitored.XXXXXX)
  while IFS=$'\t' read -r raw_path; do
    path="${raw_path/#\~/$HOME}"
    path=$(eval echo "$path")
    printf '%s\n' "$path" >> "$MONITORED_PATHS_FILE"
  done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_dirs", []):
    print(item["path"])
PY
)

  # Also expand monitored_globs / monitored_file_globs so a directory matched
  # by a glob pattern (e.g. `~/actions-runner*`) is reported as tracked too,
  # not as UNTRACKED. This keeps `discover` consistent with the snapshot
  # measurement (which honors globs).
  while IFS=$'\t' read -r raw_pattern; do
    pattern="${raw_pattern/#\~/$HOME}"
    # shellcheck disable=SC2206
    expanded=( $(eval echo "$pattern") )
    for p in "${expanded[@]}"; do
      [[ -e "$p" ]] && printf '%s\n' "$p" >> "$MONITORED_PATHS_FILE"
    done
  done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_globs", []):
    print(item["pattern"])
for item in data.get("monitored_file_globs", []):
    print(item["pattern"])
PY
)

  # STATE_DIR must exist and be known BEFORE the candidate scan below so we
  # can exclude disk_magician's own state directory from the candidate list —
  # otherwise `discover` would measure and cache itself every run.
  STATE_DIR="$HOME/.disk_magician_state"
  mkdir -p "$STATE_DIR"
  CACHE_FILE="$STATE_DIR/discover_cache.json"
  DISCOVER_LAST_FILE="$STATE_DIR/discover_last.json"

  candidates=()
  for d in "$HOME"/.[!.]* "$HOME"/*; do
    [[ -d "$d" ]] || continue
    [[ "$d" == "$STATE_DIR" ]] && continue
    candidates+=("$d")
  done

  # ────────── mtime size-cache (fixes bead jleechan-jz5t timeout) ──────────
  # A top-level dir's own mtime only changes when a DIRECT child is added or
  # removed — not on writes deep inside it — but that's exactly the signal
  # `du` itself needs re-running for: an unchanged top-level mtime means the
  # child listing (and thus what `du` would walk) is unchanged since we last
  # measured it, so we can safely reuse the cached size and skip the `du`
  # entirely. This is what turns repeat `discover` runs from "re-walk
  # everything every time" (the thing that was timing out) into "only
  # re-walk what actually changed."
  CACHE_READ_FILE=$(mktemp -t disk_magician_cache_read.XXXXXX)
  if [[ -f "$CACHE_FILE" ]]; then
    python3 - "$CACHE_FILE" > "$CACHE_READ_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
for path, v in (data or {}).items():
    print(f"{path}\t{v.get('mtime', 0)}\t{v.get('size_kb', 0)}")
PY
  fi

  DISCOVER_TEMP_FILE=$(mktemp -t disk_magician_discover.XXXXXX)
  CACHE_DUMP_FILE=$(mktemp -t disk_magician_cachedump.XXXXXX)
  _cleanup_discover_temp() {
    rm -f "$DISCOVER_TEMP_FILE" "$MONITORED_PATHS_FILE" \
      "$CACHE_READ_FILE" "$CACHE_DUMP_FILE"
  }
  trap _cleanup_discover_temp EXIT

  cache_hits=0
  cache_misses=0

  # Process substitution (not a pipe) keeps cache hit/miss counters in this
  # shell. Each refreshed row is also the complete replacement cache.
  while read -r dir; do
    mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
    cached_mtime=""
    cached_size=""
    while IFS=$'\t' read -r cached_path candidate_mtime candidate_size; do
      [[ "$cached_path" == "$dir" ]] || continue
      cached_mtime="$candidate_mtime"
      cached_size="$candidate_size"
      break
    done < "$CACHE_READ_FILE"
    if [[ -n "$cached_mtime" && "$cached_mtime" == "$mtime" ]]; then
      kb="${cached_size:-0}"
      cache_hits=$(( cache_hits + 1 ))
    else
      kb=""
      if [[ -n "$TIMEOUT_CMD" ]]; then
        kb=$("$TIMEOUT_CMD" 60 du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
      else
        kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
      fi
      kb="${kb:-0}"
      cache_misses=$(( cache_misses + 1 ))
    fi
    printf "%s\t%s\t%s\n" "$dir" "$mtime" "$kb" >> "$CACHE_DUMP_FILE"
    tracked=0
    grep -Fqx -- "$dir" "$MONITORED_PATHS_FILE" && tracked=1
    printf "%s\t%s\t%s\n" "$dir" "$kb" "$tracked" >> "$DISCOVER_TEMP_FILE"
  done < <(printf '%s\n' "${candidates[@]}")

  # Persist the refreshed cache (full replace — self-cleans entries for dirs
  # that no longer exist since we only ever wrote candidates we just scanned).
  # NOTE: dump to a temp FILE rather than piping into python3's stdin — `python3 -`
  # already reads its PROGRAM from stdin via the heredoc below, so a pipe into
  # the same invocation would silently be discarded (heredoc wins the fd, the
  # piped data is never seen). A temp file + argv path sidesteps that entirely.
  python3 - "$CACHE_DUMP_FILE" "$CACHE_FILE" <<'PY'
import json, sys
data = {}
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        path, mtime, size_kb = parts
        try:
            data[path] = {"mtime": int(mtime), "size_kb": int(size_kb)}
        except ValueError:
            continue
json.dump(data, open(sys.argv[2], "w"), indent=2)
PY

  # Build the persisted findings file + stdout output from the same data, so
  # `discover`'s findings stop "going nowhere" — every run leaves a structured
  # record behind regardless of --json, and --json additionally prints it.
  DISCOVER_JSON="$DISCOVER_JSON" CACHE_HITS="$cache_hits" CACHE_MISSES="$cache_misses" \
    python3 - "$DISCOVER_TEMP_FILE" "$DISCOVER_LAST_FILE" <<'PY'
import json, os, sys, datetime

temp_file, last_file = sys.argv[1], sys.argv[2]
THRESHOLD_KB = 5 * 1024 * 1024  # 5 GB, matches the original discover threshold

entries = []
with open(temp_file) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        path, kb_s, tracked_s = parts
        try:
            kb = int(kb_s)
        except ValueError:
            kb = 0
        if kb < THRESHOLD_KB:
            continue
        entries.append({
            "path": path,
            "size_kb": kb,
            "size_gb": round(kb / 1048576, 1),
            "tracked": tracked_s == "1",
        })
entries.sort(key=lambda e: e["size_kb"], reverse=True)

result = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cache_hits": int(os.environ.get("CACHE_HITS") or 0),
    "cache_misses": int(os.environ.get("CACHE_MISSES") or 0),
    "entries": entries,
}
with open(last_file, "w") as f:
    json.dump(result, f, indent=2)

if os.environ.get("DISCOVER_JSON") == "true":
    print(json.dumps(result, indent=2))
else:
    for e in entries:
        label = "tracked   " if e["tracked"] else "UNTRACKED"
        print(f"  {label}  {e['size_gb']} GB  {e['path']}")
PY
  exit 0
fi

# ────────── SNAPSHOT MODE ──────────
read -r disk_total_kb disk_used_kb disk_free_kb disk_pct <<< "$(get_disk_stats)"
if [[ ! "$SNAPSHOT_BUDGET_SECONDS" =~ ^[0-9]+$ || "$SNAPSHOT_BUDGET_SECONDS" -le 0 ]]; then
  echo "Error: DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS must be a positive integer." >&2
  exit 2
fi
if [[ ! "$MEASURE_PATH_MAX_SECONDS" =~ ^[0-9]+$ || "$MEASURE_PATH_MAX_SECONDS" -lt 0 ]]; then
  echo "Error: DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS must be a non-negative integer (0 = unclamped)." >&2
  exit 2
fi
if [[ ! "$LIBRARY_FRONTIER_BUDGET_SECONDS" =~ ^[0-9]+$ || "$LIBRARY_FRONTIER_BUDGET_SECONDS" -le 0 ]]; then
  echo "Error: DISK_MAGICIAN_LIBRARY_FRONTIER_BUDGET_SECONDS must be a positive integer." >&2
  exit 2
fi
MEASUREMENT_STARTED_EPOCH=$(date +%s)
# Hard measurement deadline (spec): start + min(budget, 860*scale). The outer
# SNAPSHOT_BUDGET_SECONDS (1500) stays the reported budget and safety net.
PHASE_SCALE="${DISK_MAGICIAN_PHASE_SCALE:-1}"
MEASUREMENT_WINDOW=$(awk -v b="$SNAPSHOT_BUDGET_SECONDS" -v s="$PHASE_SCALE" 'BEGIN{ w = 860 * s; if (b < w) w = b; printf "%d", (w < 1 ? 1 : w) }')
MEASUREMENT_DEADLINE_EPOCH=$(( MEASUREMENT_STARTED_EPOCH + MEASUREMENT_WINDOW ))
ORCHESTRATOR_DEADLINE_EPOCH=$(awk -v st="$MEASUREMENT_STARTED_EPOCH" -v s="$PHASE_SCALE" -v md="$MEASUREMENT_DEADLINE_EPOCH" 'BEGIN{ d = st + 640 * s; if (md < d) d = md; printf "%d", d }')
disk_total_gb=$(awk "BEGIN{printf \"%.0f\", $disk_total_kb / 1024 / 1024}")
disk_used_gb=$(awk "BEGIN{printf \"%.0f\", $disk_used_kb / 1024 / 1024}")
disk_free_gb=$(awk "BEGIN{printf \"%.0f\", $disk_free_kb / 1024 / 1024}")

# Additive swap/VM-volume accounting (bead disk_magician-8to). Never blocks
# or slows the snapshot — both helpers are cheap (sysctl/df) and default to
# "0 0" / 0 on any failure.
read -r swap_total_mb swap_used_mb <<< "$(get_swap_stats)"
swap_total_gb=$(awk "BEGIN{printf \"%.2f\", (${swap_total_mb:-0} + 0) / 1024}")
swap_used_gb=$(awk "BEGIN{printf \"%.2f\", (${swap_used_mb:-0} + 0) / 1024}")
vm_volume_used_kb=$(get_vm_volume_used_kb)
vm_volume_used_gb=$(awk "BEGIN{printf \"%.2f\", (${vm_volume_used_kb:-0} + 0) / 1024 / 1024}")

# Additive non-file signals (bead disk_magician-rpv): per-APFS-volume
# consumed, container free/purgeable, local snapshot count, Colima diffdisk
# allocation. Same never-blocks-the-snapshot posture as swap/VM above.
apfs_volume_stats_json=$(get_apfs_volume_stats_json)
read -r local_snapshots_count local_snapshot_names_csv <<< "$(get_local_snapshots_line)"
read -r colima_diffdisk_stat_bytes colima_diffdisk_du_kb <<< "$(get_colima_diffdisk_stats)"

tracked_total_kb=0
timeout_keys=()
DIRS_TEMP_FILE=$(mktemp -t disk_magician_dirs.XXXXXX)
RETRY_TEMP_FILE=$(mktemp -t disk_magician_retries.XXXXXX)
LIBRARY_FRONTIER_FILE=$(mktemp -t disk_magician_library_frontier.XXXXXX)
CARRY_FRESH_FILE=$(mktemp -t disk_magician_carry_fresh.XXXXXX)
SERIAL_ATTEMPTS_FILE=$(mktemp -t disk_magician_serial_attempts.XXXXXX)
SERIAL_RESULT_FILE=$(mktemp -t disk_magician_serial_result.XXXXXX)
_cleanup_dirs_temp() { rm -f "$DIRS_TEMP_FILE" "$RETRY_TEMP_FILE" "$LIBRARY_FRONTIER_FILE" "$CARRY_FRESH_FILE" "$SERIAL_ATTEMPTS_FILE" "$SERIAL_RESULT_FILE" "${SERIAL_RESULT_FILE}.diag"; }
trap _cleanup_dirs_temp EXIT

measure_serial() {
  local key="$1" path="$2" timeout="$3" attempt="$4" max_seconds="${5:-$MEASURE_PATH_MAX_SECONDS}"
  local started elapsed size
  started=$(date +%s)
  MEASURE_DIAGNOSTIC_FILE="${SERIAL_RESULT_FILE}.diag"
  : > "$MEASURE_DIAGNOSTIC_FILE"
  size=$(dir_size_kb "$path" "$timeout" "$max_seconds")
  elapsed=$(( $(date +%s) - started ))
  write_measurement_result "$SERIAL_RESULT_FILE" "$key" "$path" "$size" "$elapsed" "$MEASURE_DIAGNOSTIC_FILE" "$attempt"
  cat "$SERIAL_RESULT_FILE" >> "$SERIAL_ATTEMPTS_FILE"
  printf '\n' >> "$SERIAL_ATTEMPTS_FILE"
  printf '%s' "$size"
}

# add_entry records a measured (or timed-out) path under `key`. `src_path` is
# the literal config path/pattern that produced this measurement — carried
# through (not just discarded) so the dedup-trie pass below can resolve it
# to a realpath and detect parent/child or symlink-alias overlaps. Glob-based
# entries pass their raw pattern string as src_path too; the dedup pass only
# attempts realpath containment on paths that look like concrete (non-glob)
# paths and silently leaves globs out of dedup (see dedup pass comment).
add_entry() {
  local key="$1" raw_val="$2" src_path="${3:-}"
  local val="null"
  MEASURED_TOTAL=$(( MEASURED_TOTAL + 1 ))
  if [[ -n "$raw_val" ]]; then
    val="$raw_val"
    tracked_total_kb=$(( tracked_total_kb + raw_val ))
    MEASURED_OK=$(( MEASURED_OK + 1 ))
  else
    timeout_keys+=("$key")
  fi
  printf "%s\t%s\t%s\n" "$key" "$val" "$src_path" >> "$DIRS_TEMP_FILE"
}

# Run dir checks: bounded parallel orchestrator by default, the original serial
# loop when workers=0 or the orchestrator fails (measure_mode records which).
MEASURE_MODE=serial
MEASURE_WORKERS_USED=0
MEASUREMENT_FAILURES_JSON='[]'
MEASURE_WORKERS_SETTING="${DISK_MAGICIAN_MEASURE_WORKERS:-$(snapshot_measure_setting workers)}"
if [[ "$MEASURE_WORKERS_SETTING" != "0" ]]; then
  ORCH_SCRIPT="${DISK_MAGICIAN_MEASURE_ORCHESTRATOR:-$SCRIPT_DIR/snapshot_measure.py}"
  ORCH_OUT=$(mktemp -t disk_magician_orch.XXXXXX)
  ORCH_META=$(mktemp -t disk_magician_orch_meta.XXXXXX)
  ORCH_DIR=$(mktemp -d -t disk_magician_orch_dir.XXXXXX)
  if python3 "$ORCH_SCRIPT" --config "$CONFIG_FILE" --snapshot-script "$SCRIPT_DIR/disk_snapshot.sh" \
       --workers "$MEASURE_WORKERS_SETTING" --deadline-epoch "$ORCHESTRATOR_DEADLINE_EPOCH" \
       --tmpdir "$ORCH_DIR" --meta-out "$ORCH_META" --carry-state "$CARRY_STATE_FILE" > "$ORCH_OUT" 2>/dev/null; then
    MEASURE_MODE=parallel
    MEASURE_WORKERS_USED=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('measure_workers', 0))" "$ORCH_META" 2>/dev/null || echo 0)
    MEASUREMENT_FAILURES_JSON=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('measurement_failures', []), separators=(',', ':')))" "$ORCH_META" 2>/dev/null || echo '[]')
    while IFS= read -r orch_line; do
      orch_key="${orch_line%%$'\t'*}"; orch_rest="${orch_line#*$'\t'}"
      orch_size="${orch_rest%%$'\t'*}"; orch_rest="${orch_rest#*$'\t'}"
      orch_path="${orch_rest%%$'\t'*}"
      add_entry "$orch_key" "$orch_size" "$orch_path"
    done < "$ORCH_OUT"
  else
    MEASURE_MODE=serial_fallback
    MEASUREMENT_FAILURES_JSON='[{"key":"__orchestrator__","status":"failed","attempts":[{"attempt":0,"reason":"orchestrator_launch_failure","elapsed_s":0.0}]}]'
  fi
  rm -rf "$ORCH_OUT" "$ORCH_META" "$ORCH_DIR"
fi
if [[ "$MEASURE_MODE" != "parallel" ]]; then
while IFS=$'\t' read -r key path timeout retry_timeout; do
  size=$(measure_serial "$key" "$path" "$timeout" 1)
  if [[ -z "$size" && "$retry_timeout" =~ ^[0-9]+$ && "$retry_timeout" -gt 0 && \
        ( "$MEASURE_PATH_MAX_SECONDS" -eq 0 || "$retry_timeout" -gt "$MEASURE_PATH_MAX_SECONDS" ) ]]; then
    printf "%s\t%s\t%s\n" "$key" "$path" "$retry_timeout" >> "$RETRY_TEMP_FILE"
  elif [[ -z "$size" && "$MEASURE_PATH_MAX_SECONDS" -eq 0 ]]; then
    # Unclamped mode: every timed-out key gets one serial retry (own configured
    # timeout) after all keys have had a first pass; the global deadline still wins.
    printf "%s\t%s\t%s\n" "$key" "$path" "$timeout" >> "$RETRY_TEMP_FILE"
  else
    add_entry "$key" "$size" "$path"
  fi
done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_dirs", []):
    print(f"{item['key']}\t{item['path']}\t{item.get('timeout', 30)}\t{item.get('retry_timeout', 0)}")
PY
)
fi

# Retry only explicitly selected slow directories after every configured entry
# has received the short first pass. The existing global deadline remains the
# final authority, so retries cannot extend the snapshot budget.
while IFS=$'\t' read -r key path retry_timeout; do
  size=$(measure_serial "$key" "$path" "$retry_timeout" 2 "$retry_timeout")
  add_entry "$key" "$size" "$path"
done < "$RETRY_TEMP_FILE"

if [[ "$MEASURE_MODE" != "parallel" ]]; then
  MEASUREMENT_FAILURES_JSON=$(python3 - "$SCRIPT_DIR" "$SERIAL_ATTEMPTS_FILE" "$MEASUREMENT_FAILURES_JSON" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from snapshot_measure import summarize_attempts
attempts = {}
with open(sys.argv[2]) as source:
    for line in source:
        result = json.loads(line)
        attempts.setdefault(result["key"], []).append(result)
print(json.dumps(json.loads(sys.argv[3]) + summarize_attempts(attempts), separators=(",", ":")))
PY
)
fi

# ────────── TOP-20 LIBRARY/CONTAINERS SUBDIRS (additive) ──────────
# Per Lane B Section C: the 50 GB Library/Containers blind spot. Track
# the top-20 per-container subdirs so future regrowth has attribution.
# Each entry is a separate top-level directory key (lc_<safe_name>) to
# keep JSON flat — consumers do not need to recurse.
containers_parent="$HOME/Library/Containers"
containers_listing=""
if [[ -d "$containers_parent" ]]; then
  # Build a sorted list of (size_kb, name) inside the same remaining global
  # budget and per-path cap as the allowlist measurements.
  containers_budget=$(remaining_measurement_seconds)
  containers_cap="$MEASURE_PATH_MAX_SECONDS"
  (( containers_cap > 0 )) || containers_cap=20
  (( containers_budget > containers_cap )) && containers_budget="$containers_cap"
  if [[ -n "$TIMEOUT_CMD" && "$containers_budget" -gt 0 ]]; then
    containers_listing=$("$TIMEOUT_CMD" "$containers_budget" du -sk "$containers_parent"/* 2>/dev/null \
      | sort -rn | head -20 || true)
  fi
  while IFS=$'\t' read -r kb name; do
    [[ -z "$kb" || -z "$name" ]] && continue
    [[ "$kb" =~ ^[0-9]+$ ]] || continue
    base=$(basename "$name")
    safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9' '_' | head -c 40)
    key="lc_${safe}"
    add_entry "$key" "$kb" "$name"
  done <<< "$containers_listing"
fi

# ────────── LIBRARY FRONTIER (advisory, bounded, no double-count) ──────────
# The allowlist intentionally retains stable historical keys, but it cannot
# systematically name every direct ~/Library child. Reuse the exhaustive
# scanner under a strict slice of the existing global deadline. This ledger is
# advisory: its measurements are not added to tracked_total_kb, because several
# allowlist entries overlap it and the snapshot dedup trie remains the sole
# owner of coverage arithmetic.
LIBRARY_COVERAGE_JSON="null"
library_root="$HOME/Library"
LIBRARY_FRONTIER_ENABLED=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print("true" if data.get("library_frontier_enabled") is True else "false")
except Exception:
    print("false")
' "$CONFIG_FILE" 2>/dev/null || echo "false")
if [[ "$LIBRARY_FRONTIER_ENABLED" == "true" && -d "$library_root" ]]; then
  library_budget=$(remaining_measurement_seconds)
  (( library_budget > LIBRARY_FRONTIER_BUDGET_SECONDS )) && library_budget="$LIBRARY_FRONTIER_BUDGET_SECONDS"
  if [[ "$library_budget" -gt 0 && -n "$TIMEOUT_CMD" ]]; then
    scanner_budget=$(( library_budget > 2 ? library_budget - 2 : 1 ))
    "$TIMEOUT_CMD" "$library_budget" python3 "$SCRIPT_DIR/disk_frontier_scan.py" \
      --root "$library_root" --resolve-root --no-sibling-volumes --no-purgeable \
      --workers 6 --max-depth 2 --max-nodes 400 \
      --timeout-tiers 2,5 --wall-clock-cap "$scanner_budget" \
      --output "$LIBRARY_FRONTIER_FILE" >/dev/null 2>&1 || true
  fi

  # The scanner owns the per-child ledger. If the outer deadline kills it
  # before an atomic report lands, emit an explicit unfinished row per direct
  # child instead of silently omitting Library coverage.
  LIBRARY_COVERAGE_JSON=$(python3 - "$LIBRARY_FRONTIER_FILE" "$library_root" "${library_budget:-0}" <<'PY' 2>/dev/null || echo "null"
import collections, json, os, sys

report_path, root, wall_cap = sys.argv[1], os.path.realpath(sys.argv[2]), int(sys.argv[3])
try:
    with open(report_path) as f:
        report = json.load(f)
except Exception:
    report = {}
ledger = report.get("top_level_ledger")
if not isinstance(ledger, list):
    try:
        with os.scandir(root) as entries:
            paths = sorted(os.path.realpath(entry.path) for entry in entries)
    except OSError:
        paths = [root]
    ledger = [{
        "path": path,
        "status": "unfinished",
        "measured_kb": None,
        "unfinished_reasons": ["scanner_timeout_or_error"],
    } for path in paths]
status_counts = collections.Counter(item.get("status") for item in ledger)
result = {
    "mode": report.get("mode") if report else "partial",
    "root": root,
    "captured_at": report.get("captured_at"),
    "elapsed_seconds": report.get("elapsed_s"),
    "wall_clock_cap_seconds": wall_cap,
    "top_level_children_total": len(ledger),
    "top_level_children_accounted": len(ledger),
    "status_counts": dict(sorted(status_counts.items())),
    "top_level_ledger": ledger,
}
print(json.dumps(result))
PY
)
  [[ -n "$LIBRARY_COVERAGE_JSON" ]] || LIBRARY_COVERAGE_JSON="null"
fi
# Globs run after lc_* and the library frontier so those are never starved by
# slow per-directory globs; the shared measurement deadline still bounds them.
# Run file glob checks
while IFS=$'\t' read -r key pattern; do
  size=$(glob_size_kb "$pattern")
  add_entry "$key" "$size" "$pattern"
done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_file_globs", []):
    print(f"{item['key']}\t{item['pattern']}")
PY
)

# Run glob checks
while IFS=$'\t' read -r key pattern; do
  size=$(glob_size_kb "$pattern")
  add_entry "$key" "$size" "$pattern"
done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_globs", []):
    print(f"{item['key']}\t{item['pattern']}")
PY
)

MEASUREMENT_ELAPSED_SECONDS=$(( $(date +%s) - MEASUREMENT_STARTED_EPOCH ))
MEASUREMENT_BUDGET_EXHAUSTED=false
if [[ "$(remaining_measurement_seconds)" -eq 0 ]]; then
  MEASUREMENT_BUDGET_EXHAUSTED=true
fi

# ────────── CARRY-FORWARD (last-good values for timed-out keys) ──────────
# A timed-out key is never a silent zero: it is carried from the last-good
# store (with its age) or reported unmeasured. directories[] stays fresh-only.
CARRY_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CARRY_JSON=""
if python3 "$SCRIPT_DIR/snapshot_carry.py" from-tsv --tsv "$DIRS_TEMP_FILE" > "$CARRY_FRESH_FILE" 2>/dev/null; then
  CARRY_JSON=$(python3 "$SCRIPT_DIR/snapshot_carry.py" merge --state "$CARRY_STATE_FILE" \
    --fresh "$CARRY_FRESH_FILE" --now "$CARRY_NOW" --max-age-hours 72 --config "$CONFIG_FILE" 2>/dev/null || true)
fi
[[ -n "$CARRY_JSON" ]] || CARRY_JSON='{"fresh":{},"carried":{},"unmeasured":[],"gap_estimate_kb":{}}'

# ────────── DEDUP TRIE (schema_version 2 — fixes inflated coverage_pct) ──────────
# `tracked_total_kb` above is a naive sum with no overlap awareness, and the
# config has real overlaps today: claude_root+claude_projects (parent+child),
# codex_root+codex_sessions (parent+child), hermes+hermes_prod (symlink
# alias), and library_containers + its own lc_* top-20 subdirs (parent+child,
# generated by the block just above). Naively summing double/triple-counts
# those bytes and makes coverage_pct read HIGHER than reality — exactly wrong
# for an SLO that's supposed to warn when coverage is too LOW.
#
# This pass resolves each entry's source path to a realpath, sorts shallowest
# first, and keeps an entry only if its realpath is not equal to (symlink
# alias) or nested under (parent/child) an already-kept realpath. Entries
# whose src_path is a glob pattern (contains *, ?, or [) are left out of the
# trie entirely and always counted — resolving containment for an expanded
# glob is out of scope for this pass; none of the confirmed overlaps today
# are glob-based.
DEDUP_JSON=$(SNAP_CARRY_JSON="$CARRY_JSON" python3 - "$DIRS_TEMP_FILE" "$HOME" <<'PY' 2>/dev/null
import json, os, sys

temp_file, home = sys.argv[1], sys.argv[2]

def expand(p):
    if p.startswith("~"):
        p = home + p[1:]
    return os.path.expandvars(p)

def is_glob(p):
    return any(c in p for c in "*?[")

try:
    rows = []  # (key, val_kb_or_None, src_path)
    with open(temp_file) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            key, val_s, src_path = parts
            val = None if val_s in ("null", "") else int(val_s)
            rows.append((key, val, src_path))

    resolvable = []  # (depth, is_symlink_alias, realpath, key, val)
    unresolvable_keys = set()
    for key, val, src_path in rows:
        if not src_path or is_glob(src_path):
            unresolvable_keys.add(key)
            continue
        literal = os.path.normpath(expand(src_path))
        real = os.path.realpath(literal)
        depth = len([p for p in real.split(os.sep) if p])
        # When two entries share a realpath (symlink alias, e.g. hermes_prod ->
        # hermes) the literal (non-symlink) path must win the tie so it becomes
        # the "covered_by" owner — otherwise sorting ties alphabetically by key
        # would let the ALIAS become the owner and wrongly exclude the real dir.
        # Deliberately checks only whether THIS path's own final component is a
        # symlink (os.path.islink), not whether literal != realpath overall —
        # ancestor directories are routinely symlinks on macOS (/tmp -> /private/tmp,
        # /var -> /private/var) and that ambient fact must not affect tie-breaking
        # between two config-declared entries.
        is_symlink_alias = 1 if os.path.islink(literal) else 0
        resolvable.append((depth, is_symlink_alias, real, key, val))

    resolvable.sort(key=lambda r: (r[0], r[1], r[3]))

    kept_real_paths = []  # list of (realpath, key) already accepted, shallowest first
    excluded = []  # {"key":, "covered_by":, "reason":}
    tracked_total_kb_deduped = 0

    def covered_by(real):
        for kept_real, kept_key in kept_real_paths:
            if real == kept_real:
                return kept_key, "symlink_alias"
            if real.startswith(kept_real.rstrip(os.sep) + os.sep):
                return kept_key, "nested_under_parent"
        return None, None

    for depth, is_symlink_alias, real, key, val in resolvable:
        # A timed-out (null) entry measured nothing: it must neither count nor
        # shadow a fresh child (a null claude_root used to hide claude_projects).
        if val is None:
            continue
        owner, reason = covered_by(real)
        if owner is not None:
            excluded.append({"key": key, "covered_by": owner, "reason": reason})
            continue
        kept_real_paths.append((real, key))
        tracked_total_kb_deduped += val

    for key, val, src_path in rows:
        if key in unresolvable_keys and val is not None:
            tracked_total_kb_deduped += val

    # Carried and gap-estimate entries are admitted only when they overlap no
    # fresh entry and no earlier (shallower) carried entry: fresh always wins,
    # and overlapping carried entries count once. This undercounts, never double counts.
    carry = json.loads(os.environ.get("SNAP_CARRY_JSON") or "{}")
    src_of = {key: src for key, _val, src in rows}

    def real_of(key):
        src = src_of.get(key)
        if not src or is_glob(src):
            return None
        return os.path.realpath(os.path.normpath(expand(src)))

    def overlaps(a, b):
        return a == b or a.startswith(b.rstrip(os.sep) + os.sep) or b.startswith(a.rstrip(os.sep) + os.sep)

    taken = [r for r, _k in kept_real_paths]

    def admit(cands):
        total = 0
        placed = []
        for key, kb in cands:
            r = real_of(key)
            if r is not None:
                placed.append((len(r.split(os.sep)), r, kb))
        for _d, r, kb in sorted(placed):
            if any(overlaps(r, t) for t in taken):
                continue
            taken.append(r)
            total += kb
        return total

    carried_kb_deduped = admit([(k, v["kb"]) for k, v in (carry.get("carried") or {}).items()])
    gap_kb = admit(list((carry.get("gap_estimate_kb") or {}).items()))
    print(json.dumps({
        "tracked_total_kb_deduped": tracked_total_kb_deduped,
        "dedup_excluded": excluded,
        "carried_kb_deduped": carried_kb_deduped,
        "gap_kb": gap_kb,
    }))
except Exception:
    # Fail open to "no dedup applied" rather than crashing the snapshot —
    # the bash fallback below also covers a total python-invocation failure.
    print(json.dumps({"tracked_total_kb_deduped": None, "dedup_excluded": []}))
PY
)
if [[ -z "$DEDUP_JSON" ]]; then
  DEDUP_JSON=$(printf '{"tracked_total_kb_deduped": null, "dedup_excluded": []}')
fi
tracked_total_kb_deduped=$(python3 -c "import json,sys; v=json.loads(sys.argv[1])['tracked_total_kb_deduped']; print(v if v is not None else '')" "$DEDUP_JSON")
read -r carried_kb_deduped gap_kb < <(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('carried_kb_deduped') or 0, d.get('gap_kb') or 0)" "$DEDUP_JSON" 2>/dev/null || echo "0 0")
carried_kb_deduped="${carried_kb_deduped:-0}"; gap_kb="${gap_kb:-0}"
dedup_excluded_json=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])['dedup_excluded']))" "$DEDUP_JSON")
if [[ -z "$tracked_total_kb_deduped" ]]; then
  # Dedup pass failed open — fall back to the raw (undeduped) total so
  # coverage_pct is still computed rather than crashing the snapshot.
  tracked_total_kb_deduped="$tracked_total_kb"
fi

coverage_pct=$(awk "BEGIN{
  used = $disk_used_kb
  if (used <= 0) { print 0; exit }
  printf \"%.1f\", 100 * $tracked_total_kb_deduped / used
}")
coverage_pct_raw_v1=$(awk "BEGIN{
  used = $disk_used_kb
  if (used <= 0) { print 0; exit }
  printf \"%.1f\", 100 * $tracked_total_kb / used
}")
# fresh + carried + gap + unconfigured partition the used space (see spec section 4).
coverage_carried_pct=$(awk "BEGIN{ if ($disk_used_kb <= 0) {print 0; exit}; printf \"%.1f\", 100 * $carried_kb_deduped / $disk_used_kb }")
coverage_effective_pct=$(awk "BEGIN{ if ($disk_used_kb <= 0) {print 0; exit}; printf \"%.1f\", 100 * ($tracked_total_kb_deduped + $carried_kb_deduped) / $disk_used_kb }")
coverage_gap_pct=$(awk "BEGIN{ if ($disk_used_kb <= 0) {print 0; exit}; printf \"%.1f\", 100 * $gap_kb / $disk_used_kb }")
coverage_unconfigured_pct=$(awk "BEGIN{ v = 100 - $coverage_effective_pct - $coverage_gap_pct; if (v < 0) v = 0; printf \"%.1f\", v }")
warning=""
if (( $(awk "BEGIN{print ($coverage_effective_pct < 70)}") )); then
  warning="low_coverage"
elif python3 -c "import json,sys; sys.exit(0 if any(v['age_hours'] > 24 for v in json.loads(sys.argv[1]).get('carried', {}).values()) else 1)" "$CARRY_JSON" 2>/dev/null; then
  warning="degraded_carry"
fi

# ────────── SNAPSHOT METADATA + STALENESS ──────────
# Per Lane B Section C: capture captured_at, age_seconds, coverage_pct,
# and a measurement_status sentinel so consumers can distinguish
# "measurement failed" (timeout) from "value is zero".
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
age_seconds=0
prev_snapshot_ts=""
prev_snapshot_path=""
prev_residual_gb=""

# Stale-detection: if --output points to a file that already exists,
# read its embedded timestamp and compute the gap. This way the SAME
# script that writes the next snapshot also reports whether the prior
# one was overdue (>24 h).
if [[ -n "$OUTPUT" && -f "$OUTPUT" ]]; then
  prev_snapshot_path="$OUTPUT"
else
  # Even when output is new, look for a sibling committed snapshot in
  # backup/<host>/disk_snapshot.json — that is the canonical "previous"
  # for staleness purposes.
  host_short="$(hostname -s 2>/dev/null || hostname)"
  candidate="$REPO_ROOT/backup/${host_short}/disk_snapshot.json"
  if [[ -f "$candidate" ]]; then
    prev_snapshot_path="$candidate"
  fi
fi

if [[ -n "$prev_snapshot_path" ]]; then
  prev_info=$(python3 - "$prev_snapshot_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    ts = s.get("timestamp", "")
    residual_gb = s.get("residual_gb", "")
    print(f"{ts}\t{residual_gb}")
except Exception:
    pass
PY
)
  IFS=$'\t' read -r prev_ts prev_residual_gb <<< "$prev_info"
  if [[ -n "$prev_ts" ]]; then
    now_epoch=$(date -u +%s)
    prev_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$prev_ts" +%s 2>/dev/null \
      || date -u -d "$prev_ts" +%s 2>/dev/null \
      || echo "")
    if [[ -n "$prev_epoch" && "$prev_epoch" =~ ^[0-9]+$ ]]; then
      age_seconds=$(( now_epoch - prev_epoch ))
    fi
    prev_snapshot_ts="$prev_ts"
  fi
fi

# ────────── RESIDUAL (disk_used − deduped-measured, always attributable) ──────────
residual_kb=$(( disk_used_kb - tracked_total_kb_deduped ))
residual_gb=$(awk "BEGIN{printf \"%.1f\", $residual_kb / 1024 / 1024}")
residual_delta_gb=""
if [[ -n "$prev_residual_gb" && "$prev_residual_gb" != "None" ]]; then
  residual_delta_gb=$(awk "BEGIN{printf \"%.1f\", $residual_gb - $prev_residual_gb}")
fi

# measurement_status sentinel: per feedback_silent_zero_anti_pattern.md,
# distinguish "all measured" from "some timed out" from "all failed".
if [[ "$MEASURED_TOTAL" -eq 0 ]]; then
  measurement_status="empty"
elif [[ "$MEASURED_OK" -eq "$MEASURED_TOTAL" ]]; then
  measurement_status="complete"
elif [[ "$MEASURED_OK" -eq 0 ]]; then
  measurement_status="timeout"
else
  measurement_status="partial"
fi

# Stale warning: previous snapshot >24 h old. Additive to coverage
# warning — disk_audit.sh decides which to surface.
if [[ "$age_seconds" -gt 86400 && "$age_seconds" -gt 0 ]]; then
  if [[ -z "$warning" ]]; then
    warning="stale_previous_snapshot"
  else
    warning="${warning}+stale_previous_snapshot"
  fi
fi

# Track whether the per-build subdirs were captured.
containers_captured=0
containers_total_dirs=0
if [[ -d "$containers_parent" ]]; then
  containers_total_dirs=$(find "$containers_parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  containers_captured=$(printf '%s' "$containers_listing" | grep -c '^[0-9]' 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)
  [[ "$containers_captured" =~ ^[0-9]+$ ]] || containers_captured=0
fi

timeout_keys_str=""
if (( ${#timeout_keys[@]} > 0 )); then
  timeout_keys_str=$(IFS=,; echo "${timeout_keys[*]}")
fi

# ────────── TOPDOWN COVERAGE (frontier scanner summary, additive) ──────────
# Enablement: data flows when frontier_last.json exists AND config's
# `topdown_enabled` is not explicitly false (absent key = auto). File
# presence controls data availability; the config key is the off switch.
# If lane-topdown's ~/.disk_magician_state/frontier_last.json exists, is valid
# JSON, and is fresh (<36h), embed a SUMMARY only — never the full `measured`
# map — so this git-committed-every-35min snapshot JSON stays small. Stale
# data becomes a {stale: true} marker instead of being silently dropped;
# absent/corrupt/disabled fails open to omitting the field entirely (same
# fail-open posture as the dedup pass above — this must never crash a
# snapshot over a sibling tool's file).
TOPDOWN_ENABLED=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print('false' if d.get('topdown_enabled') is False else 'true')
except Exception:
    print('true')
" "$CONFIG_FILE" 2>/dev/null || echo "true")

TOPDOWN_JSON=$(python3 - "$TOPDOWN_ENABLED" "${DISK_MAGICIAN_FRONTIER_LAST:-}" "${DISK_MAGICIAN_FRONTIER_ROOT_JSON:-/var/db/disk-magician/frontier_last.json}" "$SNAPSHOT_STATE_DIR/frontier_last.json" "$SCRIPT_DIR" <<'PY' 2>/dev/null
import datetime, json, os, sys
sys.path.insert(0, sys.argv[5])
from frontier_selection import select_frontier

if sys.argv[1] != "true":
    print("null")
    sys.exit(0)
path = select_frontier(sys.argv[3], sys.argv[4],
                       explicit_json=os.environ.get("DISK_MAGICIAN_FRONTIER_JSON"),
                       explicit_last=sys.argv[2])
if not path:
    print("null")
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
    captured_at = d["captured_at"]
    ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
except (OSError, KeyError, TypeError, ValueError):
    print("null")
    sys.exit(0)
if age_hours < 0:
    print("null")
    sys.exit(0)
if age_hours > 36.0:
    result = {"stale": True, "captured_at": captured_at, "age_hours": round(age_hours, 1)}
else:
    result = {
        "mode": d.get("mode"),
        "captured_at": captured_at,
        "age_hours": round(age_hours, 1),
        "measured_total_kb": d.get("measured_total_kb"),
        "frontier_unfinished_count": len(d.get("frontier_unfinished") or []),
        "residual_kb": d.get("residual_kb"),
        "sibling_volumes_count": len(d.get("sibling_volumes") or {}),
        "local_snapshots_count": d.get("local_snapshots_count"),
    }
print(json.dumps(result))
PY
)
if [[ -z "$TOPDOWN_JSON" ]]; then
  TOPDOWN_JSON="null"
fi

# Use Python to safely and durably construct and validate JSON.
# This prevents empty/malformed variables from creating invalid syntax.
pretty_json=$(SNAP_TIMESTAMP="$captured_at" \
  SNAP_HOSTNAME="$(hostname -s 2>/dev/null || hostname)" \
  SNAP_DISK_TOTAL="$disk_total_gb" \
  SNAP_DISK_USED="$disk_used_gb" \
  SNAP_DISK_FREE="$disk_free_gb" \
  SNAP_DISK_PCT="$disk_pct" \
  SNAP_SWAP_TOTAL_GB="$swap_total_gb" \
  SNAP_SWAP_USED_GB="$swap_used_gb" \
  SNAP_VM_VOLUME_USED_GB="$vm_volume_used_gb" \
  SNAP_DISK_FREE_KB="$disk_free_kb" \
  SNAP_APFS_VOLUMES="$apfs_volume_stats_json" \
  SNAP_LOCAL_SNAPSHOTS_COUNT="$local_snapshots_count" \
  SNAP_LOCAL_SNAPSHOT_NAMES="$local_snapshot_names_csv" \
  SNAP_COLIMA_DIFFDISK_STAT_BYTES="$colima_diffdisk_stat_bytes" \
  SNAP_COLIMA_DIFFDISK_DU_KB="$colima_diffdisk_du_kb" \
  SNAP_COVERAGE_PCT="$coverage_pct" \
  SNAP_COVERAGE_PCT_RAW_V1="$coverage_pct_raw_v1" \
  SNAP_COVERAGE_CARRIED_PCT="$coverage_carried_pct" \
  SNAP_COVERAGE_EFFECTIVE_PCT="$coverage_effective_pct" \
  SNAP_COVERAGE_TIMEOUT_GAP_PCT="$coverage_gap_pct" \
  SNAP_COVERAGE_UNCONFIGURED_PCT="$coverage_unconfigured_pct" \
  SNAP_DISK_USED_KB="$disk_used_kb" \
  SNAP_CARRY_JSON="$CARRY_JSON" \
  SNAP_TRACKED_TOTAL_KB_RAW="$tracked_total_kb" \
  SNAP_TRACKED_TOTAL_KB_DEDUPED="$tracked_total_kb_deduped" \
  SNAP_DEDUP_EXCLUDED="$dedup_excluded_json" \
  SNAP_RESIDUAL_KB="$residual_kb" \
  SNAP_RESIDUAL_GB="$residual_gb" \
  SNAP_RESIDUAL_DELTA_GB="$residual_delta_gb" \
  SNAP_AGE_SECONDS="$age_seconds" \
  SNAP_STATUS="$measurement_status" \
  SNAP_MEASURED_OK="$MEASURED_OK" \
  SNAP_MEASURED_TOTAL="$MEASURED_TOTAL" \
  SNAP_MEASUREMENT_BUDGET_SECONDS="$SNAPSHOT_BUDGET_SECONDS" \
  SNAP_MEASUREMENT_PATH_MAX_SECONDS="$MEASURE_PATH_MAX_SECONDS" \
  SNAP_MEASURE_MODE="$MEASURE_MODE" \
  SNAP_MEASURE_WORKERS="$MEASURE_WORKERS_USED" \
  SNAP_MEASUREMENT_ELAPSED_SECONDS="$MEASUREMENT_ELAPSED_SECONDS" \
  SNAP_MEASUREMENT_BUDGET_EXHAUSTED="$MEASUREMENT_BUDGET_EXHAUSTED" \
  SNAP_MEASUREMENT_FAILURES="$MEASUREMENT_FAILURES_JSON" \
  SNAP_PREV_TS="$prev_snapshot_ts" \
  SNAP_CONTAINERS_CAPTURED="$containers_captured" \
  SNAP_CONTAINERS_TOTAL="$containers_total_dirs" \
  SNAP_WARNING="$warning" \
  SNAP_TIMEOUTS="$timeout_keys_str" \
  SNAP_TOPDOWN="$TOPDOWN_JSON" \
  SNAP_LIBRARY_COVERAGE="$LIBRARY_COVERAGE_JSON" \
  python3 - "$DIRS_TEMP_FILE" <<'PY' 2>/dev/null || echo ""
import json, os, sys
try:
    data = {
        "schema_version": 2,
        "timestamp": os.environ.get("SNAP_TIMESTAMP"),
        "hostname": os.environ.get("SNAP_HOSTNAME"),
        "disk_total_gb": int(os.environ.get("SNAP_DISK_TOTAL") or 0),
        "disk_used_gb": int(os.environ.get("SNAP_DISK_USED") or 0),
        "disk_free_gb": int(os.environ.get("SNAP_DISK_FREE") or 0),
        "disk_pct": int(os.environ.get("SNAP_DISK_PCT") or 0),
        # Additive (bead disk_magician-8to): swap + /System/Volumes/VM
        # consume disk space outside the "Data volume" df accounting above.
        # Readers must tolerate these keys being absent on older snapshots.
        "swap_total_gb": float(os.environ.get("SNAP_SWAP_TOTAL_GB") or 0.0),
        "swap_used_gb": float(os.environ.get("SNAP_SWAP_USED_GB") or 0.0),
        "vm_volume_used_gb": float(os.environ.get("SNAP_VM_VOLUME_USED_GB") or 0.0),
        "snapshot_coverage_pct": float(os.environ.get("SNAP_COVERAGE_PCT") or 0.0),
        # Additive (bead disk_magician-rpv): non-file signals for correlating
        # df swings that file-birth/mtime probes could not explain — see
        # scripts/correlate_disk_swings.py. Old snapshots lack these keys;
        # readers must tolerate their absence the same as swap_total_gb above.
        "residual_kb": int(os.environ.get("SNAP_RESIDUAL_KB") or 0),
        "residual_gb": float(os.environ.get("SNAP_RESIDUAL_GB") or 0.0),
        "snapshot_metadata": {
            "captured_at": os.environ.get("SNAP_TIMESTAMP"),
            "age_seconds": int(os.environ.get("SNAP_AGE_SECONDS") or 0),
            "coverage_pct": float(os.environ.get("SNAP_COVERAGE_PCT") or 0.0),
            # schema_version 2: coverage_pct is now dedup-corrected and will
            # read LOWER than pre-2026-07-11 history for the same disk state.
            # coverage_pct_raw_v1 preserves the old (inflated, undeduped)
            # formula so trend tooling built against v1 history isn't
            # misread as a regression — see roadmap/2026-07-11-total-coverage-snapshot-v2.md critic #13.
            "coverage_pct_raw_v1": float(os.environ.get("SNAP_COVERAGE_PCT_RAW_V1") or 0.0),
            "tracked_total_kb_raw": int(os.environ.get("SNAP_TRACKED_TOTAL_KB_RAW") or 0),
            "tracked_total_kb_deduped": int(os.environ.get("SNAP_TRACKED_TOTAL_KB_DEDUPED") or 0),
            "measurement_status": os.environ.get("SNAP_STATUS"),
            "measured_paths_ok": int(os.environ.get("SNAP_MEASURED_OK") or 0),
            "measured_paths_total": int(os.environ.get("SNAP_MEASURED_TOTAL") or 0),
            "measurement_budget_seconds": int(os.environ.get("SNAP_MEASUREMENT_BUDGET_SECONDS") or 0),
            "measurement_path_max_seconds": int(os.environ.get("SNAP_MEASUREMENT_PATH_MAX_SECONDS") or 0),
            "measure_mode": os.environ.get("SNAP_MEASURE_MODE") or "serial",
            "measure_workers": int(os.environ.get("SNAP_MEASURE_WORKERS") or 0),
            "measurement_elapsed_seconds": int(os.environ.get("SNAP_MEASUREMENT_ELAPSED_SECONDS") or 0),
            "measurement_budget_exhausted": os.environ.get("SNAP_MEASUREMENT_BUDGET_EXHAUSTED") == "true",
        }
    }

    # Additive non-file signals (bead disk_magician-rpv). See
    # scripts/correlate_disk_swings.py for how these are used to attribute
    # df-observed swings that no file-birth/mtime probe explained.
    #
    # Null-vs-zero (/advice review, Codex + Opus, both high confidence,
    # 2026-09-25): "probe failed" and "probe measured a real zero" must stay
    # distinguishable everywhere below, or a transient failure reads to the
    # correlator as a real multi-GiB swing in the signal itself. A missing
    # dict key (not merely a falsy value) means "not measured this tick" —
    # never coerced to 0 via `or 0` the way this file's older swap/VM
    # fields are, since those predate this bead's stricter null discipline.
    def _bytes_to_gb(value):
        return round(value / 1024 / 1024 / 1024, 3)

    try:
        apfs_volume_stats = json.loads(os.environ.get("SNAP_APFS_VOLUMES") or "{}")
    except (TypeError, ValueError):
        apfs_volume_stats = {}
    volumes_bytes = apfs_volume_stats.get("volumes_bytes") or {}
    data["apfs_volumes_gb"] = {
        role: (_bytes_to_gb(volumes_bytes[role]) if volumes_bytes.get(role) is not None else None)
        for role in ("Data", "VM", "Preboot", "Update")
    }
    container_free_bytes = apfs_volume_stats.get("container_free_bytes")
    container_capacity_bytes = apfs_volume_stats.get("container_capacity_bytes")
    data["apfs_container_free_gb"] = (
        _bytes_to_gb(container_free_bytes) if container_free_bytes is not None else None
    )
    data["apfs_container_capacity_gb"] = (
        _bytes_to_gb(container_capacity_bytes) if container_capacity_bytes is not None else None
    )
    # Purgeable estimate: diskutil exposes no distinct "purgeable" field on
    # this macOS version (verified empirically; matches disk_frontier_scan.py
    # get_purgeable_info()'s docstring finding). df's Available already nets
    # out reclaimable local-snapshot space while APFSContainerFree does not,
    # so the gap between the two is used as an estimate. Not clamped at 0 —
    # a small negative value is sampling skew between the two probes and is
    # useful to the correlator as a noise-floor signal, not an error.
    disk_free_kb_precise = int(os.environ.get("SNAP_DISK_FREE_KB") or 0)
    if container_free_bytes is not None:
        data["apfs_purgeable_estimate_gb"] = round(
            disk_free_kb_precise / 1024 / 1024 - _bytes_to_gb(container_free_bytes), 3
        )
    else:
        data["apfs_purgeable_estimate_gb"] = None
    # -1 is get_local_snapshots_line()'s failure sentinel (a real count is
    # never negative) — surface as null, not a fabricated 0 snapshot count.
    local_snapshots_count_raw = int(os.environ.get("SNAP_LOCAL_SNAPSHOTS_COUNT") or -1)
    if local_snapshots_count_raw < 0:
        data["local_snapshots_count"] = None
        data["local_snapshot_names"] = None
    else:
        local_snapshot_names_raw = os.environ.get("SNAP_LOCAL_SNAPSHOT_NAMES") or ""
        data["local_snapshots_count"] = local_snapshots_count_raw
        data["local_snapshot_names"] = [n for n in local_snapshot_names_raw.split(",") if n]
    # -1 is get_colima_diffdisk_stats()'s failure sentinel for each
    # measurement independently (stat/du can fail even when the diffdisk
    # file exists and is legitimately non-empty).
    colima_stat_bytes_raw = int(os.environ.get("SNAP_COLIMA_DIFFDISK_STAT_BYTES") or -1)
    data["colima_diffdisk_stat_allocated_gb"] = (
        _bytes_to_gb(colima_stat_bytes_raw) if colima_stat_bytes_raw >= 0 else None
    )
    colima_du_kb_raw = int(os.environ.get("SNAP_COLIMA_DIFFDISK_DU_KB") or -1)
    data["colima_diffdisk_du_allocated_gb"] = (
        round(colima_du_kb_raw / 1024 / 1024, 3) if colima_du_kb_raw >= 0 else None
    )

    try:
        measurement_failures = json.loads(os.environ.get("SNAP_MEASUREMENT_FAILURES") or "[]")
    except (TypeError, ValueError):
        measurement_failures = []
    if isinstance(measurement_failures, list) and measurement_failures:
        data["snapshot_metadata"]["measurement_failures"] = measurement_failures
    residual_delta = os.environ.get("SNAP_RESIDUAL_DELTA_GB")
    if residual_delta:
        data["residual_delta_gb"] = float(residual_delta)
    try:
        dedup_excluded = json.loads(os.environ.get("SNAP_DEDUP_EXCLUDED") or "[]")
    except (TypeError, ValueError):
        dedup_excluded = []
    data["dedup_excluded"] = dedup_excluded
    prev_ts = os.environ.get("SNAP_PREV_TS")
    if prev_ts:
        data["snapshot_metadata"]["previous_snapshot_timestamp"] = prev_ts
    containers_total = int(os.environ.get("SNAP_CONTAINERS_TOTAL") or 0)
    if containers_total > 0:
        data["snapshot_metadata"]["library_containers_top_subdirs_captured"] = int(os.environ.get("SNAP_CONTAINERS_CAPTURED") or 0)
        data["snapshot_metadata"]["library_containers_total_subdirs"] = containers_total
    warning = os.environ.get("SNAP_WARNING")
    if warning:
        data["snapshot_warning"] = warning
    timeouts = os.environ.get("SNAP_TIMEOUTS")
    if timeouts:
        data["timeout_keys"] = timeouts.split(",")
    try:
        topdown = json.loads(os.environ.get("SNAP_TOPDOWN") or "null")
    except (TypeError, ValueError):
        topdown = None
    if topdown is not None:
        data["topdown_coverage"] = topdown
    try:
        library_coverage = json.loads(os.environ.get("SNAP_LIBRARY_COVERAGE") or "null")
    except (TypeError, ValueError):
        library_coverage = None
    if library_coverage is not None:
        data["library_coverage"] = library_coverage
    dirs = {}
    dirs_file = sys.argv[1]
    if os.path.exists(dirs_file):
        with open(dirs_file) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                k, v = parts[0], parts[1]
                if v == "null" or v == "":
                    dirs[k] = None
                else:
                    try:
                        dirs[k] = int(v)
                    except ValueError:
                        dirs[k] = None
    data["directories"] = dirs
    # Additive fresh/carried/unmeasured accounting (schema_version stays 2).
    # snapshot_coverage_pct keeps its fresh-only meaning.
    try:
        carry = json.loads(os.environ.get("SNAP_CARRY_JSON") or "{}")
    except (TypeError, ValueError):
        carry = {}
    carried = carry.get("carried") or {}
    unmeasured = list(carry.get("unmeasured") or [])
    for k, v in dirs.items():  # G2: a null directory is always carried or unmeasured
        if v is None and k not in carried and k not in unmeasured:
            unmeasured.append(k)
    data["coverage_fresh_pct"] = data["snapshot_coverage_pct"]
    data["coverage_carried_pct"] = float(os.environ.get("SNAP_COVERAGE_CARRIED_PCT") or 0.0)
    data["coverage_effective_pct"] = float(os.environ.get("SNAP_COVERAGE_EFFECTIVE_PCT") or 0.0)
    data["coverage_timeout_gap_pct"] = float(os.environ.get("SNAP_COVERAGE_TIMEOUT_GAP_PCT") or 0.0)
    data["coverage_unconfigured_pct"] = float(os.environ.get("SNAP_COVERAGE_UNCONFIGURED_PCT") or 0.0)
    td = data.get("topdown_coverage")
    used_kb = int(os.environ.get("SNAP_DISK_USED_KB") or 0)
    if (isinstance(td, dict) and not td.get("stale") and used_kb > 0
            and isinstance(td.get("measured_total_kb"), int)
            and (td.get("age_hours") is None or td["age_hours"] <= 36)):
        data["coverage_frontier_pct"] = round(100.0 * td["measured_total_kb"] / used_kb, 1)
    data["carried_keys"] = [{"key": k, "kb": v["kb"], "age_hours": v["age_hours"]} for k, v in carried.items()]
    data["unmeasured_keys"] = unmeasured
    data["fresh_keys_count"] = sum(1 for v in dirs.values() if v is not None)
    data["total_keys_count"] = len(dirs)
    print(json.dumps(data, indent=4))
except Exception:
    sys.exit(1)
PY
)

if [[ -z "$pretty_json" ]]; then
  echo "ERROR: snapshot JSON failed validation — refusing to write" >&2
  exit 1
fi

# Persist fresh non-null values as the new last-good store (partial runs included).
if [[ "$DRY_RUN" == false ]]; then
  python3 "$SCRIPT_DIR/snapshot_carry.py" update --state "$CARRY_STATE_FILE" \
    --fresh "$CARRY_FRESH_FILE" --now "$CARRY_NOW" 2>/dev/null || true
fi

if [[ -n "$OUTPUT" && "$DRY_RUN" == false ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  echo "$pretty_json" > "$OUTPUT"
  msg="Snapshot written to $OUTPUT (free: ${disk_free_gb}G / ${disk_total_gb}G, ${disk_pct}%, coverage: ${coverage_pct}%)"
  if [[ -n "$warning" ]]; then
    msg="$msg [WARNING: $warning]"
  fi
  echo "$msg" >&2
else
  echo "$pretty_json"
fi

#!/usr/bin/env bash
# disk_snapshot.sh — Write a JSON snapshot of disk usage for monitored paths
#
# Reads configuration from config.json (or config.json.template).
# Supports --discover to scan home folder for large untracked folders.
set -euo pipefail

OUTPUT=""
DRY_RUN=false
DISCOVER=false
DU_TIMEOUT=30
# Track how many measured paths returned a real value (vs null/timeout)
# so we can surface a measurement_status sentinel (complete | partial |
# timeout | empty) — never a silent zero.
MEASURED_OK=0
MEASURED_TOTAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)   OUTPUT="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --discover) DISCOVER=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--output file.json] [--dry-run] [--discover]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

dir_size_kb() {
  local raw_path="$1"
  local to="${2:-$DU_TIMEOUT}"
  # Expand ~ or $HOME manually
  local path
  path="${raw_path/#\~/$HOME}"
  path=$(eval echo "$path")

  if [[ ! -e "$path" ]]; then
    echo 0
    return
  fi

  local result rc
  if [[ -n "$TIMEOUT_CMD" ]]; then
    result=$("$TIMEOUT_CMD" "$to" du -sk "$path" 2>/dev/null | awk '{print $1+0}' || true)
  else
    result=$(du -sk "$path" 2>/dev/null | awk '{print $1+0}' || true)
  fi

  if [[ -z "$result" ]]; then
    # Timeout or error -> surface as null (empty string in output)
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
    if [[ -n "$TIMEOUT_CMD" ]]; then
      s=$("$TIMEOUT_CMD" "$DU_TIMEOUT" du -sk "$d" 2>/dev/null | awk '{print $1+0}' || true)
    else
      s=$(du -sk "$d" 2>/dev/null | awk '{print $1+0}' || true)
    fi
    total=$(( total + ${s:-0} ))
  done
  echo "$total"
}

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

# ────────── DISCOVER MODE ──────────
if [[ "$DISCOVER" == true ]]; then
  echo "Discover mode: scanning for >5 GB dirs not in monitored config..."
  echo ""

  # Extract configured paths
  declare -A MONITORED_PATHS=()
  while IFS=$'\t' read -r raw_path; do
    path="${raw_path/#\~/$HOME}"
    path=$(eval echo "$path")
    MONITORED_PATHS["$path"]=1
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
      [[ -e "$p" ]] && MONITORED_PATHS["$p"]=1
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

  candidates=()
  for d in "$HOME"/.[!.]* "$HOME"/*; do
    [[ -d "$d" ]] || continue
    candidates+=("$d")
  done

  # NOTE: this loop body runs in a subshell (the `| while read` pipeline), so
  # `local` is illegal here and would crash the discover subcommand with
  # "local: can only be used in a function". We use plain vars instead.
  printf '%s\n' "${candidates[@]}" | while read -r dir; do
    kb=""
    if [[ -n "$TIMEOUT_CMD" ]]; then
      kb=$("$TIMEOUT_CMD" 60 du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
    else
      kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
    fi
    gb=$(awk "BEGIN{printf \"%.1f\", ${kb:-0} / 1048576}")
    if (( $(awk "BEGIN{print (${kb:-0} >= 5242880)}") )); then
      if [[ -z "${MONITORED_PATHS[$dir]:-}" ]]; then
        echo "  UNTRACKED  ${gb} GB  $dir"
      else
        echo "  tracked    ${gb} GB  $dir"
      fi
    fi
  done
  exit 0
fi

# ────────── SNAPSHOT MODE ──────────
read -r disk_total_kb disk_used_kb disk_free_kb disk_pct <<< "$(get_disk_stats)"
disk_total_gb=$(awk "BEGIN{printf \"%.0f\", $disk_total_kb / 1024 / 1024}")
disk_used_gb=$(awk "BEGIN{printf \"%.0f\", $disk_used_kb / 1024 / 1024}")
disk_free_gb=$(awk "BEGIN{printf \"%.0f\", $disk_free_kb / 1024 / 1024}")

tracked_total_kb=0
timeout_keys=()
dirs_json=""
first=true

add_entry() {
  local key="$1" raw_val="$2"
  local val="null"
  MEASURED_TOTAL=$(( MEASURED_TOTAL + 1 ))
  if [[ -n "$raw_val" ]]; then
    val="$raw_val"
    tracked_total_kb=$(( tracked_total_kb + raw_val ))
    MEASURED_OK=$(( MEASURED_OK + 1 ))
  else
    timeout_keys+=("$key")
  fi
  if [[ "$first" == true ]]; then
    first=false
  else
    dirs_json+=","
  fi
  dirs_json+="\"$key\":$val"
}

# Run dir checks
while IFS=$'\t' read -r key path timeout; do
  size=$(dir_size_kb "$path" "$timeout")
  add_entry "$key" "$size"
done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_dirs", []):
    print(f"{item['key']}\t{item['path']}\t{item.get('timeout', 30)}")
PY
)

# Run file glob checks
while IFS=$'\t' read -r key pattern; do
  size=$(glob_size_kb "$pattern")
  add_entry "$key" "$size"
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
  add_entry "$key" "$size"
done < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data.get("monitored_globs", []):
    print(f"{item['key']}\t{item['pattern']}")
PY
)

# ────────── TOP-20 LIBRARY/CONTAINERS SUBDIRS (additive) ──────────
# Per Lane B Section C: the 50 GB Library/Containers blind spot. Track
# the top-20 per-container subdirs so future regrowth has attribution.
# Each entry is a separate top-level directory key (lc_<safe_name>) to
# keep JSON flat — consumers do not need to recurse.
containers_parent="$HOME/Library/Containers"
containers_listing=""
if [[ -d "$containers_parent" ]]; then
  # Build a sorted list of (size_kb, name). 60s budget so this never
  # stalls the snapshot.
  if [[ -n "$TIMEOUT_CMD" ]]; then
    containers_listing=$("$TIMEOUT_CMD" 180 du -sk "$containers_parent"/* 2>/dev/null | sort -rn | head -20 || true)
  else
    containers_listing=$(du -sk "$containers_parent"/* 2>/dev/null | sort -rn | head -20 || true)
  fi
  while IFS=$'\t' read -r kb name; do
    [[ -z "$kb" || -z "$name" ]] && continue
    [[ "$kb" =~ ^[0-9]+$ ]] || continue
    base=$(basename "$name")
    safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9' '_' | head -c 40)
    key="lc_${safe}"
    add_entry "$key" "$kb"
  done <<< "$containers_listing"
fi

coverage_pct=$(awk "BEGIN{
  used = $disk_used_kb
  if (used <= 0) { print 0; exit }
  printf \"%.1f\", 100 * $tracked_total_kb / used
}")
warning=""
if (( $(awk "BEGIN{print ($coverage_pct < 70)}") )); then
  warning="low_coverage"
fi

# ────────── SNAPSHOT METADATA + STALENESS ──────────
# Per Lane B Section C: capture captured_at, age_seconds, coverage_pct,
# and a measurement_status sentinel so consumers can distinguish
# "measurement failed" (timeout) from "value is zero".
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
age_seconds=0
prev_snapshot_ts=""
prev_snapshot_path=""

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
  prev_ts=$(python3 - "$prev_snapshot_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get("timestamp", ""))
except Exception:
    pass
PY
)
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

json="{"
json+="\"timestamp\":\"$captured_at\","
json+="\"hostname\":\"$(hostname -s 2>/dev/null || hostname)\","
json+="\"disk_total_gb\":$disk_total_gb,"
json+="\"disk_used_gb\":$disk_used_gb,"
json+="\"disk_free_gb\":$disk_free_gb,"
json+="\"disk_pct\":$disk_pct,"
json+="\"snapshot_coverage_pct\":$coverage_pct,"
# snapshot_metadata (new top-level block, additive — older consumers
# ignore unknown fields). Includes the staleness signal consumers need.
json+="\"snapshot_metadata\":{"
json+="\"captured_at\":\"$captured_at\","
json+="\"age_seconds\":$age_seconds,"
json+="\"coverage_pct\":$coverage_pct,"
json+="\"measurement_status\":\"$measurement_status\","
json+="\"measured_paths_ok\":$MEASURED_OK,"
json+="\"measured_paths_total\":$MEASURED_TOTAL"
if [[ -n "$prev_snapshot_ts" ]]; then
  json+=",\"previous_snapshot_timestamp\":\"$prev_snapshot_ts\""
fi
if [[ "$containers_total_dirs" -gt 0 ]]; then
  json+=",\"library_containers_top_subdirs_captured\":$containers_captured"
  json+=",\"library_containers_total_subdirs\":$containers_total_dirs"
fi
json+="},"
if [[ -n "$warning" ]]; then
  json+="\"snapshot_warning\":\"$warning\","
fi
if (( ${#timeout_keys[@]} > 0 )); then
  json+="\"timeout_keys\":["
  for i in "${!timeout_keys[@]}"; do
    [[ $i -gt 0 ]] && json+=","
    json+="\"${timeout_keys[$i]}\""
  done
  json+="],"
fi
json+="\"directories\":{$dirs_json}}"

pretty_json=$(echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json")
if ! echo "$pretty_json" | python3 -m json.tool >/dev/null 2>&1; then
  echo "ERROR: snapshot JSON failed validation — refusing to write" >&2
  exit 1
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

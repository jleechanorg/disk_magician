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

CONFIG_FILE="$REPO_ROOT/config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$REPO_ROOT/config.json.template"
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

  candidates=()
  for d in "$HOME"/.[!.]* "$HOME"/*; do
    [[ -d "$d" ]] || continue
    candidates+=("$d")
  done

  printf '%s\n' "${candidates[@]}" | while read -r dir; do
    local kb=""
    if [[ -n "$TIMEOUT_CMD" ]]; then
      kb=$("$TIMEOUT_CMD" 60 du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
    else
      kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1+0}' || true)
    fi
    local gb
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
  if [[ -n "$raw_val" ]]; then
    val="$raw_val"
    tracked_total_kb=$(( tracked_total_kb + raw_val ))
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

coverage_pct=$(awk "BEGIN{
  used = $disk_used_kb
  if (used <= 0) { print 0; exit }
  printf \"%.1f\", 100 * $tracked_total_kb / used
}")
warning=""
if (( $(awk "BEGIN{print ($coverage_pct < 70)}") )); then
  warning="low_coverage"
fi

json="{"
json+="\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
json+="\"hostname\":\"$(hostname -s 2>/dev/null || hostname)\","
json+="\"disk_total_gb\":$disk_total_gb,"
json+="\"disk_used_gb\":$disk_used_gb,"
json+="\"disk_free_gb\":$disk_free_gb,"
json+="\"disk_pct\":$disk_pct,"
json+="\"snapshot_coverage_pct\":$coverage_pct,"
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

#!/usr/bin/env bash
# disk_snapshot.sh — Write a JSON snapshot of disk usage for monitored paths
#
# Reads configuration from config.json (or config.json.template).
# Supports --discover to scan home folder for large untracked folders.
set -euo pipefail

OUTPUT=""
DRY_RUN=false
DISCOVER=false
DISCOVER_JSON=false
DU_TIMEOUT=30
SNAPSHOT_BUDGET_SECONDS="${DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS:-1500}"
MEASURE_PATH_MAX_SECONDS="${DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS:-20}"
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

DUA_CMD=""
if command -v dua &>/dev/null; then
  DUA_CMD="dua"
fi

remaining_measurement_seconds() {
  local remaining=$(( MEASUREMENT_DEADLINE_EPOCH - $(date +%s) ))
  (( remaining > 0 )) && echo "$remaining" || echo 0
}

# dua reports allocated bytes by default (the same quantity as du -sk) and is
# parallel-by-default. Its ANSI reset can leave a trailing blank line, so take
# the last numeric row rather than the last physical line.
dua_size_kb() {
  local path="$1"
  local to="$2"
  [[ -n "$DUA_CMD" && -n "$TIMEOUT_CMD" && "$to" -gt 0 ]] || { echo ""; return; }
  local output bytes
  if ! output=$("$TIMEOUT_CMD" "$to" "$DUA_CMD" aggregate --format bytes "$path" 2>/dev/null); then
    echo ""
    return
  fi
  bytes=$(printf '%s\n' "$output" | sed -E 's/\x1b\[[0-9;]*m//g' \
    | awk '$1 ~ /^[0-9]+$/ { value=$1 } END { if (value != "") print value }')
  [[ "$bytes" =~ ^[0-9]+$ ]] && echo $(( (bytes + 1023) / 1024 )) || echo ""
}

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

  local remaining path_budget path_deadline result fallback_budget
  remaining=$(remaining_measurement_seconds)
  (( remaining > 0 )) || { echo ""; return; }
  [[ "$to" =~ ^[0-9]+$ && "$to" -gt 0 ]] || to="$DU_TIMEOUT"
  path_budget="$to"
  (( path_budget > MEASURE_PATH_MAX_SECONDS )) && path_budget="$MEASURE_PATH_MAX_SECONDS"
  (( path_budget > remaining )) && path_budget="$remaining"
  path_deadline=$(( $(date +%s) + path_budget ))

  result=$(dua_size_kb "$path" "$path_budget")

  if [[ -z "$result" ]]; then
    fallback_budget=$(( path_deadline - $(date +%s) ))
    remaining=$(remaining_measurement_seconds)
    (( fallback_budget > remaining )) && fallback_budget="$remaining"
    if [[ -n "$TIMEOUT_CMD" && "$fallback_budget" -gt 0 ]]; then
      result=$("$TIMEOUT_CMD" "$fallback_budget" du -sk "$path" 2>/dev/null \
        | awk '{print $1+0}' || true)
    fi
  fi

  if [[ -z "$result" ]]; then
    # Both bounded attempts failed/timed out -> surface as null (empty string).
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
  if [[ "$DISCOVER_JSON" != true ]]; then
    echo "Discover mode: scanning for >5 GB dirs not in monitored config..."
    echo ""
  fi

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
  declare -A CACHE_MTIME=()
  declare -A CACHE_SIZE=()
  if [[ -f "$CACHE_FILE" ]]; then
    while IFS=$'\t' read -r c_path c_mtime c_size; do
      [[ -z "$c_path" ]] && continue
      CACHE_MTIME["$c_path"]="$c_mtime"
      CACHE_SIZE["$c_path"]="$c_size"
    done < <(python3 - "$CACHE_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
for path, v in (data or {}).items():
    print(f"{path}\t{v.get('mtime', 0)}\t{v.get('size_kb', 0)}")
PY
)
  fi

  DISCOVER_TEMP_FILE=$(mktemp -t disk_magician_discover.XXXXXX)
  _cleanup_discover_temp() { rm -f "$DISCOVER_TEMP_FILE"; }
  trap _cleanup_discover_temp EXIT

  cache_hits=0
  cache_misses=0

  # Process substitution (not a pipe) so this loop runs in the CURRENT shell —
  # cache_hits/cache_misses and the CACHE_* associative arrays must survive
  # past the loop to be written back below.
  while read -r dir; do
    mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
    cached_mtime="${CACHE_MTIME[$dir]:-}"
    if [[ -n "$cached_mtime" && "$cached_mtime" == "$mtime" ]]; then
      kb="${CACHE_SIZE[$dir]:-0}"
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
    CACHE_MTIME["$dir"]="$mtime"
    CACHE_SIZE["$dir"]="$kb"
    tracked=0
    [[ -n "${MONITORED_PATHS[$dir]:-}" ]] && tracked=1
    printf "%s\t%s\t%s\n" "$dir" "$kb" "$tracked" >> "$DISCOVER_TEMP_FILE"
  done < <(printf '%s\n' "${candidates[@]}")

  # Persist the refreshed cache (full replace — self-cleans entries for dirs
  # that no longer exist since we only ever wrote candidates we just scanned).
  # NOTE: dump to a temp FILE rather than piping into python3's stdin — `python3 -`
  # already reads its PROGRAM from stdin via the heredoc below, so a pipe into
  # the same invocation would silently be discarded (heredoc wins the fd, the
  # piped data is never seen). A temp file + argv path sidesteps that entirely.
  CACHE_DUMP_FILE=$(mktemp -t disk_magician_cachedump.XXXXXX)
  for p in "${!CACHE_MTIME[@]}"; do
    printf "%s\t%s\t%s\n" "$p" "${CACHE_MTIME[$p]}" "${CACHE_SIZE[$p]}"
  done > "$CACHE_DUMP_FILE"
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
  rm -f "$CACHE_DUMP_FILE"

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
if [[ ! "$MEASURE_PATH_MAX_SECONDS" =~ ^[0-9]+$ || "$MEASURE_PATH_MAX_SECONDS" -le 0 ]]; then
  echo "Error: DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS must be a positive integer." >&2
  exit 2
fi
MEASUREMENT_STARTED_EPOCH=$(date +%s)
MEASUREMENT_DEADLINE_EPOCH=$(( MEASUREMENT_STARTED_EPOCH + SNAPSHOT_BUDGET_SECONDS ))
disk_total_gb=$(awk "BEGIN{printf \"%.0f\", $disk_total_kb / 1024 / 1024}")
disk_used_gb=$(awk "BEGIN{printf \"%.0f\", $disk_used_kb / 1024 / 1024}")
disk_free_gb=$(awk "BEGIN{printf \"%.0f\", $disk_free_kb / 1024 / 1024}")

tracked_total_kb=0
timeout_keys=()
DIRS_TEMP_FILE=$(mktemp -t disk_magician_dirs.XXXXXX)
_cleanup_dirs_temp() { rm -f "$DIRS_TEMP_FILE"; }
trap _cleanup_dirs_temp EXIT

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

# Run dir checks
while IFS=$'\t' read -r key path timeout; do
  size=$(dir_size_kb "$path" "$timeout")
  add_entry "$key" "$size" "$path"
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
  (( containers_budget > MEASURE_PATH_MAX_SECONDS )) && containers_budget="$MEASURE_PATH_MAX_SECONDS"
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
MEASUREMENT_ELAPSED_SECONDS=$(( $(date +%s) - MEASUREMENT_STARTED_EPOCH ))
MEASUREMENT_BUDGET_EXHAUSTED=false
if [[ "$(remaining_measurement_seconds)" -eq 0 ]]; then
  MEASUREMENT_BUDGET_EXHAUSTED=true
fi

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
DEDUP_JSON=$(python3 - "$DIRS_TEMP_FILE" "$HOME" <<'PY' 2>/dev/null
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
        owner, reason = covered_by(real)
        if owner is not None:
            excluded.append({"key": key, "covered_by": owner, "reason": reason})
            continue
        kept_real_paths.append((real, key))
        if val is not None:
            tracked_total_kb_deduped += val

    for key, val, src_path in rows:
        if key in unresolvable_keys and val is not None:
            tracked_total_kb_deduped += val

    print(json.dumps({
        "tracked_total_kb_deduped": tracked_total_kb_deduped,
        "dedup_excluded": excluded,
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
FRONTIER_LAST_FILE="$HOME/.disk_magician_state/frontier_last.json"
TOPDOWN_ENABLED=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print('false' if d.get('topdown_enabled') is False else 'true')
except Exception:
    print('true')
" "$CONFIG_FILE" 2>/dev/null || echo "true")

TOPDOWN_JSON=$(python3 - "$FRONTIER_LAST_FILE" "$TOPDOWN_ENABLED" <<'PY' 2>/dev/null
import datetime, json, sys

path, enabled = sys.argv[1], sys.argv[2]
if enabled != "true":
    print("null")
    sys.exit(0)

try:
    with open(path) as f:
        d = json.load(f)
    captured_at = d["captured_at"]
    ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
    if age_hours > 36:
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
except Exception:
    print("null")
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
  SNAP_COVERAGE_PCT="$coverage_pct" \
  SNAP_COVERAGE_PCT_RAW_V1="$coverage_pct_raw_v1" \
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
  SNAP_MEASUREMENT_ELAPSED_SECONDS="$MEASUREMENT_ELAPSED_SECONDS" \
  SNAP_MEASUREMENT_BUDGET_EXHAUSTED="$MEASUREMENT_BUDGET_EXHAUSTED" \
  SNAP_PREV_TS="$prev_snapshot_ts" \
  SNAP_CONTAINERS_CAPTURED="$containers_captured" \
  SNAP_CONTAINERS_TOTAL="$containers_total_dirs" \
  SNAP_WARNING="$warning" \
  SNAP_TIMEOUTS="$timeout_keys_str" \
  SNAP_TOPDOWN="$TOPDOWN_JSON" \
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
        "snapshot_coverage_pct": float(os.environ.get("SNAP_COVERAGE_PCT") or 0.0),
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
            "measurement_elapsed_seconds": int(os.environ.get("SNAP_MEASUREMENT_ELAPSED_SECONDS") or 0),
            "measurement_budget_exhausted": os.environ.get("SNAP_MEASUREMENT_BUDGET_EXHAUSTED") == "true",
        }
    }
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
    print(json.dumps(data, indent=4))
except Exception:
    sys.exit(1)
PY
)

if [[ -z "$pretty_json" ]]; then
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

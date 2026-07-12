#!/usr/bin/env bash
# residual_drilldown.sh — Bounded drilldown on named residual growth.
#
# Reads the latest committed snapshot JSON, checks how much of disk_used is
# NOT explained by measured directories (the "residual"), and — only when
# that residual crosses a threshold — proposes untracked candidates into
# config.d/auto-candidates.json for human promotion into config.json.
#
# Never writes to config.json / config.json.template directly (no silent
# self-mutation, per roadmap/2026-07-11-total-coverage-snapshot-v2.md
# "Control loop" section). Never touches disk_snapshot.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
BACKUP_DIR="${DISK_MAGICIAN_BACKUP_DIR:-$HOME/.disk_magician_backup/backup}"
SNAPSHOT_FILE="${DISK_MAGICIAN_SNAPSHOT_FILE:-$BACKUP_DIR/$HOSTNAME_SHORT/disk_snapshot.json}"

STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
DISCOVER_LAST="${DISK_MAGICIAN_DISCOVER_LAST:-$STATE_DIR/discover_last.json}"
ALERT_LOG="$STATE_DIR/residual_alerts.log"

CANDIDATES_DIR="${DISK_MAGICIAN_CANDIDATES_DIR:-$REPO_ROOT/config.d}"
CANDIDATES_FILE="$CANDIDATES_DIR/auto-candidates.json"

THRESHOLD_GB="${DISK_MAGICIAN_RESIDUAL_THRESHOLD_GB:-10}"
PER_RUN_CAP=5
TOTAL_CAP=40
BURST_ALERT_GB=100
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--threshold-gb N] [--snapshot-file PATH] [--dry-run]

Reads the latest disk_snapshot.json, fast-exits if the residual (disk_used
not explained by measured dirs) is below --threshold-gb (default: ${THRESHOLD_GB}).
When triggered, proposes untracked candidates into config.d/auto-candidates.json
(machine-local, gitignored, human-promoted — never auto-added to config).

Options:
  --threshold-gb N     Residual threshold in GB (default: ${THRESHOLD_GB}; env DISK_MAGICIAN_RESIDUAL_THRESHOLD_GB)
  --snapshot-file PATH Override snapshot JSON path (default: hostname-derived backup path; testing hook)
  --dry-run            Compute and print, but never write auto-candidates.json or the alert log
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-gb)   THRESHOLD_GB="$2"; shift 2 ;;
    --snapshot-file)  SNAPSHOT_FILE="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
[[ "$DRY_RUN" == true ]] || mkdir -p "$CANDIDATES_DIR"

# Paths that must never be proposed as anything but measure-candidates
# (personal-data trees; conservative default, not exhaustive). Prefix-match
# against the candidate's realpath.
NEVER_DELETE_PATTERNS=(
  "$HOME/Documents"
  "$HOME/Pictures"
  "$HOME/Desktop"
  "$HOME/Movies"
  "$HOME/Music"
  "$HOME/Library/Mail"
  "$HOME/Library/Messages"
  "$HOME/Library/Mobile Documents"
  "$HOME/Library/Photos"
  "/Users/Shared"
)

is_never_delete() {
  local candidate real_candidate pattern real_pattern
  candidate="$1"
  real_candidate="$(cd "$candidate" 2>/dev/null && pwd -P || echo "$candidate")"
  for pattern in "${NEVER_DELETE_PATTERNS[@]}"; do
    real_pattern="$(cd "$pattern" 2>/dev/null && pwd -P || echo "$pattern")"
    [[ "$real_candidate" == "$real_pattern" || "$real_candidate" == "$real_pattern"/* ]] && return 0
  done
  return 1
}

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
  echo "residual_drilldown: no snapshot at $SNAPSHOT_FILE — nothing to drill down on, no-op."
  exit 0
fi

# ────────── RESIDUAL CALC (real field, or fallback) ──────────
residual_info="$(python3 - "$SNAPSHOT_FILE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"ERROR\t{e}")
    sys.exit(0)

disk_used_gb = data.get("disk_used_gb")

if "residual_delta_gb" in data:
    residual_gb = data["residual_delta_gb"]
    source = "residual_delta_gb"
else:
    coverage_pct = data.get("snapshot_coverage_pct")
    if coverage_pct is None:
        coverage_pct = (data.get("snapshot_metadata") or {}).get("coverage_pct")
    if coverage_pct is None or disk_used_gb is None:
        print("MISSING\tresidual_delta_gb absent AND snapshot_coverage_pct/disk_used_gb absent")
        sys.exit(0)
    residual_gb = round(disk_used_gb * (100.0 - float(coverage_pct)) / 100.0, 1)
    source = "fallback:100-coverage_pct"

print(f"OK\t{residual_gb}\t{source}\t{disk_used_gb}")
PY
)"

status="$(echo "$residual_info" | cut -f1)"
if [[ "$status" == "ERROR" || "$status" == "MISSING" ]]; then
  reason="$(echo "$residual_info" | cut -f2)"
  echo "residual_drilldown: cannot determine residual ($reason) — no-op." >&2
  exit 0
fi

residual_gb="$(echo "$residual_info" | cut -f2)"
residual_source="$(echo "$residual_info" | cut -f3)"

if [[ "$residual_source" == fallback:* ]]; then
  echo "residual_drilldown: residual_delta_gb not present in snapshot yet (selfheal work pending) — using fallback derived from 100-coverage_pct: ${residual_gb} GB"
fi

# ────────── FAST NO-OP PATH ──────────
below_threshold=$(awk -v r="$residual_gb" -v t="$THRESHOLD_GB" 'BEGIN{print (r < t) ? "1" : "0"}')
if [[ "$below_threshold" == "1" ]]; then
  echo "residual_drilldown: residual ${residual_gb} GB < threshold ${THRESHOLD_GB} GB (source: ${residual_source}) — no-op."
  exit 0
fi

echo "residual_drilldown: residual ${residual_gb} GB >= threshold ${THRESHOLD_GB} GB (source: ${residual_source}) — drilling down."

# ────────── GATHER CANDIDATES ──────────
# Preferred: selfheal's frontier-discover state file, if it exists yet.
# Fallback: invoke disk_snapshot.sh --discover (read-only) and parse its
# "UNTRACKED  X GB  path" lines — the 80/20 phase-1 approach from the
# roadmap doc (discover already computes this; nobody captured it before).
candidates_tsv=""
candidates_source=""

if [[ -f "$DISCOVER_LAST" ]]; then
  candidates_tsv="$(python3 - "$DISCOVER_LAST" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)

rows = []

def emit(p, size_gb):
    try:
        rows.append((float(size_gb), p))
    except (TypeError, ValueError):
        pass

if isinstance(data, list):
    for item in data:
        if not isinstance(item, dict):
            continue
        p = item.get("path")
        if not p:
            continue
        if "size_gb" in item:
            emit(p, item["size_gb"])
        elif "size_kb" in item:
            emit(p, item["size_kb"] / 1048576.0)
elif isinstance(data, dict):
    # canonical producer shape (disk_snapshot.sh --discover, schema pinned
    # 2026-07-11): {generated_at, cache_hits, cache_misses,
    #               entries: [{path, size_kb, size_gb, tracked}]}
    items = data.get("entries") or data.get("candidates") or data.get("untracked") or []
    if isinstance(items, list):
        for item in items:
            if not isinstance(item, dict):
                continue
            p = item.get("path")
            if not p:
                continue
            if item.get("tracked") is True:
                continue
            if "size_gb" in item:
                emit(p, item["size_gb"])
            elif "size_kb" in item:
                emit(p, item["size_kb"] / 1048576.0)
    else:
        # dict of path -> size_kb
        for p, v in data.items():
            if isinstance(v, (int, float)):
                emit(p, v / 1048576.0)

rows.sort(reverse=True)
for size_gb, p in rows:
    print(f"{size_gb:.1f}\t{p}")
PY
)"
  if [[ -n "$candidates_tsv" ]]; then
    candidates_source="discover_last.json"
  fi
fi

if [[ -z "$candidates_tsv" ]]; then
  echo "residual_drilldown: $DISCOVER_LAST absent or empty (selfheal's discover-state not landed yet, or nothing found) — falling back to disk_snapshot.sh --discover."
  # NOTE: --discover has no overall wall-clock cap upstream (only a 60s
  # per-directory du timeout inside its loop — see bead jleechan-jz5t), so a
  # full $HOME sweep can legitimately run for minutes. Wrap it here (calling
  # side only — disk_snapshot.sh itself is out of scope) so a stuck discover
  # can never hang this 4h-cadence job indefinitely. Partial stdout already
  # written before the kill is still captured.
  discover_timeout_cmd=""
  if command -v timeout &>/dev/null; then discover_timeout_cmd="timeout"
  elif command -v gtimeout &>/dev/null; then discover_timeout_cmd="gtimeout"; fi
  if [[ -n "$discover_timeout_cmd" ]]; then
    discover_output="$("$discover_timeout_cmd" 180 "$SCRIPT_DIR/disk_snapshot.sh" --discover 2>/dev/null || true)"
  else
    discover_output="$("$SCRIPT_DIR/disk_snapshot.sh" --discover 2>/dev/null || true)"
  fi
  candidates_tsv="$(echo "$discover_output" | awk '
    /UNTRACKED/ {
      gb = $2
      path = $4
      for (i = 5; i <= NF; i++) path = path " " $i
      printf "%s\t%s\n", gb, path
    }' | sort -rn)"
  [[ -n "$candidates_tsv" ]] && candidates_source="disk_snapshot.sh --discover"
fi

if [[ -z "$candidates_tsv" ]]; then
  echo "residual_drilldown: residual is above threshold but no untracked candidates found (residual may be purgeable/snapshot space or sibling volumes, not discoverable via home-dir scan) — no-op on proposals."
  exit 0
fi

total_candidates=$(echo "$candidates_tsv" | wc -l | tr -d ' ')
sum_gb=$(echo "$candidates_tsv" | awk -F'\t' '{s+=$1} END{printf "%.1f", s+0}')

echo "residual_drilldown: found ${total_candidates} untracked candidate(s) via ${candidates_source}, summing ${sum_gb} GB."

# ────────── BURST GUARDRAIL: >100G in one run = alert, not propose ──────────
burst=$(awk -v s="$sum_gb" -v b="$BURST_ALERT_GB" 'BEGIN{print (s > b) ? "1" : "0"}')
if [[ "$burst" == "1" ]]; then
  msg="residual_drilldown: ALERT — ${sum_gb} GB of untracked candidates in one run exceeds burst threshold ${BURST_ALERT_GB} GB (source: ${candidates_source}). Treating as anomaly, NOT auto-proposing. Investigate manually."
  echo "$msg" >&2
  if [[ "$DRY_RUN" != true ]]; then
    { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $msg"; echo "$candidates_tsv" | sed 's/^/    /'; } >> "$ALERT_LOG"
  fi
  exit 1
fi

# ────────── BUILD THIS RUN'S PROPOSALS (cap 5/run) ──────────
run_candidates="$(echo "$candidates_tsv" | head -n "$PER_RUN_CAP")"
deferred=$(( total_candidates > PER_RUN_CAP ? total_candidates - PER_RUN_CAP : 0 ))
[[ "$deferred" -gt 0 ]] && echo "residual_drilldown: ${deferred} additional candidate(s) deferred (per-run cap ${PER_RUN_CAP}); will surface on a future run."

proposals_json="[]"
while IFS=$'\t' read -r size_gb path; do
  [[ -z "$path" ]] && continue
  expanded_path="${path/#\~/$HOME}"
  ctype="propose"
  if is_never_delete "$expanded_path"; then
    ctype="measure-only"
  fi
  proposals_json="$(python3 - "$proposals_json" "$expanded_path" "$size_gb" "$ctype" "$candidates_source" <<'PY'
import json, sys
existing = json.loads(sys.argv[1])
existing.append({
    "path": sys.argv[2],
    "size_gb": float(sys.argv[3]),
    "candidate_type": sys.argv[4],
    "source": sys.argv[5],
})
print(json.dumps(existing))
PY
)"
done <<< "$run_candidates"

if [[ "$DRY_RUN" == true ]]; then
  echo "residual_drilldown: --dry-run, not writing $CANDIDATES_FILE. Would have merged:"
  echo "$proposals_json" | python3 -m json.tool
  exit 0
fi

# ────────── MERGE INTO auto-candidates.json (dedup, cap 40 total) ──────────
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp_file="$(mktemp -t disk_magician_candidates.XXXXXX)"
trap 'rm -f "$tmp_file"' EXIT

python3 - "$CANDIDATES_FILE" "$proposals_json" "$now_ts" "$residual_gb" "$residual_source" "$THRESHOLD_GB" "$TOTAL_CAP" > "$tmp_file" <<'PY'
import json, sys

candidates_file, new_json, now_ts, residual_gb, residual_source, threshold_gb, total_cap = sys.argv[1:8]
new_candidates = json.loads(new_json)
total_cap = int(total_cap)

existing = {"candidates": []}
try:
    with open(candidates_file) as f:
        existing = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass

by_path = {c["path"]: c for c in existing.get("candidates", [])}

for c in new_candidates:
    p = c["path"]
    if p in by_path:
        by_path[p]["size_gb"] = c["size_gb"]
        by_path[p]["candidate_type"] = c["candidate_type"]
        by_path[p]["source"] = c["source"]
        by_path[p]["last_seen"] = now_ts
    else:
        c["first_seen"] = now_ts
        c["last_seen"] = now_ts
        by_path[p] = c

merged = sorted(by_path.values(), key=lambda c: c["size_gb"], reverse=True)[:total_cap]

out = {
    "generated_at": now_ts,
    "residual_gb": float(residual_gb),
    "residual_source": residual_source,
    "threshold_gb": float(threshold_gb),
    "candidates": merged,
}
print(json.dumps(out, indent=2))
PY

mv "$tmp_file" "$CANDIDATES_FILE"
trap - EXIT
echo "residual_drilldown: wrote $(echo "$run_candidates" | wc -l | tr -d ' ') proposal(s) to $CANDIDATES_FILE (total on file: $(python3 -c "import json; print(len(json.load(open('$CANDIDATES_FILE'))['candidates']))"))."

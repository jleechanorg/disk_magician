#!/usr/bin/env bash
# disk_usage_alert.sh — Warn when local disk space drops below a threshold.
set -euo pipefail

CHECK_PATH="/"
if [[ "$OSTYPE" == "darwin"* ]]; then
  if df "/System/Volumes/Data" >/dev/null 2>&1; then
    CHECK_PATH="/System/Volumes/Data"
  fi
fi

THRESHOLD_GB=20
SILENCE_FILE="$HOME/.disk_magician_alert.silenced"

# ────────── Coverage-streak escalation (reuses SILENCE_FILE above; no new
# alert mechanism, per roadmap/2026-07-11-total-coverage-snapshot-v2.md) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve_snapshot_json.sh
source "$SCRIPT_DIR/lib/resolve_snapshot_json.sh"
SNAPSHOT_FILE="$(resolve_snapshot_json)"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
STREAK_FILE="$STATE_DIR/coverage_streak.json"
STREAK_ESCALATE_AT=6
LEDGER_STALE_HOURS="${DISK_MAGICIAN_LEDGER_STALE_HOURS:-48}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--silence|--unsilence|--status]

Options:
  --silence    Silence alerts.
  --unsilence  Re-enable alerts.
  --status     Print current status and configuration.
EOF
}

is_silenced() { [[ -f "$SILENCE_FILE" ]]; }
set_silenced() { date -u +%Y-%m-%dT%H:%M:%SZ > "$SILENCE_FILE"; echo "Alerts silenced."; }
unset_silenced() { rm -f "$SILENCE_FILE"; echo "Alerts unsilenced."; }

# Reads the latest snapshot and scores it once (keyed by snapshot timestamp)
# into a ring of the last 12 runs in coverage_streak.json. Prints
# "streak<TAB>coverage_pct<TAB>reasons"; reasons is "none" or a comma list of
# low_effective | stale_carry:<key>@<hours>h | carry_expired:<key>. Escalation is
# sustained-degradation only: 6 consecutive effective < 60, a key carried > 48 h,
# or a previously carried key that is now unmeasured. Snapshots without
# coverage_effective_pct fall back to snapshot_coverage_pct. A missing/unreadable
# snapshot is tolerated ("unknown"), this script must keep doing its free-space check.
update_coverage_streak() {
  [[ -f "$SNAPSHOT_FILE" ]] || { printf 'unknown\tunknown\tnone\n'; return; }
  mkdir -p "$STATE_DIR"
  python3 - "$SNAPSHOT_FILE" "$STREAK_FILE" "$STREAK_ESCALATE_AT" <<'PY'
import json, sys

snapshot_file, streak_file, escalate_at = sys.argv[1], sys.argv[2], int(sys.argv[3])
RING = 12
STALE_CARRY_HOURS = 48
LOW_EFFECTIVE = 60

try:
    snap = json.load(open(snapshot_file))
except Exception:
    print("unknown\tunknown\tnone")
    sys.exit(0)

pct = snap.get("coverage_effective_pct")
if pct is None:
    pct = snap.get("snapshot_coverage_pct")
if pct is None:
    pct = (snap.get("snapshot_metadata") or {}).get("coverage_pct")
snap_ts = snap.get("timestamp", "")
carried = {c["key"]: c.get("age_hours", 0) for c in snap.get("carried_keys") or [] if "key" in c}
unmeasured = list(snap.get("unmeasured_keys") or [])

try:
    state = json.load(open(streak_file))
    if not isinstance(state, dict) or "ring" not in state:
        raise ValueError("old schema")
except FileNotFoundError:
    state = {"ring": []}
except Exception:
    print("coverage_streak.json: old or unreadable schema, resetting", file=sys.stderr)
    state = {"ring": []}
ring = state["ring"]

if snap_ts and not any(r.get("snapshot_ts") == snap_ts for r in ring):
    ring.append({"snapshot_ts": snap_ts, "effective_pct": pct, "carried": carried, "unmeasured": unmeasured})
    del ring[:-RING]
    with open(streak_file, "w") as f:
        json.dump(state, f, indent=2)

streak = 0
for r in reversed(ring):
    v = r.get("effective_pct")
    if v is not None and float(v) < LOW_EFFECTIVE:
        streak += 1
    else:
        break

reasons = []
if streak >= escalate_at:
    reasons.append("low_effective")
for key, age in carried.items():
    if float(age) > STALE_CARRY_HOURS:
        reasons.append(f"stale_carry:{key}@{age}h")
prev = ring[-2] if len(ring) >= 2 and ring[-1].get("snapshot_ts") == snap_ts else (ring[-1] if ring and ring[-1].get("snapshot_ts") != snap_ts else None)
if prev:
    for key in unmeasured:
        if key in (prev.get("carried") or {}):
            reasons.append(f"carry_expired:{key}")
print(f"{streak}\t{pct if pct is not None else 'unknown'}\t{','.join(reasons) or 'none'}")
PY
}

# ────────── Step-event attribution (bead disk_magician-pkq) ──────────
STEP_EVENTS_FILE="${DISK_MAGICIAN_STEP_EVENTS_FILE:-$STATE_DIR/step_events.jsonl}"

get_recent_step_events() {
  [[ -f "$STEP_EVENTS_FILE" ]] || { echo "0	none	0"; return; }
  python3 - "$STEP_EVENTS_FILE" <<'PY'
import json, sys, time
events_file = sys.argv[1]
try:
    with open(events_file, "r") as f:
        lines = [line.strip() for line in f if line.strip()]
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except Exception:
            continue
    if not records:
        print("0\tnone\t0")
        sys.exit(0)
    now = time.time()
    recent = [r for r in records if now - r.get("epoch", 0) <= 86400]
    latest = records[-1]
    delta_gib = round(abs(latest.get("delta_kb", 0)) / (1024 * 1024), 1)
    direction = latest.get("direction", "unknown")
    print(f"{len(recent)}\t{direction}\t{delta_gib}")
except Exception:
    print("0\tnone\t0")
PY
}

# ────────── Swap warning (bead disk_magician-8to; additive snapshot keys) ──────────
# swap_used_gb is additive and absent on pre-swap-tracking snapshots — tolerate
# a missing key/file by returning "unknown" (never alerts).
get_swap_used_gb() {
  [[ -f "$SNAPSHOT_FILE" ]] || { echo "unknown"; return; }
  python3 - "$SNAPSHOT_FILE" <<'PY'
import json, sys
try:
    snap = json.load(open(sys.argv[1]))
except Exception:
    print("unknown")
    sys.exit(0)
v = snap.get("swap_used_gb")
print(v if v is not None else "unknown")
PY
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --silence)   set_silenced; exit 0 ;;
    --unsilence) unset_silenced; exit 0 ;;
    --status)
      echo "Check path: $CHECK_PATH"
      echo "Snapshot file: $SNAPSHOT_FILE"
      if [[ -x "$SCRIPT_DIR/check_ledger_freshness.sh" ]]; then
        echo "Ledger freshness: $("$SCRIPT_DIR/check_ledger_freshness.sh" 2>&1 || true)"
      fi
      echo "Threshold: ${THRESHOLD_GB} GB"
      echo "Silenced: $(is_silenced && echo 'YES' || echo 'NO')"
      IFS=$'\t' read -r status_streak status_coverage_pct status_reasons <<< "$(update_coverage_streak)"
      echo "Coverage streak: ${status_streak} (effective_pct=${status_coverage_pct}, escalate at ${STREAK_ESCALATE_AT}; reasons: ${status_reasons})"
      IFS=$'\t' read -r step_count step_dir step_gib <<< "$(get_recent_step_events)"
      echo "Recent step events (24h): ${step_count} (latest: ${step_dir} ${step_gib} GiB)"
      exit 0
      ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
fi

df_line="$(df -kP "$CHECK_PATH" | awk 'NR==2')"
if [[ -z "$df_line" ]]; then
  echo "Failed to read disk stats." >&2
  exit 1
fi

total_kb=$(echo "$df_line" | awk '{print $2}')
avail_kb=$(echo "$df_line" | awk '{print $4}')
free_gb=$(( avail_kb / 1024 / 1024 ))
used_pct=$(( (total_kb - avail_kb) * 100 / total_kb ))

IFS=$'\t' read -r coverage_streak coverage_pct coverage_reasons <<< "$(update_coverage_streak)"
IFS=$'\t' read -r step_count step_dir step_gib <<< "$(get_recent_step_events)"

streak_alert=false
if [[ "${coverage_reasons:-none}" != "none" ]]; then
  streak_alert=true
else
  # Isolated low-coverage runs are normal under host load: INFO, never an alert.
  [[ "$coverage_streak" != "unknown" && "$coverage_streak" -gt 0 ]] && \
    echo "INFO: low coverage run ${coverage_streak}/${STREAK_ESCALATE_AT} (effective_pct=${coverage_pct}); not escalating." >&2
fi

ledger_alert=false
ledger_detail=""
if [[ -x "$SCRIPT_DIR/check_ledger_freshness.sh" ]]; then
  ledger_detail="$("$SCRIPT_DIR/check_ledger_freshness.sh" 2>&1 || true)"
  [[ "$ledger_detail" == STALE* ]] && ledger_alert=true
fi

space_alert=false
[[ $free_gb -lt $THRESHOLD_GB ]] && space_alert=true

swap_used_gb="$(get_swap_used_gb)"
swap_alert=false
if [[ "$swap_used_gb" != "unknown" ]] && awk -v v="$swap_used_gb" 'BEGIN{exit !(v+0 > 10)}'; then
  swap_alert=true
fi

if [[ "$space_alert" == true || "$streak_alert" == true || "$ledger_alert" == true || "$swap_alert" == true ]]; then
  if is_silenced; then
    echo "Disk space/coverage alert silenced (Free space: ${free_gb} GB, ${used_pct}% capacity; coverage streak: ${coverage_streak}; step events 24h: ${step_count})."
  else
    if [[ "$space_alert" == true ]]; then
      echo "🚨 WARNING: Low Disk Space! Only ${free_gb} GB free (${used_pct}% capacity)." >&2
      echo "Run './disk_magician.sh clean' to reclaim space." >&2
      if [[ "$step_count" -gt 0 ]]; then
        echo "ℹ️  Step-event attribution: ${step_count} rapid swing(s) recorded in last 24h (latest: ${step_dir} ${step_gib} GiB)." >&2
      fi
    fi
    if [[ "$streak_alert" == true ]]; then
      echo "🚨 WARNING: Snapshot coverage degraded (effective_pct=${coverage_pct}; low-run streak ${coverage_streak}): ${coverage_reasons}." >&2
      echo "Run 'scripts/residual_drilldown.sh' or check config.d/auto-candidates.json for untracked-growth proposals." >&2
    fi
    if [[ "$ledger_alert" == true ]]; then
      echo "🚨 WARNING: Published ledger/topdown-5g.json is stale (${ledger_detail#STALE	})." >&2
      echo "Run './disk_magician.sh frontier' or wait for frontier-nightly; bucket deltas are unreliable until a complete scan publishes." >&2
    fi
    if [[ "$swap_alert" == true ]]; then
      echo "🚨 WARNING: Swap used: ${swap_used_gb} GiB (>10 GB) — disk space consumed outside the Data volume (vm.swapusage)." >&2
    fi
    exit 1
  fi
else
  echo "Disk OK: ${free_gb} GB free (${used_pct}% capacity). Coverage streak: ${coverage_streak} (coverage_pct=${coverage_pct}). Step events (24h): ${step_count}."
fi

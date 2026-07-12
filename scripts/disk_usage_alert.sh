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
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
BACKUP_DIR="${DISK_MAGICIAN_BACKUP_DIR:-$HOME/.disk_magician_backup/backup}"
SNAPSHOT_FILE="${DISK_MAGICIAN_SNAPSHOT_FILE:-$BACKUP_DIR/$HOSTNAME_SHORT/disk_snapshot.json}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
STREAK_FILE="$STATE_DIR/coverage_streak.json"
STREAK_ESCALATE_AT=3

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

# Reads the latest snapshot, advances the coverage streak counter if this is
# a snapshot we haven't scored yet, and prints "streak<TAB>coverage_pct" (or
# "unknown<TAB>unknown" if the snapshot is missing/unreadable — tolerated,
# not an error, since this script must keep doing its primary free-space
# check regardless of snapshot availability).
update_coverage_streak() {
  [[ -f "$SNAPSHOT_FILE" ]] || { echo "unknown	unknown"; return; }
  mkdir -p "$STATE_DIR"
  python3 - "$SNAPSHOT_FILE" "$STREAK_FILE" "$STREAK_ESCALATE_AT" <<'PY'
import json, sys

snapshot_file, streak_file, escalate_at = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    snap = json.load(open(snapshot_file))
except Exception:
    print("unknown\tunknown")
    sys.exit(0)

coverage_pct = snap.get("snapshot_coverage_pct")
if coverage_pct is None:
    coverage_pct = (snap.get("snapshot_metadata") or {}).get("coverage_pct")
low_coverage = (snap.get("snapshot_warning") == "low_coverage") or (
    coverage_pct is not None and float(coverage_pct) < 70
)
snap_ts = snap.get("timestamp", "")

try:
    state = json.load(open(streak_file))
except Exception:
    state = {"streak": 0, "last_snapshot_timestamp": ""}

if snap_ts and snap_ts == state.get("last_snapshot_timestamp"):
    # Already scored this exact snapshot (alert runs hourly, snapshots land
    # every ~35min) — don't double-count, just report current streak.
    print(f"{state.get('streak', 0)}\t{coverage_pct if coverage_pct is not None else 'unknown'}")
    sys.exit(0)

state["streak"] = state.get("streak", 0) + 1 if low_coverage else 0
state["last_snapshot_timestamp"] = snap_ts
state["last_coverage_pct"] = coverage_pct

with open(streak_file, "w") as f:
    json.dump(state, f, indent=2)

print(f"{state['streak']}\t{coverage_pct if coverage_pct is not None else 'unknown'}")
PY
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --silence)   set_silenced; exit 0 ;;
    --unsilence) unset_silenced; exit 0 ;;
    --status)
      echo "Check path: $CHECK_PATH"
      echo "Threshold: ${THRESHOLD_GB} GB"
      echo "Silenced: $(is_silenced && echo 'YES' || echo 'NO')"
      IFS=$'\t' read -r status_streak status_coverage_pct <<< "$(update_coverage_streak)"
      echo "Coverage streak: ${status_streak} (coverage_pct=${status_coverage_pct}, escalate at ${STREAK_ESCALATE_AT})"
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

IFS=$'\t' read -r coverage_streak coverage_pct <<< "$(update_coverage_streak)"
streak_alert=false
if [[ "$coverage_streak" != "unknown" && "$coverage_streak" -ge "$STREAK_ESCALATE_AT" ]]; then
  streak_alert=true
fi

space_alert=false
[[ $free_gb -lt $THRESHOLD_GB ]] && space_alert=true

if [[ "$space_alert" == true || "$streak_alert" == true ]]; then
  if is_silenced; then
    echo "Disk space/coverage alert silenced (Free space: ${free_gb} GB, ${used_pct}% capacity; coverage streak: ${coverage_streak})."
  else
    if [[ "$space_alert" == true ]]; then
      echo "🚨 WARNING: Low Disk Space! Only ${free_gb} GB free (${used_pct}% capacity)." >&2
      echo "Run './disk_magician.sh clean' to reclaim space." >&2
    fi
    if [[ "$streak_alert" == true ]]; then
      echo "🚨 WARNING: Snapshot coverage has been low for ${coverage_streak} consecutive checks (coverage_pct=${coverage_pct})." >&2
      echo "Run 'scripts/residual_drilldown.sh' or check config.d/auto-candidates.json for untracked-growth proposals." >&2
    fi
    exit 1
  fi
else
  echo "Disk OK: ${free_gb} GB free (${used_pct}% capacity). Coverage streak: ${coverage_streak} (coverage_pct=${coverage_pct})."
fi

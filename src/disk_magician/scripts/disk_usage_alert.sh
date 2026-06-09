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

if [[ $# -gt 0 ]]; then
  case "$1" in
    --silence)   set_silenced; exit 0 ;;
    --unsilence) unset_silenced; exit 0 ;;
    --status)
      echo "Check path: $CHECK_PATH"
      echo "Threshold: ${THRESHOLD_GB} GB"
      echo "Silenced: $(is_silenced && echo 'YES' || echo 'NO')"
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

if [[ $free_gb -lt $THRESHOLD_GB ]]; then
  if is_silenced; then
    echo "Disk space alert silenced (Free space: ${free_gb} GB, ${used_pct}% capacity)."
  else
    echo "🚨 WARNING: Low Disk Space! Only ${free_gb} GB free (${used_pct}% capacity)." >&2
    echo "Run './disk_magician.sh clean' to reclaim space." >&2
    exit 1
  fi
else
  echo "Disk OK: ${free_gb} GB free (${used_pct}% capacity)."
fi

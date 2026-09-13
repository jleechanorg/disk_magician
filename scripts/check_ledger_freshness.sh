#!/usr/bin/env bash
# check_ledger_freshness.sh — Detect stale published ledger/topdown-5g.json commits.
#
# The mega-table file is publication-gated (render_topdown_ledger.py): partial
# frontier scans update topdown-5g.status.json but may leave topdown-5g.json
# unchanged for days. Investigations must not treat bucket deltas from a table
# older than DISK_MAGICIAN_LEDGER_STALE_HOURS (default 48) as current.
#
# Exit 0: published ledger commit is within threshold.
# Exit 1: published ledger commit is older than threshold (or missing).
# Exit 2: cannot read state repo / git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALE_HOURS="${DISK_MAGICIAN_LEDGER_STALE_HOURS:-48}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help] [--status]

Prints one line: OK|STALE|UNKNOWN followed by tab-separated fields.
Default threshold: ${STALE_HOURS}h since last git commit touching ledger/topdown-5g.json.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

STATE_DIR="$(python3 "$SCRIPT_DIR/resolve_state_repo_path.py" 2>/dev/null || true)"
if [[ -z "$STATE_DIR" || ! -d "$STATE_DIR/.git" ]]; then
  echo "UNKNOWN	state_repo_missing"
  exit 2
fi

LEDGER_REL="ledger/topdown-5g.json"
STATUS_PATH="$STATE_DIR/ledger/topdown-5g.status.json"

last_epoch="$(git -C "$STATE_DIR" log -1 --format=%ct -- "$LEDGER_REL" 2>/dev/null || echo 0)"
if [[ -z "$last_epoch" || "$last_epoch" == "0" ]]; then
  echo "STALE	no_published_ledger_commit"
  exit 1
fi

now_epoch="$(date +%s)"
age_hours="$(( (now_epoch - last_epoch) / 3600 ))"
last_iso="$(git -C "$STATE_DIR" log -1 --format=%cI -- "$LEDGER_REL" 2>/dev/null || echo unknown)"

pub_status="unknown"
pub_reason=""
if [[ -f "$STATUS_PATH" ]]; then
  read -r pub_status pub_reason <<< "$(python3 - "$STATUS_PATH" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("status", "unknown"), d.get("reason", ""))
except Exception:
    print("unknown", "unreadable_status")
PY
)"
fi

if (( age_hours > STALE_HOURS )); then
  echo "STALE	published_age_hours=${age_hours}	last_commit=${last_iso}	status=${pub_status}	reason=${pub_reason}"
  exit 1
fi

echo "OK	published_age_hours=${age_hours}	last_commit=${last_iso}	status=${pub_status}	reason=${pub_reason}"
exit 0

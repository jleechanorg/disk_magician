#!/usr/bin/env bash
# check_ledger_freshness.sh — Detect stale published ledger/topdown-5g.json
# commits, accepting a structurally-valid, fresh topdown-5g.partial.json as a
# second freshness source when the canonical (full-attribution) table itself
# is stale or has never published (bead disk_magician-zyn Component F/H: the
# canonical ledger is publication-gated on a *complete* frontier scan, so it
# can legitimately sit untouched for days while partial scans keep landing —
# see render_topdown_ledger.py's module docstring).
#
# The mega-table file is publication-gated (render_topdown_ledger.py): partial
# frontier scans update topdown-5g.status.json but may leave topdown-5g.json
# unchanged for days. Investigations must not treat bucket deltas from a table
# older than DISK_MAGICIAN_LEDGER_STALE_HOURS (default 48) as current unless a
# fresh, validated partial ledger is also available (labelled PARTIAL below).
#
# Output contract (unchanged from the original, merged PR #68 shape — two
# live consumers, check_launchd_fleet.sh and disk_usage_alert.sh, key off the
# leading token and `== STALE*`): one line, `OK|STALE|UNKNOWN` followed by
# tab-separated `key=value` fields. New fields (`label=`, `partial_*=`) are
# additive and only ever appended — never inserted before existing fields —
# so `${line#OK	}`-style stripping on old fields keeps working.
#
# Exit 0: canonical OR a valid, fresh partial ledger is within threshold.
# Exit 1: neither canonical nor a valid, fresh partial ledger is within
#         threshold (or both missing/invalid).
# Exit 2: cannot read state repo / git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STALE_HOURS="${DISK_MAGICIAN_LEDGER_STALE_HOURS:-48}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help]

Prints one line: OK|STALE|UNKNOWN followed by tab-separated fields.
Default threshold: ${STALE_HOURS}h.

Canonical source: last git commit touching ledger/topdown-5g.json.
Partial source: ledger/topdown-5g.partial.json's own captured_at, accepted
only when it passes history_diff.validate_ledger() (schema_version, required
keys, internal reconciliation) AND reconciles with topdown-5g.status.json
(same captured_at implies matching mode/coverage_envelope) AND is not a
future timestamp. A fresh, valid partial ledger is reported as
"OK ... label=PARTIAL ..." — the gate is OK either way; label= says which
source qualified.
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

canon_fresh=false
age_hours=""
last_iso="none"
if [[ -n "$last_epoch" && "$last_epoch" != "0" ]]; then
  now_epoch="$(date +%s)"
  age_hours="$(( (now_epoch - last_epoch) / 3600 ))"
  last_iso="$(git -C "$STATE_DIR" log -1 --format=%cI -- "$LEDGER_REL" 2>/dev/null || echo unknown)"
  (( age_hours <= STALE_HOURS )) && canon_fresh=true
fi

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

if [[ "$canon_fresh" == true ]]; then
  echo "OK	published_age_hours=${age_hours}	last_commit=${last_iso}	status=${pub_status}	reason=${pub_reason}	label=OK"
  exit 0
fi

# Canonical is stale/missing — fall back to the partial ledger. Reads and
# validates it in one python3 pass (reuses history_diff.validate_ledger via
# import — this must never duplicate that structural check in bash, per
# design spec Component "ledger-freshness recognition" and the codex/opus
# review findings that a recent-timestamp check alone can certify corrupt
# data as fresh).
# Field separator is \x1f (ASCII unit separator), NOT a tab: bash `read`
# treats tab as POSIX "IFS whitespace" and collapses consecutive delimiters
# even when IFS is set to a lone tab, silently dropping empty fields
# (p_measured/p_reachable are legitimately empty on an incomplete-coverage
# partial ledger) and shifting every field after them — verified live: a
# tab-joined line with two consecutive empty fields loses the trailing
# reason field entirely. \x1f is not whitespace, so it never collapses.
IFS=$'\x1f' read -r p_valid p_age_hours p_captured_at p_mode p_measured p_reachable p_reason <<< "$(python3 - "$STATE_DIR" "$SCRIPT_DIR" <<'PY'
import datetime, json, os, sys

state_dir, script_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)


def emit(valid, age_hours, captured_at, mode, measured, reachable, reason):
    def s(v):
        return "" if v is None else str(v)
    # \x1f (unit separator), not tab — see the caller-side comment on the
    # matching `read`: tab collapses consecutive delimiters in bash even
    # under a custom IFS, silently dropping empty fields.
    print("\x1f".join([
        "yes" if valid else "no",
        s(age_hours), s(captured_at), s(mode), s(measured), s(reachable), s(reason),
    ]))


partial_path = os.path.join(state_dir, "ledger", "topdown-5g.partial.json")
status_path = os.path.join(state_dir, "ledger", "topdown-5g.status.json")

try:
    with open(partial_path) as f:
        partial = json.load(f)
except FileNotFoundError:
    emit(False, None, None, None, None, None, "missing")
    sys.exit(0)
except (OSError, ValueError) as exc:
    emit(False, None, None, None, None, None, f"unreadable:{exc}")
    sys.exit(0)

try:
    import history_diff
    history_diff.validate_ledger(partial, label="partial")
except Exception as exc:
    emit(False, None, partial.get("captured_at"), partial.get("mode"), None, None, f"invalid:{exc}")
    sys.exit(0)

captured_at = partial.get("captured_at")
try:
    ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc
    )
except (TypeError, ValueError):
    emit(False, None, captured_at, partial.get("mode"), None, None, "invalid_captured_at")
    sys.exit(0)

age_hours = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds() / 3600.0
if age_hours < -0.1:
    emit(False, age_hours, captured_at, partial.get("mode"), None, None, "captured_at_in_future")
    sys.exit(0)

# Reconciliation: when status.json reports the SAME captured_at (the common
# case — both are written by the same render_topdown_ledger.py run), its
# mode/coverage_envelope must agree with the partial ledger's. A same-
# timestamp disagreement between the two sidecar files is exactly the
# corruption class this exists to catch. Different captured_at values mean
# they are from different runs (normal — e.g. a later run's frontier report
# was itself stale, so it wrote a new status but no new partial) and impose
# no constraint.
try:
    with open(status_path) as f:
        status = json.load(f)
except (OSError, ValueError):
    status = None

if isinstance(status, dict) and status.get("captured_at") == captured_at:
    if (
        status.get("mode") != partial.get("mode")
        or status.get("coverage_envelope") != partial.get("coverage_envelope")
    ):
        emit(False, age_hours, captured_at, partial.get("mode"), None, None,
             "status_reconciliation_mismatch")
        sys.exit(0)

envelope = partial.get("coverage_envelope") or {}
measured = envelope.get("measured_top_level_roots")
reachable = envelope.get("reachable_top_level_roots")
emit(True, age_hours, captured_at, partial.get("mode"), measured, reachable, "")
PY
)"

partial_fresh=false
if [[ "$p_valid" == "yes" ]]; then
  if awk -v a="$p_age_hours" -v t="$STALE_HOURS" 'BEGIN{exit !(a<=t)}'; then
    partial_fresh=true
  fi
fi

if [[ "$partial_fresh" == true ]]; then
  echo "OK	published_age_hours=${age_hours:-NA}	last_commit=${last_iso}	status=${pub_status}	reason=${pub_reason}	label=PARTIAL	partial_age_hours=${p_age_hours}	partial_captured_at=${p_captured_at}	partial_mode=${p_mode}	partial_roots=${p_measured:-?}/${p_reachable:-?}"
  exit 0
fi

echo "STALE	published_age_hours=${age_hours:-NA}	last_commit=${last_iso}	status=${pub_status}	reason=${pub_reason}	partial_status=${p_reason:-missing}"
exit 1

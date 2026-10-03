#!/usr/bin/env bash
# check_ledger_freshness.sh — Detect stale published ledger/topdown-5g.json
# commits, accepting a structurally-valid, fresh topdown-5g.partial.json as a
# second freshness source when the canonical (full-attribution) table itself
# is stale or has never published (bead disk_magician-zyn Component F/H: the
# canonical ledger is publication-gated on a *complete* frontier scan, so it
# can legitimately sit untouched for days while partial scans keep landing —
# see render_topdown_ledger.py module docstring).
#
# The mega-table file is publication-gated (render_topdown_ledger.py): partial
# frontier scans update topdown-5g.status.json but may leave topdown-5g.json
# unchanged for days. Investigations must not treat bucket deltas from a table
# older than DISK_MAGICIAN_LEDGER_STALE_HOURS (default 48) as current unless a
# fresh, validated partial ledger is also available (labelled PARTIAL below).
#
# Output contract (unchanged from the original, merged PR #68 shape — two
# live consumers, check_launchd_fleet.sh and disk_usage_alert.sh, key off the
# leading token and == STALE*): one line, OK|STALE|UNKNOWN followed by
# tab-separated key=value fields. New fields (label=, partial_*=) are
# additive and only ever appended — never inserted before existing fields —
# so ${line#OK	}-style stripping on old fields keeps working.
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

Canonical source: validated capture time and last git commit touching ledger/topdown-5g.json.
Partial source: ledger/topdown-5g.partial.json own captured_at, accepted
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
  printf "UNKNOWN\tstate_repo_missing\n"
  exit 2
fi

LEDGER_REL="ledger/topdown-5g.json"
STATUS_PATH="$STATE_DIR/ledger/topdown-5g.status.json"

last_epoch="$(git -C "$STATE_DIR" log -1 --format=%ct -- "$LEDGER_REL" 2>/dev/null || echo 0)"
last_iso="none"
if [[ -n "$last_epoch" && "$last_epoch" != "0" ]]; then
  last_iso="$(git -C "$STATE_DIR" log -1 --format=%cI -- "$LEDGER_REL" 2>/dev/null || echo unknown)"
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

# Run python validator for canonical capture time and partial ledger.
# Note: Heredoc body must NOT contain literal single quote / apostrophe
# characters due to bash 3.2 heredoc-in-subshell parsing bugs.
IFS=$'\x1f' read -r c_valid c_age_hours p_valid p_age_hours p_captured_at p_mode p_measured p_reachable p_reason <<< "$(python3 - "$STATE_DIR" "$SCRIPT_DIR" "$STALE_HOURS" "${last_epoch:-0}" <<'PY'
import datetime, json, os, sys

state_dir, script_dir, stale_hours_str, last_epoch_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    stale_hours = float(stale_hours_str)
except Exception:
    stale_hours = 48.0
last_epoch = float(last_epoch_str) if last_epoch_str else 0.0
sys.path.insert(0, script_dir)

now_dt = datetime.datetime.now(datetime.timezone.utc)

def s(v):
    return "" if v is None else str(v)

def safe_get(obj, key):
    return obj.get(key) if isinstance(obj, dict) else None

def check_canonical():
    canon_path = os.path.join(state_dir, "ledger", "topdown-5g.json")
    if not os.path.exists(canon_path):
        return False, None, "missing"

    try:
        with open(canon_path) as f:
            canon = json.load(f)
    except Exception:
        return False, None, "unreadable"

    if not isinstance(canon, dict):
        return False, None, "not_an_object"

    captured_at = safe_get(canon, "captured_at")
    if not isinstance(captured_at, str):
        return False, None, "missing_captured_at"

    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except Exception:
        return False, None, "invalid_captured_at"

    if ts > now_dt:
        return False, (now_dt - ts).total_seconds() / 3600.0, "captured_at_in_future"

    c_age = (now_dt - ts).total_seconds() / 3600.0
    if c_age > stale_hours:
        return False, c_age, "captured_at_stale"

    try:
        import history_diff
        history_diff.validate_ledger(canon, label="canonical")
        history_diff.validate_full_attribution_ledger(canon, label="canonical")
    except Exception:
        return False, c_age, "invalid"

    if last_epoch > 0:
        commit_age = (now_dt.timestamp() - last_epoch) / 3600.0
        if commit_age > stale_hours:
            return False, commit_age, "commit_stale"

    return True, c_age, ""

def check_partial():
    partial_path = os.path.join(state_dir, "ledger", "topdown-5g.partial.json")
    status_path = os.path.join(state_dir, "ledger", "topdown-5g.status.json")

    try:
        with open(partial_path) as f:
            partial = json.load(f)
    except FileNotFoundError:
        return False, None, None, None, None, None, "missing"
    except Exception as exc:
        return False, None, None, None, None, None, "unreadable"

    try:
        import history_diff
        history_diff.validate_ledger(partial, label="partial")
    except Exception as exc:
        return False, None, safe_get(partial, "captured_at"), safe_get(partial, "mode"), None, None, "invalid"

    buckets = safe_get(partial, "granularity_buckets") or safe_get(partial, "buckets") or []
    oversize = safe_get(partial, "oversize_indivisible_files") or []
    if not buckets and not oversize:
        return False, None, safe_get(partial, "captured_at"), safe_get(partial, "mode"), None, None, "empty_scan"

    captured_at = safe_get(partial, "captured_at")
    try:
        ts = datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except Exception:
        return False, None, captured_at, safe_get(partial, "mode"), None, None, "invalid_captured_at"

    age_hours = (now_dt - ts).total_seconds() / 3600.0
    if ts > now_dt:
        return False, age_hours, captured_at, safe_get(partial, "mode"), None, None, "captured_at_in_future"
    if age_hours > stale_hours:
        return False, age_hours, captured_at, safe_get(partial, "mode"), None, None, "partial_stale"

    try:
        with open(status_path) as f:
            status = json.load(f)
    except FileNotFoundError:
        status = None
    except Exception:
        return False, age_hours, captured_at, safe_get(partial, "mode"), None, None, "status_unreadable"

    if status is not None:
        if not isinstance(status, dict):
            return False, age_hours, captured_at, safe_get(partial, "mode"), None, None, "status_malformed"
        if status.get("captured_at") == captured_at and (
            status.get("mode") != safe_get(partial, "mode")
            or status.get("coverage_envelope") != safe_get(partial, "coverage_envelope")
        ):
            return False, age_hours, captured_at, safe_get(partial, "mode"), None, None, "status_reconciliation_mismatch"

    envelope = safe_get(partial, "coverage_envelope")
    measured = safe_get(envelope, "measured_top_level_roots")
    reachable = safe_get(envelope, "reachable_top_level_roots")
    return True, age_hours, captured_at, safe_get(partial, "mode"), measured, reachable, ""

try:
    c_ok, c_age, c_reason = check_canonical()
except Exception as exc:
    c_ok, c_age, c_reason = False, None, "canonical_check_error"

try:
    p_ok, p_age, p_cap, p_m, p_meas, p_reach, p_rsn = check_partial()
except Exception as exc:
    p_ok, p_age, p_cap, p_m, p_meas, p_reach, p_rsn = False, None, None, None, None, None, "partial_check_error"

fields = [
    "yes" if c_ok else "no",
    s(int(c_age) if c_age is not None else ""),
    "yes" if p_ok else "no",
    s(int(p_age) if p_age is not None else ""),
    s(p_cap),
    s(p_m),
    s(p_meas),
    s(p_reach),
    s(p_rsn if not p_ok else ""),
]
print("\x1f".join(fields))
PY
)"

if [[ "$c_valid" == "yes" ]]; then
  printf "OK\tpublished_age_hours=%s\tlast_commit=%s\tstatus=%s\treason=%s\tlabel=CANONICAL\n" \
    "${c_age_hours:-0}" "$last_iso" "$pub_status" "$pub_reason"
  exit 0
fi

if [[ "$p_valid" == "yes" ]]; then
  printf "OK\tpublished_age_hours=%s\tlast_commit=%s\tstatus=%s\treason=%s\tlabel=PARTIAL\tpartial_age_hours=%s\tpartial_captured_at=%s\tpartial_mode=%s\tpartial_roots=%s/%s\n" \
    "${c_age_hours:-NA}" "$last_iso" "$pub_status" "$pub_reason" \
    "${p_age_hours:-0}" "${p_captured_at:-unknown}" "${p_mode:-unknown}" \
    "${p_measured:-?}" "${p_reachable:-?}"
  exit 0
fi

printf "STALE\tpublished_age_hours=%s\tlast_commit=%s\tstatus=%s\treason=%s\tpartial_status=%s\n" \
  "${c_age_hours:-NA}" "$last_iso" "$pub_status" "$pub_reason" "${p_reason:-missing}"
exit 1

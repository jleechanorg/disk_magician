#!/usr/bin/env bash
# test_history_diff_dispatch.sh — dispatcher wiring for `history diff [ref]`
# (sandboxed: fixture STATE_DIR via DISK_MAGICIAN_STATE_REPO, no real $HOME).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DM="$REPO_ROOT/disk_magician.sh"
TMP_ROOT=$(mktemp -d -t history_diff_dispatch.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/ledger"
git -C "$STATE" init -q -b main 2>/dev/null \
  || { git -C "$STATE" init -q && git -C "$STATE" symbolic-ref HEAD refs/heads/main; }
gib=$((1024*1024))
python3 - "$STATE/ledger/topdown-5g.json" 4 <<'PY'
import json, os, sys
path, gib_count = sys.argv[1], int(sys.argv[2])
gib = 1024 * 1024
user_home = "/Users/testuser"
user_probes = {
    "mobile_sync": f"{user_home}/Library/Application Support/MobileSync/Backup",
    "mail": f"{user_home}/Library/Mail",
    "messages": f"{user_home}/Library/Messages",
}
buckets = [{"path": "/a", "measured_kb": 4 * gib}]
if gib_count > 4:
    buckets.append({"path": "/fixture_growth", "measured_kb": 4 * gib})
total_kb = gib_count * gib
ledger = {
    "schema_version": 2,
    "mode": "complete",
    "disk_used_kb": total_kb,
    "residual_kb": 0,
    "residual_label": "t",
    "buckets": buckets,
    "coverage_envelope": {
        "complete": True,
        "fda_preflight_status": "granted",
        "fda_user_preflight_status": "granted",
        "reachable_top_level_roots": 1,
        "measured_top_level_roots": 1,
        "unfinished_top_level_roots": 0,
    },
    "frontier_unfinished": [],
    "fda_probe_paths": user_probes,
    "fda_preflight": {
        "status": "granted",
        "probes": {k: {"path": v, "status": "readable"} for k, v in user_probes.items()},
    },
    "opaque_intrinsic_gates": [],
    "accounting_equation": {
        "displayed_balanced": True,
        "display_ledger_valid": True,
        "data_used_kb": total_kb,
        "displayed_buckets_kb": total_kb,
        "oversize_indivisible_files_kb": 0,
        "sub_granularity_tail_kb": 0,
        "purgeable_kb": 0,
        "residual_kb": 0,
        "clone_shared_adjustment_kb": 0,
    },
}
with open(path, "w") as f:
    json.dump(ledger, f)
PY
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm base
python3 - "$STATE/ledger/topdown-5g.json" 8 <<'PY'
import json, os, sys
path, gib_count = sys.argv[1], int(sys.argv[2])
gib = 1024 * 1024
user_home = "/Users/testuser"
user_probes = {
    "mobile_sync": f"{user_home}/Library/Application Support/MobileSync/Backup",
    "mail": f"{user_home}/Library/Mail",
    "messages": f"{user_home}/Library/Messages",
}
buckets = [{"path": "/a", "measured_kb": 4 * gib}, {"path": "/fixture_growth", "measured_kb": 4 * gib}]
total_kb = gib_count * gib
ledger = {
    "schema_version": 2,
    "mode": "complete",
    "disk_used_kb": total_kb,
    "residual_kb": 0,
    "residual_label": "t",
    "buckets": buckets,
    "coverage_envelope": {
        "complete": True,
        "fda_preflight_status": "granted",
        "fda_user_preflight_status": "granted",
        "reachable_top_level_roots": 1,
        "measured_top_level_roots": 1,
        "unfinished_top_level_roots": 0,
    },
    "frontier_unfinished": [],
    "fda_probe_paths": user_probes,
    "fda_preflight": {
        "status": "granted",
        "probes": {k: {"path": v, "status": "readable"} for k, v in user_probes.items()},
    },
    "opaque_intrinsic_gates": [],
    "accounting_equation": {
        "displayed_balanced": True,
        "display_ledger_valid": True,
        "data_used_kb": total_kb,
        "displayed_buckets_kb": total_kb,
        "oversize_indivisible_files_kb": 0,
        "sub_granularity_tail_kb": 0,
        "purgeable_kb": 0,
        "residual_kb": 0,
        "clone_shared_adjustment_kb": 0,
    },
}
with open(path, "w") as f:
    json.dump(ledger, f)
PY
git -C "$STATE" add -A
git -C "$STATE" -c user.name=t -c user.email=t@t commit -qm grown

echo "Test 1: history diff (no ref) names the grown bucket first, residual last"
OUT=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
      DISK_MAGICIAN_SCAN_USER_HOME="/Users/testuser" \
      DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff 2>&1)
RC=$?
[[ $RC -eq 0 ]] && ok "dispatch exits 0" || bad "dispatch rc" "$RC: $OUT"
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$OUT")
[[ "$FIRST_LINE" == *"/fixture_growth"* ]] && ok "grown bucket is the top line" \
  || bad "top line" "$FIRST_LINE"
[[ "$LAST_LINE" == "residual delta: +0.00 GiB" ]] && ok "residual delta is the last line" \
  || bad "last line" "$LAST_LINE"

echo "Test 2: history diff HEAD (explicit ref) still routes to history_diff.py"
OUT2=$(env -i HOME="$TMP_ROOT/home" PATH="/usr/bin:/bin" \
       DISK_MAGICIAN_SCAN_USER_HOME="/Users/testuser" \
       DISK_MAGICIAN_STATE_REPO="$STATE" "$DM" history diff HEAD 2>&1)
[[ "$OUT2" == "residual delta: +0.00 GiB" ]] && ok "diff HEAD == HEAD is empty + residual line" \
  || bad "diff HEAD" "$OUT2"

echo "Test 3: bare 'history' (no diff) still falls through to disk_history.sh"
OUT3=$(env -i HOME="$TMP_ROOT/home2" PATH="/usr/bin:/bin" "$DM" history 2>&1)
echo "$OUT3" | grep -qi "history_diff" && bad "bare history unaffected" "leaked into history_diff: $OUT3" \
  || ok "bare history is not rerouted"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

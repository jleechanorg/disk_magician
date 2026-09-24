#!/usr/bin/env bash
# test_check_ledger_freshness.sh — stale published ledger detection
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check_ledger_freshness.sh"
PASS=0
FAIL=0
ok() { echo "OK: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/repo"
STATE="$WORK/repo"
mkdir -p "$STATE/ledger"
echo '{"disk_used_kb":1}' > "$STATE/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE/ledger/topdown-5g.status.json"
git -C "$STATE" add ledger/topdown-5g.json ledger/topdown-5g.status.json
git -C "$STATE" -c user.email=t@test -c user.name=t commit -q -m "init ledger"

# Backdate commit metadata by setting an old commit time via env is hard; instead
# use STALE_HOURS=0 so any commit is immediately stale.
export DISK_MAGICIAN_STATE_REPO="$STATE"
export DISK_MAGICIAN_LEDGER_STALE_HOURS=-1
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] && ok "flags stale when threshold 0h" || bad "expected STALE rc=1 got rc=$rc out=$out"

# Fresh with huge threshold
export DISK_MAGICIAN_LEDGER_STALE_HOURS=99999
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* ]] && ok "OK within 99999h window" || bad "expected OK rc=0 got rc=$rc out=$out"

unset DISK_MAGICIAN_LEDGER_STALE_HOURS

iso_offset_hours() {
  # $1: hours offset from now (negative = past, positive = future)
  python3 -c "
import datetime, sys
dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=float(sys.argv[1]))
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

write_partial() {
  # $1: dest path, $2: captured_at ISO8601, $3: mode
  python3 -c "
import json, sys
path, captured_at, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = {
    'schema_version': 2,
    'mode': mode,
    'coverage_envelope': {'measured_top_level_roots': 5, 'reachable_top_level_roots': 10},
    'disk_used_kb': 1000,
    'residual_kb': 1000,
    'granularity_buckets': [],
    'oversize_indivisible_files': [],
    'opaque_intrinsic_gates': [],
    'captured_at': captured_at,
}
with open(path, 'w') as f:
    json.dump(ledger, f)
" "$1" "$2" "$3"
}

# --- Case 3: canonical stale, valid fresh partial present -> OK, label=PARTIAL ---
WORK3="$(mktemp -d)"
git init -q "$WORK3/repo"
STATE3="$WORK3/repo"
mkdir -p "$STATE3/ledger"
echo '{"disk_used_kb":1}' > "$STATE3/ledger/topdown-5g.json"
CAPTURED3="$(iso_offset_hours -2)"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED3\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE3/ledger/topdown-5g.status.json"
write_partial "$STATE3/ledger/topdown-5g.partial.json" "$CAPTURED3" "partial"
git -C "$STATE3" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE3" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE3" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "accepts fresh valid partial when canonical stale (label=PARTIAL)" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
rm -rf "$WORK3"

# --- Case 4: canonical stale, partial.json structurally invalid -> STALE ---
WORK4="$(mktemp -d)"
git init -q "$WORK4/repo"
STATE4="$WORK4/repo"
mkdir -p "$STATE4/ledger"
echo '{"disk_used_kb":1}' > "$STATE4/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE4/ledger/topdown-5g.status.json"
echo '{"schema_version":2,"mode":"partial","captured_at":"'"$(iso_offset_hours -1)"'"}' > "$STATE4/ledger/topdown-5g.partial.json"  # missing disk_used_kb/residual_kb/buckets
git -C "$STATE4" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE4" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE4" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "rejects structurally invalid partial ledger (STALE, not falsely OK)" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK4"

# --- Case 5: canonical stale, partial/status same captured_at but disagree -> STALE ---
WORK5="$(mktemp -d)"
git init -q "$WORK5/repo"
STATE5="$WORK5/repo"
mkdir -p "$STATE5/ledger"
echo '{"disk_used_kb":1}' > "$STATE5/ledger/topdown-5g.json"
CAPTURED5="$(iso_offset_hours -1)"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED5\",\"mode\":\"complete\",\"coverage_envelope\":{\"measured_top_level_roots\":9,\"reachable_top_level_roots\":9}}" > "$STATE5/ledger/topdown-5g.status.json"
write_partial "$STATE5/ledger/topdown-5g.partial.json" "$CAPTURED5" "partial"  # same captured_at, mode disagrees with status.json
git -C "$STATE5" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE5" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE5" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_reconciliation_mismatch* ]] \
  && ok "rejects partial/status.json same-timestamp disagreement (reconciliation)" \
  || bad "expected STALE rc=1 reconciliation_mismatch got rc=$rc out=$out"
rm -rf "$WORK5"

# --- Case 6: canonical stale, partial has a future captured_at -> STALE ---
WORK6="$(mktemp -d)"
git init -q "$WORK6/repo"
STATE6="$WORK6/repo"
mkdir -p "$STATE6/ledger"
echo '{"disk_used_kb":1}' > "$STATE6/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE6/ledger/topdown-5g.status.json"
write_partial "$STATE6/ledger/topdown-5g.partial.json" "$(iso_offset_hours 5)" "partial"
git -C "$STATE6" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE6" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE6" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "rejects future-timestamped partial ledger" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK6"

# --- Case 7: canonical never published (no commit at all), valid fresh partial -> OK ---
WORK7="$(mktemp -d)"
git init -q "$WORK7/repo"
STATE7="$WORK7/repo"
mkdir -p "$STATE7/ledger"
CAPTURED7="$(iso_offset_hours -1)"
write_partial "$STATE7/ledger/topdown-5g.partial.json" "$CAPTURED7" "partial"
git -C "$STATE7" add ledger/topdown-5g.partial.json
git -C "$STATE7" -c user.email=t@test -c user.name=t commit -q -m "init (no canonical yet)"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE7" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "accepts fresh valid partial when canonical never published" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
rm -rf "$WORK7"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

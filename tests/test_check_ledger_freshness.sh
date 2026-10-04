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

iso_offset_hours() {
  python3 -c "
import datetime, sys
dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=float(sys.argv[1]))
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

python3 -c "
import json, sys
now_iso = sys.argv[1]
home = '/Users/testuser'
probes = {
    'mobile_sync': home + '/Library/Application Support/MobileSync/Backup',
    'mail': home + '/Library/Mail',
    'messages': home + '/Library/Messages',
}
ledger = {
    'schema_version': 2,
    'mode': 'complete',
    'coverage_envelope': {
        'complete': True,
        'status': 'complete',
        'fda_preflight_status': 'granted',
        'fda_user_preflight_status': 'granted',
        'reachable_top_level_roots': 1,
        'measured_top_level_roots': 1,
        'unfinished_top_level_roots': 0,
    },
    'fda_probe_paths': probes,
    'fda_preflight': {
        'status': 'granted',
        'probes': {k: {'path': v, 'status': 'readable'} for k, v in probes.items()},
    },
    'disk_used_kb': 1000,
    'residual_kb': 0,
    'granularity_buckets': [{'path': '/Users/testuser/a', 'measured_kb': 1000, 'kind': 'dir'}],
    'oversize_indivisible_files': [],
    'opaque_intrinsic_gates': [],
    'frontier_unfinished': [],
    'accounting_equation': {
        'data_used_kb': 1000,
        'displayed_buckets_kb': 1000,
        'oversize_indivisible_files_kb': 0,
        'sub_granularity_tail_kb': 0,
        'purgeable_kb': 0,
        'residual_kb': 0,
        'clone_shared_adjustment_kb': 0,
        'displayed_balanced': True,
        'display_ledger_valid': True,
    },
    'captured_at': now_iso,
}
with open('$STATE/ledger/topdown-5g.json', 'w') as f:
    json.dump(ledger, f)
" "$(iso_offset_hours 0)"
echo '{"status":"published","reason":"complete_coverage"}' > "$STATE/ledger/topdown-5g.status.json"
git -C "$STATE" add ledger/topdown-5g.json ledger/topdown-5g.status.json
git -C "$STATE" -c user.email=t@test -c user.name=t commit -q -m "init ledger"

# Case 1: Backdate commit metadata by setting an old commit time via env is hard; instead
# use STALE_HOURS=-1 so any commit is immediately stale.
export DISK_MAGICIAN_STATE_REPO="$STATE"
export DISK_MAGICIAN_LEDGER_STALE_HOURS=-1
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] && ok "flags stale when threshold -1h" || bad "expected STALE rc=1 got rc=$rc out=$out"

# Case 2: Fresh with huge threshold
export DISK_MAGICIAN_LEDGER_STALE_HOURS=99999
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* ]] && ok "OK within 99999h window" || bad "expected OK rc=0 got rc=$rc out=$out"

unset DISK_MAGICIAN_LEDGER_STALE_HOURS


write_partial() {
  python3 -c "
import json, sys
path, captured_at, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = {
    'schema_version': 2,
    'mode': mode,
    'coverage_envelope': {'measured_top_level_roots': 5, 'reachable_top_level_roots': 10},
    'disk_used_kb': 1000,
    'residual_kb': 500,
    'granularity_buckets': [{'path': '/a', 'measured_kb': 500}],
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
echo '{"schema_version":2,"mode":"partial","captured_at":"'"$(iso_offset_hours -1)"'"}' > "$STATE4/ledger/topdown-5g.partial.json"
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
write_partial "$STATE5/ledger/topdown-5g.partial.json" "$CAPTURED5" "partial"
git -C "$STATE5" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE5" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE5" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_reconciliation_mismatch* ]] \
  && ok "rejects partial/status.json same-timestamp disagreement (reconciliation)" \
  || bad "expected STALE rc=1 reconciliation_mismatch got rc=$rc out=$out"
rm -rf "$WORK5"

# --- Case 6: rejects future-timestamped partial ledger ---
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

# --- Case 8: malformed (non-dict) partial ledger must never crash ---
WORK8="$(mktemp -d)"
git init -q "$WORK8/repo"
STATE8="$WORK8/repo"
mkdir -p "$STATE8/ledger"
echo '{"disk_used_kb":1}' > "$STATE8/ledger/topdown-5g.json"
echo '[1,2]' > "$STATE8/ledger/topdown-5g.partial.json"
git -C "$STATE8" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE8" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE8" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" != *Traceback* ]] \
  && ok "non-dict partial ledger never crashes; STALE alert still fires" \
  || bad "expected clean STALE rc=1 (no traceback) got rc=$rc out=$out"
rm -rf "$WORK8"

# --- Case 9: unparseable status.json fails closed ---
WORK9="$(mktemp -d)"
git init -q "$WORK9/repo"
STATE9="$WORK9/repo"
mkdir -p "$STATE9/ledger"
echo '{"disk_used_kb":1}' > "$STATE9/ledger/topdown-5g.json"
echo 'not{valid json' > "$STATE9/ledger/topdown-5g.status.json"
write_partial "$STATE9/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE9" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE9" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE9" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_unreadable* ]] \
  && ok "unparseable (but present) status.json fails closed, not silently accepted" \
  || bad "expected STALE rc=1 status_unreadable got rc=$rc out=$out"
rm -rf "$WORK9"

# --- Case 10: non-object status.json fails closed ---
WORK10="$(mktemp -d)"
git init -q "$WORK10/repo"
STATE10="$WORK10/repo"
mkdir -p "$STATE10/ledger"
echo '{"disk_used_kb":1}' > "$STATE10/ledger/topdown-5g.json"
echo '[1,2,3]' > "$STATE10/ledger/topdown-5g.status.json"
write_partial "$STATE10/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE10" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE10" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE10" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_malformed* ]] \
  && ok "non-object status.json fails closed, not silently accepted" \
  || bad "expected STALE rc=1 status_malformed got rc=$rc out=$out"
rm -rf "$WORK10"

# --- Case 11: absent status.json allows fresh valid partial through ---
WORK11="$(mktemp -d)"
git init -q "$WORK11/repo"
STATE11="$WORK11/repo"
mkdir -p "$STATE11/ledger"
echo '{"disk_used_kb":1}' > "$STATE11/ledger/topdown-5g.json"
write_partial "$STATE11/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE11" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE11" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE11" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "absent status.json (no reconciliation target) still accepts a fresh valid partial" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
rm -rf "$WORK11"

# --- Case 12: structurally-valid but functionally empty partial ledger rejected ---
WORK12="$(mktemp -d)"
git init -q "$WORK12/repo"
STATE12="$WORK12/repo"
mkdir -p "$STATE12/ledger"
echo '{"disk_used_kb":1}' > "$STATE12/ledger/topdown-5g.json"
python3 -c "
import json
ledger = {
    'schema_version': 2, 'mode': 'partial',
    'coverage_envelope': {'measured_top_level_roots': 0, 'reachable_top_level_roots': 40},
    'disk_used_kb': 500000000, 'residual_kb': 500000000,
    'granularity_buckets': [], 'oversize_indivisible_files': [], 'opaque_intrinsic_gates': [],
    'captured_at': '$(iso_offset_hours -1)',
}
json.dump(ledger, open('$STATE12/ledger/topdown-5g.partial.json', 'w'))
"
git -C "$STATE12" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE12" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE12" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *empty_scan* ]] \
  && ok "rejects a structurally-valid but empty (0 roots measured) partial ledger" \
  || bad "expected STALE rc=1 empty_scan got rc=$rc out=$out"
rm -rf "$WORK12"

# --- Case 13: floor recently committed but old capture timestamp in canonical -> STALE ---
WORK13="$(mktemp -d)"
git init -q "$WORK13/repo"
STATE13="$WORK13/repo"
mkdir -p "$STATE13/ledger"
ANCIENT_CAPTURED="$(iso_offset_hours -500)" # 500 hours old capture
echo "{\"disk_used_kb\":1000,\"captured_at\":\"$ANCIENT_CAPTURED\"}" > "$STATE13/ledger/topdown-5g.json"
git -C "$STATE13" add ledger/topdown-5g.json
# Fresh commit timestamp (right now)
git -C "$STATE13" -c user.email=t@test -c user.name=t commit -q -m "fresh commit of ancient capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE13" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "recently committed canonical ledger with old capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK13"

# --- Case 14: recently committed canonical ledger with missing capture timestamp -> STALE ---
WORK14="$(mktemp -d)"
git init -q "$WORK14/repo"
STATE14="$WORK14/repo"
mkdir -p "$STATE14/ledger"
echo '{"disk_used_kb":1}' > "$STATE14/ledger/topdown-5g.json"
git -C "$STATE14" add ledger/topdown-5g.json
git -C "$STATE14" -c user.email=t@test -c user.name=t commit -q -m "fresh commit missing capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE14" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "recently committed canonical ledger with missing capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK14"

# --- Case 15: canonical ledger with future capture timestamp -> STALE ---
WORK15="$(mktemp -d)"
git init -q "$WORK15/repo"
STATE15="$WORK15/repo"
mkdir -p "$STATE15/ledger"
FUTURE_CAPTURED="$(iso_offset_hours 5)"
echo "{\"disk_used_kb\":1000,\"captured_at\":\"$FUTURE_CAPTURED\"}" > "$STATE15/ledger/topdown-5g.json"
git -C "$STATE15" add ledger/topdown-5g.json
git -C "$STATE15" -c user.email=t@test -c user.name=t commit -q -m "future capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE15" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "canonical ledger with future capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK15"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1

#!/usr/bin/env bash
# test_snapshot_coverage_fields.sh — fresh/carried/unmeasured coverage fields (spec 2026-10-03).
# Scratch HOME + DISK_MAGICIAN_STATE_DIR; df is stubbed so percentages are exact.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP="$REPO_ROOT/scripts/disk_snapshot.sh"
WORK="$(mktemp -d -t dm_cov_fields.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

H="$WORK/home"; BIN="$WORK/bin"; STATE="$WORK/state"
mkdir -p "$H/.claude/projects" "$H/projects" "$H/other" "$H/gone" "$BIN" "$STATE"

# df: 1000 GB total, 100,000,000 KB used (so 1,000,000 KB == 1.0%).
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1000000000 100000000 900000000 10%% /\n'
SH
# dua: STUB_SIZES="suffix:kb,..." ; STUB_TIMEOUT="suffix,..." -> exit 124.
cat > "$BIN/dua" <<'SH'
#!/usr/bin/env bash
p="${@: -1}"
IFS=, read -ra T <<< "${STUB_TIMEOUT:-}"; for s in "${T[@]}"; do [[ -n "$s" && "$p" == *"$s" ]] && exit 124; done
IFS=, read -ra Z <<< "${STUB_SIZES:-}"
for e in "${Z[@]}"; do [[ "$p" == *"${e%%:*}" ]] && { printf '%s b total\n' $(( ${e##*:} * 1024 )); exit 0; }; done
printf '%s b total\n' 1024
SH
printf '#!/usr/bin/env bash\nexit 124\n' > "$BIN/du"
chmod +x "$BIN/df" "$BIN/dua" "$BIN/du"

CFG="$WORK/config.json"
cat > "$CFG" <<JSON
{"monitored_dirs": [
 {"key": "claude_root", "path": "$H/.claude", "timeout": 10},
 {"key": "claude_projects", "path": "$H/.claude/projects", "timeout": 10},
 {"key": "projects", "path": "$H/projects", "timeout": 10},
 {"key": "other", "path": "$H/other", "timeout": 10},
 {"key": "gone", "path": "$H/gone", "timeout": 10}
]}
JSON

# seed_state key:kb:hours_ago[:path] ...
seed_state() {
  python3 - "$STATE/last_good_measurements.json" "$H" "$@" <<'PY'
import datetime, json, sys
out, home, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
now = datetime.datetime.now(datetime.timezone.utc)
paths = {"claude_root": home + "/.claude", "claude_projects": home + "/.claude/projects",
         "projects": home + "/projects", "other": home + "/other", "gone": home + "/gone"}
d = {}
for s in specs:
    k, kb, hrs = s.split(":")[:3]
    d[k] = {"kb": int(kb), "measured_at": (now - datetime.timedelta(hours=float(hrs))).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "path": paths[k], "source": "du"}
json.dump(d, open(out, "w"))
PY
}

run_snap() { # out env...
  local out="$1"; shift
  env HOME="$H" PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin" DISK_MAGICIAN_CONFIG="$CFG" \
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=1 \
    DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=60 "$@" \
    timeout 50 bash "$SNAP" --output "$out" >"$WORK/stdout" 2>"$WORK/stderr"
}
py() { python3 - "$1" "$2" 2>"$WORK/pyerr"; }   # py file 'python expr block using d'
check() { # name file code
  local name="$1" file="$2" code="$3"
  if python3 - "$file" <<PY 2>"$WORK/pyerr"
import json, sys
d = json.load(open(sys.argv[1]))
$code
PY
  then ok "$name"; else bad "$name ($(tail -1 "$WORK/pyerr"))"; fi
}

SIZES="claude_root:30000000,claude_projects:10000000,projects:40000000,other:5000000,gone:1000000"

echo "── baseline: nothing times out ──"
rm -f "$STATE/last_good_measurements.json"
O="$WORK/a.json"; run_snap "$O" STUB_SIZES="$SIZES"
check "test_fresh_pct_equals_legacy_snapshot_coverage_pct" "$O" \
  "assert d['coverage_fresh_pct'] == d['snapshot_coverage_pct'] and d['snapshot_coverage_pct'] > 0"
check "test_schema_version_still_2" "$O" "assert d['schema_version'] == 2 and d['carried_keys'] == [] and d['unmeasured_keys'] == []"

echo "── one parent key times out, carried 10h ──"
seed_state claude_root:30000000:10
O="$WORK/b.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/.claude,/gone"
check "test_carried_key_in_carried_keys_with_age_and_null_in_directories" "$O" "
c = {x['key']: x for x in d['carried_keys']}
assert 'claude_root' in c and 9.5 <= c['claude_root']['age_hours'] <= 10.5 and c['claude_root']['kb'] == 30000000
assert d['directories']['claude_root'] is None"
check "test_no_null_directory_without_carried_or_unmeasured_entry" "$O" "
listed = {x['key'] for x in d['carried_keys']} | set(d['unmeasured_keys'])
nulls = {k for k, v in d['directories'].items() if v is None}
assert nulls and nulls <= listed, (nulls, listed)
assert 'gone' in d['unmeasured_keys']"
check "test_effective_equals_fresh_plus_carried" "$O" "
assert abs(d['coverage_effective_pct'] - (d['coverage_fresh_pct'] + d['coverage_carried_pct'])) <= 0.11
assert d['coverage_carried_pct'] == 0 or d['coverage_carried_pct'] > 0"
check "test_null_or_carried_parent_does_not_hide_fresh_child" "$O" "
# claude_projects (10,000,000 KB = 10%) is fresh even though its parent timed out
assert d['directories']['claude_projects'] == 10000000
assert d['coverage_fresh_pct'] >= 54.9, d['coverage_fresh_pct']   # projects 40 + other 5 + child 10 (+ gone timed out)
assert d['coverage_carried_pct'] == 0, d['coverage_carried_pct']  # carried parent overlaps a fresh child -> dropped"

echo "── carried child under a fresh parent ──"
seed_state claude_projects:10000000:5
O="$WORK/c.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/.claude/projects"
check "test_dedup_does_not_double_count_carried_child_of_fresh_parent" "$O" "
assert d['coverage_carried_pct'] == 0
assert 'claude_projects' in {x['key'] for x in d['carried_keys']}"

echo "── two overlapping carried keys count once ──"
seed_state claude_root:30000000:5 claude_projects:10000000:5
O="$WORK/d.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/.claude,/.claude/projects"
check "test_two_carried_overlapping_keys_count_once" "$O" "
assert abs(d['coverage_carried_pct'] - 30.0) <= 0.11, d['coverage_carried_pct']"

echo "── warnings ──"
seed_state claude_root:30000000:10 claude_projects:10000000:10 gone:1000000:10
O="$WORK/e.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/.claude/projects,/.claude,/gone"
# fresh = projects 40 + other 5 = 45 (<70); carried = 30 (claude_root; child dropped) + gone 1 = 31 -> effective 76
check "test_warning_low_coverage_uses_effective" "$O" "
assert d['coverage_fresh_pct'] < 70 <= d['coverage_effective_pct'], (d['coverage_fresh_pct'], d['coverage_effective_pct'])
assert d.get('snapshot_warning', '') == ''"
seed_state claude_root:30000000:30 claude_projects:10000000:30 gone:1000000:30
O="$WORK/f.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/.claude/projects,/.claude,/gone"
check "test_warning_degraded_carry_when_carry_over_24h" "$O" "assert d.get('snapshot_warning') == 'degraded_carry', d.get('snapshot_warning')"

echo "── gap / unconfigured split ──"
seed_state gone:5000000:100
O="$WORK/g.json"; run_snap "$O" STUB_SIZES="$SIZES" STUB_TIMEOUT="/gone"
check "test_timeout_gap_and_unconfigured_split" "$O" "
assert abs(d['coverage_timeout_gap_pct'] - 5.0) <= 0.11, d['coverage_timeout_gap_pct']
total = d['coverage_effective_pct'] + d['coverage_timeout_gap_pct'] + d['coverage_unconfigured_pct']
assert abs(total - 100) <= 0.3, total"

echo "── frontier pct ──"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "{\"captured_at\": \"$NOW\", \"mode\": \"partial\", \"measured_total_kb\": 50000000}" > "$STATE/frontier_last.json"
O="$WORK/h.json"; run_snap "$O" STUB_SIZES="$SIZES"
check "test_frontier_pct_present_when_fresh" "$O" "assert abs(d['coverage_frontier_pct'] - 50.0) <= 0.11"
echo "{\"captured_at\": \"2020-01-01T00:00:00Z\", \"mode\": \"partial\", \"measured_total_kb\": 50000000}" > "$STATE/frontier_last.json"
O="$WORK/i.json"; run_snap "$O" STUB_SIZES="$SIZES"
check "test_frontier_pct_absent_when_stale" "$O" "assert 'coverage_frontier_pct' not in d"

echo "── carry state written only from fresh values ──"
check_state() { python3 -c "import json; d=json.load(open('$STATE/last_good_measurements.json')); assert d['projects']['kb']==40000000"; }
check_state 2>/dev/null && ok "carry file updated after a run" || bad "carry file missing/incorrect after run"

echo; echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

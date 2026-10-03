#!/usr/bin/env bash
# test_snapshot_measure_fallback.sh — serial fallback, deadlines and ordering of the snapshot measurement phases.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP="$REPO_ROOT/scripts/disk_snapshot.sh"
WORK="$(mktemp -d -t dm_measure_fb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

H="$WORK/home"; BIN="$WORK/bin"; STATE="$WORK/state"
mkdir -p "$H/a" "$H/b" "$H/Library/Containers/appone" "$H/globdir1" "$BIN" "$STATE"
CALLS="$WORK/calls.log"
cat > "$BIN/dua" <<'SH'
#!/usr/bin/env bash
echo "dua ${@: -1}" >> "${CALLS:?}"
printf '%s b total\n' 2097152
SH
cat > "$BIN/du" <<'SH'
#!/usr/bin/env bash
echo "du ${@: -1}" >> "${CALLS:?}"
for a in "$@"; do [[ "$a" == -* ]] && continue; printf '4096\t%s\n' "$a"; done
SH
chmod +x "$BIN/dua" "$BIN/du"
CFG="$WORK/config.json"
cat > "$CFG" <<JSON
{"monitored_dirs": [{"key": "a", "path": "$H/a", "timeout": 10}, {"key": "b", "path": "$H/b", "timeout": 10}],
 "monitored_globs": [{"key": "globs", "pattern": "$H/globdir*"}]}
JSON

run_snap() { local out="$1"; shift
  : > "$CALLS"
  env HOME="$H" PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin" CALLS="$CALLS" DISK_MAGICIAN_CONFIG="$CFG" \
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=1 DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=100 "$@" \
    timeout 80 bash "$SNAP" --output "$out" >"$WORK/stdout" 2>"$WORK/stderr"; }
jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

echo "── test_serial_fallback_on_orchestrator_failure ──"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n' > "$WORK/fail_orch.py"; chmod +x "$WORK/fail_orch.py"
run_snap "$WORK/fb.json" DISK_MAGICIAN_MEASURE_WORKERS=3 DISK_MAGICIAN_MEASURE_ORCHESTRATOR="$WORK/fail_orch.py"
[[ "$(jget "$WORK/fb.json" "d['snapshot_metadata']['measure_mode']")" == serial_fallback && \
   "$(jget "$WORK/fb.json" "d['directories']['a']")" == 2048 ]] \
  && ok "failed orchestrator -> serial loop still measures; measure_mode=serial_fallback" \
  || bad "serial fallback failed ($(head -c 200 "$WORK/stderr"))"

echo "── parallel mode by default, serial when workers=0 ──"
run_snap "$WORK/par.json" DISK_MAGICIAN_MEASURE_WORKERS=2
[[ "$(jget "$WORK/par.json" "d['snapshot_metadata']['measure_mode']")" == parallel && \
   "$(jget "$WORK/par.json" "d['snapshot_metadata']['measure_workers']")" == 2 && \
   "$(jget "$WORK/par.json" "d['directories']['b']")" == 2048 ]] \
  && ok "parallel mode measures dirs through the orchestrator (measure_workers=2)" || bad "parallel mode wrong"
run_snap "$WORK/ser.json" DISK_MAGICIAN_MEASURE_WORKERS=0
[[ "$(jget "$WORK/ser.json" "d['snapshot_metadata']['measure_mode']")" == serial ]] \
  && ok "workers=0 -> measure_mode=serial" || bad "workers=0 did not select serial"

echo "── test_frontier_and_lc_run_before_globs ──"
run_snap "$WORK/ord.json" DISK_MAGICIAN_MEASURE_WORKERS=0
lc_line=$(grep -n "Containers/appone\|Library/Containers" "$CALLS" | head -1 | cut -d: -f1)
glob_line=$(grep -n "globdir1" "$CALLS" | head -1 | cut -d: -f1)
[[ -n "$lc_line" && -n "$glob_line" && "$lc_line" -lt "$glob_line" ]] \
  && ok "lc_* measured before globs" || bad "order wrong (lc=$lc_line glob=$glob_line)"

echo "── test_null_glob_key_listed_in_unmeasured ──"
printf '#!/usr/bin/env bash\nexit 124\n' > "$BIN/du"
printf '#!/usr/bin/env bash\nexit 124\n' > "$BIN/dua"
run_snap "$WORK/ng.json" DISK_MAGICIAN_MEASURE_WORKERS=0
[[ "$(jget "$WORK/ng.json" "'globs' in d['unmeasured_keys'] and d['directories']['globs'] is None")" == True ]] \
  && ok "timed-out glob key is reported unmeasured" || bad "null glob not in unmeasured_keys"

echo "── test_orchestrator_deadline_is_min_of_640_and_measurement_deadline ──"
cat > "$WORK/dump_orch.py" <<PY
#!/usr/bin/env python3
import sys, json
open("$WORK/orch_args.json", "w").write(json.dumps(sys.argv[1:]))
sys.exit(3)
PY
chmod +x "$WORK/dump_orch.py"
start=$(date +%s)
run_snap "$WORK/dl.json" DISK_MAGICIAN_MEASURE_WORKERS=2 DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=100 DISK_MAGICIAN_MEASURE_ORCHESTRATOR="$WORK/dump_orch.py"
dl=$(python3 -c "import json; a=json.load(open('$WORK/orch_args.json')); print(a[a.index('--deadline-epoch')+1])")
[[ "$dl" -le $((start + 105)) && "$dl" -ge $((start + 90)) ]] \
  && ok "orchestrator deadline = measurement deadline (start+100) when budget < 640" || bad "deadline arg $dl vs start $start"

echo "── test_serial_remainder_bounded_by_860s_measurement_deadline ──"
run_snap "$WORK/ph.json" DISK_MAGICIAN_MEASURE_WORKERS=0 DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=1500 DISK_MAGICIAN_PHASE_SCALE=0.01
[[ "$(jget "$WORK/ph.json" "d['snapshot_metadata']['measurement_budget_seconds']")" == 1500 && \
   "$(jget "$WORK/ph.json" "d['snapshot_metadata']['measurement_elapsed_seconds'] <= 12")" == True ]] \
  && ok "measurement deadline = min(budget, 860*scale); budget metadata still reports 1500" || bad "phase scale / budget metadata wrong"

echo; echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# test_snapshot_partial_coverage.sh — du EACCES/ENOENT lower bound, honest residual under carry-forward,
# and partial-publication marking for low-coverage snapshots.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP="$REPO_ROOT/scripts/disk_snapshot.sh"
WORK="$(mktemp -d -t dm_partial_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

H="$WORK/home"; BIN="$WORK/bin"; STATE="$WORK/state"
mkdir -p "$H/eacces" "$H/enoent" "$H/mixed" "$H/clean" "$BIN" "$STATE"
# du stub: eacces/enoent exit 1 with only those errors; mixed also reports EPERM.
cat > "$BIN/du" <<'SH'
#!/usr/bin/env bash
p="${@: -1}"
case "$p" in
  */eacces) printf '2048\t%s\n' "$p"; echo "du: $p/locked: Permission denied" >&2; exit 1 ;;
  */enoent) printf '2048\t%s\n' "$p"; echo "du: $p/gone: No such file or directory" >&2; exit 1 ;;
  */mixed)  printf '2048\t%s\n' "$p"; echo "du: $p/a: Permission denied" >&2; echo "du: $p/b: Operation not permitted" >&2; exit 1 ;;
  *) printf '2048\t%s\n' "$p" ;;
esac
SH
chmod +x "$BIN/du"
# df stub: tiny disk so tracked bytes decide coverage (used=${DF_USED_KB}).
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x %s %s %s 50%% /\n' "$((DF_USED_KB*2))" "$DF_USED_KB" "$DF_USED_KB"
SH
chmod +x "$BIN/df"
CFG="$WORK/config.json"
cat > "$CFG" <<JSON
{"monitored_dirs": [{"key": "eacces", "path": "$H/eacces", "timeout": 10}, {"key": "enoent", "path": "$H/enoent", "timeout": 10},
 {"key": "mixed", "path": "$H/mixed", "timeout": 10}, {"key": "clean", "path": "$H/clean", "timeout": 10}]}
JSON

run_snap() { local out="$1"; shift
  env HOME="$H" PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin" DF_USED_KB="${DF_USED_KB:-100000}" DISK_MAGICIAN_CONFIG="$CFG" \
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=1 DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=100 "$@" \
    timeout 80 bash "$SNAP" --output "$out" >"$WORK/stdout" 2>"$WORK/stderr"; }
jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

for mode in 2 0; do
  echo "── workers=$mode: du exit 1 with only EACCES/ENOENT stderr is a lower bound ──"
  rm -f "$STATE/last_good_measurements.json"
  run_snap "$WORK/lb$mode.json" DISK_MAGICIAN_MEASURE_WORKERS=$mode
  [[ "$(jget "$WORK/lb$mode.json" "d['directories']['eacces'],d['directories']['enoent']")" == "(2048, 2048)" ]] \
    && ok "EACCES-only and ENOENT-only du totals are recorded" || bad "lower-bound totals missing ($(head -c 200 "$WORK/stderr"))"
  [[ "$(jget "$WORK/lb$mode.json" "sorted(d['snapshot_metadata']['lower_bound_keys'])")" == "['eacces', 'enoent']" ]] \
    && ok "lower_bound_keys lists exactly the lower-bound paths" || bad "lower_bound_keys wrong"
  [[ "$(jget "$WORK/lb$mode.json" "d['directories']['mixed'] is None")" == True ]] \
    && ok "any other stderr line (EPERM) still fails the path" || bad "mixed-stderr path was accepted"
done

echo "── failed path is carried and residual uses fresh + carried ──"
python3 - "$STATE/last_good_measurements.json" "$H/mixed" <<'PY'
import json, sys, datetime
now = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"mixed": {"kb": 50 * 1024 * 1024, "measured_at": now, "path": sys.argv[2], "source": "du"}}, open(sys.argv[1], "w"))
PY
DF_USED_KB=$((120 * 1024 * 1024)) run_snap "$WORK/carry.json" DISK_MAGICIAN_MEASURE_WORKERS=2
[[ "$(jget "$WORK/carry.json" "[c['key'] for c in d['carried_keys']]")" == "['mixed']" ]] \
  && ok "failed path carried from last good value" || bad "mixed not carried"
[[ "$(jget "$WORK/carry.json" "round(d['residual_fresh_gb'] - d['residual_gb'])")" == 50 ]] \
  && ok "residual_gb subtracts the 50 GiB carried value; residual_fresh_gb keeps fresh-only" || bad "residual not carry-adjusted"

echo "── fresh+carried coverage < 70% is marked partial, >= 70% complete ──"
DF_USED_KB=$((120 * 1024 * 1024)) run_snap "$WORK/low.json" DISK_MAGICIAN_MEASURE_WORKERS=2
[[ "$(jget "$WORK/low.json" "(d['publication_kind'],d['canonical'])")" == "('partial', False)" ]] \
  && ok "low effective coverage -> publication_kind=partial, canonical=false" || bad "low coverage not marked partial"
rm -f "$STATE/last_good_measurements.json"
DF_USED_KB=7000 run_snap "$WORK/high.json" DISK_MAGICIAN_MEASURE_WORKERS=2
[[ "$(jget "$WORK/high.json" "(d['publication_kind'],d['canonical'])")" == "('complete', True)" ]] \
  && ok "adequate coverage -> publication_kind=complete, canonical=true" || bad "high coverage not complete ($(jget "$WORK/high.json" "d['snapshot_coverage_pct']"))"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

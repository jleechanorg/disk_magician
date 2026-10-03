#!/usr/bin/env bash
# test_snapshot_path_budget.sh — honest per-path timeout budget (spec 2026-10-03).
# Everything runs under a scratch HOME / state dir; never touches production state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP="$REPO_ROOT/scripts/disk_snapshot.sh"
LIB="$REPO_ROOT/scripts/lib/snapshot_budget.sh"

WORK="$(mktemp -d -t dm_path_budget.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

HOME_DIR="$WORK/home"; BIN="$WORK/bin"; STATE="$WORK/state"
mkdir -p "$HOME_DIR/target" "$BIN" "$STATE" "$HOME_DIR/.config/disk-magician"
CFG="$WORK/config.json"
LOG="$WORK/calls.log"

# dua stub: sleeps STUB_SLEEP, then reports 2 MiB (or fails first N calls).
cat > "$BIN/dua" <<'SH'
#!/usr/bin/env bash
echo "dua $*" >> "${STUB_LOG:?}"
if [[ -n "${STUB_FAIL_FIRST:-}" ]]; then
  n=0; [[ -f "$STUB_STATE_FILE" ]] && read -r n < "$STUB_STATE_FILE"
  n=$((n + 1)); echo "$n" > "$STUB_STATE_FILE"
  (( n <= STUB_FAIL_FIRST )) && exit 124
fi
sleep "${STUB_SLEEP:-0}"
printf '%s b total\n' 2097152
SH
# du stub: slow when STUB_SLEEP is set, prints one row per path argument.
cat > "$BIN/du" <<'SH'
#!/usr/bin/env bash
[[ -n "${STUB_DU_FAIL:-}" ]] && exit 124
sleep "${STUB_SLEEP:-0}"
for a in "$@"; do [[ "$a" == -* ]] && continue; printf '4096\t%s\n' "$a"; done
SH
chmod +x "$BIN/dua" "$BIN/du"

write_cfg() { # key timeout [extra json]
  cat > "$CFG" <<JSON
{"monitored_dirs": [{"key": "$1", "path": "$HOME_DIR/target", "timeout": $2 ${3:-}}]}
JSON
}

run_snap() { # out.json [env assignments...]
  local out="$1"; shift
  env HOME="$HOME_DIR" PATH="$BIN:/opt/homebrew/bin:/usr/bin:/bin" \
    DISK_MAGICIAN_CONFIG="$CFG" DISK_MAGICIAN_STATE_DIR="$STATE" \
    DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=1 STUB_LOG="$LOG" STUB_STATE_FILE="$WORK/fail_count" \
    DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=60 "$@" \
    timeout 50 bash "$SNAP" --output "$out" >"$WORK/stdout" 2>"$WORK/stderr"
}
jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

echo "── test_zero_clamp_honors_config_timeout ──"
: > "$LOG"; write_cfg slow 10
OUT="$WORK/zero.json"
run_snap "$OUT" DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=0 STUB_SLEEP=3
[[ "$(jget "$OUT" "d['directories']['slow']")" == 2048 ]] \
  && ok "clamp 0 accepted and a 3s measurement under a 10s config timeout is non-null" \
  || bad "clamp 0 rejected or value null ($(head -c 200 "$WORK/stderr"))"

echo "── default is unclamped and dua gets the configured budget ──"
: > "$LOG"; write_cfg big 100
OUT="$WORK/default.json"
run_snap "$OUT"
[[ "$(jget "$OUT" "d['snapshot_metadata']['measurement_path_max_seconds']")" == 0 ]] \
  && ok "test_metadata_reports_unclamped (default 0)" || bad "metadata path_max_seconds is not 0 by default"

echo "── test_positive_clamp_still_applies ──"
: > "$LOG"; write_cfg slow 10
OUT="$WORK/pos.json"
run_snap "$OUT" DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=1 STUB_SLEEP=3
[[ "$(jget "$OUT" "d['directories']['slow']")" == None ]] \
  && ok "clamp 1 with a 3s stub yields null" || bad "positive clamp did not apply"

echo "── test_load_scale_budget ──"
if [[ -f "$LIB" ]]; then
  # shellcheck source=/dev/null
  source "$LIB"
  a="$(scaled_path_budget 100 2)"; b="$(scaled_path_budget 200 2)"; c="$(scaled_path_budget 300 1)"
  [[ "$a" == 200 && "$b" == 240 && "$c" == 240 ]] \
    && ok "budget = min(240, config*factor) (100x2=200, 200x2=240, 300x1=240)" \
    || bad "scaled_path_budget wrong: $a $b $c"
  f1="$(DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=9 load_factor)"; f2="$(DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE=0.2 load_factor)"
  [[ "$f1" == 3* && "$f2" == 1* ]] && ok "load_factor clamps to [1,3]" || bad "load_factor clamp wrong: $f1 $f2"
else
  bad "scripts/lib/snapshot_budget.sh missing"; bad "load_factor missing"
fi

echo "── test_every_key_retries_once ──"
: > "$LOG"; rm -f "$WORK/fail_count"; write_cfg flaky 10
OUT="$WORK/retry.json"
run_snap "$OUT" STUB_FAIL_FIRST=1 STUB_DU_FAIL=1
[[ "$(jget "$OUT" "d['directories']['flaky']")" == 2048 ]] \
  && ok "first attempt fails, serial retry recovers the key (no retry_timeout configured)" \
  || bad "no generic retry (got $(jget "$OUT" "d['directories']['flaky']"))"

echo "── test_containers_budget_nonzero_when_clamp_zero ──"
mkdir -p "$HOME_DIR/Library/Containers/appone"
: > "$LOG"; write_cfg x 10
OUT="$WORK/lc.json"
run_snap "$OUT" DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=0
[[ "$(jget "$OUT" "'lc_appone' in d['directories']")" == True ]] \
  && ok "lc_* keys still produced with clamp 0" || bad "lc_* keys dropped with clamp 0"
rm -rf "$HOME_DIR/Library"

echo "── test_user_config_snapshot_measure_overrides ──"
write_cfg x 10
OUT="$WORK/uc1.json"
echo '{"state_repo_path": "/nonexistent", "snapshot_measure": {"path_max_seconds": 33, "workers": 0}}' \
  > "$HOME_DIR/.config/disk-magician/config.json"
run_snap "$OUT"
[[ "$(jget "$OUT" "d['snapshot_metadata']['measurement_path_max_seconds']")" == 33 ]] \
  && ok "user config path_max_seconds=33 is honored" || bad "user config not honored"
OUT="$WORK/uc2.json"
run_snap "$OUT" DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=5
[[ "$(jget "$OUT" "d['snapshot_metadata']['measurement_path_max_seconds']")" == 5 ]] \
  && ok "env beats user config" || bad "env did not override user config"
OUT="$WORK/uc3.json"
echo '{"snapshot_measure": {"path_max_seconds": 7}}' > "$WORK/other.json"
run_snap "$OUT" DISK_MAGICIAN_USER_CONFIG="$WORK/other.json"
[[ "$(jget "$OUT" "d['snapshot_metadata']['measurement_path_max_seconds']")" == 7 ]] \
  && ok "DISK_MAGICIAN_USER_CONFIG selects the file" || bad "DISK_MAGICIAN_USER_CONFIG ignored"
OUT="$WORK/uc4.json"
mkdir -p "$WORK/xdg/disk-magician"; echo '{"snapshot_measure": {"path_max_seconds": 9}}' > "$WORK/xdg/disk-magician/config.json"
run_snap "$OUT" XDG_CONFIG_HOME="$WORK/xdg"
[[ "$(jget "$OUT" "d['snapshot_metadata']['measurement_path_max_seconds']")" == 9 ]] \
  && ok "XDG_CONFIG_HOME location honored" || bad "XDG_CONFIG_HOME ignored"
rm -f "$HOME_DIR/.config/disk-magician/config.json"

echo "── DISK_MAGICIAN_STATE_DIR honored for frontier_last.json ──"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "{\"captured_at\": \"$TS\", \"mode\": \"partial\", \"measured_total_kb\": 5}" > "$STATE/frontier_last.json"
OUT="$WORK/state.json"
run_snap "$OUT"
[[ "$(jget "$OUT" "'topdown_coverage' in d")" == True ]] \
  && ok "state dir override feeds topdown_coverage" || bad "state dir override ignored"

echo; echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

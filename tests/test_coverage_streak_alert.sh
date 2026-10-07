#!/usr/bin/env bash
# test_coverage_streak_alert.sh — sustained-degradation coverage alert (spec 2026-10-03, section 5).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALERT="$REPO_ROOT/scripts/disk_usage_alert.sh"
WORK="$(mktemp -d -t dm_streak.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

H="$WORK/home"; BIN="$WORK/bin"; STATE="$WORK/state"; SNAP="$WORK/snap.json"
mkdir -p "$H" "$BIN" "$STATE"
# Plenty of free space; no ledger so the unrelated ledger/swap alerts stay quiet.
cat > "$BIN/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/x 1000000000 100000000 900000000 10% /"
SH
chmod +x "$BIN/df"

reset() { rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$H/.disk_magician_alert.silenced"; }

# snap TS EFFECTIVE [carried_json] [unmeasured_json] [legacy_only]
snap() {
  python3 - "$SNAP" "$1" "$2" "${3:-[]}" "${4:-[]}" "${5:-}" <<'PY'
import json, sys
out, ts, eff, carried, unmeasured, legacy = sys.argv[1:7]
d = {"schema_version": 2, "timestamp": ts, "snapshot_coverage_pct": float(eff),
     "disk_used_gb": 500, "directories": {}}
if not legacy:
    d.update({"coverage_effective_pct": float(eff), "carried_keys": json.loads(carried),
              "unmeasured_keys": json.loads(unmeasured)})
json.dump(d, open(out, "w"))
PY
}
alert() {
  env HOME="$H" PATH="$BIN:/usr/bin:/bin:/opt/homebrew/bin" DISK_MAGICIAN_SNAPSHOT_FILE="$SNAP" DISK_MAGICIAN_STATE_DIR="$STATE" \
    bash "$ALERT" >"$WORK/out" 2>"$WORK/err"
  echo $?
}
ts() { printf '2026-10-03T%02d:%02d:00Z' $(( $1 / 2 )) $(( ($1 % 2) * 30 )); }
escalated() { grep -q "Snapshot coverage" "$WORK/err"; }

echo "── isolated low run does not escalate ──"
reset; snap "$(ts 1)" 40; rc=$(alert)
[[ "$rc" == 0 ]] && ! escalated && ok "test_no_escalation_for_isolated_low_run" || bad "isolated low run escalated (rc=$rc: $(head -c 200 "$WORK/err"))"

echo "── six consecutive effective < 60 ──"
reset; esc_at=0
for i in 1 2 3 4 5 6 7; do snap "$(ts $i)" 50; rc=$(alert); [[ "$rc" != 0 && $esc_at == 0 ]] && esc_at=$i; done
[[ "$esc_at" == 6 ]] && ok "test_escalates_after_6_consecutive_effective_below_60 (first at run 6)" || bad "escalation started at run $esc_at, expected 6"

echo "── a healthy run breaks the streak ──"
reset
for i in 1 2 3 4 5; do snap "$(ts $i)" 50; alert >/dev/null; done
snap "$(ts 6)" 80; alert >/dev/null; snap "$(ts 7)" 50; rc=$(alert)
[[ "$rc" == 0 ]] && ok "streak resets after an effective >= 60 run" || bad "streak did not reset"

echo "── stale carry > 48h ──"
reset; snap "$(ts 1)" 80 '[{"key":"projects","kb":900,"age_hours":49.0}]'; rc=$(alert)
[[ "$rc" != 0 ]] && escalated && grep -q "projects" "$WORK/err" && ok "test_escalates_when_carry_older_than_48h" || bad "49h carry did not escalate"
reset; snap "$(ts 1)" 80 '[{"key":"projects","kb":900,"age_hours":30.0}]'; rc=$(alert)
[[ "$rc" == 0 ]] && ok "30h carry does not escalate" || bad "30h carry escalated"

echo "── carry expires to unmeasured ──"
reset; snap "$(ts 1)" 80 '[{"key":"projects","kb":900,"age_hours":47.0}]'; alert >/dev/null
snap "$(ts 2)" 79 '[]' '["projects"]'; rc=$(alert)
[[ "$rc" != 0 ]] && escalated && ok "test_escalates_when_carry_expires_to_unmeasured" || bad "carry expiry did not escalate"

echo "── same snapshot is not double counted ──"
reset; snap "$(ts 1)" 40; for i in 1 2 3 4 5 6 7; do rc=$(alert); done
[[ "$rc" == 0 ]] && ok "test_same_snapshot_not_double_counted" || bad "re-reading one snapshot escalated"

echo "── old streak file schema ──"
reset; echo '{"streak": 1, "last_snapshot_timestamp": "2026-09-27T00:00:00Z", "last_coverage_pct": 40}' > "$STATE/coverage_streak.json"
snap "$(ts 1)" 40; rc=$(alert)
[[ "$rc" == 0 ]] && grep -qi "reset" "$WORK/err" "$WORK/out" \
  && ok "test_old_schema_streak_file_reset_with_log_line" || bad "old schema not reset with a log line"

echo "── legacy field fallback ──"
reset; esc=0
for i in 1 2 3 4 5 6; do snap "$(ts $i)" 50 '[]' '[]' legacy; rc=$(alert); [[ "$rc" != 0 ]] && esc=1; done
[[ "$esc" == 1 ]] && ok "test_falls_back_to_legacy_field_when_effective_missing" || bad "legacy-only snapshots never escalated"

echo "── silence file ──"
reset; touch "$H/.disk_magician_alert.silenced"; snap "$(ts 1)" 80 '[{"key":"projects","kb":900,"age_hours":60.0}]'; rc=$(alert)
[[ "$rc" == 0 ]] && grep -qi "silenced" "$WORK/out" && ok "test_silence_file_suppresses" || bad "silence file ignored"

echo; echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]

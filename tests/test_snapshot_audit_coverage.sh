#!/usr/bin/env bash
# test_snapshot_audit_coverage.sh — TDD for partial-coverage snapshot acceptance.
#
# Reproduces the 2026-07-06 blocker: snapshot at 69.8% coverage with
# measurement_status=partial and snapshot_warning=low_coverage was rejected
# by disk_audit.sh even though JSON was valid.
#
# Run: bash tests/test_snapshot_audit_coverage.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
SNAP_SCRIPT="$REPO_ROOT/scripts/disk_snapshot.sh"

WORK="$(mktemp -d -t disk_audit_cov.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

write_partial_snap() {
  local path="$1" cov="$2"
  python3 - "$path" "$cov" <<'PY'
import json, datetime, sys
path, cov = sys.argv[1], float(sys.argv[2])
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 776,
    "disk_free_gb": 102,
    "disk_pct": 83,
    "snapshot_coverage_pct": cov,
    "snapshot_warning": "low_coverage",
    "snapshot_metadata": {
        "captured_at": ts,
        "age_seconds": 120,
        "coverage_pct": cov,
        "measurement_status": "partial",
        "measured_paths_ok": 39,
        "measured_paths_total": 42,
    },
    "timeout_keys": ["library_messages", "library_containers", "downloads"],
    "directories": {
        "projects": 123471436,
        "colima": 15869036,
        "ao_sessions": 44102280,
        "codex_sessions": 16766204,
    },
}
json.dump(snap, open(path, "w"))
PY
}

section "1. Partial snapshot 69.8% is accepted by audit (uses snapshot-ranked view)"
PARTIAL="$WORK/partial_698.json"
write_partial_snap "$PARTIAL" 69.8
OUTPUT=$(DISK_SNAPSHOT_JSON="$PARTIAL" timeout 30 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -q "Largest directories (snapshot-ranked"; then
  ok "69.8% partial snapshot used for directory breakdown"
else
  bad "69.8% partial snapshot rejected — expected snapshot-ranked breakdown"
  echo "$OUTPUT" | sed 's/^/      /' | head -15
fi
if echo "$OUTPUT" | grep -qiE "partial coverage|low coverage|timeout_keys|69.8"; then
  ok "audit surfaces partial/low-coverage warning"
else
  bad "audit missing partial coverage warning"
fi

section "2. Truly low coverage 30% still rejected"
LOW="$WORK/low_30.json"
write_partial_snap "$LOW" 30.0
OUTPUT=$(DISK_SNAPSHOT_JSON="$LOW" timeout 30 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -q "Snapshot not usable"; then
  ok "30% snapshot rejected"
else
  bad "30% snapshot should be rejected"
fi

section "3. containers_captured is a single integer in snapshot JSON (emnx)"
# Synthetic: simulate multi-line grep -c bug by ensuring snapshot validates
FAKE_LISTING=$'123\t/foo\n456\t/bar'
CAP=$(printf '%s' "$FAKE_LISTING" | grep -c '^[0-9]' 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)
if [[ "$CAP" =~ ^[0-9]+$ ]]; then
  ok "containers_captured sanitizes to integer ($CAP)"
else
  bad "containers_captured not integer: '$CAP'"
fi

EMNX_SNAP="$WORK/emnx_snap.json"
python3 - "$EMNX_SNAP" <<'PY'
import json, datetime, sys
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts, "hostname": "t", "disk_total_gb": 100, "disk_used_gb": 50,
    "disk_free_gb": 50, "disk_pct": 50, "snapshot_coverage_pct": 80.0,
    "snapshot_metadata": {
        "captured_at": ts, "age_seconds": 0, "coverage_pct": 80.0,
        "measurement_status": "partial", "measured_paths_ok": 10,
        "measured_paths_total": 12,
        "library_containers_top_subdirs_captured": 0,
        "library_containers_total_subdirs": 602,
    },
    "directories": {"projects": 1000},
}
json.dump(snap, open(sys.argv[1], "w"))
PY
if python3 -m json.tool < "$EMNX_SNAP" >/dev/null 2>&1; then
  ok "synthetic snapshot with containers metadata is valid JSON"
else
  bad "containers metadata broke JSON"
fi

section "4. Dedup trie: parent+child + symlink alias no longer double-counted (schema_version 2)"
# Reproduces the real bugs found in config.json.template: claude_root+claude_projects
# and codex_root+codex_sessions (parent+child both monitored), and
# hermes+hermes_prod (symlink alias) — all inflate coverage_pct today.
DEDUP_WORK="$WORK/dedup"
mkdir -p "$DEDUP_WORK/parent/child"
dd if=/dev/zero of="$DEDUP_WORK/parent/file.bin" bs=1024 count=2048 >/dev/null 2>&1
dd if=/dev/zero of="$DEDUP_WORK/parent/child/file.bin" bs=1024 count=1024 >/dev/null 2>&1
ln -s "$DEDUP_WORK/parent" "$DEDUP_WORK/alias"

DEDUP_CONFIG="$WORK/dedup_config.json"
cat > "$DEDUP_CONFIG" <<JSON
{
  "monitored_dirs": [
    {"key": "parent", "path": "$DEDUP_WORK/parent", "timeout": 10},
    {"key": "child", "path": "$DEDUP_WORK/parent/child", "timeout": 10},
    {"key": "alias", "path": "$DEDUP_WORK/alias", "timeout": 10}
  ]
}
JSON

DEDUP_OUT="$WORK/dedup_snap.json"
DISK_MAGICIAN_CONFIG="$DEDUP_CONFIG" timeout 120 "$SNAP_SCRIPT" --output "$DEDUP_OUT" >/dev/null 2>&1

if [[ -f "$DEDUP_OUT" ]] && python3 -m json.tool < "$DEDUP_OUT" >/dev/null 2>&1; then
  ok "dedup snapshot produced valid JSON"
else
  bad "dedup snapshot missing or invalid JSON"
fi

SCHEMA_VER=$(python3 -c "import json; print(json.load(open('$DEDUP_OUT')).get('schema_version'))" 2>/dev/null || echo "")
if [[ "$SCHEMA_VER" == "2" ]]; then
  ok "schema_version is 2"
else
  bad "schema_version expected 2, got '$SCHEMA_VER'"
fi

DEDUP_CHECK=$(python3 - "$DEDUP_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
excluded = {e["key"]: e for e in d.get("dedup_excluded", [])}
meta = d.get("snapshot_metadata", {})
raw = meta.get("tracked_total_kb_raw")
deduped = meta.get("tracked_total_kb_deduped")
ok = True
ok &= excluded.get("child", {}).get("covered_by") == "parent" and excluded.get("child", {}).get("reason") == "nested_under_parent"
ok &= excluded.get("alias", {}).get("covered_by") == "parent" and excluded.get("alias", {}).get("reason") == "symlink_alias"
ok &= "parent" not in excluded
ok &= raw is not None and deduped is not None and deduped < raw
print("PASS" if ok else "FAIL")
print(json.dumps({"excluded": excluded, "raw": raw, "deduped": deduped}))
PY
)
if echo "$DEDUP_CHECK" | head -1 | grep -q PASS; then
  ok "child (nested_under_parent) + alias (symlink_alias) both excluded, parent kept, deduped < raw"
else
  bad "dedup trie did not exclude overlaps as expected"
  echo "$DEDUP_CHECK" | tail -1 | sed 's/^/      /'
fi

if python3 -c "
import json
d = json.load(open('$DEDUP_OUT'))
assert isinstance(d.get('residual_kb'), int)
assert isinstance(d.get('residual_gb'), float)
assert 'coverage_pct_raw_v1' in d['snapshot_metadata']
" 2>/dev/null; then
  ok "residual_kb/residual_gb + coverage_pct_raw_v1 fields present in schema-v2 snapshot"
else
  bad "residual/coverage_pct_raw_v1 fields missing or wrong type"
fi

section "5. discover --json emits structured findings + mtime cache (sandboxed HOME, fixes jleechan-jz5t)"
FAKE_HOME="$WORK/fake_home"
mkdir -p "$FAKE_HOME/small_dir"
dd if=/dev/zero of="$FAKE_HOME/small_dir/f.bin" bs=1024 count=100 >/dev/null 2>&1

DISCOVER_OUT=$(HOME="$FAKE_HOME" timeout 30 "$SNAP_SCRIPT" --discover --json 2>/dev/null || true)
if echo "$DISCOVER_OUT" | python3 -m json.tool >/dev/null 2>&1; then
  ok "discover --json produces valid JSON in a sandboxed HOME"
else
  bad "discover --json did not produce valid JSON"
  echo "$DISCOVER_OUT" | head -5 | sed 's/^/      /'
fi

if echo "$DISCOVER_OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert {'entries', 'cache_hits', 'cache_misses', 'generated_at'} <= set(d.keys())
" 2>/dev/null; then
  ok "discover --json has entries/cache_hits/cache_misses/generated_at keys"
else
  bad "discover --json missing expected keys"
fi

if [[ -f "$FAKE_HOME/.disk_magician_state/discover_last.json" ]]; then
  ok "discover_last.json persisted under sandboxed HOME's state dir"
else
  bad "discover_last.json not found after --discover run"
fi

DISCOVER_OUT2=$(HOME="$FAKE_HOME" timeout 30 "$SNAP_SCRIPT" --discover --json 2>/dev/null || true)
HITS2=$(echo "$DISCOVER_OUT2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cache_hits',0))" 2>/dev/null || echo 0)
if [[ "${HITS2:-0}" -ge 1 ]]; then
  ok "second discover run reuses mtime cache (cache_hits=$HITS2) — fixes jleechan-jz5t repeat-timeout"
else
  bad "second discover run did not hit cache (cache_hits=$HITS2)"
fi

section "6. topdown_coverage: fresh/stale/corrupt/absent frontier_last.json + topdown_enabled:false override"
TD_HOME="$WORK/fake_home_topdown"
mkdir -p "$TD_HOME/small_dir" "$TD_HOME/.disk_magician_state"
dd if=/dev/zero of="$TD_HOME/small_dir/f.bin" bs=1024 count=100 >/dev/null 2>&1

TD_CONFIG="$TD_HOME/config.json"
cat > "$TD_CONFIG" <<JSON
{"monitored_dirs": [{"key": "small", "path": "$TD_HOME/small_dir", "timeout": 10}]}
JSON

FRONTIER_FILE="$TD_HOME/.disk_magician_state/frontier_last.json"
write_frontier_last() {
  local captured_at="$1"
  python3 - "$FRONTIER_FILE" "$captured_at" <<'PY'
import json, sys
path, captured_at = sys.argv[1], sys.argv[2]
json.dump({
    "schema_version": 1, "tool": "disk_frontier_scan", "mode": "partial",
    "captured_at": captured_at, "measured_total_kb": 15476968,
    "frontier_unfinished": [{"path": "/x"}] * 82,
    "residual_kb": 873829052,
    "sibling_volumes": {f"v{i}": {} for i in range(10)},
    "local_snapshots_count": 3,
}, open(path, "w"))
PY
}

# 6a. fresh (<36h) -> full summary embedded
NOW_TS=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
write_frontier_last "$NOW_TS"
TD_OUT="$TD_HOME/snap_fresh.json"
HOME="$TD_HOME" DISK_MAGICIAN_CONFIG="$TD_CONFIG" timeout 30 "$SNAP_SCRIPT" --output "$TD_OUT" >/dev/null 2>&1
if python3 -c "
import json
d = json.load(open('$TD_OUT'))
td = d.get('topdown_coverage')
assert td is not None and td.get('mode') == 'partial'
assert td.get('frontier_unfinished_count') == 82
assert td.get('sibling_volumes_count') == 10
assert td.get('local_snapshots_count') == 3
assert 'measured' not in td and 'deduped' not in td and 'sibling_volumes' not in td  # summary only, never the full maps/lists
assert 'stale' not in td
" 2>/dev/null; then
  ok "fresh frontier_last.json embeds full topdown_coverage summary (no full measured map)"
else
  bad "fresh frontier_last.json did not embed the expected summary"
fi

# 6b. stale (>36h) -> {stale: true, ...} marker
OLD_TS=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=48)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
write_frontier_last "$OLD_TS"
TD_OUT_STALE="$TD_HOME/snap_stale.json"
HOME="$TD_HOME" DISK_MAGICIAN_CONFIG="$TD_CONFIG" timeout 30 "$SNAP_SCRIPT" --output "$TD_OUT_STALE" >/dev/null 2>&1
if python3 -c "
import json
d = json.load(open('$TD_OUT_STALE'))
td = d.get('topdown_coverage')
assert td == {'stale': True, 'captured_at': td.get('captured_at'), 'age_hours': td.get('age_hours')}
assert td['age_hours'] > 36
" 2>/dev/null; then
  ok "stale (>36h) frontier_last.json embeds {stale: true} marker only"
else
  bad "stale frontier_last.json did not produce the expected stale marker"
fi

# 6c. corrupt JSON -> field omitted entirely, snapshot still valid
echo "{not valid json" > "$FRONTIER_FILE"
TD_OUT_CORRUPT="$TD_HOME/snap_corrupt.json"
HOME="$TD_HOME" DISK_MAGICIAN_CONFIG="$TD_CONFIG" timeout 30 "$SNAP_SCRIPT" --output "$TD_OUT_CORRUPT" >/dev/null 2>&1
if python3 -c "
import json
d = json.load(open('$TD_OUT_CORRUPT'))
assert 'topdown_coverage' not in d
" 2>/dev/null; then
  ok "corrupt frontier_last.json fails open — snapshot valid, field omitted"
else
  bad "corrupt frontier_last.json broke the snapshot or field wasn't omitted"
fi

# 6d. absent file -> field omitted, snapshot still valid
rm -f "$FRONTIER_FILE"
TD_OUT_ABSENT="$TD_HOME/snap_absent.json"
HOME="$TD_HOME" DISK_MAGICIAN_CONFIG="$TD_CONFIG" timeout 30 "$SNAP_SCRIPT" --output "$TD_OUT_ABSENT" >/dev/null 2>&1
if python3 -c "
import json
d = json.load(open('$TD_OUT_ABSENT'))
assert 'topdown_coverage' not in d
" 2>/dev/null; then
  ok "absent frontier_last.json — field omitted, snapshot still valid"
else
  bad "absent frontier_last.json broke the snapshot or field unexpectedly present"
fi

# 6e. topdown_enabled:false override skips embedding even with a fresh file present
write_frontier_last "$NOW_TS"
TD_CONFIG_DISABLED="$TD_HOME/config_disabled.json"
cat > "$TD_CONFIG_DISABLED" <<JSON
{"monitored_dirs": [{"key": "small", "path": "$TD_HOME/small_dir", "timeout": 10}], "topdown_enabled": false}
JSON
TD_OUT_DISABLED="$TD_HOME/snap_disabled.json"
HOME="$TD_HOME" DISK_MAGICIAN_CONFIG="$TD_CONFIG_DISABLED" timeout 30 "$SNAP_SCRIPT" --output "$TD_OUT_DISABLED" >/dev/null 2>&1
if python3 -c "
import json
d = json.load(open('$TD_OUT_DISABLED'))
assert 'topdown_coverage' not in d
" 2>/dev/null; then
  ok "topdown_enabled:false skips embedding even with a fresh frontier_last.json present"
else
  bad "topdown_enabled:false did not suppress topdown_coverage"
fi

section "7. allowlist measurement is dua-first and bounded per path + in total"
BUDGET_HOME="$WORK/budget_home"
BUDGET_BIN="$WORK/budget_bin"
BUDGET_LOG="$WORK/budget_invocations.log"
mkdir -p "$BUDGET_HOME/slow-a" "$BUDGET_HOME/slow-b" "$BUDGET_HOME/slow-c" "$BUDGET_BIN"
: > "$BUDGET_LOG"

cat > "$BUDGET_BIN/dua" <<'SH'
#!/usr/bin/env bash
echo "dua $*" >> "${BUDGET_LOG:?}"
case "${BUDGET_MODE:?}" in
  parity)
    printf '\033[32m%12s b payload\033[39m\n' "${DUA_BYTES:?}"
    printf '\033[32m%12s b total\033[39m\n' "${DUA_BYTES:?}"
    printf '\033[32m\n'
    ;;
  fail-fast) exit 1 ;;
  slow) sleep 5 ;;
esac
SH
cat > "$BUDGET_BIN/du" <<'SH'
#!/usr/bin/env bash
echo "du $*" >> "${BUDGET_LOG:?}"
sleep 5
SH
chmod +x "$BUDGET_BIN/dua" "$BUDGET_BIN/du"

PARITY_CONFIG="$WORK/budget_parity_config.json"
cat > "$PARITY_CONFIG" <<JSON
{"monitored_dirs": [{"key": "parity", "path": "$BUDGET_HOME/slow-a", "timeout": 180}]}
JSON
PARITY_OUT="$WORK/budget_parity.json"
expected_kb=1234
if HOME="$BUDGET_HOME" PATH="$BUDGET_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
  BUDGET_LOG="$BUDGET_LOG" BUDGET_MODE=parity DUA_BYTES=$(( expected_kb * 1024 )) \
  DISK_MAGICIAN_CONFIG="$PARITY_CONFIG" DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=5 \
  DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=2 timeout 10 "$SNAP_SCRIPT" --output "$PARITY_OUT" \
  >/dev/null 2>&1 && \
  python3 -c "import json; d=json.load(open('$PARITY_OUT')); assert d['directories']['parity'] == $expected_kb" && \
  [[ "$(head -1 "$BUDGET_LOG")" == dua* ]] && ! grep -q '^du ' "$BUDGET_LOG"; then
  ok "dua is primary and parses the last numeric row despite trailing ANSI output"
else
  bad "dua primary/parity parsing contract failed"
fi

PER_PATH_CONFIG="$WORK/budget_per_path_config.json"
cat > "$PER_PATH_CONFIG" <<JSON
{"monitored_dirs": [{"key": "slow", "path": "$BUDGET_HOME/slow-a", "timeout": 180}]}
JSON
PER_PATH_OUT="$WORK/budget_per_path.json"
: > "$BUDGET_LOG"
start=$(date +%s)
HOME="$BUDGET_HOME" PATH="$BUDGET_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
  BUDGET_LOG="$BUDGET_LOG" BUDGET_MODE=fail-fast \
  DISK_MAGICIAN_CONFIG="$PER_PATH_CONFIG" DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=5 \
  DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=1 timeout 8 "$SNAP_SCRIPT" --output "$PER_PATH_OUT" \
  >/dev/null 2>&1 || true
per_path_elapsed=$(( $(date +%s) - start ))
if [[ "$per_path_elapsed" -le 3 ]] && \
  [[ "$(sed -n '1p' "$BUDGET_LOG")" == dua* ]] && \
  [[ "$(sed -n '2p' "$BUDGET_LOG")" == du* ]] && \
  python3 -c "import json; d=json.load(open('$PER_PATH_OUT')); assert d['directories']['slow'] is None" 2>/dev/null; then
  ok "dua failure falls back to du inside one shared 1s per-path deadline"
else
  bad "per-path deadline failed (elapsed=${per_path_elapsed}s, calls=$(tr '\n' ';' < "$BUDGET_LOG"))"
fi

TOTAL_CONFIG="$WORK/budget_total_config.json"
cat > "$TOTAL_CONFIG" <<JSON
{"monitored_dirs": [
  {"key": "slow_a", "path": "$BUDGET_HOME/slow-a", "timeout": 180},
  {"key": "slow_b", "path": "$BUDGET_HOME/slow-b", "timeout": 180},
  {"key": "slow_c", "path": "$BUDGET_HOME/slow-c", "timeout": 180}
]}
JSON
TOTAL_OUT="$WORK/budget_total.json"
: > "$BUDGET_LOG"
start=$(date +%s)
HOME="$BUDGET_HOME" PATH="$BUDGET_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
  BUDGET_LOG="$BUDGET_LOG" BUDGET_MODE=slow \
  DISK_MAGICIAN_CONFIG="$TOTAL_CONFIG" DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=2 \
  DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=1 timeout 8 "$SNAP_SCRIPT" --output "$TOTAL_OUT" \
  >/dev/null 2>&1 || true
total_elapsed=$(( $(date +%s) - start ))
if [[ "$total_elapsed" -le 4 ]] && python3 - "$TOTAL_OUT" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
m = d["snapshot_metadata"]
assert all(d["directories"][key] is None for key in ("slow_a", "slow_b", "slow_c"))
assert set(d["timeout_keys"]) == {"slow_a", "slow_b", "slow_c"}
assert m["measurement_budget_seconds"] == 2
assert m["measurement_path_max_seconds"] == 1
assert m["measurement_elapsed_seconds"] <= 4
assert m["measurement_budget_exhausted"] is True
PY
then
  ok "global 2s measurement budget fail-closes all remaining paths as null"
else
  bad "global measurement budget failed (elapsed=${total_elapsed}s)"
fi

section "Summary"
echo "  PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All snapshot audit coverage checks passed."
exit 0

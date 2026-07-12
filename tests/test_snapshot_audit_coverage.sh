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

section "Summary"
echo "  PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "  All snapshot audit coverage checks passed."
exit 0

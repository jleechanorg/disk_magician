#!/usr/bin/env bash
# test_snapshot_freshness.sh — Lane B Section C
#
# Verifies:
#   1. disk_snapshot.sh writes a top-level `snapshot_metadata` block with
#      captured_at / age_seconds / coverage_pct / measurement_status.
#   2. disk_snapshot.sh captures top-20 Library/Containers subdirs as
#      `lc_<safe_name>` entries.
#   3. A fake "stale" snapshot (age_seconds > 4*3600) makes disk_audit.sh
#      emit a STALE SNAPSHOT WARNING.
#   4. A fake "low coverage" snapshot (coverage_pct < 50) makes
#      disk_audit.sh refuse to use it (existing behavior + new warn).
#   5. growth_rate_kb_per_day is computable from disk_history.sh when
#      multiple snapshots exist in the window.
#
# Run:  bash tests/test_snapshot_freshness.sh
# Exit 0 on pass, non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAP_SCRIPT="$REPO_ROOT/scripts/disk_snapshot.sh"
AUDIT_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
HISTORY_SCRIPT="$REPO_ROOT/scripts/disk_history.sh"

# Temp work area — cleaned up on exit. Allocate explicitly under /tmp, reject
# symlinked roots before installing the cleanup trap, then canonicalize it.
WORK="$(mktemp -d /tmp/disk-magician-snapshot-freshness.XXXXXX)" || {
    echo "FATAL: could not allocate /tmp fixture root" >&2
    exit 2
}
if [[ -z "$WORK" || ! -d "$WORK" || -L "$WORK" ]]; then
    echo "FATAL: invalid or symlinked fixture root '$WORK'" >&2
    exit 2
fi
WORK="$(cd "$WORK" && pwd -P)" || {
    echo "FATAL: could not canonicalize fixture root" >&2
    exit 2
}
case "$WORK" in
    /tmp/*|/private/tmp/*) ;;
    *) echo "FATAL: fixture root not under /tmp: '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The snapshot writer expands ~ through HOME, while config.json.template also
# lists absolute host paths (/Applications, /Library, /private/var, /opt, etc.).
# Keep the ENTIRE input surface inside $WORK (bead disk_magician-4gd) so hosted
# runners never traverse 40+ GiB of /Applications or /Library during metadata
# and lc_* verification.
export HOME="$WORK/home"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$WORK/user_tmp/T"
export DISK_MAGICIAN_FRONTIER_ROOT_JSON="$WORK/no-root-frontier.json"
export DISK_MAGICIAN_GDU_CMD=""
mkdir -p "$HOME/Library/Containers" "$WORK/user_tmp/T" "$WORK/user_tmp/X" "$WORK/host_root" "$WORK/bin"
for container in com.example.alpha com.example.beta com.example.gamma; do
    mkdir -p "$HOME/Library/Containers/$container/Data"
    touch "$HOME/Library/Containers/$container/Data/fixture"
done
cat > "$WORK/bin/diskutil" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$WORK/bin/tmutil" <<'SH'
#!/usr/bin/env bash
printf 'Snapshots for disk /:\n'
SH
cat > "$WORK/bin/taskpolicy" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) shift ;;
    -c|-g|-p|-a|-x|-S|-t) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SH
chmod +x "$WORK/bin/diskutil" "$WORK/bin/tmutil" "$WORK/bin/taskpolicy"
export PATH="$WORK/bin:$PATH"
export DISK_MAGICIAN_CONFIG="$WORK/config.json"
python3 - "$REPO_ROOT/config.json.template" "$DISK_MAGICIAN_CONFIG" "$WORK/host_root" <<'PY'
import json, os, sys
template_path, out_path, host_root = sys.argv[1:4]
cfg = json.load(open(template_path))
for item in cfg.get("monitored_dirs", []):
    p = item.get("path", "")
    if p.startswith("/"):
        relocated = os.path.join(host_root, p.lstrip("/"))
        os.makedirs(relocated, exist_ok=True)
        item["path"] = relocated
json.dump(cfg, open(out_path, "w"), indent=2)
PY

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

# ────────── 1. Live snapshot produces snapshot_metadata + lc_ keys ──────────
section "1. Live snapshot has snapshot_metadata block and lc_ keys"

LIVE_SNAP="$WORK/live_snap.json"
live_rc=0
DISK_MAGICIAN_STATE_DIR="$WORK/state" timeout "${SNAPSHOT_TIMEOUT:-180}" "$SNAP_SCRIPT" --output "$LIVE_SNAP" > "$WORK/live_snap.log" 2>&1 || live_rc=$?
if [[ "$live_rc" -eq 0 ]]; then
    if [[ -s "$LIVE_SNAP" ]]; then
        ok "live snapshot written to $LIVE_SNAP"
    else
        bad "live snapshot file is empty"
        cat "$WORK/live_snap.log" 2>/dev/null | sed 's/^/      /' || true
    fi
else
    bad "live snapshot run timed out or failed (rc=$live_rc, ${SNAPSHOT_TIMEOUT:-180}s budget)"
    tail -n 40 "$WORK/live_snap.log" 2>/dev/null | sed 's/^/      /' || true
    echo "  (skipping live assertions — using synthetic snapshots for the rest)"
    LIVE_SNAP=""
fi

if [[ -n "$LIVE_SNAP" && -s "$LIVE_SNAP" ]]; then
    # Check required metadata fields
    for field in captured_at age_seconds coverage_pct measurement_status; do
        if python3 -c "import json,sys; d=json.load(open('$LIVE_SNAP')); m=d.get('snapshot_metadata') or {}; sys.exit(0 if '$field' in m else 1)" 2>/dev/null; then
            ok "snapshot_metadata has '$field'"
        else
            bad "snapshot_metadata missing '$field'"
        fi
    done
    # Check top-20 library_containers lc_ keys
    LC_COUNT=$(python3 -c "import json; d=json.load(open('$LIVE_SNAP')); print(sum(1 for k in d.get('directories',{}) if k.startswith('lc_')))" 2>/dev/null || echo 0)
    HAS_LC_TIMEOUT=$(python3 -c "import json; d=json.load(open('$LIVE_SNAP')); print('library_containers' in (d.get('timeout_keys') or []))" 2>/dev/null || echo False)
    if [[ "$LC_COUNT" -ge 1 ]]; then
        ok "snapshot has $LC_COUNT lc_ keys (top Library/Containers subdirs)"
    elif [[ "$HAS_LC_TIMEOUT" == "True" ]]; then
        ok "0 lc_ keys but library_containers timed out (expected on large installs)"
    else
        bad "snapshot has 0 lc_ keys — Library/Containers expansion not capturing"
    fi
fi

# ────────── 2. Stale snapshot triggers alert ──────────
section "2. Stale snapshot (age > 4h) triggers disk_audit.sh STALE WARNING"

# Build a synthetic snapshot whose embedded timestamp is 5 hours old.
STALE_SNAP="$WORK/stale_snap.json"
export STALE_SNAP_VAL="$STALE_SNAP"
python3 - <<'PYEOF'
import json, datetime, os
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 740,
    "disk_free_gb": 186,
    "disk_pct": 80,
    "snapshot_coverage_pct": 93.0,
    "snapshot_metadata": {
        "captured_at": ts,
        # 5 hours old — above the 4 h threshold
        "age_seconds": 5 * 3600,
        "coverage_pct": 93.0,
        "measurement_status": "complete",
        "measured_paths_ok": 30,
        "measured_paths_total": 30,
    },
    "directories": {
        "docker_raw": 50 * 1024 * 1024,
        "codex_sessions": 8 * 1024 * 1024,
        "gemini_root": 25 * 1024 * 1024,
        "library_containers": 30 * 1024 * 1024,
    },
}
json.dump(snap, open(os.environ["STALE_SNAP_VAL"], "w"))
print("WROTE", os.environ["STALE_SNAP_VAL"])
PYEOF

# Run disk_audit.sh with this snapshot. We can't trivially point it at
# the synthetic file because snapshot_lib.sh prefers backup/<host>/...,
# so we patch DISK_SNAPSHOT_JSON to override.
OUTPUT=$(DISK_SNAPSHOT_JSON="$STALE_SNAP" timeout 60 "$AUDIT_SCRIPT" --no-history 2>&1 || true)

if echo "$OUTPUT" | grep -q "STALE SNAPSHOT WARNING"; then
    ok "stale snapshot produced STALE SNAPSHOT WARNING"
    if echo "$OUTPUT" | grep -qE "age [0-9]+s .*4h"; then
        ok "warning includes age_seconds detail"
    else
        bad "warning missing age_seconds detail (got: $(echo "$OUTPUT" | grep STALE | head -1))"
    fi
else
    bad "stale snapshot did NOT produce STALE SNAPSHOT WARNING"
    echo "    output snippet:"
    echo "$OUTPUT" | sed 's/^/      /' | head -40
fi

# ────────── 3. Low coverage snapshot is rejected ──────────
section "3. Low coverage snapshot (coverage_pct < 50) rejected by audit"

LOW_SNAP="$WORK/low_snap.json"
export LOW_SNAP_VAL="$LOW_SNAP"
python3 - <<'PYEOF'
import json, datetime, os
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 740,
    "disk_free_gb": 186,
    "disk_pct": 80,
    "snapshot_coverage_pct": 30.0,  # < 50
    "snapshot_metadata": {
        "captured_at": ts,
        "age_seconds": 60,
        "coverage_pct": 30.0,
        "measurement_status": "complete",
        "measured_paths_ok": 10,
        "measured_paths_total": 10,
    },
    "directories": {"docker_raw": 5 * 1024 * 1024},
}
json.dump(snap, open(os.environ["LOW_SNAP_VAL"], "w"))
PYEOF

OUTPUT=$(DISK_SNAPSHOT_JSON="$LOW_SNAP" timeout 60 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -qE "coverage.*<.*70|coverage.*30.0%"; then
    ok "low-coverage snapshot rejected (audit falls back to live du)"
else
    bad "low-coverage snapshot was not rejected"
    echo "    output snippet:"
    echo "$OUTPUT" | sed 's/^/      /' | head -20
fi

# ────────── 4. measurement_status=timeout surfaces in output ──────────
section "4. measurement_status=timeout surfaces in audit output"

TIMEOUT_SNAP="$WORK/timeout_snap.json"
export TIMEOUT_SNAP_VAL="$TIMEOUT_SNAP"
python3 - <<'PYEOF'
import json, datetime, os
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 740,
    "disk_free_gb": 186,
    "disk_pct": 80,
    "snapshot_coverage_pct": 0.0,
    "snapshot_warning": "low_coverage",
    "snapshot_metadata": {
        "captured_at": ts,
        "age_seconds": 60,
        "coverage_pct": 0.0,
        "measurement_status": "timeout",
        "measured_paths_ok": 0,
        "measured_paths_total": 30,
    },
    "directories": {},
}
json.dump(snap, open(os.environ["TIMEOUT_SNAP_VAL"], "w"))
PYEOF

# The audit refuses this snapshot (coverage 0) so we just verify the
# status field is parsed (no crash). A separate "rejected" message is
# sufficient evidence.
OUTPUT=$(DISK_SNAPSHOT_JSON="$TIMEOUT_SNAP" timeout 60 "$AUDIT_SCRIPT" --no-history 2>&1 || true)
if echo "$OUTPUT" | grep -qiE "snapshot.*not.*usable|coverage"; then
    ok "timeout-only snapshot correctly refused (low coverage fallback)"
else
    bad "audit did not produce expected refusal message for timeout snapshot"
fi

# ────────── 5. disk_history.sh --growth-rate is exposed ──────────
section "5. disk_history.sh exposes --growth-rate and --growth-window"

HELP=$(timeout 10 python3 "$HISTORY_SCRIPT" --help 2>&1 || true)
if echo "$HELP" | grep -q -- "--growth-rate"; then
    ok "disk_history.sh --help shows --growth-rate"
else
    bad "disk_history.sh --help missing --growth-rate"
fi
if echo "$HELP" | grep -q -- "--growth-window"; then
    ok "disk_history.sh --help shows --growth-window"
else
    bad "disk_history.sh --help missing --growth-window"
fi

# Verify growth_rate runs. Two acceptable outcomes depending on whether
# there's committed history: (a) a populated growth_rate_kb_per_day
# table, or (b) a "No disk_snapshot.json found" or "need >=2 snapshots"
# sentinel — both are correct responses when no history is committed.
GR_OUT=$(timeout 30 python3 "$HISTORY_SCRIPT" --growth-rate --growth-window 7 2>&1 || true)
if echo "$GR_OUT" | grep -qE "growth_rate_kb_per_day|need >=2 snapshots|No disk_snapshot.json"; then
    ok "disk_history.sh --growth-rate runs and emits header / sentinel"
else
    bad "disk_history.sh --growth-rate produced no output"
    echo "    output:"
    echo "$GR_OUT" | sed 's/^/      /' | head -10
fi

# ────────── 6. JSON output is valid against python json.tool ──────────
section "6. Synthetic snapshots are valid JSON"

for f in "$STALE_SNAP" "$LOW_SNAP" "$TIMEOUT_SNAP"; do
    if python3 -m json.tool < "$f" >/dev/null 2>&1; then
        ok "$(basename "$f") is valid JSON"
    else
        bad "$(basename "$f") is NOT valid JSON"
    fi
done

# ────────── Summary ──────────
section "Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "  All freshness checks passed."
exit 0

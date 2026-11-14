#!/usr/bin/env bash
# tests/test_scratch_floor_alert.sh — bead disk_magician-91fp.
#
# Verifies disk_usage_alert.sh warns on Scratch volume HEADROOM (free GiB or
# free %) before the volume fills, rather than only at the volume-level
# 90%/100% alarms. Measured trigger: jeff-ubuntu 2026-11-12 reached 115 MB
# free with live builds writing, and nothing alerted because the alert script
# was not scheduled there and its Darwin path never checked Scratch capacity.
#
# Uses a fake `diskm` on PATH so the test does not depend on a real volume.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALERT="$REPO_ROOT/scripts/disk_usage_alert.sh"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

[[ -f "$ALERT" ]] || { echo "FAIL: missing $ALERT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake diskm: only `volume path scratch` is exercised by the floor arm.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/disk-magician" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "volume" && "${2:-}" == "path" && "${3:-}" == "scratch" ]]; then
  printf '%s\n' "$FAKE_SCRATCH_PATH"
  exit 0
fi
exit 1
EOF
chmod +x "$BIN/disk-magician"

# Make a directory we can free-space-query. We cannot fabricate a real
# filesystem, so assert on RELATIVE behaviour using a floor far above the
# real free space of the temp dir's filesystem.
SCRATCH_DIR="$TMP/scratch"
mkdir -p "$SCRATCH_DIR"
export FAKE_SCRATCH_PATH="$SCRATCH_DIR"
export PATH="$BIN:$PATH"
export DISK_MAGICIAN_DISKM_BIN="$BIN/disk-magician"

# Neutralise unrelated alert arms so only the floor arm can speak:
#   - silence file removed
#   - snapshot pointed at a missing file (coverage -> "unknown")
#   - diskm volume status failing keeps volume_alarms quiet for the floor test
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
rm -f "$HOME/.disk_magician_alert.silenced" 2>/dev/null || true

run_alert() {  # run_alert <env...>
  env "$@" bash "$ALERT" 2>&1 || true
}

# ── 1. Floor crossed by absolute GiB -> must warn on headroom ────────────────
out="$(run_alert DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0)"
if grep -q 'Scratch volume headroom low' <<<"$out"; then
  pass "absolute GiB floor triggers a headroom warning"
else
  fail "absolute GiB floor did not trigger: $out"
fi

if grep -qi 'Act before it fills' <<<"$out"; then
  pass "warning explains why acting early matters"
else
  fail "warning missing the act-early guidance"
fi

# ── 2. Floor crossed by percentage -> must warn ──────────────────────────────
out="$(run_alert DISK_MAGICIAN_SCRATCH_FLOOR_GB=0 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=100)"
if grep -q 'Scratch volume headroom low' <<<"$out"; then
  pass "percentage floor triggers a headroom warning"
else
  fail "percentage floor did not trigger: $out"
fi

if grep -q '% free <' <<<"$out"; then
  pass "percentage arm reports the percentage form"
else
  fail "percentage arm did not report percentage detail: $out"
fi

# ── 3. Both arms disabled -> silent, and must NOT fail closed ───────────────
out="$(run_alert DISK_MAGICIAN_SCRATCH_FLOOR_GB=0 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0)"
if grep -q 'Scratch volume headroom low' <<<"$out"; then
  fail "disabled arms still warned"
else
  pass "0 disables both arms"
fi

# ── 4. Generous floor -> no warning (no false positive) ─────────────────────
out="$(run_alert DISK_MAGICIAN_SCRATCH_FLOOR_GB=1 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=1)"
if grep -q 'Scratch volume headroom low' <<<"$out"; then
  fail "generous floor produced a false positive: $out"
else
  pass "generous floor stays silent"
fi

# ── 5. Unresolvable scratch path -> silent, never a spurious alarm ──────────
out="$(FAKE_SCRATCH_PATH="$TMP/does-not-exist" \
       run_alert DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999)"
if grep -q 'Scratch volume headroom low' <<<"$out"; then
  fail "missing scratch path should not alert"
else
  pass "unresolvable scratch path stays silent"
fi

# ── 6. --status documents the floor config ──────────────────────────────────
out="$(env DISK_MAGICIAN_SCRATCH_FLOOR_GB=7 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=9 bash "$ALERT" --status 2>&1 || true)"
if grep -q 'Scratch floor: 7 GiB free / 9% free' <<<"$out"; then
  pass "--status reports the configured floor"
else
  fail "--status did not report floor: $out"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "All scratch floor alert tests passed."
  exit 0
fi
echo "Some scratch floor alert tests FAILED."
exit 1

#!/usr/bin/env bash
# test_cleanup_colima_trim_only.sh — cleanup_colima.sh --trim-only (bead disk_magician-mux)
#
# Hermetic: temp HOME, fake colima/ssh/docker/du/timeout on PATH. Asserts:
#   1. datadisk above DISK_MAGICIAN_COLIMA_TRIM_GB -> fstrim invoked once, under timeout.
#   2. datadisk below threshold -> fstrim not invoked.
#   3. colima ssh + Lima mux unreachable -> DEGRADED logged, rc 0.
#   4. trim-only never calls colima stop/start, docker prune, or docker at all.
#   5. du failure (unmeasurable) -> no trim, DEGRADED logged, rc 0.
#
# Run: bash tests/test_cleanup_colima_trim_only.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_colima.sh"

TMP_ROOT=$(mktemp -d /tmp/dm-colima-trim.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
FAKE_BIN="$TMP_ROOT/bin"
INV="$TMP_ROOT/invocations.log"
mkdir -p "$FAKE_BIN" "$FAKE_HOME/.colima/_lima/_disks/colima"

cat > "$FAKE_BIN/colima" <<'EOF'
#!/bin/bash
echo "colima $* TIMEOUT=${UNDER_TIMEOUT:-none}" >> "$INV"
[[ "${COLIMA_MODE:-ok}" == "ok" ]] || exit 1
exit 0
EOF
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$INV"
exit 255
EOF
cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$INV"
exit 0
EOF
cat > "$FAKE_BIN/du" <<'EOF'
#!/bin/bash
echo "du $*" >> "$INV"
[[ "${DU_MODE:-ok}" == "ok" ]] || exit 1
printf '%s\t%s\n' "$FAKE_DU_KB" "${!#}"
EOF
cat > "$FAKE_BIN/timeout" <<'EOF'
#!/bin/bash
echo "timeout $1 $2" >> "$INV"
secs="$1"; shift
UNDER_TIMEOUT="$secs" exec "$@"
EOF
chmod +x "$FAKE_BIN"/*

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

run_trim() {
  local du_kb="$1"; shift
  : > "$INV"
  env -i HOME="$FAKE_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" INV="$INV" \
    FAKE_DU_KB="$du_kb" COLIMA_MODE="${COLIMA_MODE:-ok}" DU_MODE="${DU_MODE:-ok}" \
    DISK_MAGICIAN_COLIMA_TRIM_GB="${TRIM_GB:-8}" \
    /bin/bash "$SCRIPT" --trim-only "$@" > "$TMP_ROOT/out.log" 2>&1
}

# 1. above threshold (9 GiB > 8) -> trim once, under timeout
rc=0; run_trim $((9 * 1048576)) --clean || rc=$?
n=$(grep -c 'colima ssh -- sudo fstrim -av' "$INV" || true)
if [[ $rc -eq 0 && "$n" -eq 1 ]] && grep -q 'colima ssh -- sudo fstrim -av TIMEOUT=[0-9]' "$INV"; then
  pass "above threshold: fstrim invoked once under timeout"
else
  fail "above threshold: rc=$rc count=$n"; cat "$INV" "$TMP_ROOT/out.log"
fi
if grep -q '^du ' "$INV" && grep -q '^timeout [0-9]* du' "$INV"; then
  pass "datadisk du is bounded by timeout"
else
  fail "du not bounded by timeout"; cat "$INV"
fi

# 2. below threshold (7 GiB < 8) -> no trim
rc=0; run_trim $((7 * 1048576)) --clean || rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'fstrim' "$INV"; then
  pass "below threshold: fstrim not invoked"
else
  fail "below threshold: rc=$rc"; cat "$INV" "$TMP_ROOT/out.log"
fi

# 3. unreachable (colima ssh fails, mux absent) -> DEGRADED, rc 0
rc=0; COLIMA_MODE=fail run_trim $((20 * 1048576)) --clean || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'DEGRADED' "$TMP_ROOT/out.log"; then
  pass "unreachable: DEGRADED logged, rc 0"
else
  fail "unreachable: rc=$rc"; cat "$INV" "$TMP_ROOT/out.log"
fi

# 4. trim-only never restarts Colima or touches docker (across all runs above + this one)
rc=0; COLIMA_MODE=fail run_trim $((20 * 1048576)) --clean || rc=$?
if ! grep -qE '^colima (stop|start)|^docker ' "$INV"; then
  pass "trim-only never calls colima stop/start or docker"
else
  fail "trim-only invoked forbidden command"; cat "$INV"
fi

# 5. du failure -> no trim, DEGRADED, rc 0
rc=0; DU_MODE=fail run_trim 0 --clean || rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'fstrim' "$INV" && grep -q 'DEGRADED' "$TMP_ROOT/out.log"; then
  pass "unmeasurable datadisk: no trim, DEGRADED, rc 0"
else
  fail "unmeasurable datadisk: rc=$rc"; cat "$INV" "$TMP_ROOT/out.log"
fi

echo "trim-only: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

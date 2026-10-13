#!/usr/bin/env bash
# Regression: actuator_receipt_exit must turn a failed receipt write into a
# nonzero process (an EXIT trap handler's `return` does not replace the shell's
# exit status), while preserving an existing failure code. Fixture writer failure
# only; no cleanup act is performed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/arexit.XXXXXX)" || exit 1
[[ "$TMP" == /tmp/arexit.* && -d "$TMP" && ! -L "$TMP" ]] || exit 1
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; STATE="$TMP/state"; FIX="$TMP/fixture"
mkdir -p "$HOME_DIR" "$STATE" "$FIX"

# Fixture writer: begin is real (so a run id exists); finish always fails.
cat > "$FIX/job_receipt.py" <<'PY'
class JobReceiptStore:
    def __init__(self, *a, **k):
        pass
    def finish(self, *a, **k):
        raise SystemExit("fixture finish failure")
PY

PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_case() {
  local name="$1" expected="$2" body="$3" rc
  bash "$body"; rc=$?
  if [[ "$rc" == "$expected" ]]; then ok "$name (rc=$rc)"; else bad "$name — expected rc=$expected, got rc=$rc"; fi
}

# Case 1: script exits 0, receipt writer fails -> process must be nonzero (3).
cat > "$TMP/case1.sh" <<SH
#!/usr/bin/env bash
cd "$TMP"
source "$ROOT/scripts/lib/actuator_receipt.sh"
export HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$STATE"
actuator_receipt_begin "$ROOT/scripts" test_receipt "\$DISK_MAGICIAN_STATE_DIR" || exit 90
ACTUATOR_RECEIPT_SCRIPT_DIR="$FIX"
exit 0
SH
run_case "failed writer overrides exit 0" 3 "$TMP/case1.sh"

# Case 2: script exits 7, receipt writer fails -> preserve the original code.
cat > "$TMP/case2.sh" <<SH
#!/usr/bin/env bash
cd "$TMP"
source "$ROOT/scripts/lib/actuator_receipt.sh"
export HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$STATE"
actuator_receipt_begin "$ROOT/scripts" test_receipt "\$DISK_MAGICIAN_STATE_DIR" || exit 90
ACTUATOR_RECEIPT_SCRIPT_DIR="$FIX"
exit 7
SH
run_case "preexisting failure code preserved" 7 "$TMP/case2.sh"

# Case 3: script exits 0, real writer succeeds -> still 0 (no false positive).
cat > "$TMP/case3.sh" <<SH
#!/usr/bin/env bash
cd "$TMP"
source "$ROOT/scripts/lib/actuator_receipt.sh"
export HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$STATE"
actuator_receipt_begin "$ROOT/scripts" test_receipt "\$DISK_MAGICIAN_STATE_DIR" || exit 90
exit 0
SH
run_case "successful receipt keeps exit 0" 0 "$TMP/case3.sh"

echo
echo "test_actuator_receipt_exit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

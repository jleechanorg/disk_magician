#!/usr/bin/env bash
# test_disk_audit_top20_sigpipe.sh — the "Largest directories (top 20)" section
# must never terminate the run with SIGPIPE.
#
# Root cause (2026-11-18): the section used
#
#     sort -t$'\t' -k2 -rn "$SNAP_CACHE" | head -20 | while read …
#
# under `set -euo pipefail`. `head -20` exits after the twentieth row; when the
# sorted stream is still larger than the pipe buffer, `sort` takes SIGPIPE and
# pipefail reports 141 for the whole pipeline. disk_audit.sh runs with
# `set -euo pipefail`, so the script died there. That is the observed nightly
# unit failure: disk-magician-routine-clean.service exited 141 after printing
# the complete 20-row directory table (`diskm clean --routine` →
# disk_audit.sh --clean).
#
# The table printed fully, which is why the failure looked unrelated to this
# section: only the writer's exit status was lost, after its rows were shown.
#
# The fix is to bound the *number of printed rows* without truncating the
# writer — a consumer that reads every row (awk NR<=20) seals no pipe early.
#
# Usage: bash tests/test_disk_audit_top20_sigpipe.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/disk_audit.sh"
[[ -f "$TARGET_SCRIPT" ]] || { echo "FAIL: missing $TARGET_SCRIPT" >&2; exit 1; }

TMP_DIR="$(mktemp -d -t test_top20_sigpipe.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_HOME="$TMP_DIR/home"
FIXTURE_STATE="$TMP_DIR/state"
mkdir -p "$FIXTURE_HOME" "$FIXTURE_STATE"

# Enough rows, each long enough, that the sorted stream exceeds a 64 KiB pipe
# buffer: a truncating consumer is then guaranteed to break the writer.
ROWS=4000
SNAP="$TMP_DIR/snapshot.json"
python3 - "$SNAP" "$ROWS" <<'PY'
import datetime, json, sys
out, rows = sys.argv[1], int(sys.argv[2])
ts = (datetime.datetime.now(datetime.timezone.utc)
      - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
directories = {}
for i in range(rows):
    # Long keys keep the serialized stream well past one pipe buffer.
    directories["monitored_directory_with_a_long_name_%04d_padding_%s" % (i, "x" * 40)] = 1024 * (rows - i + 1)
snap = {
    "timestamp": ts,
    "hostname": "test-host",
    "disk_total_gb": 926,
    "disk_used_gb": 750,
    "disk_free_gb": 176,
    "disk_pct": 81,
    "snapshot_coverage_pct": 100.0,
    "snapshot_warning": "",
    "swap_used_gb": 2.0,
    "snapshot_metadata": {"measurement_status": "complete", "coverage_pct": 100.0},
    "directories": directories,
}
with open(out, "w") as fh:
    json.dump(snap, fh)
PY

# Keep the real HOME: this host's shell shims (e.g. ~/.local/bin/rm) resolve
# guard paths relative to it, and a redirected HOME makes them exit 127 before
# the section under test is ever reached. Only the snapshot and state root are
# redirected, so the run measures the fixture instead of live state.
OUT="$TMP_DIR/audit.log"
set +e
DISK_MAGICIAN_STATE_DIR="$FIXTURE_STATE" DISK_SNAPSHOT_JSON="$SNAP" \
  DISK_MAGICIAN_BACKUP_DIR="$TMP_DIR/backup" \
  timeout 300 bash "$TARGET_SCRIPT" >"$OUT" 2>&1
rc=$?
set -e

fail=0
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: disk_audit.sh exited $rc${rc:+ (SIGPIPE is 141)}; the top-20 section truncated its writer" >&2
  fail=1
else
  echo "  PASS audit exits 0 with $ROWS directory rows in the snapshot"
fi

# Rows are the 4-space-indented lines inside the section; header lines are
# indented by two spaces, so counting starts only once a row is seen.
printed="$(awk '/Largest directories \(snapshot-ranked, top 20\)/{found=1; next}
  found { if ($0 ~ /^    [^ ]/) count++; else if (count > 0) exit }
  END { print count + 0 }' "$OUT")"
if [[ "$printed" == "20" ]]; then
  echo "  PASS exactly 20 directory rows are printed"
else
  echo "FAIL: expected 20 printed directory rows, got $printed" >&2
  fail=1
fi

if grep -q "Broken pipe\|SIGPIPE" "$OUT"; then
  echo "FAIL: audit output reports a broken pipe" >&2
  fail=1
else
  echo "  PASS no broken-pipe diagnostics"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "--- audit output (head) ---" >&2
  head -40 "$OUT" >&2
  exit 1
fi
echo "PASS: top-20 directory section bounds its rows without breaking the writer"
exit 0

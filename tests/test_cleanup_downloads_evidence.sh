#!/usr/bin/env bash
# test_cleanup_downloads_evidence.sh — regression coverage for the Downloads
# evidence-spool retention sweeper (bead jleechan-uwtk; incident
# jleechan-m4yc: 9 DK2D runs = 55.9 GiB in one day with no retention).
#
# Sandboxed: DISK_MAGICIAN_EVIDENCE_ROOT points at a fixture tree; the real
# ~/Downloads is never touched.
#
# Run: bash tests/test_cleanup_downloads_evidence.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/cleanup_downloads_evidence.sh"

TMP_ROOT=$(mktemp -d -t cleanup_downloads_evidence.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$(( FAIL + 1 )); }

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then record_pass "$name"; else record_fail "$name" "expected rc=$expected, got rc=$actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then record_pass "$name"; else
    record_fail "$name" "expected output to contain: $needle"
    printf '        | %s\n' "${haystack//$'\n'/$'\n        | '}"
  fi
}
assert_exists()  { local n="$1" p="$2"; if [[ -e "$p" ]]; then record_pass "$n"; else record_fail "$n" "expected path to exist: $p"; fi; }
assert_missing() { local n="$1" p="$2"; if [[ ! -e "$p" ]]; then record_pass "$n"; else record_fail "$n" "expected path to be absent: $p"; fi; }

run_sweeper() {
  # run_sweeper <root> <outvar-file> [extra env pairs...] [-- args...]
  local root="$1" out_file="$2"; shift 2
  local envs=() args=()
  local in_args=false
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then in_args=true; continue; fi
    if [[ "$in_args" == true ]]; then args+=("$a"); else envs+=("$a"); fi
  done
  set +e
  # ${arr[0]+...} guards: bash 3.2 (macOS /bin/bash, used by CI) treats
  # empty-array expansion as unbound under set -u.
  env DISK_MAGICIAN_EVIDENCE_ROOT="$root" ${envs[0]+"${envs[@]}"} \
    bash "$SWEEPER" ${args[0]+"${args[@]}"} >"$out_file" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

spool() {
  # spool <root> <name> <age-spec: fresh|old>
  local dir="$1/$2"
  mkdir -p "$dir"
  printf 'x%.0s' {1..2048} > "$dir/payload.bin"
  if [[ "$3" == old ]]; then
    /usr/bin/find "$dir" -exec touch -t 202001010000 {} +
  fi
}

echo "=== cleanup_downloads_evidence.sh retention tests ==="

echo "T1: dry-run default deletes nothing, reports what it would remove"
R1="$TMP_ROOT/r1"; mkdir -p "$R1"
spool "$R1" "DK2D-EVIDENCE-RUN1" old
spool "$R1" "DK2D-EVIDENCE-RUN2" old
spool "$R1" "DK2D-EVIDENCE-RUN3" old
O1="$TMP_ROOT/o1"
run_sweeper "$R1" "$O1" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1; RC1=$?
assert_rc "T1: exits 0" 0 "$RC1"
assert_contains "T1: logs DRY RUN removal intent" "DRY RUN: would remove expired evidence spool" "$(cat "$O1")"
assert_exists "T1: nothing deleted (RUN1)" "$R1/DK2D-EVIDENCE-RUN1"
assert_exists "T1: nothing deleted (RUN3)" "$R1/DK2D-EVIDENCE-RUN3"

echo "T2: --clean keeps KEEP_COUNT newest, removes older expired spools"
R2="$TMP_ROOT/r2"; mkdir -p "$R2"
spool "$R2" "DK2D-EVIDENCE-OLD1" old
spool "$R2" "DK2D-EVIDENCE-OLD2" old
spool "$R2" "dk2d_evidence_sidekick_old" old
spool "$R2" "DK2D-EVIDENCE-NEWEST" fresh
O2="$TMP_ROOT/o2"
run_sweeper "$R2" "$O2" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1 -- --clean; RC2=$?
assert_rc "T2: exits 0" 0 "$RC2"
assert_exists "T2: newest kept" "$R2/DK2D-EVIDENCE-NEWEST"
assert_missing "T2: old spool 1 removed" "$R2/DK2D-EVIDENCE-OLD1"
assert_missing "T2: old spool 2 removed" "$R2/DK2D-EVIDENCE-OLD2"
assert_missing "T2: old sidekick-pattern spool removed" "$R2/dk2d_evidence_sidekick_old"
assert_contains "T2: logs keep decision" "Keeping (newest #1)" "$(cat "$O2")"

echo "T3: non-matching and within-retention dirs are untouched by --clean"
R3="$TMP_ROOT/r3"; mkdir -p "$R3"
spool "$R3" "my_thesis_backup" old
spool "$R3" "DK2D-EVIDENCE-FRESH1" fresh
spool "$R3" "DK2D-EVIDENCE-FRESH2" fresh
spool "$R3" "DK2D-EVIDENCE-FRESH3" fresh
O3="$TMP_ROOT/o3"
run_sweeper "$R3" "$O3" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1 -- --clean; RC3=$?
assert_rc "T3: exits 0" 0 "$RC3"
assert_exists "T3: non-matching dir untouched" "$R3/my_thesis_backup"
assert_exists "T3: fresh spool inside retention untouched" "$R3/DK2D-EVIDENCE-FRESH3"
assert_contains "T3: logs within-retention skip" "Skipping within retention" "$(cat "$O3")"

echo "T4: .keep / .in-use markers exempt an otherwise-expired spool"
R4="$TMP_ROOT/r4"; mkdir -p "$R4"
spool "$R4" "DK2D-EVIDENCE-KEEPME" old
touch "$R4/DK2D-EVIDENCE-KEEPME/.keep"
/usr/bin/find "$R4/DK2D-EVIDENCE-KEEPME" -name .keep -exec touch -t 202001010000 {} +
spool "$R4" "DK2D-EVIDENCE-NEW" fresh
O4="$TMP_ROOT/o4"
run_sweeper "$R4" "$O4" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1 -- --clean; RC4=$?
assert_rc "T4: exits 0" 0 "$RC4"
assert_exists "T4: marked spool kept" "$R4/DK2D-EVIDENCE-KEEPME"
assert_contains "T4: logs marker skip" "Skipping marked dir (.keep/.in-use)" "$(cat "$O4")"

echo "T5: retention-hours env override expires younger spools"
R5="$TMP_ROOT/r5"; mkdir -p "$R5"
spool "$R5" "DK2D-EVIDENCE-A" fresh
spool "$R5" "DK2D-EVIDENCE-B" fresh
# Backdate B by ~2 hours only.
/usr/bin/find "$R5/DK2D-EVIDENCE-B" -exec touch -A -020000 {} + 2>/dev/null || \
  /usr/bin/find "$R5/DK2D-EVIDENCE-B" -exec touch -t "$(date -v-3H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" {} +
O5="$TMP_ROOT/o5"
run_sweeper "$R5" "$O5" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1 DISK_MAGICIAN_EVIDENCE_RETENTION_HOURS=1 -- --clean; RC5=$?
assert_rc "T5: exits 0" 0 "$RC5"
assert_exists "T5: newest kept despite 1h retention" "$R5/DK2D-EVIDENCE-A"
assert_missing "T5: 3h-old spool expired under 1h retention" "$R5/DK2D-EVIDENCE-B"

echo "T6: custom patterns via env replace defaults"
R6="$TMP_ROOT/r6"; mkdir -p "$R6"
spool "$R6" "MYEVID-run1" old
spool "$R6" "MYEVID-run2" old
spool "$R6" "DK2D-EVIDENCE-OLD" old
O6="$TMP_ROOT/o6"
run_sweeper "$R6" "$O6" DISK_MAGICIAN_EVIDENCE_KEEP_COUNT=1 "DISK_MAGICIAN_EVIDENCE_PATTERNS=MYEVID-*" -- --clean; RC6=$?
assert_rc "T6: exits 0" 0 "$RC6"
assert_missing "T6: custom-pattern old spool removed" "$R6/MYEVID-run1"
assert_exists "T6: default-pattern dir untouched when patterns overridden" "$R6/DK2D-EVIDENCE-OLD"

echo "T7: missing evidence root is a clean no-op"
O7="$TMP_ROOT/o7"
run_sweeper "$TMP_ROOT/does-not-exist" "$O7" -- --clean; RC7=$?
assert_rc "T7: exits 0" 0 "$RC7"
assert_contains "T7: logs nothing-to-do" "nothing to do" "$(cat "$O7")"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]

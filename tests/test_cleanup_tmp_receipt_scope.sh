#!/usr/bin/env bash
# test_cleanup_tmp_receipt_scope.sh — a cleanup_tmp --clean run must record
# exactly one terminal receipt, from the shell that began it.
#
# Reproduced 2026-10-30 (disk_magician-p39b) on the PR286 head: cleanup_tmp.sh
# began a cleanup_tmp receipt, then ran C14 inside a nested command substitution
# (`$(scratch_budget_quarantine_remove ...)` -> `$(quarantine_remove ...)`). The
# lease lock scope re-installed the caller's inherited EXIT trap inside that
# subshell, so cleanup_tmp_exit_trap ran there, finished the receipt with
# outcome=success_noop, and the real parent finish failed:
#   ERROR: Cannot finish run_id '...': no active matching run found
# cleanup_tmp then exited 1 on a run that had actually archived an artifact.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/sandbox_env.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-tmp-receipt.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1${2:+ ($2)}"; }

priv="$T/private-tmp"
tmpdir="$T/tmp"
archive="$T/archive"
home="$T/home"
mkdir -p "$priv/pr4242-scratch" "$tmpdir"
mkdir -m 0700 -p "$home"
printf 'x%.0s' {1..2048} > "$priv/pr4242-scratch/payload.bin"
/usr/bin/find "$priv/pr4242-scratch" -exec touch -t 202001010000 {} + 2>/dev/null || \
  find "$priv/pr4242-scratch" -exec touch -t 202001010000 {} +

out="$T/run.out"
env -i HOME="$home" \
  PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" \
  TMPDIR="$T" \
  LARGE_TMP_MIN_KB=1 LARGE_TMP_APPROVED=1 \
  DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
  DISK_MAGICIAN_TEST_SANDBOX="$T" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$priv" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tmpdir" \
  DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$tmpdir" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$archive" \
  bash "$ROOT/scripts/cleanup_tmp.sh" --clean --large >"$out" 2>&1
rc=$?

[[ "$rc" == 0 ]] && ok "cleanup_tmp --clean exits 0" || bad "cleanup_tmp --clean exits 0" "rc=$rc"
if grep -qF "no active matching run found" "$out"; then
  bad "the receipt run survives the whole pass" "parent finish lost the active run"
else
  ok "the receipt run survives the whole pass"
fi
if grep -qF "failed to record cleanup_tmp receipt finish" "$out"; then
  bad "the terminal receipt is recorded" "finish failed"
else
  ok "the terminal receipt is recorded"
fi

receipts="$home/.disk_magician_state/receipts/cleanup_tmp.json"
if [[ -f "$receipts" ]]; then
  ok "receipt file exists"
  [[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("active") or []))' "$receipts")" == 0 ]] && \
    ok "no run is left active after the pass" || bad "no run is left active after the pass"
  last_outcome="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(((d.get("last_terminal") or {}).get("outcome")) or "missing")' "$receipts")"
  [[ "$last_outcome" != "missing" && "$last_outcome" != "error" ]] && \
    ok "the terminal receipt has a non-error outcome ($last_outcome)" || \
    bad "the terminal receipt has a non-error outcome" "outcome=$last_outcome"
else
  bad "receipt file exists" "$receipts"
fi

echo
# A caller requesting an observational policy preview can avoid writing a
# receipt. The flag cannot suppress receipts for a real cleanup.
before_receipt="$T/before-receipt.json"
cp "$receipts" "$before_receipt"
for mode in --dry-run --clean; do
  env -i HOME="$home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" TMPDIR="$T" \
    DISK_MAGICIAN_TEST_CONTEXT="$DISK_MAGICIAN_TEST_CONTEXT" \
    DISK_MAGICIAN_TEST_SANDBOX="$T" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$priv" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$tmpdir" \
    DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$tmpdir" DISK_MAGICIAN_ARCHIVE_ROOT="$archive" \
    bash "$ROOT/scripts/cleanup_tmp.sh" "$mode" --no-job-receipt >"$out" 2>&1
  rc=$?
  if [[ "$mode" == --dry-run ]]; then
    [[ "$rc" == 0 ]] && ok "receipt-free dry run succeeds" || bad "receipt-free dry run succeeds" "rc=$rc"
  else
    [[ "$rc" == 2 ]] && ok "clean cannot opt out of receipts" || bad "clean cannot opt out of receipts" "rc=$rc"
  fi
  cmp -s "$before_receipt" "$receipts" && ok "$mode leaves the prior receipt intact" || bad "$mode leaves the prior receipt intact"
done

echo "test_cleanup_tmp_receipt_scope: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]

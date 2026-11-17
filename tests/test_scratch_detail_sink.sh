#!/usr/bin/env bash
# Scheduled runs send per-file detail rows to a per-run file, not stdout (journal flood, 2026-11-12).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/detail-sink.XXXXXX")" || exit 2
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
pass=0 fail=0
check() { if [[ "$2" == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1" >&2; fi; }
setup="$(sed -n '/^DETAIL_FILE=""$/,/^fi$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
definition="$(sed -n '/^report_candidate_detail() {$/,/^}$/p' "$ROOT/scripts/cleanup_scratch_top_level.sh")"
[[ -n "$setup" && -n "$definition" ]] || { echo 'detail sink code absent' >&2; exit 2; }
eval "$definition"
DETAIL_MIB=100
mkdir -p "$T/artifact/a" "$T/artifact/b"
truncate -s 150M "$T/artifact/a/one"
truncate -s 150M "$T/artifact/b/two"
kb="$(du -sk "$T/artifact" | awk '{print $1}')"

run_case() {  # <automatic> <trigger or -> <detail mode or -> <state dir>
  (
    SCRATCH_AUTOMATIC="$1"
    if [[ "$2" == - ]]; then unset DISK_MAGICIAN_TRIGGER; else DISK_MAGICIAN_TRIGGER="$2"; fi
    if [[ "$3" == - ]]; then unset DISK_MAGICIAN_SCRATCH_DETAIL; else DISK_MAGICIAN_SCRATCH_DETAIL="$3"; fi
    DISK_MAGICIAN_STATE_DIR="$4"
    eval "$setup"
    report_candidate_detail "$T/artifact" "$kb"
  )
}
rows_in() { grep -c '^detail:F' <<<"$1"; }

out="$(run_case 0 - - "$T/s1")"
check "interactive prints detail rows" "$([[ "$(rows_in "$out")" -eq 2 ]] && echo 1)"
check "interactive writes no file" "$([[ ! -e "$T/s1/scratch_detail/latest.txt" ]] && echo 1)"

out="$(run_case 0 timer - "$T/s2")"
check "scheduled prints no detail rows" "$([[ "$(rows_in "$out")" -eq 0 ]] && echo 1)"
check "scheduled prints one summary" "$([[ "$(grep -c "^detail-summary: rows=2 file=$T/s2/scratch_detail/latest.txt $T/artifact\$" <<<"$out")" -eq 1 ]] && echo 1)"
check "scheduled file holds rows" "$([[ "$(grep -c '^detail:F' "$T/s2/scratch_detail/latest.txt")" -eq 2 ]] && echo 1)"

out="$(run_case 1 - - "$T/s2")"
check "automatic routes to file" "$([[ "$(rows_in "$out")" -eq 0 ]] && echo 1)"
check "new run truncates file" "$([[ "$(grep -c '^detail:F' "$T/s2/scratch_detail/latest.txt")" -eq 2 ]] && echo 1)"

out="$(run_case 1 timer stdout "$T/s3")"
check "stdout opt-out prints rows" "$([[ "$(rows_in "$out")" -eq 2 ]] && echo 1)"

mkdir -p "$T/ro"
chmod 0500 "$T/ro"
out="$(run_case 1 timer - "$T/ro/x")"
chmod 0700 "$T/ro"
check "unwritable state falls back to stdout" "$([[ "$(rows_in "$out")" -eq 2 ]] && echo 1)"

echo "PASS=$pass FAIL=$fail"
(( fail == 0 ))

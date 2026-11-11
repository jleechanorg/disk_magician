#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/scratch_budget.sh"
: "${TMPDIR:?admitted Scratch TMPDIR required}"
T="$(mktemp -d "$TMPDIR/scratch-measure-batch.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir "$T/bin" "$T/flat"
REAL_STAT="$(command -v stat)"
REAL_PYTHON="$(command -v python3)"
cat >"$T/bin/stat" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$STAT_INVOKE_TRACE"
exec "$REAL_STAT" "$@"
SH
chmod +x "$T/bin/stat"
cat >"$T/bin/python3" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$PYTHON_INVOKE_TRACE"
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$T/bin/python3"
python3 -c 'from pathlib import Path; import sys; root=Path(sys.argv[1]); data=b"x"*2048; [(root / ("f%04d.bin" % i)).write_bytes(data) for i in range(1000)]' "$T/flat"
STAT_INVOKE_TRACE="$T/stat.calls" REAL_STAT="$REAL_STAT" \
  PYTHON_INVOKE_TRACE="$T/python.calls" REAL_PYTHON="$REAL_PYTHON" \
  PATH="$T/bin:$PATH" scratch_budget_measure_files "$T/flat" 1 >"$T/rows"; rc=$?
summary="$(awk -F '\t' '$4 == "F" { files++; bytes += $1 } $4 == "E" { errors++ } END { printf "%d %0.f %d", files, bytes, errors }' "$T/rows")"
stat_calls="$(wc -l <"$T/stat.calls" | tr -d ' ')"
python_calls="$(wc -l <"$T/python.calls" | tr -d ' ')"
printf 'rows=%s stat_processes=%s python_processes=%s rc=%s\n' "$summary" "$stat_calls" "$python_calls" "$rc"
if [[ "$summary" == "1000 2048000 0" && "$rc" -eq 0 && "$stat_calls" -le 2 && "$python_calls" -le 10 ]]; then
  ok 'flat file rows and apparent bytes are preserved with bounded stat process fanout'
else
  bad 'flat file measurement changed rows or still spawns stat per leaf'
fi

eval "$(declare -f _dm_mf_list | sed '1s/_dm_mf_list/_batch_original_list/')"
_dm_mf_list() {
  _batch_original_list "$@" || return $?
  rm -f "$T/flat/f0000.bin"
}
scratch_budget_measure_files "$T/flat" 1 >"$T/missing.rows" 2>"$T/missing.err"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -Fqx "$(printf '0\t0\t0\tE\t%s' "$T/flat/f0000.bin")" "$T/missing.rows"; then
  ok 'a file disappearing after enumeration remains explicitly unmeasured'
else
  bad 'a missing file was counted or lost its error row'
fi

_dm_mf_list() {
  _batch_original_list "$@" || return $?
  ACT_DEADLINE_AT="$(python3 -c 'import time; print(time.monotonic() - 1)')"
}
scratch_budget_measure_files "$T/flat" 1 >"$T/deadline.rows" 2>"$T/deadline.err"; rc=$?
if [[ "$rc" -eq 124 ]] && grep -q $'\tE\t' "$T/deadline.rows" && ! grep -q $'\tF\t' "$T/deadline.rows"; then
  ok 'deadline after enumeration returns unknown rows rather than a complete batch'
else
  bad 'expired batch deadline was hidden or reported complete file rows'
fi
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
